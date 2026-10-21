"""生成 M10 面板测试夹具：用进程内 JobQueue + 假 executor 产出**真实**快照。

覆盖 5 种状态各至少一条：queued / running / done / failed / canceled，
外加一条多阶段（stages）done 与一条带 resource_key 的 running。
产物写 ``llm_server/.m10_fixture.json``，由 ``verify_m10_panel.js`` 消费。

用法（在 llm_server/ 下）：
    .venv/Scripts/python.exe gen_m10_fixture.py
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

from core.jobs import JobQueue

OUT = Path(__file__).with_name('.m10_fixture.json')


async def _scenario() -> dict:
    q = JobQueue(concurrency=1, retain=50)

    async def exec_blocker(job):
        # 占着 worker；带检查点，收到取消即退。
        for _ in range(600):
            job.check_cancelled()
            await asyncio.sleep(0.05)
        return {}

    async def exec_done(job):
        job.report(40, '提取中…')
        await asyncio.sleep(0.05)
        job.report(90, '收尾中…')
        return {'saved': 3, 'rejected': 1}

    async def exec_fail(job):
        job.report(20, '请求上游…')
        await asyncio.sleep(0.02)
        raise RuntimeError('模拟上游错误')

    async def exec_slow(job):
        # 不退出：running 样本（随后打上「取消已请求」标记）。
        job.report(35, '第 1/2 层 1/3')
        await asyncio.sleep(30)
        return {}

    q.set_executor(exec_blocker)
    q.start()

    # ① running 样本：blocker 占住 worker（稍后取消收尾）。
    j_hold, _ = q.submit({'task': 'T1', 'label': '占位（running 样本）'})
    await asyncio.sleep(0.08)

    # ② queued 样本：blocker 占着 worker，它保持排队；先抓快照再取消
    #    （queued → canceled 即消，方案 §4.3）。
    j_queued, _ = q.submit({'task': 'T3', 'label': '排队样本', 'resource_key': 'tree:demo'})
    await asyncio.sleep(0.05)
    queued_snap = j_queued.snapshot()
    q.cancel(j_queued.job_id)

    # ③ 取消 blocker 让出 worker（检查点生效 → canceled）。
    q.cancel(j_hold.job_id)
    await asyncio.sleep(0.2)

    # ④ 换执行体，补 done（多阶段）/ failed / running（带取消请求）三种样本。
    async def exec_dispatch(job):
        if job.task == 'T3':
            return await exec_done(job)
        if job.label.startswith('补前置：极限'):
            return await exec_fail(job)
        return await exec_slow(job)

    q.set_executor(exec_dispatch)

    j_done, _ = q.submit({
        'task': 'T3', 'label': '自动连线《高等数学》', 'resource_key': 'tree:math',
        'stages': ['T1', 'T3'],
    })
    await asyncio.sleep(0.3)
    j_fail, _ = q.submit({'task': 'T4', 'label': '补前置：极限', 'resource_key': 'tree:math'})
    await asyncio.sleep(0.3)
    j_run, _ = q.submit({'task': 'T4', 'label': '补前置：导数', 'resource_key': 'kp:deriv'})
    await asyncio.sleep(0.12)
    q.cancel(j_run.job_id)  # running → cancel_requested（面板「取消已请求…」分支）

    # 先抓快照再停队列（stop 会取消 worker，slow 样本随之退出）。
    snaps = [queued_snap] + [j.snapshot() for j in (j_run, j_fail, j_done)]
    listed = q.list_jobs(limit=50)
    have = {s['job_id'] for s in snaps}
    snaps.extend(j for j in listed['jobs'] if j['job_id'] not in have)

    data = {
        'jobs': snaps,
        'buffer_size': listed['buffer_size'],
        'concurrency': listed['concurrency'],
    }
    await q.stop()
    return data


def main() -> int:
    data = asyncio.run(_scenario())
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    statuses: dict[str, int] = {}
    for j in data['jobs']:
        statuses[j['status']] = statuses.get(j['status'], 0) + 1
    print(f'已生成 {OUT.name}：{len(data["jobs"])} 条快照 {statuses}')
    missing = {'queued', 'running', 'done', 'failed', 'canceled'} - set(statuses)
    if missing:
        print(f'缺少状态样本：{missing}', file=sys.stderr)
        return 1
    if data['concurrency'] != 1:
        print(f'concurrency 应为 1（Q2），实际 {data["concurrency"]}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
