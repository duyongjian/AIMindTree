"""方案 A 同步中继（llm_server 本地 /sync/*）自测。

用 FastAPI TestClient 直接驱动 ``create_app()``，验证 push → pull → manifest
全链路与 App 端 ``HttpSyncApi`` 契约一致，并覆盖：

- 空 relay_token 放行；
- 设 relay_token 后缺/错 Bearer → 401，正确 → 200；
- push 接收计数 + server_time(ISO)；
- manifest 计数；
- pull 全量（envelope 字段 / payload 还原）；
- INSERT OR REPLACE 覆盖同 (entity_table, entity_id)；
- pull since 增量过滤。

运行：cd llm_server && python test_sync_relay.py
"""

from __future__ import annotations

import os
import tempfile

from fastapi.testclient import TestClient

import routers.sync_relay as sync_relay
from server import create_app

# 用临时文件替换真实 sync_relay.db，避免污染仓库。
_TMP_DB = os.path.join(tempfile.gettempdir(), 'aimindtree_sync_relay_test.db')
if os.path.exists(_TMP_DB):
    os.remove(_TMP_DB)
sync_relay._DB_PATH = type(sync_relay._DB_PATH)(_TMP_DB)  # type: ignore[assignment]


def _make_env(table: str, eid: str, device: str, payload) -> dict:
    return {
        'device_id': device,
        'entity_table': table,
        'entity_id': eid,
        'op': 'upsert',
        'payload': payload,
        'base_version': 1,
        'updated_at': '2024-10-23T00:00:00.000000+00:00',
        'deleted_at': None,
    }


def main() -> int:
    app = create_app()
    # 默认 relay_token 为空（开发期放行）；用例 2 显式设置再测 401。
    app.state.config.sync['relay_token'] = ''
    client = TestClient(app)

    passed = 0
    failed = 0

    def check(cond: bool, msg: str) -> None:
        nonlocal passed, failed
        if cond:
            passed += 1
            print(f'  ✓ {msg}')
        else:
            failed += 1
            print(f'  ✗ {msg}')

    # 1) 空 token 放行
    r = client.post(
        '/sync/push',
        json={'device_id': 'd1', 'envelopes': []},
    )
    check(r.status_code == 200, '空 relay_token：push 放行 (200)')

    # 2) 设 token 后鉴权
    app.state.config.sync['relay_token'] = 'secret-123'
    r = client.post('/sync/push', json={'device_id': 'd1', 'envelopes': []})
    check(r.status_code == 401, '设 token 后缺 Bearer 返回 401')
    r = client.post(
        '/sync/push',
        json={'device_id': 'd1', 'envelopes': []},
        headers={'Authorization': 'Bearer secret-123'},
    )
    check(r.status_code == 200, '正确 Bearer 放行 (200)')
    # 还原为空，后续用例走开发期免 token
    app.state.config.sync['relay_token'] = ''

    # 3) push 接收计数 + server_time
    envelopes = [
        _make_env('notes', 'n1', 'd1', {'title': 'A'}),
        _make_env('notes', 'n2', 'd1', {'title': 'B'}),
    ]
    r = client.post('/sync/push', json={'device_id': 'd1', 'envelopes': envelopes})
    j = r.json()
    check(r.status_code == 200, 'push 返回 200')
    check(j.get('received') == 2, 'push 返回 received=2')
    check(isinstance(j.get('server_time'), str) and 'T' in j['server_time'],
          'push 返回 server_time(ISO)')

    # 4) manifest 计数
    r = client.get('/sync/manifest')
    check(r.json().get('count') == 2, 'manifest 返回 count=2')

    # 5) pull 全量
    r = client.post('/sync/pull', json={'device_id': 'd1', 'since': None})
    j = r.json()
    check(r.status_code == 200, 'pull 返回 200')
    check(len(j.get('envelopes', [])) == 2, 'pull 全量返回 2 条')
    first = j['envelopes'][0]
    check(first.get('device_id') == 'd1' and first.get('entity_table') == 'notes',
          'envelope 字段还原正确')
    check(first.get('payload') and first['payload'].get('title') == 'A',
          'payload 反序列化正确')
    check(first.get('op') == 'upsert' and first.get('base_version') == 1,
          'op / base_version 还原正确')

    # 6) INSERT OR REPLACE 覆盖同 key
    updated = [_make_env('notes', 'n1', 'd1', {'title': 'A-updated'})]
    client.post('/sync/push', json={'device_id': 'd1', 'envelopes': updated})
    r = client.get('/sync/manifest')
    check(r.json().get('count') == 2, '覆盖同 key 后 count 仍为 2（未新增）')
    r = client.post('/sync/pull', json={'device_id': 'd1', 'since': None})
    n1 = next(e for e in r.json()['envelopes'] if e['entity_id'] == 'n1')
    check(n1['payload']['title'] == 'A-updated', '覆盖后拉取拿到新 payload')

    # 7) pull since 增量过滤（确定性：用刚推的 n3 作游标）
    p3 = client.post('/sync/push',
                     json={'device_id': 'd1',
                           'envelopes': [_make_env('notes', 'n3', 'd1', {'title': 'C'})]})
    t3 = p3.json()['server_time']
    client.post('/sync/push',
                json={'device_id': 'd1',
                      'envelopes': [_make_env('notes', 'n4', 'd1', {'title': 'D'})]})
    r = client.post('/sync/pull', json={'device_id': 'd1', 'since': t3})
    pulled = r.json()['envelopes']
    check(len(pulled) == 1, 'since 增量过滤只返回 1 条')
    check(pulled and pulled[0]['entity_id'] == 'n4', '增量过滤命中的是 n4')

    # 8) 未知路径 404
    r = client.get('/sync/nope')
    check(r.status_code == 404, '未知路径返回 404')

    print(f'\n结果：通过 {passed}，失败 {failed}')
    if os.path.exists(_TMP_DB):
        os.remove(_TMP_DB)
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
