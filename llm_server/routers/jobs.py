"""``/v1/jobs``：异步任务队列（提交即返回，worker 池执行，进度可轮询）。

App 的批量型 AI 功能走这里：T1 提取 / T3 自动连线 / T4 递归补前置 / T5 检测。
交互流式（T5 问答 / T6 / T7 / T8）仍走 ``POST /v1/chat`` SSE 直连（方案 §3）。

命名：``/v1/task/{code}`` 已被「结构化任务同步执行」占用，队列用 ``/v1/jobs``。

执行体零重复：单次调用直接复用 ``routers/tasks.run_task_core`` 与
``routers/chat.chat_blocking_core``（HTTP 路径同款函数）；T4 的递归驱动
（Q1）从 App 搬来后住在本模块的 :func:`_execute_t4`。
"""

from __future__ import annotations

import time
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from core.errors import LlmError, invalid_request
from core.jobs import Job, JobQueue
from core.logging import get_logger
from core.stats import record as stats_record
from routers.chat import chat_blocking_core
from routers.tasks import run_task_core

router = APIRouter(tags=['jobs'])
_log = get_logger('job')

#: T4 深度档位参数（与 App 侧 ``prereq_depth.dart`` / ``auto_graph_service.dart``
#: 逐行同构；改一侧必须同步另一侧）。
_DEPTH_LEVELS = {'low': 1, 'medium': 2, 'high': 3, 'custom': 3}
_DEPTH_BREADTH = {'low': 3, 'medium': 4, 'high': 5, 'custom': 5}


# ---------------------------------------------------------------- 装配


def create_queue(state) -> JobQueue:
    """按 ``config.jobs`` 装配队列；执行体闭包捕获 ``state``（无环依赖）。"""
    jobs_cfg = getattr(state.config, 'jobs', None) or {}
    queue = JobQueue(
        concurrency=jobs_cfg.get('concurrency', 1),
        retain=jobs_cfg.get('retain', 200),
    )

    async def executor(job: Job) -> dict[str, Any]:
        return await _execute_job(state, job)

    queue.set_executor(executor)
    return queue


def _queue_of(request: Request) -> JobQueue:
    return request.app.state.jobs


async def _read_body(request: Request) -> dict:
    try:
        raw = await request.json()
    except Exception as exc:
        raise invalid_request(f'请求体不是合法 JSON（{exc}）') from exc
    if not isinstance(raw, dict):
        raise invalid_request('请求体必须是 JSON 对象')
    return raw


# ---------------------------------------------------------------- API


@router.post('/v1/jobs')
async def submit_job(request: Request) -> JSONResponse:
    """提交任务：202 + ``{job_id, status, deduped}``。

    锁冲突（``resource_key`` 被未终态 job 持有）→ 409 ``lock_conflict``；
    幂等（60s 内同 ``idempotency_key``）→ ``deduped: true``。
    """
    body = await _read_body(request)
    job, deduped = _queue_of(request).submit(body)
    return JSONResponse(
        {'job_id': job.job_id, 'status': job.status, 'deduped': deduped},
        status_code=202,
    )


@router.get('/v1/jobs')
async def list_jobs(
    request: Request,
    status: str | None = None,
    limit: int = 50,
) -> JSONResponse:
    """任务列表（未终态 + 最近终态，新的在前）。管理后台 M10 与 App 对账共用。"""
    return JSONResponse(_queue_of(request).list_jobs(status=status, limit=limit))


@router.get('/v1/jobs/{job_id}')
async def get_job(job_id: str, request: Request) -> JSONResponse:
    """任务详情。不存在 → 404（App 据此判定「服务已重启，请重试」，方案 §8.3）。"""
    job = _queue_of(request).get(job_id)
    if job is None:
        raise LlmError(
            'invalid_request',
            f'任务不存在或已被清理：{job_id}',
            http_status=404,
        )
    return JSONResponse(job.snapshot())


@router.post('/v1/jobs/{job_id}/cancel')
async def cancel_job(job_id: str, request: Request) -> JSONResponse:
    """取消：queued 立即；running 置检查点（UI 明示「当前步不可中断」）。"""
    job = _queue_of(request).cancel(job_id)
    return JSONResponse(job.snapshot())


# ---------------------------------------------------------------- 执行体


async def _execute_job(state, job: Job) -> dict[str, Any]:
    """按任务分派：T4 → 递归执行体；其余按提示词 ``structured`` 标志分流。

    失败埋点与 HTTP 薄壳（``routers/tasks.run_task``）对称：成功埋点在
    ``run_task_core`` / ``_blocking`` 内部，失败在这里补一条。T4 的每次
    内层调用已各自埋点，外层不再重复记。
    """
    task_code = job.task
    kind = 'task'
    started = time.time()
    try:
        if task_code == 'T4':
            return await _execute_t4(state, job)
        meta = state.registry.get(task_code, job.variant)  # 未知任务 → unknown_task
        kind = 'task' if meta.structured else 'chat'
        if meta.structured:
            return await run_task_core(state, task_code, _task_body(job))
        return await chat_blocking_core(state, _chat_body(job))
    except LlmError as exc:
        stats_record(
            kind=kind,
            task=task_code,
            variant=job.variant,
            ok=False,
            error_code=exc.code,
            backend=getattr(exc, 'backend', None),
            latency_ms=int((time.time() - started) * 1000),
        )
        raise
    except Exception:
        stats_record(
            kind=kind,
            task=task_code,
            variant=job.variant,
            ok=False,
            error_code='internal',
            latency_ms=int((time.time() - started) * 1000),
        )
        raise


def _task_body(job: Job) -> dict[str, Any]:
    """job → ``run_task_core`` 的 body（与 App 侧 ``runTask`` 同款字段）。"""
    body: dict[str, Any] = {'inputs': job.inputs, 'user': job.user}
    if job.backend:
        body['backend'] = job.backend
    if job.model:
        body['model'] = job.model
    if job.variant:
        body['variant'] = job.variant
    if job.timeout_s is not None:
        body['timeout_s'] = job.timeout_s
    return body


def _chat_body(job: Job) -> dict[str, Any]:
    """job → ``chat_blocking_core`` 的 body（``stream`` 强制 false）。"""
    body: dict[str, Any] = {
        'query': job.query,
        'task': job.task,
        'stream': False,
        'user': job.user,
    }
    if job.variant:
        body['variant'] = job.variant
    if job.backend:
        body['backend'] = job.backend
    if job.model:
        body['model'] = job.model
    if job.timeout_s is not None:
        body['timeout_s'] = job.timeout_s
    if job.inputs:
        body['inputs'] = job.inputs
    return body


# ---------------------------------------------------------------- T4 递归（Q1）


async def _execute_t4(state, job: Job) -> dict[str, Any]:
    """T4 递归补前置：递归驱动权从 App 搬服务端（Q1 决策）。

    与 App 侧 ``auto_graph_service.autoPrerequisites`` 逐行同构：

    - frontier 按层展开，每层对每个节点调一次 T4（``run_task_core``）；
    - 单次返回的 gaps 先 ``maxBreadth`` 截断、再按名字去重，进下一层 frontier；
    - 进度按 ``AutoPrereqProgress.label`` 同款文案经 ``job.report`` 上报
      （真实层级进度，不谎报）；
    - 取消检查点在每层开始与每个节点请求前（``job.check_cancelled``）；
    - 任一层调用失败 → 整体 failed（半成品不回传，Q6 取消回滚语义一致）；
    - **锚点硬规则**：全程不写任何库（建议形态，入库在 App 侧）。
    """
    inputs = job.inputs or {}
    target = inputs.get('target')
    if isinstance(target, dict):
        name = str(target.get('name') or '').strip()
        ttype = str(target.get('type') or '').strip()
        definition = str(target.get('definition') or '').strip()
    elif isinstance(target, str) and target.strip():
        # 兼容直传 "name | type | definition" 字符串：按纯 name 处理。
        name, ttype, definition = target.strip(), '', ''
    else:
        raise invalid_request('T4 缺少 inputs.target（{name, type, definition}）')
    if not name:
        raise invalid_request('T4 的 inputs.target.name 不能为空')

    depth_code = str(inputs.get('depth') or 'medium').strip().lower()
    if depth_code not in _DEPTH_LEVELS:
        depth_code = 'medium'
    custom = (str(inputs.get('custom_instruction') or '').strip()) or None
    if depth_code == 'custom':
        max_levels, max_breadth = _parse_custom_instruction(custom)
    else:
        max_levels = _DEPTH_LEVELS[depth_code]
        max_breadth = _DEPTH_BREADTH[depth_code]
    depth_instruction = _depth_instruction_for(depth_code, custom)

    seen = {name.lower()}
    frontier: list[tuple[str, str, str]] = [(name, ttype, definition)]
    suggestions: list[dict[str, Any]] = []

    for level in range(1, max_levels + 1):
        if not frontier:
            break
        job.check_cancelled()
        next_frontier: list[tuple[str, str, str]] = []
        done = 0
        for fname, ftype, fdef in frontier:
            job.check_cancelled()
            body: dict[str, Any] = {
                'inputs': {
                    'target': f'{fname} | {ftype} | {fdef}',
                    'depth': depth_code,
                    'depth_instruction': depth_instruction,
                },
                'user': job.user,
            }
            if job.timeout_s is not None:
                body['timeout_s'] = job.timeout_s
            if job.backend:
                body['backend'] = job.backend
            if job.model:
                body['model'] = job.model
            payload = await run_task_core(state, 'T4', body)
            done += 1
            job.report(
                _t4_percent(level, done, len(frontier), max_levels),
                f'正在请求前置（第 {level}/{max_levels} 层，'
                f'本层已完成 {done}/{len(frontier)}）…',
            )
            parsed = payload.get('parsed')
            if not isinstance(parsed, dict):
                preview = str(payload.get('content') or '')[:200]
                raise LlmError(
                    'bad_json',
                    f'T4 输出解析失败（parsed 非 Map）：{preview or "(空输出)"}',
                    backend=payload.get('backend'),
                )
            raw_gaps = parsed.get('gaps')
            if not isinstance(raw_gaps, list):
                raw_gaps = []
            # 先 maxBreadth 截断、再按名字去重（与 App 侧 .take(maxBreadth) 顺序一致）。
            for g in [g for g in raw_gaps if isinstance(g, dict)][:max_breadth]:
                gname = str(g.get('name') or '').strip()
                if not gname:
                    continue
                lower = gname.lower()
                if lower in seen:
                    continue
                seen.add(lower)
                suggestions.append(
                    {
                        'name': gname,
                        'type': str(g.get('type') or '').strip(),
                        'definition': str(g.get('definition') or '').strip(),
                        'reason': str(g.get('reason') or '').strip(),
                        'level': level,
                    }
                )
                next_frontier.append(
                    (gname, str(g.get('type') or '').strip(),
                     str(g.get('definition') or '').strip())
                )
        frontier = next_frontier

    return {
        'task': 'T4',
        'suggestions': suggestions,
        'count': len(suggestions),
        'max_levels': max_levels,
        'used_fallback': False,
    }


def _t4_percent(level: int, done: int, level_total: int, max_levels: int) -> float:
    """``(level-1 + levelDone/levelTotal) / totalLevels`` → 0–100（方案 §4.4）。"""
    if max_levels <= 0:
        return 0.0
    inner = (done / level_total) if level_total else 1.0
    return ((level - 1) + inner) / max_levels * 100.0


def _parse_custom_instruction(text: str | None) -> tuple[int, int]:
    """自由文本 → (maxLevels, maxBreadth)（与 App 侧关键词映射逐条一致）。"""
    t = (text or '').lower()
    if '大学' in t or '本科' in t:
        return 2, 4
    if '高中' in t or '初中' in t:
        return 2, 4
    if '小学' in t or '常识' in t or '基础' in t:
        return 3, 5
    if '一层' in t or '直接前置' in t or '最近一层' in t or '只要一层' in t:
        return 1, 3
    # 无法识别 → 回落 high。
    return 3, 5


def _depth_instruction_for(depth_code: str, custom: str | None) -> str:
    """T4 的 ``depth_instruction``（线上部署态必填，与 App 侧文案一致）。"""
    if depth_code == 'custom':
        return custom or '根据目标知识点的性质，自行判断合适的讲解深度与学段。'
    return {
        'low': '大学/高中入门级：只列最近一层直接相关前置。',
        'medium': '初中/高中基础：列出中等基础的前置。',
        'high': '小学/常识级：尽量补到最基础的概念。',
    }[depth_code]
