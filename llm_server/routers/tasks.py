"""``POST /v1/task/{task_code}``（S-01 / S-13 / S-14）：结构化任务。

App 侧 ``LlmServerClient.runTask`` 打这个端点（T1/T2/T3/T4/T9/T12/T13）。
提示词在服务端装载，客户端只传 ``inputs``；服务端做完六层容错后回填 ``parsed``。
"""

from __future__ import annotations

import json
import time

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from backends.base import Message
from core.errors import LlmError, bad_json, invalid_request
from core.json_repair import repair
from core.logging import dump, get_logger
from core.stats import record as stats_record

router = APIRouter(tags=['tasks'])
_log = get_logger('task')

#: 重试时追加给模型的纠错提示（S-13）。
_RETRY_HINT = (
    '你上一次的输出不是合法 JSON（可能混入了思考过程、代码块标记或解释文字）。\n'
    '请**只**输出一个 JSON 值：不要任何解释、前后缀，不要用 ``` 围栏包裹。'
)


async def _read_body(request: Request) -> dict:
    """读请求体；非 JSON 对象抛 ``invalid_request``。"""
    try:
        raw = await request.json()
    except Exception as exc:
        raise invalid_request(f'请求体不是合法 JSON（{exc}）') from exc
    if not isinstance(raw, dict):
        raise invalid_request('请求体必须是 JSON 对象')
    return raw


@router.post('/v1/task/{task_code}')
async def run_task(task_code: str, request: Request) -> JSONResponse:
    """执行一次结构化任务（薄壳：只负责失败埋点，业务体在 :func:`_run_task_impl`）。

    成功埋点写在 ``_run_task_impl`` 里（那里才拿得到 backend / model / attempts）；
    ``bad_json`` 走 ``raise``，会被这里的 ``except LlmError`` 捕获并记一条
    ``ok=False`` —— 符合 AC-07「成功与 LlmError 都记录」。
    """
    started0 = time.time()
    try:
        return await _run_task_impl(task_code, request)
    except LlmError as exc:
        stats_record(
            kind='task',
            task=str(task_code or '').upper(),
            ok=False,
            error_code=exc.code,
            backend=getattr(exc, 'backend', None),
            latency_ms=int((time.time() - started0) * 1000),
        )
        raise
    except Exception:
        stats_record(
            kind='task',
            task=str(task_code or '').upper(),
            ok=False,
            error_code='internal',
            latency_ms=int((time.time() - started0) * 1000),
        )
        raise


async def _run_task_impl(task_code: str, request: Request) -> JSONResponse:
    """执行一次结构化任务（原 ``run_task`` 函数体，逐行不变 + 成功埋点）。"""
    state = request.app.state
    config = state.config
    registry = state.registry
    config.maybe_reload()

    body = await _read_body(request)
    variant = (body.get('variant') or '').strip() or None

    # 1) 提示词（未知任务 / 文件缺失 → unknown_task）
    meta = registry.get(task_code, variant)

    # 2) 输入校验
    inputs = body.get('inputs')
    if inputs is not None and not isinstance(inputs, dict):
        raise invalid_request('inputs 必须是 JSON 对象')
    values = registry.require_inputs(meta, inputs)

    # 3) 后端 / 模型 / 超时
    backend_conf = registry.resolve_backend(meta.task, body.get('backend'))
    model_override = (body.get('model') or '').strip() or None
    if model_override is None:
        # AC-06：per-task 模型覆盖（只在请求未显式带 model 时生效，D2）
        model_override = registry.resolve_model(meta.task)
    temperature = float(body.get('temperature') or meta.temperature)
    timeout_s = float(body.get('timeout_s') or config.timeout('structured_s', 120.0))
    max_attempts = 1 + max(0, int(config.retry.get('structured_on_bad_json', 1)))
    user = str(body.get('user') or 'aimindtree-app')

    messages = [Message(role=m['role'], content=m['content']) for m in meta.render(values)]
    dump(_log, f'{meta.task} prompt', messages)

    # 4) 执行（失败可重试一次，S-13）
    started = time.time()
    backend = state.get_backend(backend_conf.name, timeout_s=timeout_s)
    parsed = None
    content = ''
    usage: dict | None = None
    model_id = backend.model_id(model_override)
    attempts = 0
    last_error: str | None = None

    for attempt in range(1, max_attempts + 1):
        attempts = attempt
        completion = await backend.complete(
            messages,
            temperature=temperature,
            max_tokens=meta.max_tokens,
            json_mode=bool(meta.json_output),
            timeout_s=timeout_s,
            model=model_override,
        )
        model_id = completion.model_id or model_id
        usage = completion.usage or usage
        parsed, content = repair(completion.text)
        last_error = None if parsed is not None else (content[:200] or '(空输出)')
        if parsed is not None:
            break
        if attempt < max_attempts:
            _log.warning(
                '%s 第 %d 次输出不是合法 JSON，重试（backend=%s, model=%s）',
                meta.task,
                attempt,
                backend_conf.name,
                model_id,
            )
            messages = [*messages, Message(role='user', content=_RETRY_HINT)]

    latency_ms = int((time.time() - started) * 1000)
    dump(_log, f'{meta.task} response', content)

    # 5) 结构化任务解析失败 = bad_json（不静默返回 null，S-14）
    if meta.json_output and parsed is None:
        raise bad_json(backend_conf.name, attempts)

    if parsed is None:
        _log.warning('%s 未解析出结构（json_output=False，按纯文本返回）', meta.task)

    _log.info(
        '%s 完成：backend=%s model=%s attempts=%d latency=%dms parsed=%s',
        meta.task,
        backend_conf.name,
        model_id,
        attempts,
        latency_ms,
        'yes' if parsed is not None else 'no',
    )

    # 成功埋点（AC-07）：record() 永不抛，不影响业务返回。
    stats_record(
        kind='task',
        task=meta.task,
        variant=meta.variant,
        backend=backend_conf.name,
        model=model_id or '',
        latency_ms=latency_ms,
        ok=True,
        error_code=None,
        attempts=attempts,
        input_chars=len(json.dumps(values, ensure_ascii=False)),
        output_chars=len(content),
    )

    return JSONResponse(
        {
            'task': meta.task,
            'variant': meta.variant,
            'content': content,
            'parsed': parsed,
            'backend': backend_conf.name,
            'model_id': model_id,
            'latency_ms': latency_ms,
            'usage': usage,
            'attempts': attempts,
            'output_key': meta.output_key,
            'prompt_sha1': meta.sha1,
            'user': user,
            'last_error': last_error,
        }
    )


@router.post('/v1/task')
async def run_task_missing_code(request: Request) -> JSONResponse:
    """友好报错：``/v1/task`` 少了任务代码。"""
    raise LlmError(
        'unknown_task',
        '缺少任务代码：请用 POST /v1/task/{T1..T13}（已加载提示词见 GET /v1/prompts）',
    )
