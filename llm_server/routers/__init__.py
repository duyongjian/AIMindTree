"""路由层。"""

from __future__ import annotations

from fastapi import APIRouter

from routers import admin, app_config, chat, health, prompts, tasks


def build_router() -> APIRouter:
    """装配全部子路由（``server.py`` 调用）。"""
    router = APIRouter()
    router.include_router(health.router)
    router.include_router(app_config.router)  # GET /v1/app/config（无鉴权）
    router.include_router(tasks.router)
    router.include_router(chat.router)
    router.include_router(prompts.router)
    router.include_router(admin.router)
    return router


__all__ = ['build_router', 'admin', 'app_config', 'chat', 'health', 'prompts', 'tasks']
