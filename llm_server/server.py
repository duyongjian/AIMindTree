"""FastAPI 装配：4 个 router + 全局异常处理器 + CORS + 生命周期。

``python llm_server/run.py`` 走 :func:`create_app`；也可以被测试直接 import。
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse

import core.logging as logging_setup
from backends import create_backend
from core.config import ROOT, Config
from core.errors import LlmError, internal
from core.logging import get_logger
from core.prompt_store import PromptStore
from core.registry import TaskRegistry
from routers import build_router

_log = get_logger('config')

VERSION = '0.1.0'

#: 管理后台单页（``static/admin.html``）；``GET /`` 与 ``GET /admin`` 都返回它。
STATIC_DIR = ROOT / 'static'
ADMIN_HTML = STATIC_DIR / 'admin.html'


class AppState:
    """挂在 ``app.state`` 上的共享依赖（含后端实例缓存）。"""

    def __init__(self, config: Config, prompts_dir: Path | None = None) -> None:
        self.config = config
        self.store = PromptStore(prompts_dir or (ROOT / 'prompts'))
        self.registry = TaskRegistry(self.store, self.config)
        self._backends: dict[str, object] = {}

    # -------- 后端实例缓存 --------

    def get_backend(self, name: str, timeout_s: float | None = None) -> object:
        """取（或创建）后端实例。

        缓存 key 只按名字：后端地址/密钥改了要 ``POST /v1/admin/reload`` 清缓存。
        """
        key = f'{name}@{timeout_s or 0:g}'
        backend = self._backends.get(key)
        if backend is None:
            conf = self.config.backend(name)
            api_key = self.config.resolve_api_key(conf)
            backend = create_backend(
                conf,
                api_key,
                timeout_s=timeout_s or self.config.timeout('structured_s', 120.0),
                connect_s=self.config.timeout('connect_s', 10.0),
                trust_env=bool(self.config.server.get('trust_env_proxy', False)),
            )
            self._backends[key] = backend
        return backend

    def clear_backends(self) -> int:
        """清空后端实例缓存（配置热加载后调用）。"""
        count = len(self._backends)
        self._backends.clear()
        return count


def create_app(
    config_path: Path | str | None = None,
    prompts_dir: Path | str | None = None,
) -> FastAPI:
    """构造 app。"""
    config = Config(Path(config_path) if config_path else None)
    logging_setup.setup(
        level=str(config.server.get('log_level', 'info')),
        verbose=bool(config.server.get('verbose', False)),
    )
    state = AppState(config, Path(prompts_dir) if prompts_dir else None)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        _log.info(
            'llm_server %s 启动：%s:%s（默认后端=%s，提示词 %d 个）',
            VERSION,
            config.server.get('host', '127.0.0.1'),
            config.server.get('port', 8787),
            config.default_backend,
            state.store.count(),
        )
        if state.store.errors:
            for err in state.store.errors:
                _log.error('提示词加载错误：%s', err)
        yield
        _log.info('llm_server 关闭')

    app = FastAPI(
        title='AIMindTree LLM Server',
        version=VERSION,
        description='自研本地 LLM 服务：提示词在服务端、密钥在服务端、JSON 容错在服务端。',
        lifespan=lifespan,
    )

    origins = list(config.server.get('cors_origins') or [])
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins or ['http://127.0.0.1', 'http://localhost'],
        allow_credentials=True,
        allow_methods=['*'],
        allow_headers=['*'],
    )

    # 把 state 挂上去（router 通过 request.app.state.* 访问）
    app.state.config = state.config
    app.state.store = state.store
    app.state.registry = state.registry
    app.state.get_backend = state.get_backend
    app.state.clear_backends = state.clear_backends
    app.state._state = state

    @app.exception_handler(LlmError)
    async def _llm_error_handler(request: Request, exc: LlmError) -> JSONResponse:
        """统一错误出口：``{"error": {code, message, backend, retryable}}``。"""
        payload = exc.to_dict()['error']
        _log.warning(
            '%s %s → %s（%s）',
            request.method,
            request.url.path,
            payload['code'],
            payload['message'],
        )
        return JSONResponse({'error': payload}, status_code=exc.http_status)

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
        """兜底：绝不把 traceback 甩给客户端。"""
        err = internal(f'{type(exc).__name__}: {exc}')
        _log.error('未捕获异常 %s %s：%s', request.method, request.url.path, exc, exc_info=exc)
        return JSONResponse(err.to_dict(), status_code=err.http_status)

    app.include_router(build_router())

    # ---- 管理后台单页（原生 HTML，无额外依赖）----
    @app.get('/admin', include_in_schema=False)
    async def admin_page() -> FileResponse:
        """管理后台：``GET /admin``。"""
        return FileResponse(str(ADMIN_HTML))

    @app.get('/', include_in_schema=False)
    async def index_page() -> FileResponse:
        """根路径也指向管理后台（``GET /``）。"""
        return FileResponse(str(ADMIN_HTML))

    return app


#: ``uvicorn llm_server.server:app`` 也能起（此时需要仓库根在 sys.path）。
app = create_app()
