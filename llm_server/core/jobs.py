"""进程内 AI 任务队列（``POST /v1/jobs`` 的状态机与 worker 池）。

定位：App 的**批量型** AI 功能（T1 提取 / T3 自动连线 / T4 递归补前置 / T5 检测）
时长 18s–数分钟，提交后应当立即释放界面。本模块提供：

- ``Job``：一个异步任务的全部可观测状态（status / stage / elapsed / result / error）；
- ``JobQueue``：``asyncio.Queue`` + N 个 worker 协程（N=``config.jobs.concurrency``，
  默认 1）、资源锁表（``resource_key`` → job_id，409 防线）、幂等去重（60s TTL）、
  终态环形保留（``config.jobs.retain``，默认 200）。

设计约束（与 ``core/stats.py`` / ``core/logbuf.py`` 同构）：

- **内存态、不落盘**：服务重启丢任务是可接受降级（App 轮询拿到 404 后标
  ``failed(服务已重启，请重试)``）；
- **永不抛**：队列自身的查询 / 取消 / 状态突变不抛业务异常；worker 里未捕获异常
  统一转 ``failed(internal)``，绝不把 worker 协程搞死；
- **不返回 null 数组**：空态查询返回空 list / None，见各方法 docstring；
- **执行体注入**：本模块不 import 任何 router（避免环依赖），真正干活的
  ``executor(job) -> dict`` 由 ``routers/jobs.py`` 装配后注入；
- 单事件循环内突变，无跨线程竞争；``Job.report`` 只做内存赋值。

状态机::

    queued → running → done | failed | canceled
    queued → canceled（未开始，取消立即生效）

取消语义（UI 明示「当前步不可中断」）：``queued`` 立即取消；``running`` 只置
``cancel_requested``，由执行体在**检查点**（T4 每层每个节点请求前、复合 job 的
stage 间）主动抛 :class:`JobCancelled`。单次 LLM HTTP 调用不可中断（Ollama 没有
中断 API），最坏多等一个 stage。
"""

from __future__ import annotations

import asyncio
import time
import uuid
from collections import deque
from typing import Any, Callable

from core.errors import LlmError, invalid_request
from core.logging import get_logger

_log = get_logger('job')

#: 合法任务状态（顺序即 UI 排序权重之外的展示顺序）。
STATUSES = ('queued', 'running', 'done', 'failed', 'canceled')

#: 幂等键 TTL（秒）：同 key 在 TTL 内重复提交直接返回既有 job。
IDEMPOTENCY_TTL_S = 60.0

#: label / resource_key 截断上限（防客户端塞长文本撑爆内存与响应）。
MAX_LABEL_CHARS = 120
MAX_KEY_CHARS = 120
#: task 是任务分类标签（如 SESSION / BACKGROUND / EXTERNAL），纯元数据，
#: 不参与服务端分派。App 使用 'BACKGROUND'（10 字符）等长业务名，故放宽到 32。
MAX_TASK_CHARS = 32

#: 单 stage 任务（chat / structured）只有「一次 LLM 调用」语义，进入 running
#: 后没有中间进度信号：按方案 §4.4「不谎报」铁律，进度保持 0（App 侧显示
#: 不确定态：只走计时、不画假百分比），等模型阶段不假跳。多阶段真实进度由
#: 执行体（如 T4）逐层 ``report`` 推进。

JobExecutor = Callable[['Job'], Any]


class JobCancelled(Exception):
    """执行体在检查点发现 ``cancel_requested`` 时抛出（→ 终态 canceled）。"""


def _new_job_id() -> str:
    return f'job_{uuid.uuid4().hex[:12]}'


class Job:
    """一个异步 AI 任务的可观测状态（worker 与 API 层共用的唯一事实源）。"""

    __slots__ = (
        'job_id', 'task', 'label', 'resource_key', 'stages', 'inputs', 'query',
        'variant', 'backend', 'model', 'user', 'timeout_s', 'idempotency_key',
        'status', 'stage_index', 'stage_percent', 'stage_message',
        'cancel_requested', 'result', 'error',
        'submitted_at', 'started_at', 'finished_at', 'seq',
        'updated_at', 'revision', 'external', 'heartbeat_deadline',
    )

    def __init__(
        self,
        *,
        task: str,
        label: str,
        resource_key: str = '',
        stages: list[str] | None = None,
        inputs: dict[str, Any] | None = None,
        query: str = '',
        variant: str | None = None,
        backend: str | None = None,
        model: str | None = None,
        user: str = 'aimindtree-app',
        timeout_s: float | None = None,
        idempotency_key: str = '',
    ) -> None:
        self.job_id = _new_job_id()
        self.task = task
        self.label = label
        self.resource_key = resource_key
        self.stages = stages or [task]
        self.inputs = inputs or {}
        self.query = query
        self.variant = variant
        self.backend = backend
        self.model = model
        self.user = user
        self.timeout_s = timeout_s
        self.idempotency_key = idempotency_key

        self.status = 'queued'
        self.stage_index = 0
        self.stage_percent = 0.0
        self.stage_message = '排队中…'
        self.cancel_requested = False
        self.result: dict[str, Any] | None = None
        self.error: dict[str, Any] | None = None

        now = time.time()
        self.submitted_at = now
        self.started_at: float | None = None
        self.finished_at: float | None = None
        self.seq = 0
        self.updated_at = now
        self.revision = 0
        self.external = False
        self.heartbeat_deadline: float | None = None

    # ---------- 状态突变（worker / cancel 调用；单事件循环，无需加锁） ----------

    @property
    def elapsed_ms(self) -> int:
        """已用毫秒（终态用 finished-started，进行中用 now-started/submitted）。"""
        if self.started_at is not None:
            end = self.finished_at if self.finished_at is not None else time.time()
            return int((end - self.started_at) * 1000)
        end = self.finished_at if self.finished_at is not None else time.time()
        return int((end - self.submitted_at) * 1000)

    def report(self, percent: float, message: str) -> None:
        """执行体上报进度（0–100）。**不谎报**：等模型的阶段由执行体决定是否上报。"""
        try:
            self.stage_percent = max(0.0, min(100.0, float(percent)))
        except (TypeError, ValueError):
            return
        self.stage_message = str(message or '')[:200]
        self.touch()

    def touch(self) -> None:
        """每次可观测状态变化都 bump（``updated_at`` / ``revision`` 供 App 判断
        「这次轮询相对上次有没有新东西」，避免无变化时整行重绘 / 误判）。"""
        self.updated_at = time.time()
        self.revision += 1

    def start(self) -> None:
        self.status = 'running'
        self.started_at = time.time()
        # 诚实：单 stage 任务没有中间进度，保持 0（App 显示不确定态，不假报）。
        self.stage_percent = 0.0
        self.stage_message = f'正在请求（{self.task}）…'
        self.touch()

    def finish(self, result: dict[str, Any] | None) -> None:
        self.status = 'done'
        self.finished_at = time.time()
        self.stage_percent = 100.0
        self.stage_message = '已完成'
        self.result = result if isinstance(result, dict) else {}
        self.touch()

    def fail(self, code: str, message: str, *, retryable: bool = False) -> None:
        self.status = 'failed'
        self.finished_at = time.time()
        self.stage_message = '失败'
        self.error = {
            'code': str(code or 'internal'),
            'message': str(message or '')[:500],
            'retryable': bool(retryable),
        }
        self.touch()

    def mark_canceled(self, reason: str = '已取消') -> None:
        self.status = 'canceled'
        self.finished_at = time.time()
        self.stage_message = str(reason or '已取消')[:100]
        self.touch()

    def check_cancelled(self) -> None:
        """检查点：执行体在每层 / 每个节点请求前调用。"""
        if self.cancel_requested:
            raise JobCancelled()

    # ---------- 序列化 ----------

    def snapshot(self) -> dict[str, Any]:
        """API 视图（与方案 §4.2 契约一致）。"""
        return {
            'job_id': self.job_id,
            'task': self.task,
            'label': self.label,
            'resource_key': self.resource_key,
            'stages': list(self.stages),
            'status': self.status,
            'stage': {
                'index': self.stage_index + 1,
                'total': len(self.stages),
                'task': self.stages[min(self.stage_index, len(self.stages) - 1)],
                'percent': int(round(self.stage_percent)),
                'message': self.stage_message,
            },
            'submitted_at': self.submitted_at,
            'started_at': self.started_at,
            'finished_at': self.finished_at,
            'elapsed_ms': self.elapsed_ms,
            'result': self.result,
            'error': self.error,
            'cancel_requested': self.cancel_requested,
            'external': self.external,
            'updated_at': self.updated_at,
            'revision': self.revision,
        }


class JobQueue:
    """内存任务队列：提交 → worker 池执行 → 终态进环形缓冲。

    线程模型：所有突变发生在事件循环线程；查询方法（``get`` / ``list_jobs``）
    也在循环里被调用，无锁。``stop`` 在 lifespan 关闭时取消 worker 协程。
    """

    def __init__(
        self,
        *,
        concurrency: int = 1,
        retain: int = 200,
        executor: JobExecutor | None = None,
        external_heartbeat_s: float = 30.0,
        sweep_interval_s: float = 5.0,
    ) -> None:
        try:
            self._concurrency = max(1, int(concurrency))
        except (TypeError, ValueError):
            self._concurrency = 1
        try:
            self._retain = max(1, int(retain))
        except (TypeError, ValueError):
            self._retain = 200
        self._executor = executor
        self._queue: asyncio.Queue[Job] | None = None
        self._workers: list[asyncio.Task[None]] = []
        self._active: dict[str, Job] = {}
        self._recent: deque[Job] = deque(maxlen=self._retain)
        #: 外部驱动任务（App 后台体 / 交互会话 / 流式会话）登记表：
        #: 这类任务服务端不执行，只持有状态 + 心跳看门狗（超时 failed）。
        self._external: dict[str, Job] = {}
        #: 心跳看门狗扫描周期（秒）与单次超时（秒）。
        self._external_heartbeat_s = max(5.0, float(external_heartbeat_s))
        self._sweep_interval_s = max(1.0, float(sweep_interval_s))
        self._sweep_task: asyncio.Task[None] | None = None
        #: 资源锁表：resource_key → job_id（仅 queued/running 持有；终态即摘除）。
        self._locks: dict[str, str] = {}
        #: 幂等表：key → (job_id, ts)。job_id 建好前先占位空串。
        self._idem: dict[str, tuple[str, float]] = {}
        self._seq = 0

    # ---------- 生命周期 ----------

    def set_executor(self, executor: JobExecutor) -> None:
        """注入执行体（``routers/jobs.py`` 装配，避免 core → routers 环依赖）。"""
        self._executor = executor

    def start(self) -> None:
        """起 worker 池（lifespan 启动时调一次；重复调用幂等）。"""
        if self._queue is not None:
            return
        self._queue = asyncio.Queue()
        for i in range(self._concurrency):
            self._workers.append(
                asyncio.create_task(self._worker(i), name=f'job-worker-{i}')
            )
        self._sweep_task = asyncio.create_task(self._sweep_loop(), name='job-sweep')
        _log.info(
            '任务队列已启动：concurrency=%d retain=%d external_heartbeat=%.0fs',
            self._concurrency,
            self._retain,
            self._external_heartbeat_s,
        )

    async def stop(self) -> None:
        """停 worker 池（lifespan 关闭时调）。

        worker 里的取消可能被后端层（``protocols/base.py`` 宽 except
        BaseException）转成 LlmError 而吞掉，因此：① worker 循环里补检
        ``task.cancelling()`` 显式补 CancelledError；②这里用
        ``asyncio.wait(timeout)`` 兜底，绝不为停机无限等待
        （进行中的 job 随进程结束，不补终态，方案 §8.3）。
        """
        for w in self._workers:
            w.cancel()
        if self._workers:
            await asyncio.wait(self._workers, timeout=5.0)
        self._workers.clear()
        self._queue = None
        if self._sweep_task is not None:
            self._sweep_task.cancel()
            try:
                await asyncio.wait({self._sweep_task}, timeout=2.0)
            except (asyncio.CancelledError, Exception):
                pass
            self._sweep_task = None

    @property
    def concurrency(self) -> int:
        return self._concurrency

    # ---------- 提交 ----------

    def submit(self, body: dict[str, Any]) -> tuple[Job, bool]:
        """校验 + 建 job + 入队。返回 ``(job, deduped)``。

        Raises:
            LlmError: ``invalid_request``（缺 task / 字段类型错）；
                ``lock_conflict``（409，resource_key 已被未终态 job 持有）。
        """
        if not isinstance(body, dict):
            raise invalid_request('请求体必须是 JSON 对象')

        task = str(body.get('task') or '').strip().upper()
        if not task:
            raise invalid_request('缺少 task（任务代码，如 T1 / T3 / T4）')
        if len(task) > MAX_TASK_CHARS:
            raise invalid_request(f'task 过长（>{MAX_TASK_CHARS} 字符）')

        label = str(body.get('label') or '').strip()[:MAX_LABEL_CHARS] or task
        resource_key = str(body.get('resource_key') or '').strip()[:MAX_KEY_CHARS]

        stages_raw = body.get('stages')
        stages = [task]
        if isinstance(stages_raw, list):
            cleaned = [str(s).strip().upper() for s in stages_raw if str(s).strip()]
            # 复合流水线的 stage 编排在 App 侧链式提交（方案 §11.1），
            # 服务端只执行 task；stages 仅回显备用（首元素必须与 task 一致）。
            if cleaned and cleaned[0] == task:
                stages = cleaned[:8]

        inputs = body.get('inputs')
        if inputs is not None and not isinstance(inputs, dict):
            raise invalid_request('inputs 必须是 JSON 对象')

        backend = body.get('backend')
        backend = str(backend).strip() or None if backend else None
        model = body.get('model')
        model = str(model).strip() or None if model else None
        variant = body.get('variant')
        variant = str(variant).strip() or None if variant else None
        user = str(body.get('user') or 'aimindtree-app')[:64]
        timeout_s = body.get('timeout_s')
        try:
            timeout_s = float(timeout_s) if timeout_s is not None else None
        except (TypeError, ValueError):
            timeout_s = None
        idem = str(body.get('idempotency_key') or '').strip()[:64]

        now = time.time()
        self._gc_idem(now)

        # 1) 幂等：TTL 内同 key 直接返回既有 job（deduped=True）。
        if idem:
            hit = self._idem.get(idem)
            if hit is not None and now - hit[1] < IDEMPOTENCY_TTL_S and hit[0]:
                existing = self._active.get(hit[0]) or self._find_recent(hit[0])
                if existing is not None:
                    return existing, True

        # 2) 资源锁（409 防线；App 侧 isLocked 才是唯一判定入口，方案 §11.1）。
        if resource_key:
            holder = self._locks.get(resource_key)
            if holder and holder in self._active:
                raise LlmError(
                    'lock_conflict',
                    f'资源 {resource_key} 已有任务在进行（{holder}），完成后自动放行',
                    retryable=True,
                )

        job = Job(
            task=task,
            label=label,
            resource_key=resource_key,
            stages=stages,
            inputs=inputs,
            query=str(body.get('query') or ''),
            variant=variant,
            backend=backend,
            model=model,
            user=user,
            timeout_s=timeout_s,
            idempotency_key=idem,
        )
        self._seq += 1
        job.seq = self._seq
        self._active[job.job_id] = job
        if resource_key:
            self._locks[resource_key] = job.job_id
        if idem:
            self._idem[idem] = (job.job_id, now)

        assert self._queue is not None, 'JobQueue.start() 尚未调用'
        self._queue.put_nowait(job)
        _log.info(
            'job %s 已提交：task=%s label=%s key=%s',
            job.job_id,
            task,
            label,
            resource_key or '-',
        )
        return job, False

    # ---------- 查询 ----------

    def get(self, job_id: str) -> Job | None:
        """按 id 查（未终态优先，再查外部登记表，最后查终态缓冲）。找不到返回 None（不抛）。"""
        job = self._active.get(str(job_id))
        if job is not None:
            return job
        job = self._external.get(str(job_id))
        if job is not None:
            return job
        return self._find_recent(str(job_id))

    def list_jobs(
        self,
        status: str | None = None,
        limit: int = 50,
    ) -> dict[str, Any]:
        """任务列表（未终态 + 最近终态，新的在前）。

        - 状态过滤：只认合法状态；**全非法 → 返回空列表**（不再退化成「不过滤返回全量」）。
        - **活跃任务（queued/running）永不被截断**：即便历史终态很多、超过 limit，
          活跃任务也始终出现在结果里（App 托盘 / 对账依赖这一点，方案 §8.2）。
        - 终态部分按 ``limit`` 截断（优先保留 seq 更大的新任务）。

        Args:
            status: 逗号分隔的状态过滤（如 ``running,queued``）；非法值忽略。
            limit: 1–200，越界钳制。

        Returns:
            ``{'jobs': [...], 'buffer_size': int, 'concurrency': int}``；
            空态时 ``jobs`` 为 ``[]``（**不返回 null 数组**）。
        """
        try:
            cap = max(1, min(200, int(limit)))
        except (TypeError, ValueError):
            cap = 50
        wanted: set[str] | None = None
        if status:
            raw = {s.strip() for s in str(status).split(',') if s.strip()}
            valid = raw & set(STATUSES)
            if raw and not valid:
                # 传入状态全非法（如 ``?status=foo``）→ 返回空列表，而非退化成全量。
                return {
                    'jobs': [],
                    'buffer_size': len(self._active) + len(self._external) + len(self._recent),
                    'concurrency': self._concurrency,
                }
            wanted = valid

        # 活跃任务（queued/running，含外部登记任务）无论历史多长都出现在结果里。
        all_jobs = [*self._active.values(), *self._external.values(), *self._recent]
        if wanted:
            all_jobs = [j for j in all_jobs if j.status in wanted]
        active = [j for j in all_jobs if j.status in ('queued', 'running')]
        terminal = [j for j in all_jobs if j.status not in ('queued', 'running')]
        active.sort(key=lambda j: j.seq, reverse=True)
        terminal.sort(key=lambda j: j.seq, reverse=True)
        # 终态部分按 limit 截断（活跃任务已全额保留）。
        visible = active + terminal[:max(0, cap - len(active))]
        return {
            'jobs': [j.snapshot() for j in visible],
            'buffer_size': len(self._active) + len(self._external) + len(self._recent),
            'concurrency': self._concurrency,
        }

    # ---------- 取消 ----------

    def cancel(self, job_id: str) -> Job:
        """取消任务。

        - ``queued``：立即置 canceled（worker 不会取到）；
        - ``running``：置 ``cancel_requested``，执行体下一个检查点生效
          （UI 明示「当前步不可中断」）。

        Raises:
            LlmError: ``invalid_request``（任务不存在 / 已终态）。
        """
        job = self.get(str(job_id))
        if job is None:
            raise invalid_request(f'任务不存在：{job_id}')
        if job.status in ('done', 'failed', 'canceled'):
            raise invalid_request(f'任务已终态（{job.status}），无需取消')
        if job.status == 'queued':
            job.mark_canceled('已取消（未开始）')
            self._finish(job)
            _log.info('job %s 已取消（queued → canceled）', job.job_id)
        else:
            job.cancel_requested = True
            job.stage_message = '已请求取消（当前步不可中断，下一步生效）…'
            _log.info('job %s 已请求取消（running，检查点生效）', job.job_id)
        return job

    # ---------- worker ----------

    async def _worker(self, idx: int) -> None:
        queue = self._queue
        assert queue is not None
        while True:
            job = await queue.get()
            try:
                await self._run_job(job)
            except asyncio.CancelledError:
                # 进程关闭：worker 被取消，job 保持原状（不补终态，方案 §8.3）。
                raise
            except Exception as exc:  # noqa: BLE001 - worker 绝不能死
                _log.error('job %s worker-%d 未捕获异常：%s', job.job_id, idx, exc)
                job.fail('internal', f'队列内部错误：{type(exc).__name__}: {exc}')
                self._finish(job)
            finally:
                queue.task_done()
            # 停机取消被后端层宽 except 吞掉时（CancelledError → LlmError），
            # _run_job 会「正常返回」。这里补检 task.cancelling() 显式再抛，
            # 否则 worker 复活后空转，stop() 永远等不到它（3.11+ API）。
            task = asyncio.current_task()
            if task is not None and task.cancelling():
                raise asyncio.CancelledError()

    async def _run_job(self, job: Job) -> None:
        if job.status != 'queued':
            # queued 期间被取消（cancel 已把它移出 _active 但队列里还有它）：
            # worker 取到时已是终态，直接跳过，**绝不复活**（cancel → running 是 bug）。
            return
        if job.cancel_requested:
            job.mark_canceled('已取消（未开始）')
            self._finish(job)
            return
        if self._executor is None:
            job.fail('internal', '任务队列未装配执行体')
            self._finish(job)
            return
        job.start()
        try:
            result = await self._executor(job)
            job.finish(result)
            _log.info(
                'job %s 完成：task=%s latency=%dms',
                job.job_id,
                job.task,
                job.elapsed_ms,
            )
        except JobCancelled:
            job.mark_canceled('已取消')
            _log.info('job %s 已取消（检查点生效）', job.job_id)
        except LlmError as exc:
            job.fail(exc.code, exc.message, retryable=exc.retryable)
            _log.warning('job %s 失败：%s（%s）', job.job_id, exc.code, exc.message)
        except Exception as exc:  # noqa: BLE001 - 任何异常都转终态，绝不挂住队列
            job.fail('internal', f'{type(exc).__name__}: {exc}')
            _log.error('job %s 未捕获异常：%s', job.job_id, exc)
        finally:
            self._finish(job)

    # ---------- 内部 ----------

    def _finish(self, job: Job) -> None:
        """终态收尾：摘资源锁 + 移出活跃/外部登记表 + 移入环形缓冲（幂等，重复调用安全）。"""
        self._active.pop(job.job_id, None)
        self._external.pop(job.job_id, None)
        if job.resource_key and self._locks.get(job.resource_key) == job.job_id:
            del self._locks[job.resource_key]
        if not any(j.job_id == job.job_id for j in self._recent):
            self._recent.appendleft(job)

    def _find_recent(self, job_id: str) -> Job | None:
        for j in self._recent:
            if j.job_id == job_id:
                return j
        return None

    # ---------- 外部驱动任务（App 后台体 / 交互会话 / 流式会话） ----------

    def register_external(
        self,
        *,
        task: str,
        label: str,
        resource_key: str = '',
        job_id: str | None = None,
        heartbeat_s: float | None = None,
        user: str = 'aimindtree-app',
    ) -> Job:
        """登记一个**外部驱动**的任务实体（服务端不执行，只持有状态 + 心跳看门狗）。

        调用方通过 :meth:`report_external` 周期性上报进度（同时续心跳），
        :meth:`finish_external` 标终态。看门狗见 :meth:`_sweep_external`：
        超过 ``heartbeat_s``（默认 :attr:`_external_heartbeat_s`）无心跳即判
        ``failed(watchdog_timeout)``——覆盖「App 被强杀、后台任务人間蒸发」的盲区。

        Raises:
            LlmError: ``invalid_request``（job_id 冲突 / task 非法）。
        """
        task = str(task).strip().upper()
        if not task:
            raise invalid_request('外部任务缺少 task')
        if len(task) > MAX_TASK_CHARS:
            raise invalid_request(f'task 过长（>{MAX_TASK_CHARS} 字符）')
        label = str(label or '').strip()[:MAX_LABEL_CHARS] or task
        resource_key = str(resource_key or '').strip()[:MAX_KEY_CHARS]
        if job_id:
            job_id = str(job_id).strip()
            if not job_id or len(job_id) > 64:
                raise invalid_request('job_id 非法（空或过长）')
            if (
                job_id in self._active
                or job_id in self._external
                or self._find_recent(job_id) is not None
            ):
                raise invalid_request(f'job_id 已存在：{job_id}')
        else:
            job_id = _new_job_id()

        # heartbeat_s=None → 看门狗豁免（无截止时间）。用于「交互会话 / 流式
        # 会话」这类由 App 本地 SSE 流驱动、不靠心跳续命、且可能跑很久的任务：
        # 退出页面不中断、LLM 慢也不该被误杀（方案 B）。非空 → 正常看门狗
        # （默认 30s），用于 App 后台体等「App 被强杀应超时标 failed」的任务。
        try:
            hb = None if heartbeat_s is None else max(5.0, float(heartbeat_s))
        except (TypeError, ValueError):
            hb = None

        job = Job(
            task=task,
            label=label,
            resource_key=resource_key,
            user=str(user)[:64],
        )
        job.job_id = job_id
        job.external = True
        job.status = 'running'
        job.stage_message = '进行中…'
        job.started_at = time.time()
        # 豁免任务 deadline=None：_sweep_external 跳过它；非空才进看门狗。
        job.heartbeat_deadline = None if hb is None else time.monotonic() + hb
        self._seq += 1
        job.seq = self._seq
        self._external[job.job_id] = job
        _log.info('外部任务 %s 已登记：task=%s label=%s', job.job_id, task, label)
        return job

    def report_external(
        self,
        job_id: str,
        *,
        percent: float | None = None,
        message: str | None = None,
        stage_task: str | None = None,
        stage_index: int | None = None,
        stage_total: int | None = None,
    ) -> Job:
        """上报外部任务进度（并续心跳）。"""
        job = self._external.get(str(job_id))
        if job is None:
            raise invalid_request(f'外部任务不存在：{job_id}')
        if job.status not in ('queued', 'running'):
            raise invalid_request(f'外部任务已终态（{job.status}）')
        if percent is not None:
            try:
                job.stage_percent = max(0.0, min(100.0, float(percent)))
            except (TypeError, ValueError):
                pass
        if message is not None:
            job.stage_message = str(message)[:200]
        if stage_task is not None:
            name = str(stage_task).strip().upper()
            if name:
                if job.stages:
                    job.stages[0] = name
                else:
                    job.stages = [name]
        if stage_total is not None:
            try:
                t = max(1, int(stage_total))
                base = job.stages[0] if job.stages else job.task
                job.stages = [base] * t
            except (TypeError, ValueError):
                pass
        if stage_index is not None:
            try:
                job.stage_index = max(0, int(stage_index) - 1)
            except (TypeError, ValueError):
                pass
        # 续心跳：仅当该任务配置了看门狗（deadline 非 None）才重置截止时间。
        # 看门狗豁免的任务（heartbeat_s=None 登记）上报只更新进度，不被拉回看门狗。
        if job.heartbeat_deadline is not None:
            job.heartbeat_deadline = time.monotonic() + self._external_heartbeat_s
        job.touch()
        return job

    def finish_external(
        self,
        job_id: str,
        *,
        status: str,
        result: dict[str, Any] | None = None,
        error: dict[str, Any] | None = None,
        message: str | None = None,
    ) -> Job:
        """外部任务终态（``done`` / ``failed`` / ``canceled``）。"""
        job = self._external.get(str(job_id))
        if job is None:
            raise invalid_request(f'外部任务不存在：{job_id}')
        status = str(status).strip().lower()
        if status not in ('done', 'failed', 'canceled'):
            raise invalid_request(f'非法终态：{status}')
        job.status = status
        job.finished_at = time.time()
        job.heartbeat_deadline = None
        if message:
            job.stage_message = str(message)[:200]
        else:
            job.stage_message = {
                'done': '已完成',
                'failed': '失败',
                'canceled': '已取消',
            }[status]
        if status == 'done':
            job.stage_percent = 100.0
        if isinstance(result, dict):
            job.result = result
        if isinstance(error, dict):
            job.error = error
        job.touch()
        self._finish_external(job)
        _log.info('外部任务 %s 已终态：%s', job.job_id, status)
        return job

    def _finish_external(self, job: Job) -> None:
        """外部任务终态收尾：移出登记表、进环形缓冲。"""
        self._external.pop(job.job_id, None)
        if not any(j.job_id == job.job_id for j in self._recent):
            self._recent.appendleft(job)

    def _sweep_external(self) -> None:
        """心跳看门狗：扫描外部任务，超时无心跳的 running 任务标 failed。

        纯同步、无副作用风险；由 :meth:`_sweep_loop` 周期驱动（或测试直接调用）。
        """
        now = time.monotonic()
        dead = [
            j for j in self._external.values()
            if j.heartbeat_deadline is not None
            and now > j.heartbeat_deadline
            and j.status in ('queued', 'running')
        ]
        for job in dead:
            job.fail('watchdog_timeout', '任务心跳超时（客户端失联），已自动标记失败')
            self._finish_external(job)
            _log.warning('外部任务 %s 心跳超时，标记 failed（watchdog）', job.job_id)

    async def _sweep_loop(self) -> None:
        """看门狗扫描循环（``start()`` 启动，``stop()`` 取消）。"""
        try:
            while True:
                await asyncio.sleep(self._sweep_interval_s)
                try:
                    self._sweep_external()
                except Exception as exc:  # noqa: BLE001 - 看门狗自己不能挂
                    _log.error('external sweep error: %s', exc)
        except asyncio.CancelledError:
            pass

    def _gc_idem(self, now: float) -> None:
        """惰性清理过期幂等键（提交路径上顺带做，不另起定时器）。"""
        if len(self._idem) < 512:
            return
        stale = [k for k, (_, ts) in self._idem.items() if now - ts >= IDEMPOTENCY_TTL_S]
        for k in stale:
            self._idem.pop(k, None)


def reset_queue(queue: JobQueue | None) -> None:
    """清空队列全部状态（**仅供测试**：配合全新 JobQueue 使用）。"""
    if queue is None:
        return
    queue._active.clear()
    queue._recent.clear()
    queue._external.clear()
    queue._locks.clear()
    queue._idem.clear()
    queue._seq = 0
