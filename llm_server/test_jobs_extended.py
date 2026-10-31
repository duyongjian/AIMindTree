"""``core/jobs.py`` 扩展逻辑单测（stdlib unittest，无 FastAPI 依赖）。

覆盖本次「完整修复」：
- list_jobs 状态过滤（全非法 → 空，而非退化成全量）；
- 活跃任务（queued/running）永不被 limit 截断（即便历史终态很多）；
- 外部任务登记 / 进度上报 / 终态；
- 心跳看门狗：超时无心跳的 running 外部任务被自动标 failed；
- snapshot 暴露 updated_at / revision / external。
"""

import time
import unittest

from core.jobs import Job, JobQueue, reset_queue


def _make_queue() -> JobQueue:
    q = JobQueue(concurrency=1, retain=200, external_heartbeat_s=30.0, sweep_interval_s=5.0)
    return q


def _make_done(q: JobQueue, idx: int) -> Job:
    """往 _recent 塞一个已终态 job（模拟历史），seq 单调递增。"""
    j = Job(task='T1', label=f'hist-{idx}')
    j.status = 'done'
    j.finished_at = time.time()
    j.seq = idx
    q._recent.append(j)
    return j


class ListFilterTest(unittest.TestCase):
    def setUp(self) -> None:
        self.q = _make_queue()

    def test_all_illegal_status_returns_empty(self):
        # 全非法 → 空列表，而非「不过滤返回全量」（回归原 bug：wanted &= set(STATUSES) or wanted）。
        j = self.q.register_external(task='EXTERNAL', label='t')
        out = self.q.list_jobs(status='foo,bar')
        self.assertEqual(out['jobs'], [])
        # 该任务仍在（只是被过滤掉）。
        self.assertIsNotNone(self.q.get(j.job_id))

    def test_valid_status_filter_works(self):
        run = self.q.register_external(task='EXTERNAL', label='running-task')
        out = self.q.list_jobs(status='running')
        ids = [x['job_id'] for x in out['jobs']]
        self.assertIn(run.job_id, ids)
        out = self.q.list_jobs(status='done')
        self.assertNotIn(run.job_id, [x['job_id'] for x in out['jobs']])

    def test_active_never_truncated_by_limit(self):
        # 灌满 80 个历史终态，远超 limit=10。
        for i in range(1, 81):
            _make_done(self.q, i)
        active = self.q.register_external(task='EXTERNAL', label='live')
        out = self.q.list_jobs(limit=10)
        ids = [x['job_id'] for x in out['jobs']]
        # 活跃任务必须出现在结果里（即便只留 9 个历史名额）。
        self.assertIn(active.job_id, ids)
        self.assertLessEqual(len(out['jobs']), 10)
        # 活跃任务排在终态之前。
        self.assertEqual(out['jobs'][0]['job_id'], active.job_id)

    def test_buffer_size_counts_external(self):
        self.q.register_external(task='EXTERNAL', label='a')
        out = self.q.list_jobs()
        self.assertEqual(out['buffer_size'], 1)


class ExternalLifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.q = _make_queue()

    def test_register_get_report_finish(self):
        j = self.q.register_external(task='EXTERNAL', label='bg-task', job_id='ext-1')
        self.assertEqual(j.job_id, 'ext-1')
        self.assertTrue(j.external)
        self.assertEqual(j.status, 'running')
        snap0 = j.snapshot()
        self.assertTrue(snap0['external'])
        self.assertIn('updated_at', snap0)
        self.assertIn('revision', snap0)
        rev0 = snap0['revision']

        # 进度上报续心跳 + bump revision。
        j2 = self.q.report_external('ext-1', percent=42.0, message='step 2/5')
        self.assertEqual(j2.stage_percent, 42.0)
        self.assertEqual(j2.stage_message, 'step 2/5')
        self.assertEqual(j2.revision, rev0 + 1)

        # 终态后从 _external 移出、进 _recent。
        j3 = self.q.finish_external('ext-1', status='done', result={'ok': True})
        self.assertEqual(j3.status, 'done')
        self.assertIsNone(self.q._external.get('ext-1'))
        self.assertIsNotNone(self.q._find_recent('ext-1'))

    def test_duplicate_job_id_rejected(self):
        self.q.register_external(task='EXTERNAL', label='a', job_id='dup-1')
        with self.assertRaises(Exception):
            self.q.register_external(task='EXTERNAL', label='b', job_id='dup-1')

    def test_report_missing_job_raises(self):
        with self.assertRaises(Exception):
            self.q.report_external('nope', percent=10)

    def test_finish_illegal_status_raises(self):
        self.q.register_external(task='EXTERNAL', label='a', job_id='ext-x')
        with self.assertRaises(Exception):
            self.q.finish_external('ext-x', status='weird')


class WatchdogTest(unittest.TestCase):
    def setUp(self) -> None:
        self.q = _make_queue()

    def test_heartbeat_timeout_marks_failed(self):
        j = self.q.register_external(task='EXTERNAL', label='bg', heartbeat_s=30.0)
        # 模拟「客户端失联」：把心跳截止时间拨到过去。
        j.heartbeat_deadline = time.monotonic() - 1.0
        self.q._sweep_external()
        self.assertEqual(j.status, 'failed')
        self.assertEqual(j.error['code'], 'watchdog_timeout')
        # 终态后不再在 _external 里。
        self.assertIsNone(self.q._external.get(j.job_id))

    def test_alive_job_not_swept(self):
        j = self.q.register_external(task='EXTERNAL', label='bg')
        # 心跳 deadline 还在未来 → 不被清扫。
        self.q._sweep_external()
        self.assertEqual(j.status, 'running')

    def test_finished_job_not_swept(self):
        j = self.q.register_external(task='EXTERNAL', label='bg')
        self.q.finish_external(j.job_id, status='done')
        j.heartbeat_deadline = time.monotonic() - 999  # 即便 deadline 过期
        self.q._sweep_external()  # 已终态，不应再被扫。
        self.assertEqual(j.status, 'done')

    def test_exempt_task_never_swept(self):
        # 交互会话 / 流式会话登记时 heartbeat_s=None → deadline=None → 看门狗豁免：
        # 没截止时间，所以无论扫多少次、过多久都不该被误杀（修复：退出页面 /
        # LLM 慢导致 watchdog 假 failed）。
        j = self.q.register_external(task='SESSION', label='老师模式', heartbeat_s=None)
        self.assertIsNone(j.heartbeat_deadline)
        for _ in range(3):
            self.q._sweep_external()
            self.assertEqual(j.status, 'running')
        # 豁免任务连「上报进度」都不会被拉回看门狗（见下个用例），这里再确认
        # 多次 sweep 后 deadline 仍是 None。
        self.assertIsNone(j.heartbeat_deadline)

    def test_report_does_not_rearm_exempt_task(self):
        # 豁免任务上报进度时不应被「拉回」看门狗（否则仍会被超时误杀）。
        j = self.q.register_external(task='SESSION', label='老师模式', heartbeat_s=None)
        self.assertIsNone(j.heartbeat_deadline)
        self.q.report_external(j.job_id, message='进度中')
        self.assertIsNone(j.heartbeat_deadline)
        self.assertEqual(j.stage_message, '进度中')


class HonestProgressTest(unittest.TestCase):
    def test_start_sets_indeterminate_zero(self):
        j = Job(task='T1', label='t')
        j.start()
        self.assertEqual(j.status, 'running')
        self.assertEqual(j.stage_percent, 0.0)  # 不再谎报 10% 假进度
        self.assertTrue(j.touch)  # touch 方法存在


class TaskLabelBoundaryTest(unittest.TestCase):
    """task 是纯元数据标签（不参与分派），上限需容纳 App 真实取值。"""

    def setUp(self) -> None:
        self.q = _make_queue()

    def test_background_task_accepted(self):
        # App 实际发送 task='BACKGROUND'（10 字符）—— 曾是 MAX_TASK_CHARS=8 的受害者，
        # 会导致所有后台体/交互会话的服务端登记被 invalid_request 拒绝。回归用。
        j = self.q.register_external(task='BACKGROUND', label='出题中', job_id='bg-1')
        self.assertEqual(j.task, 'BACKGROUND')
        self.assertTrue(j.external)
        self.q.finish_external('bg-1', status='done')

    def test_session_task_accepted(self):
        j = self.q.register_external(task='SESSION', label='交互会话', job_id='s-1')
        self.assertEqual(j.task, 'SESSION')
        self.q.finish_external('s-1', status='canceled')

    def test_overlong_task_rejected(self):
        with self.assertRaises(Exception):
            self.q.register_external(task='X' * 40, label='t', job_id='bad-1')


if __name__ == '__main__':
    unittest.main(verbosity=2)
