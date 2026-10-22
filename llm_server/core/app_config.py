"""App 运行配置下发（密钥边界 C3 的**唯一出口**）。

**纯函数**：只吃 ``Config``，不碰 ``Request`` / ``Response``，可脱离 FastAPI 单测。

构造方式是「白名单逐字段抄」，**绝不** dump 整个 config，因此在结构上不可能
把 ``api_key`` / Supabase token 带出去（R1 规避措施 ①）。

**唯一例外**是 ``sync.token``（Supabase 同步令牌）：它经本端点明文下发给
App —— 依赖「llm_server 仅绑 127.0.0.1（localhost，无外网暴露）」的安全
假设，详见 :func:`build_app_config` 里 ``sync`` 段的注释（含重评条件）。
"""

from __future__ import annotations

import hashlib
import json
import time
from datetime import datetime
from typing import Any, Mapping

#: 下发 schema 版本（App 只识别 1）。
SCHEMA_VERSION = 1

#: 服务端版本（与 server.VERSION / health.VERSION 三处同源）。
SERVER_VERSION = '0.1.0'

#: 与 App 侧 ``kLlmServerProtocol`` 一致。
APP_PROTOCOL = 'llm_server'

#: 下发字段白名单（**锁死 13 个键**；新增字段必须同步改这里与 App 侧 parse()）。
APP_CONFIG_FIELDS: tuple[str, ...] = (
    'schema',
    'server_version',
    'service_name',
    'protocol',
    'base_url',
    'backend',
    'model',
    'console_url',
    'timeouts',
    'task_backends',
    'sync',
    'config_sha1',
    'updated_at',
)

#: 参与 sha1 的字段（= 全集 减去 自身与展示用时间戳，D8）。
_SHA_FIELDS: tuple[str, ...] = tuple(
    f for f in APP_CONFIG_FIELDS if f not in ('config_sha1', 'updated_at')
)

#: 会被归一成 127.0.0.1 的监听地址（App 侧连本机服务）。
_LOCAL_HOSTS = frozenset({'127.0.0.1', 'localhost', '0.0.0.0', '::1'})

#: 进程启动时刻（settings.json 不存在时的 ``updated_at`` 兜底）。
_STARTED = time.time()


def _derive_base_url(server: Mapping[str, Any]) -> str:
    """由 ``config.server`` 推导出 App 可直连的地址。"""
    host = str(server.get('host') or '127.0.0.1').strip()
    try:
        port = int(server.get('port') or 8787)
    except (TypeError, ValueError):
        port = 8787
    if host in _LOCAL_HOSTS:
        return f'http://127.0.0.1:{port}'
    return f'http://{host}:{port}'


def _task_backends_payload(config: Any) -> dict[str, Any]:
    """``{T1: {'backend': .., 'model': ..} | None}``；``None`` = 跟随全局。"""
    out: dict[str, Any] = {}
    tasks = set(getattr(config, 'task_backends', {}) or {})
    tasks |= set(getattr(config, 'task_models', {}) or {})
    for task in sorted(tasks):
        backend, model = config.task_route(task)
        if not backend and not model:
            out[task] = None
        else:
            out[task] = {'backend': backend, 'model': model}
    return out


def _iso(mtime: float) -> str:
    """epoch 秒 → ISO8601 本地时间（带偏移，秒精度）。"""
    try:
        return datetime.fromtimestamp(float(mtime)).astimezone().isoformat(timespec='seconds')
    except (OSError, OverflowError, ValueError):
        return datetime.fromtimestamp(_STARTED).astimezone().isoformat(timespec='seconds')


def _sync_token(sync: Mapping[str, Any]) -> str:
    """取同步令牌（去首尾空白；空串 = 未设置）。"""
    return str(sync.get('token') or '').strip()


def build_app_config(
    config: Any,
    *,
    server_version: str = SERVER_VERSION,
    updated_at: str | None = None,
    now: float | None = None,
) -> dict[str, Any]:
    """构造 ``GET /v1/app/config`` 的响应体（白名单 13 字段）。

    Args:
        config: ``core.config.Config`` 实例（只读）。
        server_version: 服务端版本，由调用方（router）传入。
        updated_at: 覆盖更新时间（默认取 settings.json 的 mtime）。
        now: 仅供测试注入时间。
    """
    base_url = _derive_base_url(getattr(config, 'server', {}) or {})
    app = dict(getattr(config, 'app', {}) or {})
    sync = dict(getattr(config, 'sync', {}) or {})

    service_name = str(app.get('service_name') or '').strip() or 'AIMindTree AI 服务'
    console_url = str(app.get('console_url') or '').strip() or f'{base_url}/admin'
    backend = str(getattr(config, 'default_backend', '') or '').strip() or 'auto'
    model = str(getattr(config, 'default_model', '') or '').strip()

    try:
        timeouts = dict(config.app_timeouts())
    except Exception:  # noqa: BLE001 - 配置异常时退回代码默认值
        timeouts = {'structured_s': 120, 'chat_s': 120, 'connect_s': 10}

    payload: dict[str, Any] = {
        'schema': SCHEMA_VERSION,
        'server_version': str(server_version or SERVER_VERSION),
        'service_name': service_name,
        'protocol': APP_PROTOCOL,
        'base_url': base_url,
        'backend': backend,
        'model': model,
        'console_url': console_url,
        'timeouts': timeouts,
        'task_backends': _task_backends_payload(config),
        # Q-C：恒返回 object，App 不用判 null。
        # ⚠️ 安全假设（重评记录，2026-10）：llm_server 仅绑 127.0.0.1
        # （localhost，无外网暴露，CORS 也只放行本机源），因此 sync.token
        # （Supabase 同步令牌）随本端点明文下发是可接受的 —— App 需要它
        # 直连 Supabase 做同步。**若服务端将来对非 localhost 暴露，必须
        # 重评此处置**：要么改回只回 token_set（令牌改走其它通道分发），
        # 要么给本端点加鉴权。改这里必须同步 App 侧 parse() 与 selftest。
        'sync': {
            'base_url': str(sync.get('base_url') or '').strip(),
            'enabled': bool(sync.get('enabled', True)),
            'token': _sync_token(sync) or None,
            'token_set': bool(_sync_token(sync)),
        },
    }
    payload['config_sha1'] = config_sha1(payload)
    payload['updated_at'] = updated_at or _iso(
        config.settings_mtime() if hasattr(config, 'settings_mtime') else 0.0
    )
    if now is not None:  # pragma: no cover - 测试注入点
        payload['updated_at'] = _iso(now)
    return payload


def config_sha1(payload: Mapping[str, Any]) -> str:
    """下发内容的 sha1（**排除** ``config_sha1`` 与 ``updated_at``）。"""
    subset = {k: payload.get(k) for k in _SHA_FIELDS}
    text = json.dumps(subset, sort_keys=True, ensure_ascii=False, separators=(',', ':'))
    return hashlib.sha1(text.encode('utf-8')).hexdigest()
