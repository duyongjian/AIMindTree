"""提示词管理（S-08 / S-09）：列出 / 读原文 / 写回 / 热更新。

改 md 后不用重启进程：``POST /v1/prompts/reload`` 或写回时带 ``?reload=true``。
"""

from __future__ import annotations

from fastapi import APIRouter, Query, Request
from fastapi.responses import JSONResponse

from core.errors import LlmError, invalid_request
from core.logging import get_logger

router = APIRouter(tags=['prompts'])
_log = get_logger('prompt')


@router.get('/v1/prompts')
async def list_prompts(request: Request) -> JSONResponse:
    """列出全部提示词的元信息（``file/mtime/size/sha1/structured/output_key/inputs``）。"""
    store = request.app.state.registry.store  # type: ignore[attr-defined]
    items = [m.to_info() for m in store.list()]
    return JSONResponse(
        {
            'count': len(items),
            'dir': str(store.dir),
            'prompts': items,
            'skipped': list(store.skipped),
            'errors': list(store.errors),
        }
    )


@router.post('/v1/prompts/reload')
async def reload_prompts(request: Request) -> JSONResponse:
    """重扫提示词目录（改完 md 立即生效，不用重启）。"""
    store = request.app.state.registry.store  # type: ignore[attr-defined]
    loaded, skipped, errors = store.reload()
    return JSONResponse(
        {'ok': True, 'loaded': loaded, 'skipped': list(skipped), 'errors': list(errors)}
    )


@router.get('/v1/prompts/{task}')
async def get_prompt(
    request: Request,
    task: str,
    variant: str | None = Query(default=None),
) -> JSONResponse:
    """取提示词原文。"""
    store = request.app.state.registry.store  # type: ignore[attr-defined]
    meta = store.get(task, variant)
    try:
        content = meta.path.read_text(encoding='utf-8')
    except OSError as exc:
        raise LlmError('prompt_not_found', f'读取 {meta.file_name} 失败：{exc}') from exc
    return JSONResponse(
        {
            'task': meta.task,
            'variant': meta.variant,
            'file': meta.file_name,
            'path': str(meta.path),
            'content': content,
        }
    )


@router.put('/v1/prompts/{task}')
async def put_prompt(
    request: Request,
    task: str,
    variant: str | None = Query(default=None),
    reload: bool = Query(default=False),
) -> JSONResponse:
    """写回提示词原文。body：``{"content": "<完整 md>"}``。"""
    store = request.app.state.registry.store  # type: ignore[attr-defined]
    try:
        body = await request.json()
    except Exception as exc:
        raise invalid_request(f'请求体不是合法 JSON（{exc}）') from exc
    if not isinstance(body, dict) or not isinstance(body.get('content'), str):
        raise invalid_request('body 必须是 {"content": "<md 原文>"}')
    if not body['content'].strip():
        raise invalid_request('content 不能为空（会写坏提示词文件）')

    path = store.save(task, variant, body['content'])
    loaded = store.count()
    if reload:
        loaded, _, _ = store.reload()
    return JSONResponse(
        {
            'ok': True,
            'path': str(path),
            'reloaded': bool(reload),
            'loaded': loaded,
        }
    )
