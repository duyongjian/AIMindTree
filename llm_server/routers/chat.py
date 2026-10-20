"""``POST /v1/chat``（S-03 / S-04）：会话任务，SSE 或一次性。

**SSE 封装只在这一处**：后端 ``stream_complete`` 只 yield 纯文本 delta，
本模块负责包成 ``data: {...}\\n\\n``，三个后端零重复。

``stream:false`` 时降级为一次性 JSON（A-03 的 P0 兜底，App 侧
``kLlmServerBlockingChat`` 开关对应）。
"""

from __future__ import annotations

import json
import time
import uuid

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, StreamingResponse

from backends.base import Message
from core.errors import invalid_request
from core.json_repair import repair
from core.logging import dump, get_logger

router = APIRouter(tags=['chat'])
_log = get_logger('chat')

#: 没带 task 时的兜底人格（纯 chat 场景）。
_FALLBACK_SYSTEM = (
    '你是 AIMindTree 的 AI 学习助手：回答简洁、循序渐进、点出易混淆点。\n'
    '当用户明确要求「只输出 JSON」时，严格只输出一个 JSON 值：'
    '不要任何解释、前后缀，不要用 ``` 围栏包裹。'
)


def _new_conversation_id() -> str:
    """生成一个会话 id（**服务端无状态**，仅回显透传，Q4）。"""
    return f'conv_{uuid.uuid4().hex[:20]}'


async def _read_body(request: Request) -> dict:
    try:
        raw = await request.json()
    except Exception as exc:
        raise invalid_request(f'请求体不是合法 JSON（{exc}）') from exc
    if not isinstance(raw, dict):
        raise invalid_request('请求体必须是 JSON 对象')
    return raw


def _build_messages(request_meta, query: str, extra: dict | None) -> list[Message]:
    """按提示词渲染 messages；无 task 时用兜底人格。"""
    if request_meta is None:
        return [
            Message(role='system', content=_FALLBACK_SYSTEM),
            Message(role='user', content=query),
        ]
    values: dict[str, object] = {'query': query}
    for key, value in (extra or {}).items():
        values[str(key)] = value
    return [
        Message(role=m['role'], content=m['content'])
        for m in request_meta.render(values)
    ]


# response_model=None：返回值是 JSONResponse | StreamingResponse 两种，
# 不能让 FastAPI 拿它去推 pydantic 响应模型（会直接起不来）。
@router.post('/v1/chat', response_model=None)
async def chat(request: Request) -> JSONResponse | StreamingResponse:
    """会话任务入口。"""
    state = request.app.state
    config = state.config
    config.maybe_reload()

    body = await _read_body(request)
    task_code = (body.get('task') or '').strip() or None
    variant = (body.get('variant') or '').strip() or None
    query = str(body.get('query') or '')
    if not query:
        raise invalid_request('缺少 query')
    stream = bool(body.get('stream', True))
    timeout_s = float(body.get('timeout_s') or config.timeout('chat_s', 120.0))
    model_override = (body.get('model') or '').strip() or None
    conversation_id = (body.get('conversation_id') or '').strip() or _new_conversation_id()
    user = str(body.get('user') or 'aimindtree-app')

    meta = None
    if task_code:
        meta = state.registry.get(task_code, variant)
    backend_conf = state.registry.resolve_backend(task_code or 'CHAT', body.get('backend'))
    backend = state.get_backend(backend_conf.name, timeout_s=timeout_s)

    messages = _build_messages(meta, query, body.get('inputs'))
    dump(_log, f'{task_code or "CHAT"}{"/" + variant if variant else ""} prompt', messages)

    temperature = float(meta.temperature) if meta else 0.6
    max_tokens = int(meta.max_tokens) if meta else 4096
    need_json = bool(meta.json_output) if meta else False

    if not stream:
        return await _blocking(
            backend,
            messages,
            temperature=temperature,
            max_tokens=max_tokens,
            timeout_s=timeout_s,
            model=model_override,
            need_json=need_json,
            conversation_id=conversation_id,
            backend_name=backend_conf.name,
            task_code=task_code,
        )

    return StreamingResponse(
        _sse(
            backend,
            messages,
            temperature=temperature,
            max_tokens=max_tokens,
            timeout_s=timeout_s,
            model=model_override,
            need_json=need_json,
            conversation_id=conversation_id,
            backend_name=backend_conf.name,
            task_code=task_code,
            variant=variant,
        ),
        media_type='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
            'X-Accel-Buffering': 'no',
        },
    )


async def _blocking(backend, messages, *, temperature, max_tokens, timeout_s, model,
                    need_json, conversation_id, backend_name, task_code) -> JSONResponse:
    """``stream:false``：一次性返回。"""
    started = time.time()
    completion = await backend.complete(
        messages,
        temperature=temperature,
        max_tokens=max_tokens,
        json_mode=need_json,
        timeout_s=timeout_s,
        model=model,
    )
    content = completion.text
    parsed = None
    if need_json:
        parsed, content = repair(content)
    latency_ms = int((time.time() - started) * 1000)
    dump(_log, f'{task_code or "CHAT"} response', content)
    _log.info('%s chat（blocking）完成：%dms', task_code or 'CHAT', latency_ms)
    return JSONResponse(
        {
            'content': content,
            'parsed': parsed,
            'conversation_id': conversation_id,
            'usage': completion.usage,
            'backend': backend_name,
            'model_id': completion.model_id,
            'latency_ms': latency_ms,
        }
    )


async def _sse(backend, messages, *, temperature, max_tokens, timeout_s, model,
               need_json, conversation_id, backend_name, task_code, variant):
    """SSE 生成器：逐条 ``data: {...}\\n\\n``。"""
    started = time.time()
    buffer: list[str] = []
    try:
        async for delta in backend.stream_complete(
            messages,
            temperature=temperature,
            max_tokens=max_tokens,
            timeout_s=timeout_s,
            model=model,
        ):
            if not delta:
                continue
            buffer.append(delta)
            yield _line({'delta': delta})

        content = ''.join(buffer)
        parsed = None
        if need_json:
            parsed, content = repair(content)
        latency_ms = int((time.time() - started) * 1000)
        dump(_log, f'{task_code or "CHAT"} response', content)
        _log.info(
            '%s%s chat（SSE）完成：%dms, %d 字符',
            task_code or 'CHAT',
            f'/{variant}' if variant else '',
            latency_ms,
            len(content),
        )
        yield _line(
            {
                'done': True,
                'conversation_id': conversation_id,
                'content': content,
                'parsed': parsed,
                'backend': backend_name,
                'model_id': backend.model_id(model),
                'latency_ms': latency_ms,
            }
        )
    except Exception as exc:  # noqa: BLE001 - 流中途出错也要给客户端一个终态
        from core.errors import LlmError

        if isinstance(exc, LlmError):
            payload = exc.to_dict()['error']
        else:
            payload = {
                'code': 'internal',
                'message': str(exc)[:300],
                'backend': backend_name,
                'retryable': False,
            }
        _log.error('chat 流中断：%s', payload.get('message'))
        yield _line({'done': True, 'error': payload, 'conversation_id': conversation_id})


def _line(payload: dict) -> str:
    """一条 SSE 帧。``ensure_ascii=False`` 保证中文不被转义成 \\uXXXX。"""
    return f'data: {json.dumps(payload, ensure_ascii=False)}\n\n'
