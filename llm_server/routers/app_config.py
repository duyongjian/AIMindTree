"""``GET /v1/app/config``：App 启动时的运行配置下发（AC-01 / AC-02）。

**无鉴权**（C10）：本端点只下发「连接地址 + 后端/模型名 + 超时」这类非敏感
运行参数，密钥一律不出现（C3，由 :mod:`core.app_config` 的白名单保证）。
将来的 admin token 只挂在 ``/v1/admin/*`` 与 ``/admin``，不动这里。
"""

from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from core.app_config import SERVER_VERSION, build_app_config
from core.logging import get_logger

router = APIRouter(tags=['app-config'])
_log = get_logger('app_config')


@router.get('/v1/app/config')
async def app_config(request: Request) -> JSONResponse:
    """App 运行配置下发（13 字段白名单，无密钥，``Cache-Control: no-store``）。"""
    state = request.app.state
    state.config.maybe_reload()  # 与 /health 一致：改了 settings.json 立即生效
    payload = build_app_config(state.config, server_version=SERVER_VERSION)
    return JSONResponse(payload, headers={'Cache-Control': 'no-store'})
