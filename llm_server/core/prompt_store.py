"""提示词仓库：扫描 ``prompts/*.md``、解析 front-matter、热更新（S-07 / S-08 / S-09）。

**唯一真相源是 md 文件里的 front-matter**，``index.yaml`` 只声明
``task → file`` 映射（含 ``T5.detect`` 这类变体键）；两边不一致时以 md 为准，
只在启动日志里打 WARN。

文件格式见 ``prompts/README.md``，正文必须是且仅是 ``# SYSTEM`` 与 ``# USER``
两个一级标题。
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

import yaml

from core.errors import LlmError
from core.logging import get_logger

_log = get_logger('prompt')

_ROOT = Path(__file__).resolve().parent.parent
#: 默认提示词目录
DEFAULT_DIR = _ROOT / 'prompts'

_PLACEHOLDER_RE = re.compile(r'\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}')

#: front-matter 必填字段
_REQUIRED_FIELDS = ('task', 'structured', 'json_output', 'temperature', 'max_tokens', 'inputs')


@dataclass(frozen=True)
class PromptMeta:
    """一个提示词文件的元信息 + 正文。"""

    task: str
    variant: str | None
    structured: bool
    json_output: bool
    temperature: float
    max_tokens: int
    inputs: tuple[str, ...]
    output_key: str | None
    preferred_backend: str | None
    path: Path
    system: str
    user: str
    mtime: float
    size: int
    sha1: str

    # ---------- 派生 ----------

    @property
    def file_name(self) -> str:
        return self.path.name

    @property
    def key(self) -> tuple[str, str | None]:
        return (self.task, self.variant)

    @property
    def placeholders(self) -> tuple[str, ...]:
        """正文里出现的 ``{{name}}`` 占位符（按出现顺序去重）。"""
        seen: dict[str, None] = {}
        for name in _PLACEHOLDER_RE.findall(self.user):
            seen.setdefault(name, None)
        for name in _PLACEHOLDER_RE.findall(self.system):
            seen.setdefault(name, None)
        return tuple(seen)

    @property
    def placeholders_mismatch(self) -> bool:
        """占位符与 ``inputs[]`` 是否一一对应（多一个 / 少一个都算错）。"""
        return set(self.placeholders) != set(self.inputs)

    def render(self, values: Mapping[str, Any]) -> list[dict[str, str]]:
        """渲染出 messages（**纯字符串替换**，不做 HTML 转义、不递归）。

        未知占位符保持原样（不报错）—— 提示词里可能出现 ``{{}}`` 这类示例文本，
        强行报错会让正常提示词加载失败。
        """
        merged: dict[str, str] = {}
        for name in self.placeholders:
            value = values.get(name)
            merged[name] = '' if value is None else str(value)

        def _sub(text: str) -> str:
            if not text:
                return text
            out = text
            for name, value in merged.items():
                out = re.sub(r'\{\{\s*' + re.escape(name) + r'\s*\}\}', _escape_repl(value), out)
            return out

        messages: list[dict[str, str]] = []
        if self.system.strip():
            messages.append({'role': 'system', 'content': _sub(self.system).strip()})
        messages.append({'role': 'user', 'content': _sub(self.user).strip()})
        return messages

    def to_info(self) -> dict[str, Any]:
        """``GET /v1/prompts`` 用的摘要。"""
        return {
            'task': self.task,
            'variant': self.variant,
            'file': self.file_name,
            'mtime': self.mtime,
            'size': self.size,
            'sha1': self.sha1,
            'structured': self.structured,
            'json_output': self.json_output,
            'temperature': self.temperature,
            'max_tokens': self.max_tokens,
            'output_key': self.output_key,
            'inputs': list(self.inputs),
            'preferred_backend': self.preferred_backend,
            'placeholders': list(self.placeholders),
            'placeholders_mismatch': self.placeholders_mismatch,
        }


def _escape_repl(value: str) -> str:
    """``re.sub`` 的替换串里 ``\\`` 与 ``\\g`` 需要转义。"""
    return value.replace('\\', '\\\\').replace('\\g', '\\\\g')


def _split_front_matter(text: str) -> tuple[dict[str, Any], str]:
    """拆 front-matter 与正文；没有 front-matter 返回 ``({}, 原文)``。"""
    if not text.startswith('---'):
        return {}, text
    lines = text.splitlines()
    if not lines or lines[0].strip() != '---':
        return {}, text
    end = -1
    for i in range(1, len(lines)):
        if lines[i].strip() == '---':
            end = i
            break
    if end == -1:
        return {}, text
    raw_fm = '\n'.join(lines[1:end])
    body = '\n'.join(lines[end + 1 :])
    parsed = yaml.safe_load(raw_fm) or {}
    if not isinstance(parsed, dict):
        raise ValueError('front-matter 不是 mapping')
    return parsed, body


def _split_sections(body: str) -> tuple[str, str]:
    """按行首 ``# SYSTEM`` / ``# USER`` 切分正文（大小写敏感）。"""
    system_lines: list[str] = []
    user_lines: list[str] = []
    current: list[str] | None = None
    for line in body.splitlines():
        stripped = line.strip()
        if stripped == '# SYSTEM':
            current = system_lines
            continue
        if stripped == '# USER':
            current = user_lines
            continue
        if current is not None:
            current.append(line)
    return '\n'.join(system_lines).strip(), '\n'.join(user_lines).strip()


class PromptStore:
    """提示词目录的读写与热更新。"""

    def __init__(self, directory: Path | str | None = None) -> None:
        self.dir = Path(directory) if directory else DEFAULT_DIR
        self.index_path = self.dir / 'index.yaml'
        self._by_key: dict[tuple[str, str | None], PromptMeta] = {}
        self._index: dict[str, str] = {}
        self.errors: list[str] = []
        self.skipped: list[str] = []
        self.load()

    # ---------- 加载 ----------

    def load(self) -> tuple[int, list[str], list[str]]:
        """扫描目录。返回 ``(loaded, skipped, errors)``。"""
        self._by_key = {}
        self.errors = []
        self.skipped = []
        self._index = self._load_index()

        if not self.dir.is_dir():
            self.errors.append(f'提示词目录不存在：{self.dir}')
            _log.error('提示词目录不存在：%s', self.dir)
            return 0, self.skipped, self.errors

        for path in sorted(self.dir.glob('*.md')):
            if path.name.lower() == 'readme.md':
                self.skipped.append(path.name)
                continue
            try:
                meta = self._parse_file(path)
            except Exception as exc:
                self.errors.append(f'{path.name}: {exc}')
                _log.error('提示词 %s 解析失败：%s', path.name, exc)
                continue
            if meta.key in self._by_key:
                self.errors.append(f'{path.name}: 与已加载提示词冲突（task={meta.task}, variant={meta.variant}）')
                continue
            self._by_key[meta.key] = meta
            self._check_index(meta)
            if meta.placeholders_mismatch:
                _log.warning(
                    '%s 占位符 %s 与 inputs %s 不一致',
                    path.name,
                    list(meta.placeholders),
                    list(meta.inputs),
                )

        _log.info('提示词已加载 %d 个（跳过 %d，错误 %d）', len(self._by_key), len(self.skipped), len(self.errors))
        return len(self._by_key), self.skipped, self.errors

    def reload(self) -> tuple[int, list[str], list[str]]:
        """重扫目录（``POST /v1/prompts/reload``）。"""
        return self.load()

    def _load_index(self) -> dict[str, str]:
        """``index.yaml``：``T1: t1_extract.md`` / ``T5.detect: t5_ask__detect.md``。"""
        try:
            if not self.index_path.is_file():
                return {}
            parsed = yaml.safe_load(self.index_path.read_text(encoding='utf-8')) or {}
            if not isinstance(parsed, dict):
                return {}
            return {str(k): str(v) for k, v in parsed.items() if isinstance(v, (str, int, float))}
        except Exception as exc:
            _log.warning('index.yaml 解析失败（%s），退化为按 front-matter 匹配', exc)
            return {}

    def _check_index(self, meta: PromptMeta) -> None:
        """index 与 front-matter 不一致时打 WARN（**以 md 为准**）。"""
        key = meta.task if not meta.variant else f'{meta.task}.{meta.variant}'
        expected = self._index.get(key)
        if expected and expected != meta.file_name:
            _log.warning(
                'index.yaml 与 front-matter 不一致：%s 声明 %s，实际文件 %s（以文件为准）',
                key,
                expected,
                meta.file_name,
            )

    def _parse_file(self, path: Path) -> PromptMeta:
        text = path.read_text(encoding='utf-8')
        front, body = _split_front_matter(text)
        if not front:
            raise ValueError('缺少 front-matter（文件必须以 --- 开头）')
        missing = [f for f in _REQUIRED_FIELDS if f not in front]
        if missing:
            raise ValueError(f'front-matter 缺少字段：{", ".join(missing)}')

        task = str(front['task']).strip().upper()
        if not task:
            raise ValueError('front-matter 的 task 为空')
        raw_variant = front.get('variant')
        variant = str(raw_variant).strip().lower() if raw_variant not in (None, '', 'null') else None

        inputs_raw = front.get('inputs') or []
        if not isinstance(inputs_raw, (list, tuple)):
            raise ValueError('front-matter 的 inputs 必须是列表')
        inputs = tuple(str(x) for x in inputs_raw)

        system, user = _split_sections(body)
        if not user and not system:
            raise ValueError('正文缺少 # SYSTEM / # USER 两节')

        stat = path.stat()
        return PromptMeta(
            task=task,
            variant=variant,
            structured=bool(front.get('structured', False)),
            json_output=bool(front.get('json_output', False)),
            temperature=float(front.get('temperature', 0.2)),
            max_tokens=int(front.get('max_tokens', 4096)),
            inputs=inputs,
            output_key=(str(front['output_key']) if front.get('output_key') else None),
            preferred_backend=(
                str(front['preferred_backend']) if front.get('preferred_backend') else None
            ),
            path=path,
            system=system,
            user=user,
            mtime=stat.st_mtime,
            size=stat.st_size,
            sha1=hashlib.sha1(text.encode('utf-8')).hexdigest(),
        )

    # ---------- 查询 ----------

    def get(self, task: str, variant: str | None = None) -> PromptMeta:
        """取提示词；不存在抛 ``unknown_task``。"""
        key_task = str(task or '').strip().upper()
        key_variant = variant.strip().lower() if variant else None
        meta = self._by_key.get((key_task, key_variant))
        if meta is None and key_variant is None:
            # 容错：主形态的 variant 有时被写成 'main' / 'default'
            for (t, v), m in self._by_key.items():
                if t == key_task and v in (None, '', 'main', 'default'):
                    return m
        if meta is None:
            raise LlmError(
                'unknown_task',
                f'未知任务代码：{task}'
                + (f'（variant={variant}）' if variant else '')
                + f'（已加载 {len(self._by_key)} 个提示词，见 GET /v1/prompts）',
            )
        return meta

    def list(self) -> list[PromptMeta]:
        """全部提示词，按 (task, variant) 排序。"""
        return sorted(self._by_key.values(), key=lambda m: (m.task, m.variant or ''))

    def count(self) -> int:
        return len(self._by_key)

    def save(self, task: str, variant: str | None, content: str) -> Path:
        """写回文件（``PUT /v1/prompts/{task}``）。

        优先写到已存在的文件；不存在时按命名规范新建
        ``<task 小写>_<英文名>.md``（英文名取 index 里的文件名，否则用 task 小写）。
        """
        try:
            meta = self.get(task, variant)
            path = meta.path
        except LlmError:
            key = task if not variant else f'{task}.{variant}'
            name = self._index.get(key) or f'{str(task).lower()}.md'
            path = self.dir / name
        if not self.dir.is_dir():
            self.dir.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')
        _log.info('提示词已写回：%s', path.name)
        return path
