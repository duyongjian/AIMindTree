"""``POST /v1/logs``：接收 App 侧运行日志，抄入 M7 运行日志缓冲（P0-5）。

App 的 Dart ``AppLog`` 经此端点把本地运行日志（提取、诊断、异常等）抄送到
服务端 ``logbuf``，使管理后台 M7「运行日志」能看到 App 侧活动——否则 M7 只有
服务端日志，看不到 App 端「提取知识点」等事件。

与 ``/v1/app/config`` 同信任级：本机 127.0.0.1，无鉴权。密钥边界：端点绝不
接受 / 回显任何密钥片段，只抄日志文本（与 logbuf 同样约束）。
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from core.errors import invalid_request
from core.logbuf import MAX_MESSAGE_CHARS, append

router = APIRouter(tags=['logs'])

#: 单次请求最多抄送条数（防一次性灌爆缓冲）。
_MAX_BATCH = 200


@router.post('/v1/logs')
async def ingest_logs(request: Request) -> JSONResponse:
    """接收 App 侧日志并抄入运行日志缓冲。

    body: ``{"entries": [{"level": "INFO", "module": "app.extract",
    "message": "..."}, ...]}``；模块名以 ``app.`` 前缀区分 App 侧日志。
    """
    try:
        raw = await request.json()
    except Exception as exc:  # noqa: BLE001
        raise invalid_request(f'请求体不是合法 JSON（{exc}）') from exc
    if not isinstance(raw, dict):
        raise invalid_request('请求体必须是 JSON 对象')
    entries = raw.get('entries')
    if not isinstance(entries, list):
        raise invalid_request('entries 必须是数组')

    accepted = 0
    for e in entries[:_MAX_BATCH]:
        if not isinstance(e, dict):
            continue
        msg = e.get('message')
        if not isinstance(msg, str) or not msg:
            continue
        if len(msg) > MAX_MESSAGE_CHARS:
            msg = msg[:MAX_MESSAGE_CHARS] + '…（已截断）'
        level = str(e.get('level') or 'INFO').upper()
        module = str(e.get('module') or 'app')
        # append 永不抛，且会规范化级别 / 截断。
        append(level=level, module=module, message=msg)
        accepted += 1

    return JSONResponse({'accepted': accepted})
