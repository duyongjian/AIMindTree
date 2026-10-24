"""管理后台 P0 验收脚本（与 ``selftest.py`` 同级，纯标准库 + TestClient）。

为什么不用「起 uvicorn + curl」：沙箱的 loopback 隔离会让跨进程访问
``127.0.0.1:8787`` 超时（C7）。这里一律用 ``fastapi.testclient.TestClient``
在**进程内**打完整 ASGI 栈，等价于真实 HTTP 请求但不跨进程。

覆盖：

1. ``GET /health`` **结构逐字段不变**（C4 向后兼容）；
2. ``GET /v1/app/config``：200 + 13 字段白名单 + **无鉴权**（C10）+
   ``sync`` = ``{base_url, enabled, token, token_set}``（App 契约；token 明文
   随配置下发是唯一例外，依赖「服务端仅绑 127.0.0.1」的安全假设）；
3. ``GET /v1/admin/config``：既有字段一字不改 + 新增 5 个字段；
4. **密钥零扩散**（C3，最高优先级）：把 ``.env`` 里每个疑似密钥（名含
   KEY/TOKEN/SECRET 且长度 ≥ 8）的真实值拿来做字符串级断言 —— 必须
   ①不出现在 ``/v1/app/config`` 响应体；②不出现在 ``/v1/admin/config``
   响应除 ``key_masked`` 之外的任何位置；
5. 任务路由 ``GET/PUT /v1/admin/routes``（含非法值 400）；
6. 统计埋点 ``GET /v1/admin/stats``（空缓冲 → 空数组；打 3 次坏请求 → 累加）；
7. 运行日志 ``GET /v1/admin/logs``（过滤 / 游标分页 / 级别校验 / **密钥零泄露**）；
7b. 任务队列 ``POST/GET /v1/jobs``（202 提交 / 幂等去重 / 409 锁冲突 / 取消
    queued 即消 / running 检查点 / 终态环形保留 / M7 日志联动 / **密钥零泄露**）；
8. 配置写入往返（``app`` / ``sync`` / per-backend / ``task_backends``）+ **还原**；
8b. 同步配置端点 ``GET/PUT /v1/admin/sync``（形状 / 空串清空 / 缺 key 不修改 /
    非法值 400 / 无 token 明文回显）+ **还原**；
8c. M11 云端同步 ``/v1/admin/relay/*``：模块注册（导航 / 模块表 / 视图脚本）+
    配置端点（形状 / 令牌零明文 / 空串清空 / 缺 key 不修改 / 类型错 400）+
    **代理转发**（起本地临时假中继：路径 / Bearer / body / 上游 4xx·5xx 原样
    透传 / 不可达 502）+ **还原**；
8d. M11 出站代理 ``relay_admin.<name>.proxy``：保存回显 / 空串清空 / 非法值 400 /
    **不可达代理 → 502（证明代理真的被用上）** / 清空后恢复 200 + **还原**；
9. 静态资源挂载（``/admin``、``/static/*``）；
10. 可选：真实链路 ``POST /v1/task/T1`` + ``POST /v1/chat``（blocking 与 SSE
    两条路径都要进埋点）（``--live``，需要本机 Ollama 在跑，约 60s）。

用法::

    python llm_server/verify_admin_console.py
    python llm_server/verify_admin_console.py --live      # 追加真实 T1 调用

退出码：0 = 全绿；1 = 有失败。

⚠️ 第 7 步会**临时改写** ``llm_server/settings.json``（该文件已被 .gitignore
忽略），脚本结束时有 ``finally`` 还原（原本不存在则删除）。
"""

from __future__ import annotations

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from fastapi.testclient import TestClient  # noqa: E402

from core.app_config import APP_CONFIG_FIELDS  # noqa: E402
from server import create_app  # noqa: E402

#: ``GET /health`` 改动前的**完整键集合**（C4：只能新增，不能改/删）。
_HEALTH_KEYS = {
    'status',
    'version',
    'uptime_s',
    'default_backend',
    'task_backends',
    'prompts_loaded',
    'prompt_errors',
    'backends',
}

#: ``GET /health`` 里 ``backends[]`` 每项的键集合（BackendHealth.to_dict）。
_HEALTH_BACKEND_KEYS = {'name', 'reachable', 'base_url', 'models', 'error'}

#: ``GET /v1/admin/config`` 改动前的 per-backend 键集合。
_ADMIN_BACKEND_KEYS = {'name', 'protocol', 'default_model', 'key_set', 'key_masked', 'models'}

#: 新增的 per-backend / 顶层字段。
_ADMIN_BACKEND_NEW_KEYS = {'base_url', 'editable', 'for_app'}
_ADMIN_TOP_NEW_KEYS = {'app', 'sync'}

#: 疑似密钥的环境变量名特征。
_SECRET_NAME_HINTS = ('KEY', 'TOKEN', 'SECRET', 'PASSWORD')

_PASS = 0
_FAIL = 0
_SKIP = 0


def ok(name: str, detail: str = '') -> None:
    global _PASS
    _PASS += 1
    suffix = f'  —— {detail}' if detail else ''
    print(f'  ✅ {name}{suffix}')


def bad(name: str, detail: str = '') -> None:
    global _FAIL
    _FAIL += 1
    suffix = f'\n      {detail}' if detail else ''
    print(f'  ❌ {name}{suffix}')


def skip(name: str, detail: str = '') -> None:
    global _SKIP
    _SKIP += 1
    suffix = f'  —— {detail}' if detail else ''
    print(f'  ⚪ {name}（跳过）{suffix}')


def check(cond: bool, name: str, detail: str = '') -> bool:
    if cond:
        ok(name, detail)
    else:
        bad(name, detail)
    return cond


# ---------------------------------------------------------------- .env


def load_env_secrets(path: Path) -> dict[str, str]:
    """读 ``.env``，返回「疑似密钥」的真实值（名含 KEY/TOKEN/SECRET 且值长 ≥ 8）。

    **故意读取真实值**：只有拿真值做字符串级断言，才能证明密钥没被下发。
    脚本全程只做 ``in`` 比较，**不打印任何真实值**。
    """
    secrets: dict[str, str] = {}
    if not path.is_file():
        return secrets
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, _, value = line.partition('=')
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        upper = key.upper()
        if not any(hint in upper for hint in _SECRET_NAME_HINTS):
            continue
        if len(value) < 8:
            continue
        secrets[key] = value
    return secrets


def strip_key_masked(node: Any) -> Any:
    """深拷贝并剔除所有 ``key_masked`` 键（掩码里出现的前4/后2位是**允许**的）。"""
    if isinstance(node, dict):
        return {
            k: strip_key_masked(v) for k, v in node.items() if k != 'key_masked'
        }
    if isinstance(node, list):
        return [strip_key_masked(v) for v in node]
    return node


def assert_no_secret(text: str, secrets: dict[str, str], label: str) -> bool:
    """断言 ``text`` 里不含任何密钥真实值。"""
    if not secrets:
        skip(f'{label}：无密钥泄露', '.env 里没有长度 ≥8 的疑似密钥')
        return True
    leaked = [name for name, value in secrets.items() if value and value in text]
    if leaked:
        bad(f'{label}：无密钥泄露', f'响应体里出现了 {leaked} 的真实值（已确证泄露！）')
        return False
    ok(f'{label}：无密钥泄露', f'已比对 {len(secrets)} 个密钥真值，0 命中')
    return True


# ---------------------------------------------------------------- 各检查项


def check_health(c: TestClient) -> None:
    print('\n[1] GET /health —— 结构逐字段不变（C4）')
    r = c.get('/health')
    if not check(r.status_code == 200, '/health 返回 200', f'实际 {r.status_code}'):
        return
    body = r.json()
    missing = _HEALTH_KEYS - set(body)
    check(not missing, '/health 既有字段一个不少', f'缺 {sorted(missing)}' if missing else '')
    check(body.get('status') == 'ok', "status == 'ok'", str(body.get('status')))
    check(
        isinstance(body.get('task_backends'), dict)
        and all(isinstance(v, str) for v in body['task_backends'].values()),
        'task_backends 仍是 {task: str}（未变对象，D3）',
        str(body.get('task_backends')),
    )
    backends = body.get('backends') or []
    shape_ok = all(set(b) == _HEALTH_BACKEND_KEYS for b in backends)
    check(shape_ok, f'backends[{len(backends)}] 每项键集合不变', str(_HEALTH_BACKEND_KEYS))


def check_app_config(c: TestClient, secrets: dict[str, str]) -> dict:
    print('\n[2] GET /v1/app/config —— 下发 13 字段、无鉴权、无密钥（AC-01/02, C3, C10）')
    r = c.get('/v1/app/config')  # 故意不带任何 header
    if not check(r.status_code == 200, '无鉴权即可访问（C10）', f'实际 {r.status_code}'):
        return {}
    body = r.json()
    check(set(body) == set(APP_CONFIG_FIELDS), '字段集合 == 白名单 13 项',
          f'差异 {sorted(set(body) ^ set(APP_CONFIG_FIELDS))}')
    check(body.get('schema') == 1, 'schema == 1', str(body.get('schema')))
    check(body.get('protocol') == 'llm_server', "protocol == 'llm_server'",
          str(body.get('protocol')))
    check(
        isinstance(body.get('timeouts'), dict)
        and set(body['timeouts']) == {'structured_s', 'chat_s', 'connect_s'},
        'timeouts = {structured_s, chat_s, connect_s}',
        str(body.get('timeouts')),
    )
    sync = body.get('sync')
    check(
        isinstance(sync, dict) and set(sync) == {'base_url', 'enabled', 'token', 'token_set'},
        'sync 恒为 object 且含 base_url/enabled/token/token_set（App 契约）',
        str(sync),
    )
    check(
        isinstance(sync, dict) and isinstance(sync.get('token_set'), bool)
        and (sync.get('token') is None or isinstance(sync.get('token'), str)),
        'sync.token 为 string|null、token_set 为 bool',
        str(sync),
    )
    check(
        str(r.headers.get('cache-control', '')).lower() == 'no-store',
        'Cache-Control: no-store',
        str(r.headers.get('cache-control')),
    )
    assert_no_secret(r.text, secrets, '/v1/app/config')
    return body


def check_admin_config(c: TestClient, secrets: dict[str, str]) -> None:
    print('\n[3] GET /v1/admin/config —— 既有字段不变 + 新增 5 字段（C4 允许新增）')
    r = c.get('/v1/admin/config')
    if not check(r.status_code == 200, '返回 200', f'实际 {r.status_code}'):
        return
    body = r.json()
    for key in ('default_backend', 'default_model', 'backends', 'minimax_balance_path'):
        check(key in body, f'既有顶层字段 {key} 仍在')
    backends = body.get('backends') or []
    check(bool(backends), 'backends 非空', f'{len(backends)} 个')
    keep_ok = all(_ADMIN_BACKEND_KEYS <= set(b) for b in backends)
    check(keep_ok, 'per-backend 既有 6 字段一个不少', str(_ADMIN_BACKEND_KEYS))
    new_ok = all(_ADMIN_BACKEND_NEW_KEYS <= set(b) for b in backends)
    check(new_ok, 'per-backend 新增 base_url / editable / for_app', str(_ADMIN_BACKEND_NEW_KEYS))
    check(_ADMIN_TOP_NEW_KEYS <= set(body), '顶层新增 app / sync', str(sorted(set(body))))
    app = body.get('app') or {}
    check(
        isinstance(app, dict) and set(app) == {'service_name', 'console_url', 'timeouts'},
        'app 只含 service_name / console_url / timeouts（无密钥）',
        str(sorted(app)),
    )
    sync = body.get('sync') or {}
    check(
        isinstance(sync, dict) and set(sync) == {'base_url', 'enabled', 'token_set'},
        'sync 只含 base_url / enabled / token_set（无 token 明文）',
        str(sorted(sync)),
    )
    # C3：除 key_masked 外任何位置都不得出现密钥真值
    stripped = json.dumps(strip_key_masked(body), ensure_ascii=False)
    assert_no_secret(stripped, secrets, '/v1/admin/config（剔除 key_masked 后）')


def check_routes(c: TestClient) -> None:
    print('\n[4] GET / PUT /v1/admin/routes —— 任务路由（AC-05）')
    r = c.get('/v1/admin/routes')
    if not check(r.status_code == 200, 'GET 返回 200', f'实际 {r.status_code}'):
        return
    body = r.json()
    for key in ('default_backend', 'default_model', 'task_backends', 'tasks'):
        check(key in body, f'含字段 {key}')
    tasks = body.get('tasks') or []
    check(len(tasks) >= 14, f'tasks ≥ 14 条（含 T5.detect）', f'实际 {len(tasks)}')
    row_keys_ok = all(
        {'task', 'variant', 'backend', 'model', 'structured', 'preferred_backend', 'inputs'}
        <= set(t)
        for t in tasks
    )
    check(row_keys_ok, '每条 task 含 variant/backend/model/structured/preferred_backend/inputs')
    check(
        any(t.get('variant') == 'detect' for t in tasks),
        'T5 的 detect 变体在列',
    )

    # 非法 backend → 400 invalid_request
    r2 = c.put('/v1/admin/routes', json={'task_backends': {'T1': {'backend': 'no-such'}}})
    check(
        r2.status_code == 400 and r2.json().get('error', {}).get('code') == 'invalid_request',
        'PUT 非法 backend → 400 invalid_request',
        f'{r2.status_code} {r2.text[:120]}',
    )
    # 缺 task_backends → 400
    r3 = c.put('/v1/admin/routes', json={})
    check(r3.status_code == 400, 'PUT 缺 task_backends → 400', str(r3.status_code))


def check_stats(c: TestClient) -> None:
    print('\n[5] GET /v1/admin/stats —— 统计埋点（AC-07/08）')
    from core.stats import reset

    reset()
    r = c.get('/v1/admin/stats')
    if not check(r.status_code == 200, 'GET 返回 200', f'实际 {r.status_code}'):
        return
    empty = r.json()
    check(
        empty.get('by_task') == [] and empty.get('by_backend') == []
        and empty.get('slowest') == [] and empty.get('last_error') is None,
        '空缓冲：数组为 []、last_error 为 None（AC-08 不返回 null 数组）',
        f"total={empty.get('total')}",
    )

    # 打 3 次「未知任务」：不触发任何真实 LLM 调用，但一定被埋点记录
    for _ in range(3):
        c.post('/v1/task/ZZZ', json={'inputs': {}})
    after = c.get('/v1/admin/stats').json()
    check(
        after.get('total', 0) >= 3,
        '3 次失败请求被埋点（total 累加）',
        f"total={after.get('total')} error={after.get('error')}",
    )
    check(
        isinstance(after.get('by_task'), list)
        and any(t.get('task') == 'ZZZ' for t in after['by_task']),
        'by_task 里出现该任务',
        str(after.get('by_task')),
    )
    check(
        after.get('last_error') is not None
        and after['last_error'].get('code') == 'unknown_task',
        'last_error.code == unknown_task（错误码已归一化）',
        str(after.get('last_error')),
    )
    bad_window = c.get('/v1/admin/stats?window_s=-1').json()
    check(bad_window.get('window_s') == 3600, 'window_s 非正数 → 回落 3600',
          str(bad_window.get('window_s')))


def check_logs(c: TestClient, secrets: dict[str, str]) -> None:
    print('\n[6] GET /v1/admin/logs —— 运行日志（M7，环形缓冲）')
    from core.logbuf import reset as logbuf_reset

    logbuf_reset()
    r = c.get('/v1/admin/logs')
    if not check(r.status_code == 200, 'GET 返回 200', f'实际 {r.status_code}'):
        return
    empty = r.json()
    check(empty.get('items') == [], '空缓冲：items 为 []（不返回 null 数组）', str(empty.get('items')))
    for key in ('matched', 'buffer_size', 'since_startup', 'dropped', 'levels', 'next_cursor'):
        check(key in empty, f'含字段 {key}')

    # 打 3 次「未知任务」：server.py 的异常处理器会记 WARNING 级日志
    for _ in range(3):
        c.post('/v1/task/ZZZ', json={'inputs': {}})
    after = c.get('/v1/admin/logs').json()
    items = after.get('items') or []
    check(len(items) >= 3, '3 次失败请求产生日志', f'items={len(items)}')
    check(
        all({'seq', 'ts', 'level', 'module', 'message'} <= set(i) for i in items),
        '单条含 seq/ts/level/module/message',
    )
    check(
        all(i.get('level') in ('DEBUG', 'INFO', 'WARNING', 'ERROR') for i in items),
        '级别取值合法',
    )
    seqs = [i['seq'] for i in items]
    check(seqs == sorted(seqs, reverse=True), 'items 按 seq 降序（新的在前）', str(seqs[:5]))

    # 级别过滤：ERROR 之下不应混入 WARNING
    err = c.get('/v1/admin/logs?level=ERROR').json()
    check(
        all(i['level'] == 'ERROR' for i in (err.get('items') or [])),
        'level=ERROR 只留 ERROR',
        str([i['level'] for i in err.get('items') or []]),
    )
    # 模块过滤：短名 config → llmserver.config（异常处理器的 logger）
    mod = c.get('/v1/admin/logs?module=config').json()
    check(
        bool(mod.get('items')) and all(i['module'] == 'llmserver.config' for i in mod['items']),
        'module=config → llmserver.config',
        str({i['module'] for i in mod.get('items') or []}),
    )
    # 关键字过滤
    kw = c.get('/v1/admin/logs?q=ZZZ').json()
    check(
        bool(kw.get('items')) and all('ZZZ' in i['message'] for i in kw['items']),
        'q=ZZZ 只命中含该关键字的日志',
        str(len(kw.get('items') or [])),
    )
    # limit 钳制（99999 → 500）
    big = c.get('/v1/admin/logs?limit=99999').json()
    check(len(big.get('items') or []) <= 500, 'limit 上限 500', str(len(big.get('items') or [])))
    # 非法级别 → 400 invalid_request
    bad = c.get('/v1/admin/logs?level=TRACE')
    check(
        bad.status_code == 400 and bad.json().get('error', {}).get('code') == 'invalid_request',
        '非法 level → 400 invalid_request',
        f'{bad.status_code} {bad.text[:100]}',
    )
    # 游标分页：before_seq 只返回更早的
    first = c.get('/v1/admin/logs?limit=2').json()
    if first.get('next_cursor') and len(first.get('items') or []) == 2:
        older = c.get(f"/v1/admin/logs?limit=2&before_seq={first['next_cursor']}").json()
        older_seqs = [i['seq'] for i in older.get('items') or []]
        check(
            bool(older_seqs) and all(s < first['next_cursor'] for s in older_seqs),
            'before_seq 游标只返回更早的日志',
            str(older_seqs),
        )
    else:
        skip('before_seq 游标分页', '缓冲内日志不足')
    # 密钥零扩散：日志响应体不得包含 .env 里任何真实密钥
    if secrets:
        blob = r.text + json.dumps(after, ensure_ascii=False)
        leaked = [name for name, value in secrets.items() if value in blob]
        check(not leaked, '日志响应不含 .env 任何密钥明文', f'泄露：{leaked}' if leaked else '')
    else:
        skip('日志密钥零泄露', '.env 无疑似密钥')


def check_jobs(c: TestClient, secrets: dict[str, str]) -> None:
    print('\n[7] POST/GET /v1/jobs —— 异步任务队列（提交即返回 / 取消 / 锁 / 幂等）')
    import asyncio

    from core.jobs import JobQueue
    from core.logbuf import reset as logbuf_reset

    # ---- 7.1 HTTP 级：空列表结构（空态不返回 null 数组）----
    r = c.get('/v1/jobs')
    if not check(r.status_code == 200, 'GET /v1/jobs 返回 200', f'实际 {r.status_code}'):
        return
    body = r.json()
    for key in ('jobs', 'buffer_size', 'concurrency'):
        check(key in body, f'列表含字段 {key}')
    check(isinstance(body.get('jobs'), list), 'jobs 为数组', str(type(body.get('jobs'))))
    check(body.get('concurrency') == 1, 'concurrency 默认 1（Q2 决策）', str(body.get('concurrency')))

    # ---- 7.2 参数校验：缺 task → 400 ----
    bad = c.post('/v1/jobs', json={'inputs': {}})
    check(
        bad.status_code == 400 and bad.json().get('error', {}).get('code') == 'invalid_request',
        '缺少 task → 400 invalid_request',
        f'{bad.status_code} {bad.text[:80]}',
    )

    # ---- 7.3 未知任务：202 提交 → worker 内 failed(unknown_task) ----
    logbuf_reset()
    r = c.post('/v1/jobs', json={'task': 'ZZZ', 'label': '未知任务探测'})
    if check(r.status_code == 202, '未知任务也先 202（异步语义：失败在终态）', f'实际 {r.status_code}'):
        jid = r.json()['job_id']
        job = None
        for _ in range(50):
            job = c.get(f'/v1/jobs/{jid}').json()
            if job.get('status') in ('done', 'failed', 'canceled'):
                break
            import time as _t

            _t.sleep(0.1)
        check(
            job is not None and job.get('status') == 'failed'
            and (job.get('error') or {}).get('code') == 'unknown_task',
            '终态 failed + error.code=unknown_task',
            str(job.get('error') if job else None),
        )
        check(
            job is not None and job.get('stage', {}).get('message') == '失败'
            and (job.get('error') or {}).get('code') == 'unknown_task',
            '失败时 stage.message=失败 + error.code=unknown_task',
            str(job.get('stage') if job else None),
        )

    # ---- 7.4 幂等：60s 内同 key 重复提交 → deduped=True 且同一 job ----
    r1 = c.post('/v1/jobs', json={'task': 'T1', 'inputs': {'note_text': 'x'}, 'idempotency_key': 'verify-idem-1'})
    r2 = c.post('/v1/jobs', json={'task': 'T1', 'inputs': {'note_text': 'x'}, 'idempotency_key': 'verify-idem-1'})
    check(
        r1.status_code == 202 and r2.status_code == 202
        and r1.json().get('job_id') == r2.json().get('job_id')
        and r2.json().get('deduped') is True,
        '幂等键 TTL 内重复提交 → deduped=True、同一 job_id',
        f'{r1.json()} / {r2.json()}',
    )

    # ---- 7.5 404：不存在的 job ----
    nf = c.get('/v1/jobs/job_does_not_exist')
    check(nf.status_code == 404, 'GET 不存在 job → 404（App 据此判定服务重启）', f'实际 {nf.status_code}')

    # ---- 7.6 日志联动：llmserver.job 模块进 M7 ----
    logs = c.get('/v1/admin/logs?module=job&limit=50').json()
    items = logs.get('items') or []
    check(
        bool(items) and all(i['module'] == 'llmserver.job' for i in items),
        'module=job 过滤出 llmserver.job 日志（M7 联动）',
        f'items={len(items)}',
    )
    check(
        any('已提交' in i['message'] for i in items),
        '日志含「已提交」记录',
        items[0]['message'] if items else '(空)',
    )

    # ---- 7.7 状态机单测（内存 executor，无 Ollama 依赖）：done / 锁 / 取消 / 保留 ----
    async def _scenario() -> None:
        q = JobQueue(concurrency=1, retain=5)

        async def slow_exec(job):
            for i in range(20):
                job.check_cancelled()
                job.report(i * 5, f'第 {i} 步')
                await asyncio.sleep(0.05)
            return {'ok': True, 'echo': job.label}

        q.set_executor(slow_exec)
        q.start()
        try:
            # (a) done 路径：进度上报 + 100% 终态（slow_exec 共 20×0.05≈1s）
            j1, d1 = q.submit({'task': 'T1', 'label': 'done 路径'})
            await asyncio.sleep(1.4)
            s1 = j1.snapshot()
            check(
                s1['status'] == 'done' and s1['stage']['percent'] == 100
                and s1['stage']['message'] == '已完成' and s1['result'] == {'ok': True, 'echo': 'done 路径'},
                '状态机：running → done，percent=100、result 回填',
                str(s1['stage']),
            )
            check(d1 is False, '首次提交 deduped=False')

            # (b) 锁：同 resource_key 未终态 → lock_conflict
            j2, _ = q.submit({'task': 'T1', 'resource_key': 'tree:a', 'label': '占锁'})
            await asyncio.sleep(0.12)  # 让 worker 取到 j2（j1 已 done）
            check(j2.status == 'running', 'j2 已被 worker 取到（running）', j2.status)
            try:
                q.submit({'task': 'T3', 'resource_key': 'tree:a', 'label': '冲突'})
                check(False, '锁冲突应抛 lock_conflict', '未抛异常')
            except Exception as exc:  # noqa: BLE001 - 断言错误码
                check(
                    getattr(exc, 'code', None) == 'lock_conflict'
                    and getattr(exc, 'http_status', None) == 409,
                    '状态机：同 resource_key → 409 lock_conflict',
                    f'{type(exc).__name__}: {exc}',
                )
            # 不同 key 不受影响
            j3, _ = q.submit({'task': 'T1', 'resource_key': 'tree:b', 'label': '异键'})
            check(j3.status == 'queued', '不同 resource_key 放行')

            # (c) 取消 queued：立即生效（j3 还在排队，worker 忙于 j2）
            q.cancel(j3.job_id)
            check(j3.status == 'canceled', '取消 queued → canceled（立即）', j3.status)

            # (d) 取消 running：检查点生效（slow_exec 每步前 check_cancelled）
            q.cancel(j2.job_id)
            check(
                j2.cancel_requested is True and j2.status == 'running',
                '取消 running → cancel_requested=True（检查点前仍 running）',
                j2.status,
            )
            await asyncio.sleep(0.3)
            check(
                j2.status == 'canceled' and j2.finished_at is not None,
                '检查点生效：running → canceled',
                j2.status,
            )

            # (e) 终态可见：list(status=canceled) 含两个被取消任务
            lst_c = q.list_jobs(status='canceled')
            check(
                any(j['job_id'] == j2.job_id for j in lst_c['jobs'])
                and any(j['job_id'] == j3.job_id for j in lst_c['jobs']),
                'list(status=canceled) 含两个被取消任务',
                str([j['job_id'] for j in lst_c['jobs']]),
            )

            # (f) 保留环：换即时 executor 灌 8 个 → retain=5 封顶
            async def fast_exec(job):
                return {'ok': True}

            q.set_executor(fast_exec)
            for i in range(8):
                q.submit({'task': 'T1', 'label': f'灌水{i}'})
            await asyncio.sleep(0.5)
            lst = q.list_jobs(status='done', limit=50)
            check(
                len(lst['jobs']) <= 5 and lst['buffer_size'] <= 5,
                'retain=5：终态环封顶（done 列表 ≤5）',
                f"buffer_size={lst['buffer_size']} done={len(lst['jobs'])}",
            )
            lst3 = q.list_jobs(limit=99999)
            check(len(lst3['jobs']) <= 200, 'limit 越界钳制 ≤200', str(len(lst3['jobs'])))
        finally:
            await q.stop()

    try:
        asyncio.run(_scenario())
    except Exception as exc:  # noqa: BLE001 - 场景本身崩了要报出来
        check(False, '状态机场景执行', f'{type(exc).__name__}: {exc}')

    # ---- 7.8 密钥零扩散 ----
    if secrets:
        blob = r.text + r1.text + r2.text
        leaked = [name for name, value in secrets.items() if value in blob]
        check(not leaked, 'jobs 响应不含 .env 任何密钥明文', f'泄露：{leaked}' if leaked else '')
    else:
        skip('jobs 密钥零泄露', '.env 无疑似密钥')


def check_config_roundtrip(c: TestClient) -> None:
    print('\n[8] POST /v1/admin/config —— 覆盖层往返 + 还原（AC-03/04, C9）')
    settings_path = _HERE / 'settings.json'
    original: str | None = None
    existed = settings_path.is_file()
    if existed:
        original = settings_path.read_text(encoding='utf-8')

    try:
        body = {
            'app': {
                'service_name': '验收临时名',
                'console_url': 'http://127.0.0.1:8787/admin',
                'timeouts': {'structured_s': 90, 'chat_s': 91, 'connect_s': 9},
            },
            'sync': {'base_url': 'https://example.supabase.co', 'enabled': True,
                     'token': 'verify-temp-token-should-never-be-echoed'},
        }
        r = c.post('/v1/admin/config', json=body)
        if not check(r.status_code == 200, 'POST 返回 200', f'{r.status_code} {r.text[:160]}'):
            return
        out = r.json()
        check(out.get('app', {}).get('service_name') == '验收临时名', 'app.service_name 已生效')
        check(
            out.get('app', {}).get('timeouts', {}).get('structured_s') == 90,
            'app.timeouts 已生效',
            str(out.get('app', {}).get('timeouts')),
        )
        check(out.get('sync', {}).get('enabled') is True, 'sync.enabled 已生效')
        check(out.get('sync', {}).get('token_set') is True, 'sync.token_set 为 True')
        check(
            'token' not in (out.get('sync') or {}),
            'sync 回显里没有 token 明文（只有 token_set）',
            str(sorted((out.get('sync') or {}).keys())),
        )

        # 非法值 → 400
        r2 = c.post('/v1/admin/config', json={'app': {'console_url': 'ftp://x'}})
        check(
            r2.status_code == 400 and r2.json()['error']['code'] == 'invalid_request',
            'console_url 非 http(s) → 400',
            str(r2.status_code),
        )
        r3 = c.post('/v1/admin/config', json={'app': {'timeouts': {'chat_s': 0}}})
        check(r3.status_code == 400, 'timeouts ≤ 0 → 400', str(r3.status_code))
        r4 = c.post('/v1/admin/config', json={'backends': {'nope': {'base_url': 'x'}}})
        check(r4.status_code == 400, '未知后端名 → 400', str(r4.status_code))
        r5 = c.post('/v1/admin/config', json={'sync': {'enabled': 'yes'}})
        check(r5.status_code == 400, 'sync.enabled 非 bool → 400', str(r5.status_code))

        # 下发端能看到 app.service_name；sync 按新契约含 token 明文
        pushed = c.get('/v1/app/config').json()
        check(
            pushed.get('service_name') == '验收临时名',
            '/v1/app/config 同步看到新服务名',
            str(pushed.get('service_name')),
        )
        check(
            pushed.get('sync', {}).get('token') == 'verify-temp-token-should-never-be-echoed'
            and pushed.get('sync', {}).get('token_set') is True,
            '下发 sync 含 token 明文 + token_set（新契约：localhost 假设下随配置下发）',
            str(sorted((pushed.get('sync') or {}).keys())),
        )
    finally:
        # 还原 settings.json（原本不存在则删除），保证仓库零污染
        if existed and original is not None:
            settings_path.write_text(original, encoding='utf-8')
        elif settings_path.is_file():
            settings_path.unlink()
        print('  ↩️  settings.json 已还原（C9：config.yaml 全程未被写入）')


def check_sync_endpoints(c: TestClient, secrets: dict[str, str]) -> None:
    print('\n[8b] GET/PUT /v1/admin/sync —— 同步配置端点（B-backend）')
    settings_path = _HERE / 'settings.json'
    original: str | None = None
    existed = settings_path.is_file()
    if existed:
        original = settings_path.read_text(encoding='utf-8')

    token = 'verify-sync-token-should-not-echo'
    try:
        r = c.get('/v1/admin/sync')
        if not check(r.status_code == 200, 'GET 返回 200', f'实际 {r.status_code}'):
            return
        body = r.json()
        check(
            set(body) == {'base_url', 'enabled', 'token_set', 'token_masked'},
            'GET 形状 = {base_url, enabled, token_set, token_masked}（无 token 明文）',
            str(sorted(body)),
        )

        r2 = c.put('/v1/admin/sync', json={
            'base_url': 'https://verify.supabase.co', 'enabled': True, 'token': token,
        })
        if not check(r2.status_code == 200, 'PUT 返回 200', f'{r2.status_code} {r2.text[:120]}'):
            return
        out = r2.json()
        check(out.get('base_url') == 'https://verify.supabase.co', 'PUT 后 base_url 生效')
        check(out.get('enabled') is True, 'PUT 后 enabled 生效')
        check(out.get('token_set') is True, 'PUT 后 token_set=True')
        check(
            'token' not in out and token not in json.dumps(out, ensure_ascii=False),
            'PUT 响应不含 token 明文（只有 token_masked）',
            str(sorted(out)),
        )

        # /v1/app/config 契约：sync = {base_url, enabled, token, token_set}
        psync = c.get('/v1/app/config').json().get('sync') or {}
        check(
            set(psync) == {'base_url', 'enabled', 'token', 'token_set'},
            '下发 sync = {base_url, enabled, token, token_set}（App 契约）',
            str(sorted(psync)),
        )
        check(
            psync.get('token') == token and psync.get('token_set') is True,
            '下发 sync.token 为明文（localhost 假设下随配置下发）',
        )

        # 空串 = 清空
        r3 = c.put('/v1/admin/sync', json={'token': ''})
        out3 = r3.json() if r3.status_code == 200 else {}
        check(
            r3.status_code == 200 and out3.get('token_set') is False
            and out3.get('token_masked') is None,
            'PUT token="" → 清空令牌',
            str(out3),
        )
        psync = c.get('/v1/app/config').json().get('sync') or {}
        check(
            psync.get('token') is None and psync.get('token_set') is False,
            '清空后下发 sync.token=None',
            str(psync),
        )

        # 缺 key = 不修改
        r4 = c.put('/v1/admin/sync', json={'enabled': False})
        out4 = r4.json() if r4.status_code == 200 else {}
        check(
            out4.get('enabled') is False
            and out4.get('base_url') == 'https://verify.supabase.co',
            'PUT 只传 enabled → base_url 不修改（缺 key 语义）',
            str(out4),
        )

        # 非法值 → 400 invalid_request
        for field, value in (('base_url', 1), ('enabled', 'yes'), ('token', 5)):
            rr = c.put('/v1/admin/sync', json={field: value})
            check(
                rr.status_code == 400
                and rr.json().get('error', {}).get('code') == 'invalid_request',
                f'PUT {field}={value!r} → 400 invalid_request',
                str(rr.status_code),
            )

        # 密钥零扩散：.env 里的 LLM 密钥不得出现在本组任何响应里
        assert_no_secret(r.text + r2.text + r3.text, secrets, '/v1/admin/sync')
    finally:
        # 还原 settings.json（原本不存在则删除），保证仓库零污染
        if existed and original is not None:
            settings_path.write_text(original, encoding='utf-8')
        elif settings_path.is_file():
            settings_path.unlink()
        print('  ↩️  settings.json 已还原')


# ---------------------------------------------------------------- M11 假中继


class _FakeRelay:
    """临时「云端中继」（标准库 ``http.server``，绑 127.0.0.1 随机端口）。

    进程内起线程即可访问（不跨进程，C7 不适用），只实现 M11 需要的 6 个管理
    接口；每次请求的方法 / 路径 / Bearer / body 都记在 :attr:`requests` 里，
    用来断言「llm_server 代理是否真的原样转发了」。

    特例：``Authorization: Bearer boom-token`` 时一律回 500 —— 验证上游 5xx
    会被**原样透传**（而不是被本地包装成别的状态码）。
    """

    def __init__(self) -> None:
        self.requests: list[dict[str, Any]] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def _record(self, method: str) -> dict[str, Any]:
                length = int(self.headers.get('Content-Length') or 0)
                raw = self.rfile.read(length).decode('utf-8') if length else ''
                try:
                    body: Any = json.loads(raw) if raw else None
                except ValueError:
                    body = raw
                item = {
                    'method': method,
                    'path': self.path,
                    'auth': self.headers.get('Authorization', ''),
                    'body': body,
                }
                outer.requests.append(item)
                return item

            def _send(self, status: int, payload: dict[str, Any]) -> None:
                data = json.dumps(payload, ensure_ascii=False).encode('utf-8')
                self.send_response(status)
                self.send_header('Content-Type', 'application/json; charset=utf-8')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _dispatch(self, method: str) -> None:
                item = self._record(method)
                if item['auth'] == 'Bearer boom-token':
                    self._send(
                        500, {'error': {'code': 'internal', 'message': '假中继故意 500'}}
                    )
                    return
                path = urlsplit(self.path).path
                body = item['body'] if isinstance(item['body'], dict) else {}
                if path == '/admin/ping':
                    self._send(
                        200,
                        {'ok': True, 'storage': 'd1', 'server_time': '2026-10-24T00:00:00Z'},
                    )
                elif path == '/admin/stats':
                    self._send(
                        200,
                        {
                            'storage': 'd1',
                            'users': 2,
                            'tokens': 3,
                            'envelopes': 7,
                            'server_time': '2026-10-24T00:00:00Z',
                            'per_user': [
                                {
                                    'user_id': 'u_1',
                                    'username': 'alice',
                                    'tokens': 2,
                                    'envelopes': 5,
                                    'last_server_time': '2026-10-24T00:00:00Z',
                                }
                            ],
                        },
                    )
                elif path == '/admin/users':
                    self._send(
                        200,
                        {
                            'users': [
                                {
                                    'user_id': 'u_1',
                                    'username': 'alice',
                                    'created_at': '2026-10-01T00:00:00Z',
                                    'tokens': 2,
                                    'envelopes': 5,
                                },
                                {
                                    'user_id': 'u_2',
                                    'username': 'bob',
                                    'created_at': '2026-10-02T00:00:00Z',
                                    'tokens': 1,
                                    'envelopes': 2,
                                },
                            ]
                        },
                    )
                elif path == '/admin/reset':
                    if body.get('confirm') != 'RESET':
                        self._send(400, {'error': 'confirm_required'})
                        return
                    self._send(
                        200,
                        {
                            'scope': body.get('scope'),
                            'deleted': {'envelopes': 3, 'tokens': 2, 'users': 1},
                        },
                    )
                elif path.startswith('/admin/user/'):
                    if path[len('/admin/user/'):] == 'ghost':
                        self._send(404, {'error': 'user_not_found'})
                        return
                    self._send(
                        200, {'deleted': {'envelopes': 5, 'tokens': 1, 'users': 1}}
                    )
                elif path == '/admin/export':
                    self._send(
                        200,
                        {
                            'user_id': body.get('user_id') or 'u_1',
                            'exported_at': '2026-10-24T00:00:00Z',
                            'truncated': False,
                            'envelopes': [],
                            'users': [],
                        },
                    )
                else:
                    self._send(404, {'error': 'not_found'})

            def do_GET(self) -> None:  # noqa: N802 - http.server 的命名约定
                self._dispatch('GET')

            def do_POST(self) -> None:  # noqa: N802
                self._dispatch('POST')

            def do_DELETE(self) -> None:  # noqa: N802
                self._dispatch('DELETE')

            def log_message(self, *args: Any) -> None:
                """静音（默认会往 stderr 打访问日志，污染验收输出）。"""

        self._server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.base_url = f'http://127.0.0.1:{self._server.server_address[1]}'
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    def __enter__(self) -> _FakeRelay:
        self._thread.start()
        return self

    def __exit__(self, *exc: Any) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=5)

    def last(self) -> dict[str, Any]:
        return self.requests[-1] if self.requests else {}


def check_relay_admin(c: TestClient, secrets: dict[str, str]) -> None:
    print('\n[8c] M11 云端同步 —— /v1/admin/relay/*（注册 / 配置 / 代理转发）')
    settings_path = _HERE / 'settings.json'
    original: str | None = None
    existed = settings_path.is_file()
    if existed:
        original = settings_path.read_text(encoding='utf-8')

    token = 'verify-relay-admin-token-should-never-echo'
    seen: list[str] = []  # 收集所有响应文本，最后统一做密钥/令牌零扩散断言
    try:
        # ---- 8c.1 M11 已注册：导航 / 模块表 / 视图脚本 ----
        index_text = (_HERE / 'static' / 'index.html').read_text(encoding='utf-8')
        app_js = (_HERE / 'static' / 'app.js').read_text(encoding='utf-8')
        view_path = _HERE / 'static' / 'views-e.js'
        check(
            'data-page="m11"' in index_text and '云端同步' in index_text,
            'index.html 注册 M11（导航项「云端同步」+ 视图容器）',
        )
        check(
            'm11:' in app_js and 'renderRelay' in app_js,
            'app.js 模块表含 m11 → renderRelay',
        )
        view_text = view_path.read_text(encoding='utf-8') if view_path.is_file() else ''
        check(
            view_path.is_file() and 'function renderRelay' in view_text,
            'views-e.js 定义 renderRelay（M11 视图脚本可取到）',
            f'{view_path.name} {len(view_text)} 字节',
        )
        rr = c.get('/static/views-e.js')
        check(rr.status_code == 200, '/static/views-e.js → 200', f'实际 {rr.status_code}')
        api_js_text = (_HERE / 'static' / 'api.js').read_text(encoding='utf-8')
        check(
            'function prompt(' in api_js_text,
            'api.js 仍声明全局 prompt(task, variant)（M11 因此必须另取原生 prompt）',
        )
        check(
            '__nativePrompt' in index_text
            and index_text.index('__nativePrompt') < index_text.index('/static/api.js'),
            'index.html 在加载 api.js **之前**存下原生 prompt（否则被同名全局函数覆盖）',
        )
        check(
            'window.prompt(' not in view_text and '__nativePrompt' in view_text,
            'views-e.js 不用 window.prompt（走 __nativePrompt → 手输 RESET 才能真的生效）',
        )

        # ---- 8c.2 GET 形状 + 令牌零明文 ----
        r = c.get('/v1/admin/relay/config')
        seen.append(r.text)
        if not check(r.status_code == 200, 'GET /v1/admin/relay/config 返回 200',
                     f'实际 {r.status_code}'):
            return
        backends = r.json().get('backends') or []
        check(
            isinstance(backends, list) and len(backends) >= 2,
            'backends 是数组且含默认后端（cloudflare / netlify）',
            str([b.get('name') for b in backends]),
        )
        keys = {'name', 'base_url', 'token_set', 'token_masked'}
        check(all(keys <= set(b) for b in backends),
              '每项含 name / base_url / token_set / token_masked', str(keys))
        names = {b.get('name') for b in backends}
        check({'cloudflare', 'netlify'} <= names, '五个中继后端恒在', str(sorted(names)))
        cf0 = next(b for b in backends if b.get('name') == 'cloudflare')
        check(
            str(cf0.get('base_url') or '').startswith('https://'),
            'cloudflare 默认 base_url 已兜底',
            str(cf0.get('base_url')),
        )
        if cf0.get('token_set'):
            skip('未配置时 token_masked=None', 'settings.json 里已有 cloudflare 令牌')
        else:
            check(cf0.get('token_masked') is None,
                  '未配置令牌时 token_set=False、token_masked=None',
                  str(cf0))

        # ---- 8c.3 PUT 保存 → token_set / masked，且零明文 ----
        r2 = c.put('/v1/admin/relay/config', json={
            'backend': 'cloudflare',
            'base_url': 'https://relay.example.test',
            'token': token,
        })
        seen.append(r2.text)
        if not check(r2.status_code == 200, 'PUT 保存返回 200',
                     f'{r2.status_code} {r2.text[:120]}'):
            return
        cf = next(b for b in r2.json()['backends'] if b.get('name') == 'cloudflare')
        check(cf.get('token_set') is True, 'PUT 后 token_set=True', str(cf))
        check(
            isinstance(cf.get('token_masked'), str) and bool(cf.get('token_masked')),
            'PUT 后 token_masked 非空（前端 placeholder 用）',
            str(cf.get('token_masked')),
        )
        check(cf.get('base_url') == 'https://relay.example.test', 'PUT 后 base_url 生效')
        r2b = c.get('/v1/admin/relay/config')
        seen.append(r2b.text)
        check(
            token not in r2.text and token not in r2b.text,
            '配置响应零明文（PUT / GET 都不含令牌真值）',
        )

        # ---- 8c.4 缺 key = 不修改；类型错 / 未知后端 → 400 ----
        r3 = c.put('/v1/admin/relay/config', json={
            'backend': 'cloudflare', 'base_url': 'https://relay.example.test/v2',
        })
        seen.append(r3.text)
        cf3 = next((b for b in (r3.json().get('backends') or [])
                    if b.get('name') == 'cloudflare'), {})
        check(
            r3.status_code == 200 and cf3.get('token_set') is True
            and cf3.get('base_url') == 'https://relay.example.test/v2',
            'PUT 缺 token key → 令牌不修改（缺 key 语义）',
            str(cf3),
        )
        for field, value in (('base_url', 5), ('token', ['x'])):
            rb = c.put('/v1/admin/relay/config', json={'backend': 'cloudflare', field: value})
            check(
                rb.status_code == 400
                and rb.json().get('error', {}).get('code') == 'invalid_request',
                f'PUT {field}={value!r} → 400 invalid_request',
                str(rb.status_code),
            )
        rb = c.put('/v1/admin/relay/config', json={'backend': 'no-such-backend'})
        check(rb.status_code == 400, '未知 backend → 400', str(rb.status_code))

        # ---- 8c.5 未配置后端 → 400 relay_not_configured ----
        rn = c.get('/v1/admin/relay/stats?backend=edgeone')
        seen.append(rn.text)
        check(
            rn.status_code == 400
            and rn.json().get('error', {}).get('code') == 'relay_not_configured',
            '未配置后端（edgeone）→ 400 relay_not_configured',
            f'{rn.status_code} {rn.text[:120]}',
        )

        # ---- 8c.6 代理转发：本地假中继（路径 / Bearer / body / 状态码透传）----
        with _FakeRelay() as fake:
            c.put('/v1/admin/relay/config', json={
                'backend': 'cloudflare', 'base_url': fake.base_url, 'token': token,
            })

            rp = c.get('/v1/admin/relay/ping?backend=cloudflare')
            seen.append(rp.text)
            req = fake.last()
            check(
                rp.status_code == 200 and req.get('path') == '/admin/ping',
                '代理 ping：转发到 /admin/ping', str(req.get('path')),
            )
            check(
                req.get('auth') == f'Bearer {token}',
                '代理 ping：Authorization: Bearer <已保存令牌>',
            )
            check(
                rp.json().get('storage') == 'd1' and rp.json().get('ok') is True,
                '代理 ping：上游 body 原样返回',
                rp.text[:120],
            )

            rs = c.get('/v1/admin/relay/stats?backend=cloudflare')
            seen.append(rs.text)
            body = rs.json()
            check(
                rs.status_code == 200 and body.get('users') == 2
                and body.get('tokens') == 3 and body.get('envelopes') == 7
                and body.get('storage') == 'd1',
                '代理 stats：用户/令牌/行数/存储 逐字段透传',
                json.dumps(body, ensure_ascii=False)[:160],
            )
            check(
                bool(body.get('per_user')) and fake.last().get('path') == '/admin/stats',
                '代理 stats：per_user 明细保留',
            )

            ru = c.get('/v1/admin/relay/users?backend=cloudflare')
            seen.append(ru.text)
            users = ru.json().get('users') or []
            check(
                len(users) == 2
                and {'user_id', 'username', 'created_at', 'tokens', 'envelopes'}
                <= set(users[0]),
                '代理 users：列表字段原样透传（含 created_at / 计数）',
                str(len(users)),
            )

            # reset：body 转发 + deleted 计数
            rr2 = c.post('/v1/admin/relay/reset', json={
                'backend': 'cloudflare', 'scope': 'envelopes', 'confirm': 'RESET',
            })
            seen.append(rr2.text)
            req = fake.last()
            check(
                rr2.status_code == 200
                and rr2.json().get('deleted')
                == {'envelopes': 3, 'tokens': 2, 'users': 1},
                '代理 reset：deleted 计数原样返回',
                rr2.text[:160],
            )
            check(
                req.get('method') == 'POST' and req.get('path') == '/admin/reset'
                and req.get('body') == {'scope': 'envelopes', 'confirm': 'RESET'},
                '代理 reset：body（scope + confirm）转发正确',
                str(req.get('body')),
            )

            # scope=user 要带 user_id；缺 user_id 本地就 400（不必打扰上游）
            c.post('/v1/admin/relay/reset', json={
                'backend': 'cloudflare', 'scope': 'user', 'user_id': 'u_1',
                'confirm': 'RESET',
            })
            check(
                fake.last().get('body') == {
                    'scope': 'user', 'confirm': 'RESET', 'user_id': 'u_1',
                },
                '代理 reset：scope=user 时带 user_id 转发',
                str(fake.last().get('body')),
            )
            rbad = c.post('/v1/admin/relay/reset', json={
                'backend': 'cloudflare', 'scope': 'user', 'confirm': 'RESET',
            })
            check(rbad.status_code == 400, 'scope=user 缺 user_id → 400', str(rbad.status_code))

            # 上游 400 原样透传（confirm 不对 → confirm_required）
            r400 = c.post('/v1/admin/relay/reset', json={
                'backend': 'cloudflare', 'scope': 'all', 'confirm': 'nope',
            })
            seen.append(r400.text)
            check(
                r400.status_code == 400 and r400.json() == {'error': 'confirm_required'},
                '上游 400 原样透传（confirm_required，body 不被改写）',
                f'{r400.status_code} {r400.text[:120]}',
            )

            # DELETE：路径 / 不存在用户 404 透传
            rd = c.delete('/v1/admin/relay/user/u_1?backend=cloudflare')
            seen.append(rd.text)
            check(
                rd.status_code == 200
                and fake.last().get('method') == 'DELETE'
                and fake.last().get('path') == '/admin/user/u_1',
                '代理 DELETE：/admin/user/{id} 路径正确',
                str(fake.last().get('path')),
            )
            rd404 = c.delete('/v1/admin/relay/user/ghost?backend=cloudflare')
            seen.append(rd404.text)
            check(
                rd404.status_code == 404
                and rd404.json().get('error') == 'user_not_found',
                '上游 404 原样透传（user_not_found）',
                f'{rd404.status_code} {rd404.text[:120]}',
            )

            # export：query 透传
            re_ = c.get('/v1/admin/relay/export?backend=cloudflare&user_id=u_1')
            seen.append(re_.text)
            check(
                re_.status_code == 200 and 'exported_at' in re_.json()
                and 'user_id=u_1' in str(fake.last().get('path')),
                '代理 export：user_id 作为 query 转发',
                str(fake.last().get('path')),
            )

            # 上游 500 原样透传（假中继对 boom-token 一律 500）
            c.put('/v1/admin/relay/config', json={
                'backend': 'netlify', 'base_url': fake.base_url, 'token': 'boom-token',
            })
            r500 = c.get('/v1/admin/relay/stats?backend=netlify')
            seen.append(r500.text)
            check(
                r500.status_code == 500
                and r500.json().get('error', {}).get('message') == '假中继故意 500',
                '上游 500 原样透传（状态码 + body 都不改写）',
                f'{r500.status_code} {r500.text[:120]}',
            )

        # ---- 8c.7 中继不可达 → 502 backend_unreachable（假中继已关闭）----
        r502 = c.get('/v1/admin/relay/ping?backend=cloudflare')
        seen.append(r502.text)
        check(
            r502.status_code == 502
            and r502.json().get('error', {}).get('code') == 'backend_unreachable',
            '中继不可达 → 502 backend_unreachable',
            f'{r502.status_code} {r502.text[:160]}',
        )
        check(token not in r502.text, '错误消息不含令牌明文')

        # ---- 8c.8 令牌 / .env 密钥零扩散 ----
        blob = ''.join(seen)
        check(token not in blob, 'relay 全部响应不含令牌明文（只 token_masked）')
        assert_no_secret(blob, secrets, '/v1/admin/relay/*')
    finally:
        # 还原 settings.json（原本不存在则删除）+ 让内存配置回到还原后的状态
        if existed and original is not None:
            settings_path.write_text(original, encoding='utf-8')
        elif settings_path.is_file():
            settings_path.unlink()
        c.post('/v1/admin/reload')
        print('  ↩️  settings.json 已还原（relay_admin 段一并回滚）')


def check_relay_proxy(c: TestClient, secrets: dict[str, str]) -> None:
    """[8d] 每后端可选出站代理：保存 / 清空 / 非法值 / **真的被用上**。

    「真的被用上」靠两条互补断言：配一个**不可达**代理 + 本地可达的假中继 →
    必须 502（若代理被忽略、悄悄直连，就会误判成功）；清空代理 → 恢复 200。
    """
    print('\n[8d] M11 出站代理（relay_admin.<name>.proxy）')
    settings_path = _HERE / 'settings.json'
    original: str | None = None
    existed = settings_path.is_file()
    if existed:
        original = settings_path.read_text(encoding='utf-8')

    token = 'verify-relay-proxy-token-should-never-echo'
    dead_proxy = 'http://127.0.0.1:1'  # 本机 1 号端口：必然连不上
    seen: list[str] = []
    try:
        r = c.get('/v1/admin/relay/config')
        seen.append(r.text)
        items = r.json().get('backends') or []
        check(all('proxy' in b for b in items), 'GET /relay/config 每个后端都带 proxy 字段',
              str(sorted(items[0])) if items else '(空)')
        cf = next((b for b in items if b.get('name') == 'cloudflare'), {})
        check(isinstance(cf.get('proxy'), str), 'proxy 为字符串（明文，非掩码）', str(cf.get('proxy')))

        # ---- 保存 → 回显一致 ----
        r1 = c.put('/v1/admin/relay/config', json={
            'backend': 'cloudflare', 'proxy': 'http://127.0.0.1:7890',
        })
        seen.append(r1.text)
        cf1 = next((b for b in (r1.json().get('backends') or [])
                    if b.get('name') == 'cloudflare'), {})
        check(
            r1.status_code == 200 and cf1.get('proxy') == 'http://127.0.0.1:7890',
            'PUT proxy 保存成功且回显一致（明文）',
            str(cf1.get('proxy')),
        )
        r1b = c.get('/v1/admin/relay/config')
        seen.append(r1b.text)
        cf1b = next((b for b in (r1b.json().get('backends') or [])
                     if b.get('name') == 'cloudflare'), {})
        check(cf1b.get('proxy') == 'http://127.0.0.1:7890', 'GET 回读 proxy 一致')

        # ---- 非法值 → 400（必须说清要带 scheme）----
        for bad in ('127.0.0.1:7890', 'socks5://127.0.0.1:7890'):
            rb = c.put('/v1/admin/relay/config', json={'backend': 'cloudflare', 'proxy': bad})
            msg = rb.json().get('error', {}).get('message', '') if rb.status_code == 400 else ''
            check(
                rb.status_code == 400
                and rb.json().get('error', {}).get('code') == 'invalid_request'
                and '代理地址必须以 http:// 或 https:// 开头' in msg,
                f'PUT proxy={bad!r} → 400 invalid_request（提示要带 scheme）',
                f'{rb.status_code} {msg[:80]}',
            )
        rb = c.put('/v1/admin/relay/config', json={'backend': 'cloudflare', 'proxy': 5})
        check(rb.status_code == 400, 'PUT proxy 类型错 → 400', str(rb.status_code))

        # ---- 缺 key = 不修改 ----
        r2 = c.put('/v1/admin/relay/config', json={'backend': 'cloudflare'})
        cf2 = next((b for b in (r2.json().get('backends') or [])
                    if b.get('name') == 'cloudflare'), {})
        check(
            r2.status_code == 200 and cf2.get('proxy') == 'http://127.0.0.1:7890',
            'PUT 缺 proxy key → 不修改（缺 key 语义）',
            str(cf2.get('proxy')),
        )

        # ---- 真的被用上：不可达代理 + 本地假中继 → 502 ----
        with _FakeRelay() as fake:
            c.put('/v1/admin/relay/config', json={
                'backend': 'cloudflare', 'base_url': fake.base_url,
                'token': token, 'proxy': dead_proxy,
            })
            r902 = c.get('/v1/admin/relay/ping?backend=cloudflare')
            seen.append(r902.text)
            check(
                r902.status_code == 502
                and r902.json().get('error', {}).get('code') == 'backend_unreachable',
                '不可达代理 + 可达中继 → 502 backend_unreachable（证明确实走了代理）',
                f'{r902.status_code} {r902.text[:140]}',
            )
            err = r902.json().get('error', {}).get('message', '')
            check(
                dead_proxy in err and token not in r902.text,
                '错误消息带代理地址（可排查）、不带令牌',
                err[:120],
            )

            # ---- proxy="" → 清空，同一假中继恢复 200 ----
            r3 = c.put('/v1/admin/relay/config', json={
                'backend': 'cloudflare', 'proxy': '',
            })
            seen.append(r3.text)
            cf3 = next((b for b in (r3.json().get('backends') or [])
                        if b.get('name') == 'cloudflare'), {})
            check(cf3.get('proxy') == '', 'PUT proxy="" → 清空（回落直连）', str(cf3.get('proxy')))
            r4 = c.get('/v1/admin/relay/ping?backend=cloudflare')
            seen.append(r4.text)
            check(
                r4.status_code == 200 and r4.json().get('ok') is True,
                '清空代理后同一中继恢复 200（证明清空生效）',
                f'{r4.status_code} {r4.text[:120]}',
            )

            # ---- proxy=null 同样视为清空 ----
            c.put('/v1/admin/relay/config', json={
                'backend': 'netlify', 'base_url': fake.base_url, 'token': token,
                'proxy': 'http://127.0.0.1:7890',
            })
            r5 = c.put('/v1/admin/relay/config', json={'backend': 'netlify', 'proxy': None})
            seen.append(r5.text)
            nf = next((b for b in (r5.json().get('backends') or [])
                       if b.get('name') == 'netlify'), {})
            check(nf.get('proxy') == '', 'PUT proxy=null → 清空', str(nf.get('proxy')))

        # ---- 配置响应：有 proxy 明文、无 token 明文 ----
        rc = c.get('/v1/admin/relay/config')
        seen.append(rc.text)
        blob = ''.join(seen)
        check('"proxy"' in rc.text, 'config 响应确实含 proxy 字段')
        check(token not in blob, '全部响应不含令牌明文（proxy 明文是可以的）')
        assert_no_secret(blob, secrets, '/v1/admin/relay/*（含 proxy）')
    finally:
        if existed and original is not None:
            settings_path.write_text(original, encoding='utf-8')
        elif settings_path.is_file():
            settings_path.unlink()
        c.post('/v1/admin/reload')
        print('  ↩️  settings.json 已还原（relay_admin.proxy 一并回滚）')


def check_static(c: TestClient) -> None:
    print('\n[9] 静态资源挂载（AC-09）')
    index = _HERE / 'static' / 'index.html'
    if not index.is_file():
        skip('/admin 返回 200', 'static/index.html 尚未创建（T03 后自动生效）')
        return
    r = c.get('/admin')
    check(r.status_code == 200, 'GET /admin → 200', f'实际 {r.status_code}')
    check('<html' in r.text.lower(), '/admin 返回 HTML 骨架')
    r2 = c.get('/')
    check(r2.status_code == 200, 'GET / → 200', f'实际 {r2.status_code}')
    for name in ('app.css', 'api.js', 'app.js', 'views-a.js', 'views-b.js', 'views-c.js',
                 'views-d.js', 'views-e.js'):
        path = _HERE / 'static' / name
        if not path.is_file():
            skip(f'/static/{name} → 200', '文件尚未创建')
            continue
        rr = c.get(f'/static/{name}')
        check(rr.status_code == 200, f'/static/{name} → 200', f'实际 {rr.status_code}')


def check_live_t1(c: TestClient) -> None:
    print('\n[10] 真实链路 POST /v1/task/T1（--live，需要本机 Ollama 在跑）')
    note = ('牛顿第二定律：物体加速度的大小跟作用力成正比，跟物体的质量成反比，'
            '加速度的方向跟作用力的方向相同。公式 F=ma。')
    r = c.post('/v1/task/T1', json={'inputs': {'note_text': note}})
    if r.status_code != 200:
        bad('T1 调用成功', f'{r.status_code} {r.text[:200]}')
        return
    body = r.json()
    parsed = body.get('parsed') or {}
    kps = parsed.get('knowledge_points') if isinstance(parsed, dict) else None
    if not check(isinstance(kps, list) and len(kps) > 0, 'parsed.knowledge_points 非空',
                 f'实际 {type(kps).__name__} len={len(kps) if isinstance(kps, list) else "-"}'):
        return
    hit = [k for k in kps if isinstance(k, dict) and str(k.get('source_quote') or '') in note]
    check(len(hit) > 0, 'source_quote 命中原文（锚点校验的前提）',
          f'{len(hit)}/{len(kps)} 条命中')
    stats = c.get('/v1/admin/stats').json()
    check(stats.get('total', 0) > 0, 'stats.total 有累加（task 埋点真的接上了）',
          f"total={stats.get('total')} by_task={stats.get('by_task')}")


def check_live_chat(c: TestClient) -> None:
    """真实链路：chat 的两条路径（blocking / SSE）都要进埋点。

    任务埋点已在 [check_live_t1] 覆盖；这里补 chat —— 两条路径分别落在
    ``_blocking`` 与 ``_sse`` 里，改任一处都可能漏埋，必须各打一次。
    """
    print('\n[11] 真实链路 POST /v1/chat（--live，blocking + SSE 两条路径）')
    from core.stats import snapshot as raw_snapshot

    query = '用一句话解释牛顿第二定律'

    # ---- blocking（stream:false）----
    base = raw_snapshot(3600)['total']
    r = c.post('/v1/chat', json={'task': 'T6', 'query': query, 'stream': False})
    if not check(r.status_code == 200, 'chat(blocking) 返回 200', f'{r.status_code} {r.text[:160]}'):
        return
    body = r.json()
    check(
        set(body) == {'content', 'parsed', 'conversation_id', 'usage', 'backend',
                      'model_id', 'latency_ms'},
        'chat(blocking) 响应字段与改动前一致（C4）',
        str(sorted(body)),
    )
    after_blocking = raw_snapshot(3600)['total']
    check(
        after_blocking == base + 1,
        'chat(blocking) 埋点 +1',
        f'{base} → {after_blocking}',
    )

    # ---- SSE（stream:true）----
    base2 = after_blocking
    r2 = c.post('/v1/chat', json={'task': 'T6', 'query': query, 'stream': True})
    if not check(r2.status_code == 200, 'chat(SSE) 返回 200', f'{r2.status_code}'):
        return
    done = None
    for line in (r2.text or '').splitlines():
        if line.startswith('data: '):
            try:
                ev = json.loads(line[6:])
            except ValueError:
                continue
            if isinstance(ev, dict) and ev.get('done'):
                done = ev
    check(done is not None, 'chat(SSE) 收到 done 帧')
    if done is not None:
        check(
            set(done) == {'done', 'conversation_id', 'content', 'parsed', 'backend',
                          'model_id', 'latency_ms'},
            'chat(SSE) done 帧字段与改动前一致（C4）',
            str(sorted(done)),
        )
    after_sse = raw_snapshot(3600)['total']
    check(after_sse == base2 + 1, 'chat(SSE) 埋点 +1', f'{base2} → {after_sse}')


# ---------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    live = '--live' in argv

    print('=' * 72)
    print('AIMindTree 管理后台 P0 验收（进程内 TestClient，不跨进程，C7）')
    print('=' * 72)

    secrets = load_env_secrets(_HERE / '.env')
    if secrets:
        names = sorted(secrets)
        print(f'  已从 .env 读取 {len(names)} 个疑似密钥做泄露比对（不打印值）：{names}')
    else:
        print('  ⚠️ .env 里没有长度 ≥8 的疑似密钥 → 泄露断言将跳过')

    app = create_app()
    with TestClient(app) as c:
        check_health(c)
        check_app_config(c, secrets)
        check_admin_config(c, secrets)
        check_routes(c)
        check_stats(c)
        check_logs(c, secrets)
        check_jobs(c, secrets)
        check_config_roundtrip(c)
        check_sync_endpoints(c, secrets)
        check_relay_admin(c, secrets)
        check_relay_proxy(c, secrets)
        check_static(c)
        if live:
            check_live_t1(c)
            check_live_chat(c)

    print()
    print('-' * 72)
    print(f'结果：{_PASS} 通过，{_FAIL} 失败，{_SKIP} 跳过')
    if _FAIL:
        print('❌ verify_admin_console FAILED')
        return 1
    print('✅ verify_admin_console PASSED')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
