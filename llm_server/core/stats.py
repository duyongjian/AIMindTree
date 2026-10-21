"""进程内调用统计（环形缓冲，不落盘、不引入存储依赖）。

并发安全：``deque.append`` 单操作线程安全，但 ``snapshot()`` 要遍历，
因此统一用一把 ``threading.Lock`` 保护「写」与「快照」。

设计约束（AC-07 / AC-08）：

- ``record()`` **永不抛异常**（统计绝不能把业务请求搞挂），函数体整段包裹
  ``try/except Exception``；
- 容量固定 ``MAX_ENTRIES = 500``（``deque(maxlen=...)`` 天然不会内存膨胀）；
- 空缓冲时 ``by_task`` / ``by_backend`` / ``slowest`` 返回 ``[]``，
  ``last_error`` 返回 ``None``（**不返回 null 数组**，AC-08）。
"""

from __future__ import annotations

import threading
import time
from collections import deque
from typing import Any

#: 环形缓冲容量（进程内，不落盘）。
MAX_ENTRIES = 500

#: 允许的调用类型。
KINDS = ('task', 'chat')

#: 12 个归一化错误码（与 core/errors.py 一致）；不在其中的一律记为 internal。
ERROR_CODES = (
    'unknown_task',
    'missing_input',
    'prompt_not_found',
    'backend_unknown',
    'backend_unreachable',
    'backend_timeout',
    'auth_failed',
    'rate_limited',
    'bad_json',
    'upstream_error',
    'invalid_request',
    'internal',
)

_lock = threading.Lock()
_buf: deque[dict[str, Any]] = deque(maxlen=MAX_ENTRIES)
_STARTED = time.time()
_SEQ = 0


def _normalize(entry: dict[str, Any]) -> dict[str, Any]:
    """补齐/规整一条记录的字段（在锁内调用）。"""
    out = dict(entry)
    out['ts'] = float(out.get('ts') or time.time())
    if out.get('kind') not in KINDS:
        out['kind'] = 'task'
    code = out.get('error_code')
    if code is not None and code not in ERROR_CODES:
        out['error_code'] = 'internal'
    out['ok'] = bool(out.get('ok'))
    try:
        out['latency_ms'] = int(out.get('latency_ms') or 0)
    except (TypeError, ValueError):
        out['latency_ms'] = 0
    out['task'] = str(out.get('task') or '')
    out['variant'] = out.get('variant')
    out['backend'] = str(out.get('backend') or '')
    out['model'] = str(out.get('model') or '')
    try:
        out['attempts'] = int(out.get('attempts') or 0)
    except (TypeError, ValueError):
        out['attempts'] = 0
    try:
        out['input_chars'] = int(out.get('input_chars') or 0)
    except (TypeError, ValueError):
        out['input_chars'] = 0
    try:
        out['output_chars'] = int(out.get('output_chars') or 0)
    except (TypeError, ValueError):
        out['output_chars'] = 0
    return out


def record(**fields: Any) -> None:
    """记一条调用。**永不抛异常**。

    常用字段见模块 docstring 的「单条记录字段」；未传的按 0 / 空串兜底。
    """
    global _SEQ
    try:
        entry = _normalize(dict(fields))
        with _lock:
            _buf.append(entry)
            _SEQ += 1
    except Exception:  # noqa: BLE001 - 统计绝不能影响业务
        pass


def record_entry(entry: dict[str, Any]) -> None:
    """同上，但入口是 dict（便于批量 / 从已有 payload 复用）。"""
    global _SEQ
    try:
        norm = _normalize(dict(entry))
        with _lock:
            _buf.append(norm)
            _SEQ += 1
    except Exception:  # noqa: BLE001
        pass


def _p95(values: list[int]) -> int:
    """``idx = int(0.95 * (n - 1))``；空列表返回 0。"""
    if not values:
        return 0
    ordered = sorted(values)
    idx = int(0.95 * (len(ordered) - 1))
    return int(ordered[idx])


def _mean(values: list[int]) -> int:
    if not values:
        return 0
    return int(sum(values) / len(values))


def snapshot(window_s: float = 3600.0) -> dict[str, Any]:
    """聚合窗口内的统计。

    Args:
        window_s: 窗口秒数；非正数 / 非法值回落 3600。

    Returns:
        结构见设计 §3.3（``total`` / ``ok`` / ``error`` / ``avg_latency_ms`` /
        ``p95_latency_ms`` / ``by_task`` / ``by_backend`` / ``last_error`` /
        ``slowest`` / ``buffer_size`` / ``since_startup``）。
    """
    try:
        window = float(window_s)
    except (TypeError, ValueError):
        window = 3600.0
    if window <= 0:
        window = 3600.0

    now = time.time()
    with _lock:
        entries = [e for e in _buf if float(e.get('ts') or 0.0) >= now - window]
        total_since_startup = _SEQ
        # 环形缓冲**当前占用**（必须在锁内读）；MAX_ENTRIES 是上限常量，
        # 不开字段 —— 三个条数字段要各是一个语义：total=窗口内 / buffer_size=当前占用 /
        # since_startup=累计。
        buffer_len = len(_buf)

    total = len(entries)
    ok_list = [e for e in entries if e.get('ok')]
    err_list = [e for e in entries if not e.get('ok')]
    latencies = [int(e.get('latency_ms') or 0) for e in entries]

    by_task_map: dict[str, dict[str, Any]] = {}
    for e in entries:
        key = str(e.get('task') or '(无)')
        slot = by_task_map.setdefault(
            key, {'task': key, 'count': 0, 'ok': 0, 'error': 0, '_lat': []}
        )
        slot['count'] += 1
        if e.get('ok'):
            slot['ok'] += 1
        else:
            slot['error'] += 1
        slot['_lat'].append(int(e.get('latency_ms') or 0))
    by_task = [
        {
            'task': v['task'],
            'count': v['count'],
            'ok': v['ok'],
            'error': v['error'],
            'avg_latency_ms': _mean(v['_lat']),
        }
        for v in sorted(by_task_map.values(), key=lambda x: (-x['count'], x['task']))
    ]

    by_backend_map: dict[str, dict[str, Any]] = {}
    for e in entries:
        key = str(e.get('backend') or '(无)')
        slot = by_backend_map.setdefault(key, {'backend': key, 'count': 0, 'error': 0})
        slot['count'] += 1
        if not e.get('ok'):
            slot['error'] += 1
    by_backend = [
        {'backend': v['backend'], 'count': v['count'], 'error': v['error']}
        for v in sorted(by_backend_map.values(), key=lambda x: (-x['count'], x['backend']))
    ]

    last_error: dict[str, Any] | None = None
    for e in sorted(err_list, key=lambda x: float(x.get('ts') or 0.0)):
        last_error = {
            'ts': float(e.get('ts') or 0.0),
            'task': str(e.get('task') or ''),
            'variant': e.get('variant'),
            'code': e.get('error_code') or 'internal',
            'message': str(e.get('message') or ''),
            'backend': str(e.get('backend') or ''),
        }

    slowest = [
        {
            'ts': float(e.get('ts') or 0.0),
            'task': str(e.get('task') or ''),
            'variant': e.get('variant'),
            'latency_ms': int(e.get('latency_ms') or 0),
            'ok': bool(e.get('ok')),
        }
        for e in sorted(entries, key=lambda x: -(int(x.get('latency_ms') or 0)))[:5]
    ]

    return {
        'window_s': int(window),
        'total': total,
        'ok': len(ok_list),
        'error': len(err_list),
        'avg_latency_ms': _mean(latencies),
        'p95_latency_ms': _p95(latencies),
        'by_task': by_task,
        'by_backend': by_backend,
        'last_error': last_error,
        'slowest': slowest,
        'buffer_size': int(buffer_len),
        'since_startup': int(total_since_startup),
    }


def reset() -> None:
    """清空缓冲（**仅供测试**）。"""
    global _SEQ
    with _lock:
        _buf.clear()
        _SEQ = 0


def size() -> int:
    """当前缓冲里的条数。"""
    with _lock:
        return len(_buf)


def uptime_s() -> float:
    """模块被导入以来的秒数（≈ 进程运行时长）。"""
    return time.time() - _STARTED
