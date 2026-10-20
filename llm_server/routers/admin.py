"""``POST /v1/admin/reload``（S-06）：手动热加载 config.yaml。

提示词的热更新走 ``POST /v1/prompts/reload``；这里是**配置**（后端地址 / 默认
后端 / 超时）的热加载，改完 config.yaml 不用重启进程。
"""

from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from core.logging import get_logger

router = APIRouter(tags=['admin'])
_log = get_logger('config')


@router.post('/v1/admin/reload')
async def reload_config(request: Request) -> JSONResponse:
    """重载 config.yaml，并清空后端实例缓存（地址/密钥可能变了）。"""
    state = request.app.state
    reloaded = state.config.load() or True  # type: ignore[attr-defined]
    state.clear_backends()  # type: ignore[attr-defined]
    return JSONResponse(
        {
            'ok': True,
            'reloaded': True,
            'default_backend': state.config.default_backend,  # type: ignore[attr-defined]
            'backends': sorted(state.config.backends),  # type: ignore[attr-defined]
            'loaded_at': state.config._mtime,  # type: ignore[attr-defined]
        }
    )
