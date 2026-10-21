"""``GET /health``（S-10）。

服务本身活着就返回 ``status=ok``；后端不可达只体现在 ``backends[].reachable=false``
（Ollama 没起不该让整个健康检查 500）。各后端**并发**探测，超时取
``timeouts.health_s``（默认 5s）。
"""

from __future__ import annotations

import asyncio
import time

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from backends.base import BackendHealth
from core.app_config import SERVER_VERSION
from core.logging import get_logger

router = APIRouter(tags=['health'])
_log = get_logger('backend')

#: 进程启动时刻（用于 uptime_s）
_START = time.time()

#: 与 ``server.VERSION`` / ``core.app_config.SERVER_VERSION`` 三处同源。
VERSION = SERVER_VERSION


@router.get('/health')
async def health(request: Request) -> JSONResponse:
    """服务 + 各后端可达性 + 提示词加载数。"""
    state = request.app.state
    config = state.config
    config.maybe_reload()

    backends_conf = list(config.backends.values())
    health_timeout = config.timeout('health_s', 5.0)

    async def _probe(conf: object) -> BackendHealth:
        try:
            backend = state.get_backend(conf.name)  # type: ignore[attr-defined]
            return await backend.health(timeout_s=health_timeout)
        except Exception as exc:  # noqa: BLE001 - 探活失败不算 500
            return BackendHealth(
                name=getattr(conf, 'name', '?'),
                reachable=False,
                base_url=getattr(conf, 'base_url', ''),
                models=[],
                error=str(exc)[:200],
            )

    results: list[BackendHealth] = []
    if backends_conf:
        done = await asyncio.gather(*[_probe(c) for c in backends_conf])
        results = list(done)

    return JSONResponse(
        {
            'status': 'ok',
            'version': VERSION,
            'uptime_s': round(time.time() - _START, 1),
            'default_backend': config.default_backend,
            'task_backends': dict(config.task_backends),
            'prompts_loaded': state.registry.store.count(),  # type: ignore[attr-defined]
            'prompt_errors': state.registry.store.errors,  # type: ignore[attr-defined]
            'backends': [b.to_dict() for b in results],
        }
    )
