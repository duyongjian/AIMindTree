"""配置加载（config.yaml + .env），支持 mtime 热加载。

设计要点：
- **不引入 python-dotenv**：自己解析 ``.env``（只有 ``KEY=VALUE`` 与 ``#`` 注释），
  依赖清单保持 4 个（fastapi / uvicorn / httpx / pyyaml）。
- **热加载**：每次请求前调 [:meth:`Config.maybe_reload`]，mtime 变了才重读，
  避免每次请求都做磁盘 IO。也可 POST ``/v1/admin/reload`` 强制重载。
- **密钥只在服务端**：``api_key_env`` 只是**环境变量名**，真正的值从
  ``os.environ`` 或 ``.env`` 取，绝不写进日志。
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Mapping

import yaml

from core.errors import LlmError
from core.logging import get_logger

_log = get_logger('config')

_HERE = Path(__file__).resolve().parent
#: ``llm_server/`` 目录
ROOT = _HERE.parent

#: 全部字段的默认值：最小化部署可以只写 ``default_backend``。
DEFAULTS: dict[str, Any] = {
    'server': {
        'host': '127.0.0.1',
        'port': 8787,
        'log_level': 'info',
        'verbose': False,
        'cors_origins': ['http://127.0.0.1', 'http://localhost'],
    },
    'default_backend': 'ollama',
    'task_backends': {},
    'timeouts': {
        'structured_s': 120,
        'chat_s': 120,
        'connect_s': 10,
        'health_s': 5,
    },
    'retry': {
        'structured_on_bad_json': 1,
    },
    'backends': {},
}


@dataclass(frozen=True)
class BackendConf:
    """一个后端（backend）的连接参数。

    注意 **backend ≠ protocol**：backend 是用户在 config 里看到的可切换名字
    （ollama / minimax / openai_compat），protocol 是 HTTP 形态
    （openai_compat / anthropic_compat）。二者解耦，见设计 §2.4。
    """

    name: str = ''
    type: str = ''
    protocol: str = 'openai_compat'
    base_url: str = ''
    api_key_env: str = ''
    default_model: str = ''
    models: tuple[str, ...] = ()
    #: anthropic_compat 协议用的路径（MiniMax 走 /anthropic/v1/messages）
    anthropic_path: str = '/anthropic/v1/messages'
    #: openai_compat 协议用的路径
    openai_path: str = '/v1/chat/completions'
    anthropic_version: str = '2023-06-01'
    #: 探活路径（None = 用协议默认：openai→/v1/models，ollama→/api/tags）
    health_path: str | None = None
    #: 其它透传给协议的参数（如 Ollama 的 num_ctx）
    extra: Mapping[str, Any] = field(default_factory=dict)

    def path_for(self, protocol: str) -> str:
        """按协议取请求路径。"""
        return self.anthropic_path if protocol == 'anthropic_compat' else self.openai_path

    def model(self) -> str:
        """后端默认模型。"""
        return self.default_model or (self.models[0] if self.models else '')


def _deep_merge(base: dict[str, Any], override: Mapping[str, Any]) -> dict[str, Any]:
    """递归合并：override 覆盖 base，dict 递归，其余整体替换。"""
    out = dict(base)
    for key, value in (override or {}).items():
        if isinstance(value, Mapping) and isinstance(out.get(key), dict):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def _load_env(path: Path) -> dict[str, str]:
    """解析 ``.env``：``KEY=VALUE`` 行，``#`` 开头为注释。失败返回空 dict。"""
    env: dict[str, str] = {}
    try:
        if not path.is_file():
            return env
        for line in path.read_text(encoding='utf-8').splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            key, _, value = line.partition('=')
            env[key.strip()] = value.strip().strip('"').strip("'")
    except OSError as exc:  # pragma: no cover - 权限等极端情况
        _log.warning('读取 .env 失败：%s', exc)
    return env


class Config:
    """运行时配置（可变单例，靠 mtime 热加载）。"""

    def __init__(self, config_path: Path | None = None) -> None:
        self.path: Path = Path(config_path) if config_path else ROOT / 'config.yaml'
        self.env_path: Path = self.path.parent / '.env'
        self.server: dict[str, Any] = dict(DEFAULTS['server'])
        self.default_backend: str = str(DEFAULTS['default_backend'])
        self.task_backends: dict[str, str] = {}
        self.timeouts: dict[str, Any] = dict(DEFAULTS['timeouts'])
        self.retry: dict[str, Any] = dict(DEFAULTS['retry'])
        self.backends: dict[str, BackendConf] = {}
        #: 顶层默认模型（管理后台用）；来自默认后端的 default_model，可能被 settings 覆盖。
        self.default_model: str = ''
        #: settings.json 覆盖层（运行时可调、持久化到 llm_server/settings.json，不碰 config.yaml）
        self._settings: dict[str, Any] = {}
        self._settings_api_keys: dict[str, str] = {}
        self._settings_mtime: float = 0.0
        self._settings_path: Path = self.path.parent / 'settings.json'
        self._env: dict[str, str] = {}
        self._mtime: float = 0.0
        self._env_mtime: float = 0.0
        self.load()

    # ---------- 加载 ----------

    def load(self) -> None:
        """（重新）读取 config.yaml 与 .env。"""
        raw: dict[str, Any] = {}
        try:
            if self.path.is_file():
                text = self.path.read_text(encoding='utf-8')
                parsed = yaml.safe_load(text) or {}
                if not isinstance(parsed, dict):
                    raise ValueError('config.yaml 顶层必须是 mapping')
                raw = parsed
            else:
                _log.warning('config.yaml 不存在（%s），全部使用默认值', self.path)
        except Exception as exc:
            _log.error('config.yaml 解析失败（%s），回退默认值：%s', self.path, exc)
            raw = {}

        merged = _deep_merge(DEFAULTS, raw)
        self.server = dict(merged.get('server') or DEFAULTS['server'])
        self.default_backend = str(merged.get('default_backend') or 'ollama')
        self.task_backends = {
            str(k).upper(): str(v) for k, v in (merged.get('task_backends') or {}).items()
        }
        self.timeouts = _deep_merge(DEFAULTS['timeouts'], merged.get('timeouts') or {})
        self.retry = _deep_merge(DEFAULTS['retry'], merged.get('retry') or {})

        backends: dict[str, BackendConf] = {}
        for name, conf in (merged.get('backends') or {}).items():
            if not isinstance(conf, Mapping):
                _log.warning('后端 %s 配置不是 mapping，已跳过', name)
                continue
            known = {
                'type',
                'protocol',
                'base_url',
                'api_key_env',
                'default_model',
                'models',
                'anthropic_path',
                'openai_path',
                'anthropic_version',
                'health_path',
                'extra',
            }
            extra = dict(conf.get('extra') or {})
            extra.update({k: v for k, v in conf.items() if k not in known})
            backends[str(name)] = BackendConf(
                name=str(name),
                type=str(conf.get('type') or name),
                protocol=str(conf.get('protocol') or 'openai_compat'),
                base_url=str(conf.get('base_url') or ''),
                api_key_env=str(conf.get('api_key_env') or ''),
                default_model=str(conf.get('default_model') or ''),
                models=tuple(str(m) for m in (conf.get('models') or [])),
                anthropic_path=str(conf.get('anthropic_path') or '/anthropic/v1/messages'),
                openai_path=str(conf.get('openai_path') or '/v1/chat/completions'),
                anthropic_version=str(conf.get('anthropic_version') or '2023-06-01'),
                health_path=(
                    str(conf['health_path']) if conf.get('health_path') else None
                ),
                extra=extra,
            )
        self.backends = backends

        # 顶层默认模型：默认取「默认后端」的 default_model，
        # 随后 _load_settings 可能被 settings.json 覆盖。
        if self.default_backend in self.backends:
            self.default_model = self.backends[self.default_backend].default_model
        else:
            self.default_model = ''

        self._load_settings()

        self._env = _load_env(self.env_path)
        try:
            self._mtime = self.path.stat().st_mtime if self.path.is_file() else 0.0
            self._env_mtime = self.env_path.stat().st_mtime if self.env_path.is_file() else 0.0
        except OSError:  # pragma: no cover
            self._mtime = self._env_mtime = 0.0

        _log.info(
            '配置已加载：%s（默认后端=%s，后端=%s，提示词目录=%s）',
            self.path.name,
            self.default_backend,
            '/'.join(sorted(self.backends)) or '(无)',
            ROOT / 'prompts',
        )

    def maybe_reload(self) -> bool:
        """mtime 变了才重载；返回是否真的重载了（含 config.yaml / .env / settings.json）。"""
        try:
            mtime = self.path.stat().st_mtime if self.path.is_file() else 0.0
            env_mtime = self.env_path.stat().st_mtime if self.env_path.is_file() else 0.0
            settings_mtime = (
                self._settings_path.stat().st_mtime if self._settings_path.is_file() else 0.0
            )
        except OSError:
            return False
        if (
            mtime != self._mtime
            or env_mtime != self._env_mtime
            or settings_mtime != self._settings_mtime
        ):
            self.load()
            return True
        return False

    # ---------- 查询 ----------

    def backend(self, name: str | None = None) -> BackendConf:
        """取后端配置；未知 / 缺失抛 ``backend_unknown``。"""
        target = (name or self.default_backend or '').strip()
        conf = self.backends.get(target)
        if conf is None:
            raise LlmError(
                'backend_unknown',
                f'未配置的后端：{target or "(空)"}'
                f'（可用：{" / ".join(sorted(self.backends)) or "(无)"}）',
            )
        return conf

    def timeout(self, kind: str, default: float = 120.0) -> float:
        """取超时秒数（``structured_s`` / ``chat_s`` / ``connect_s`` / ``health_s``）。"""
        try:
            return float(self.timeouts.get(kind, default))
        except (TypeError, ValueError):
            return default

    # ---------- 运行时 settings 覆盖层 ----------

    def _load_settings(self) -> None:
        """读取 ``settings.json`` 覆盖层并合并。

        覆盖优先级：**settings.json > config.yaml > 代码默认值**。
        只影响：默认后端 / 默认模型 / 各后端 api_key / minimax 协议。
        """
        path = self._settings_path
        raw: dict[str, Any] = {}
        if path.is_file():
            try:
                parsed = json.loads(path.read_text(encoding='utf-8'))
                raw = parsed if isinstance(parsed, dict) else {}
            except Exception as exc:  # noqa: BLE001 - 坏文件不影响启动
                _log.warning('settings.json 解析失败（%s），忽略覆盖层：%s', path, exc)
                raw = {}
        self._settings = raw
        self._settings_api_keys = {}

        # 默认后端覆盖（务必在 default_model / protocol 覆盖之前，保证落到正确后端）
        db = raw.get('default_backend')
        if isinstance(db, str) and db in self.backends:
            self.default_backend = db

        # 默认模型覆盖（落到当前默认后端）
        dm = raw.get('default_model')
        if isinstance(dm, str) and dm:
            self._apply_default_model(dm)

        # 各后端 api_key 覆盖
        bk = raw.get('backends')
        if isinstance(bk, dict):
            for name, sub in bk.items():
                if isinstance(sub, dict) and isinstance(sub.get('api_key'), str) and sub['api_key']:
                    self._settings_api_keys[str(name)] = sub['api_key']

        # minimax 协议覆盖
        mp = raw.get('minimax_protocol')
        if isinstance(mp, str) and mp in ('openai_compat', 'anthropic_compat'):
            if 'minimax' in self.backends:
                self._apply_backend_protocol(self.backends, 'minimax', mp)

        try:
            self._settings_mtime = path.stat().st_mtime if path.is_file() else 0.0
        except OSError:  # pragma: no cover
            self._settings_mtime = 0.0

    def _apply_default_model(self, model: str) -> None:
        """把默认模型写到「当前默认后端」的配置里（保持 ``conf.model()`` 一致）。"""
        self.default_model = model
        if self.default_backend in self.backends:
            self.backends[self.default_backend] = replace(
                self.backends[self.default_backend], default_model=model
            )

    @staticmethod
    def _apply_backend_protocol(backends: dict[str, BackendConf], name: str, protocol: str) -> None:
        """覆盖某后端的协议（dataclass 不可变，用 ``replace`` 重建）。"""
        conf = backends.get(name)
        if conf is not None:
            backends[name] = replace(conf, protocol=protocol)

    def save_settings(self, data: dict[str, Any] | None = None) -> dict[str, Any]:
        """把覆盖层持久化到 ``llm_server/settings.json``（**不写** config.yaml）。

        Args:
            data: 规范化后的覆盖层，允许字段：
                ``default_backend`` / ``default_model`` / ``minimax_protocol`` /
                ``backends: {name: {api_key}}``。
                只持久化这些字段，且与已有 settings.json **合并**（不整体覆盖）。

        Returns:
            合并后写入磁盘的 settings 字典。
        """
        data = data or {}
        existing: dict[str, Any] = {}
        if self._settings_path.is_file():
            try:
                parsed = json.loads(self._settings_path.read_text(encoding='utf-8'))
                existing = parsed if isinstance(parsed, dict) else {}
            except Exception:  # noqa: BLE001
                existing = {}
        if not isinstance(existing, dict):
            existing = {}

        out: dict[str, Any] = dict(existing)
        if isinstance(data.get('default_backend'), str) and data['default_backend']:
            out['default_backend'] = data['default_backend']
        if isinstance(data.get('default_model'), str) and data['default_model']:
            out['default_model'] = data['default_model']
        if isinstance(data.get('minimax_protocol'), str) and data['minimax_protocol']:
            out['minimax_protocol'] = data['minimax_protocol']
        if isinstance(data.get('backends'), dict):
            merged_backends: dict[str, Any] = dict(out.get('backends') or {})
            for name, sub in data['backends'].items():
                if isinstance(sub, dict) and 'api_key' in sub:
                    cur = dict(merged_backends.get(str(name)) or {})
                    cur['api_key'] = sub['api_key']
                    merged_backends[str(name)] = cur
            out['backends'] = merged_backends

        self._settings_path.write_text(
            json.dumps(out, ensure_ascii=False, indent=2) + '\n', encoding='utf-8'
        )
        _log.info(
            '已写入 settings.json（默认后端=%s，默认模型=%s）',
            out.get('default_backend'),
            out.get('default_model'),
        )
        return out

    def resolve_api_key(self, conf: BackendConf) -> str:
        """解析后端密钥：settings.json 的 per-backend 覆盖 > 进程环境变量 > ``.env``。

        查找顺序：settings.json 覆盖 → 进程环境变量 → ``.env`` 文件。都没有返回空串
        （本地后端如 Ollama 不需要密钥，不报错）。
        """
        override = self._settings_api_keys.get(conf.name)
        if override:
            return override.strip()
        if not conf.api_key_env:
            return ''
        value = os.environ.get(conf.api_key_env) or self._env.get(conf.api_key_env) or ''
        return value.strip()

    def mask(self, secret: str) -> str:
        """日志用的掩码（绝不打印完整密钥）。"""
        if not secret:
            return '(空)'
        return f'{secret[:4]}…{secret[-2:]}(len={len(secret)})'
