"""路由层。"""

from __future__ import annotations

from fastapi import APIRouter

from routers import admin, chat, health, prompts, tasks


def build_router() -> APIRouter:
    """装配全部子路由（``server.py`` 调用）。"""
    router = APIRouter()
    router.include_router(health.router)
    router.include_router(tasks.router)
    router.include_router(chat.router)
    router.include_router(prompts.router)
    router.include_router(admin.router)
    return router


__all__ = ['build_router', 'admin', 'chat', 'health', 'prompts', 'tasks']
