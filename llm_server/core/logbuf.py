"""进程内运行日志缓冲（管理后台 M7「运行日志」的数据源）。

与 ``core/stats.py`` 同构的设计约束：

- **环形缓冲**：``deque(maxlen=MAX_ENTRIES)`` 天然不会内存膨胀；
- **永不抛异常**：``emit()`` 整段包裹 ``try/except`` —— 日志绝不能把业务请求搞挂；
- **线程安全**：一把 ``threading.Lock`` 保护「写」与「查询」；
- **单条消息截断**：``MAX_MESSAGE_CHARS`` 防止 verbose 模式的完整 prompt/response
  把缓冲撑爆（查看全文请开服务端 ``--verbose`` 看 stdout）。

安装方式：``core.logging.setup()`` 会把 [LogBufferHandler] 挂到根 logger
（幂等：先摘掉已存在的同名 handler，避免重复 addHandler 导致日志翻倍）。

安全边界：缓冲里只有**日志消息文本**——服务端约定永不记录密钥明文
（配置只记「已保存」、密钥只出掩码），因此本模块不存在密钥外泄面；
管理后台与本服务同在本机（127.0.0.1），与其余 ``/v1/admin/*`` 端点同信任级。
"""

from __future__ import annotations

import logging
import threading
import time
from collections import deque
from typing import Any

#: 环形缓冲容量（进程内，不落盘）。
MAX_ENTRIES = 1000

#: 单条消息最大字符数（超出截断；verbose 全文请到 stdout 看）。
MAX_MESSAGE_CHARS = 4000

#: 查询接口暴露的级别（含临界，便于按严重度过滤）。
LEVELS = ('DEBUG', 'INFO', 'WARNING', 'ERROR')

#: 级别 → 严重度数（与 logging 模块一致）。
_LEVEL_NO = {
    'DEBUG': logging.DEBUG,
    'INFO': logging.INFO,
    'WARNING': logging.WARNING,
    'ERROR': logging.ERROR,
}

_lock = threading.Lock()
_buf: deque[dict[str, Any]] = deque(maxlen=MAX_ENTRIES)
_SEQ = 0
_DROPPED = 0


class LogBufferHandler(logging.Handler):
    """把日志记录抄送进环形缓冲的 handler。

    挂在根 logger 上；``emit`` 永不抛（logging 框架会吞掉 handler 异常并
    打印 ``--- Logging error ---``，但我们要连那个都不出现）。
    """

    def emit(self, record: logging.LogRecord) -> None:
        try:
            message = self.format(record)
            if len(message) > MAX_MESSAGE_CHARS:
                message = message[:MAX_MESSAGE_CHARS] + '…（已截断）'
            append(
                level=str(record.levelname or 'INFO').upper(),
                module=str(record.name or ''),
                message=message,
            )
        except Exception:  # noqa: BLE001 - 日志绝不能影响业务
            pass


def append(level: str, module: str, message: str) -> None:
    """直接写一条（不经过 logging，供测试 / 非 logger 场景使用）。永不抛。"""
    global _SEQ, _DROPPED
    try:
        name = str(level or 'INFO').upper()
        if name not in _LEVEL_NO:
            name = 'INFO'
        with _lock:
            _SEQ += 1
            _buf.append(
                {
                    'seq': _SEQ,
                    'ts': time.time(),
                    'level': name,
                    'module': str(module or ''),
                    'message': str(message or ''),
                }
            )
            if len(_buf) == MAX_ENTRIES:
                _DROPPED += 1
    except Exception:  # noqa: BLE001
        pass


def _normalize_module(module: str | None) -> str | None:
    """``task`` → ``llmserver.task``；已带前缀或空值原样返回。"""
    name = (module or '').strip()
    if not name:
        return None
    if not name.startswith('llmserver.'):
        name = f'llmserver.{name}'
    return name


def query(
    level: str | None = None,
    module: str | None = None,
    q: str | None = None,
    limit: int = 100,
    before_seq: int | None = None,
) -> dict[str, Any]:
    """按条件查日志（**新的在前**）。

    Args:
        level: 最低级别（DEBUG/INFO/WARNING/ERROR）；None = 不限。
        module: 模块名，``task`` 或 ``llmserver.task`` 均可（前缀精确匹配）。
        q: 消息关键字（大小写不敏感的子串）。
        limit: 返回条数（1..500，默认 100）。
        before_seq: 游标——只返回 ``seq < before_seq`` 的（「加载更早」用）。

    Returns:
        ``items`` / ``matched`` / ``buffer_size`` / ``since_startup`` /
        ``dropped`` / ``levels`` / ``next_cursor``。
    """
    try:
        want = _LEVEL_NO.get((level or '').strip().upper()) if level else None
    except Exception:  # noqa: BLE001
        want = None
    mod = _normalize_module(module)
    keyword = (q or '').strip().lower()[:200]
    try:
        want_limit = int(limit)
    except (TypeError, ValueError):
        want_limit = 100
    want_limit = max(1, min(500, want_limit))
    try:
        cursor = int(before_seq) if before_seq is not None else None
    except (TypeError, ValueError):
        cursor = None

    with _lock:
        entries = list(_buf)
        dropped = _DROPPED
        seq_total = _SEQ

    matched = [
        e
        for e in entries
        if (want is None or _LEVEL_NO.get(e['level'], 99) >= want)
        and (mod is None or e['module'] == mod)
        and (not keyword or keyword in e['message'].lower())
        and (cursor is None or e['seq'] < cursor)
    ]
    matched.reverse()  # 新的在前
    items = matched[:want_limit]
    next_cursor = items[-1]['seq'] if len(matched) > len(items) else None

    level_counts: dict[str, int] = {}
    for e in entries:
        level_counts[e['level']] = level_counts.get(e['level'], 0) + 1

    return {
        'items': items,
        'matched': len(matched),
        'buffer_size': len(entries),
        'since_startup': seq_total,
        'dropped': dropped,
        'levels': level_counts,
        'next_cursor': next_cursor,
    }


def snapshot() -> dict[str, Any]:
    """缓冲概览（不含 items），供概览卡 / 自检。"""
    with _lock:
        entries = list(_buf)
        dropped = _DROPPED
        seq_total = _SEQ
    level_counts: dict[str, int] = {}
    for e in entries:
        level_counts[e['level']] = level_counts.get(e['level'], 0) + 1
    return {
        'buffer_size': len(entries),
        'since_startup': seq_total,
        'dropped': dropped,
        'levels': level_counts,
    }


def reset() -> None:
    """清空缓冲（**仅供测试**）。"""
    global _SEQ, _DROPPED
    with _lock:
        _buf.clear()
        _SEQ = 0
        _DROPPED = 0
