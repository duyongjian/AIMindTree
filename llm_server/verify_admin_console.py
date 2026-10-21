"""管理后台 P0 验收脚本（与 ``selftest.py`` 同级，纯标准库 + TestClient）。

为什么不用「起 uvicorn + curl」：沙箱的 loopback 隔离会让跨进程访问
``127.0.0.1:8787`` 超时（C7）。这里一律用 ``fastapi.testclient.TestClient``
在**进程内**打完整 ASGI 栈，等价于真实 HTTP 请求但不跨进程。

覆盖：

1. ``GET /health`` **结构逐字段不变**（C4 向后兼容）；
2. ``GET /v1/app/config``：200 + 13 字段白名单 + **无鉴权**（C10）；
3. ``GET /v1/admin/config``：既有字段一字不改 + 新增 5 个字段；
4. **密钥零扩散**（C3，最高优先级）：把 ``.env`` 里每个疑似密钥（名含
   KEY/TOKEN/SECRET 且长度 ≥ 8）的真实值拿来做字符串级断言 —— 必须
   ①不出现在 ``/v1/app/config`` 响应体；②不出现在 ``/v1/admin/config``
   响应除 ``key_masked`` 之外的任何位置；
5. 任务路由 ``GET/PUT /v1/admin/routes``（含非法值 400）；
6. 统计埋点 ``GET /v1/admin/stats``（空缓冲 → 空数组；打 3 次坏请求 → 累加）；
7. 配置写入往返（``app`` / ``sync`` / per-backend / ``task_backends``）+ **还原**；
8. 静态资源挂载（``/admin``、``/static/*``）；
9. 可选：真实链路 ``POST /v1/task/T1`` + ``POST /v1/chat``（blocking 与 SSE
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
from pathlib import Path
from typing import Any

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
        isinstance(sync, dict) and set(sync) == {'base_url', 'enabled', 'token_set'},
        'sync 恒为 object 且只含 base_url/enabled/token_set（Q-C, C3）',
        str(sync),
    )
    check(
        isinstance(sync, dict) and 'token' not in sync and isinstance(sync.get('token_set'), bool),
        'sync 里没有 token 明文（只有 token_set 布尔）',
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


def check_config_roundtrip(c: TestClient) -> None:
    print('\n[6] POST /v1/admin/config —— 覆盖层往返 + 还原（AC-03/04, C9）')
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

        # 下发端能看到 app.service_name，且 sync 只回布尔
        pushed = c.get('/v1/app/config').json()
        check(
            pushed.get('service_name') == '验收临时名',
            '/v1/app/config 同步看到新服务名',
            str(pushed.get('service_name')),
        )
        check(
            pushed.get('sync', {}).get('token_set') is True
            and 'token' not in (pushed.get('sync') or {}),
            '下发 sync 只有 token_set（无明文）',
            str(sorted((pushed.get('sync') or {}).keys())),
        )
        check(
            'verify-temp-token-should-never-be-echoed' not in json.dumps(pushed, ensure_ascii=False),
            '临时 token 未出现在下发体',
        )
    finally:
        # 还原 settings.json（原本不存在则删除），保证仓库零污染
        if existed and original is not None:
            settings_path.write_text(original, encoding='utf-8')
        elif settings_path.is_file():
            settings_path.unlink()
        print('  ↩️  settings.json 已还原（C9：config.yaml 全程未被写入）')


def check_static(c: TestClient) -> None:
    print('\n[7] 静态资源挂载（AC-09）')
    index = _HERE / 'static' / 'index.html'
    if not index.is_file():
        skip('/admin 返回 200', 'static/index.html 尚未创建（T03 后自动生效）')
        return
    r = c.get('/admin')
    check(r.status_code == 200, 'GET /admin → 200', f'实际 {r.status_code}')
    check('<html' in r.text.lower(), '/admin 返回 HTML 骨架')
    r2 = c.get('/')
    check(r2.status_code == 200, 'GET / → 200', f'实际 {r2.status_code}')
    for name in ('app.css', 'api.js', 'app.js', 'views-a.js', 'views-b.js'):
        path = _HERE / 'static' / name
        if not path.is_file():
            skip(f'/static/{name} → 200', '文件尚未创建')
            continue
        rr = c.get(f'/static/{name}')
        check(rr.status_code == 200, f'/static/{name} → 200', f'实际 {rr.status_code}')


def check_live_t1(c: TestClient) -> None:
    print('\n[8] 真实链路 POST /v1/task/T1（--live，需要本机 Ollama 在跑）')
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
    print('\n[9] 真实链路 POST /v1/chat（--live，blocking + SSE 两条路径）')
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
        check_config_roundtrip(c)
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
