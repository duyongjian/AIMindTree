"""本地同步中继（方案 A）：把 ``/sync/*`` 三个接口直接并进 llm_server。

与 App 端 ``HttpSyncApi`` 契约严格对齐（见
``aimindtree_app/lib/data/sync/sync_api.dart`` 头部注释）：

- ``POST /sync/push``  ``{device_id, envelopes:[...]}`` → ``{received, server_time}``
- ``POST /sync/pull``  ``{device_id, since|null}``     → ``{envelopes:[...], server_time}``
- ``GET  /sync/manifest``                             → ``{count}``

envelope 字段与 App ``SyncEnvelope`` 一致：
``device_id / entity_table / entity_id / op / payload / base_version /
updated_at / deleted_at``。

存储用**标准库** ``sqlite3``（不引入新依赖，保持 4 依赖约束），库文件
``llm_server/sync_relay.db``（已加入仓库根 ``.gitignore``）。该表只存
「每个 (entity_table, entity_id) 的最新态」——LWW 已在客户端做，服务端
只需保存最新态 + ``server_time`` 供增量拉取。

鉴权：Bearer token 比对 ``config.sync.relay_token``；若该值为空则直接放行
（开发期 llm_server 仅绑 127.0.0.1，localhost 信任）。部署到公网时务必设置
``relay_token``。
"""

from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from core.config import ROOT

router = APIRouter()

_DB_PATH = ROOT / 'sync_relay.db'
_LOCK = threading.Lock()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(str(_DB_PATH))
    conn.execute(
        '''
        CREATE TABLE IF NOT EXISTS sync_envelopes (
            entity_table TEXT NOT NULL,
            entity_id    TEXT NOT NULL,
            device_id   TEXT NOT NULL,
            op          TEXT NOT NULL,
            payload_json TEXT,
            base_version INTEGER NOT NULL DEFAULT 0,
            updated_at  TEXT,
            deleted_at  TEXT,
            server_time TEXT NOT NULL,
            PRIMARY KEY (entity_table, entity_id)
        )
        '''
    )
    return conn


# ---------------- 请求体模型（FastAPI 自动解析 JSON） ----------------

class EnvelopeIn(BaseModel):
    device_id: str
    entity_table: str
    entity_id: str
    op: str
    payload: dict[str, Any] | None = None
    base_version: int = 0
    updated_at: str | None = None
    deleted_at: str | None = None


class PushBody(BaseModel):
    device_id: str
    envelopes: list[EnvelopeIn] = Field(default_factory=list)


class PullBody(BaseModel):
    device_id: str
    since: str | None = None


# ---------------- 鉴权依赖 ----------------

def _verify_token(request: Request) -> None:
    """Bearer token 比对 ``config.sync.relay_token``；空值放行（开发期）。"""
    expected = (request.app.state.config.sync.get('relay_token') or '').strip()
    if not expected:
        return
    auth = request.headers.get('Authorization', '')
    token = auth[len('Bearer '):].strip() if auth.lower().startswith('bearer ') else ''
    if token != expected:
        raise HTTPException(status_code=401, detail='invalid sync token')


# ---------------- 端点 ----------------

@router.post('/sync/push')
def sync_push(body: PushBody, _: None = Depends(_verify_token)) -> dict[str, Any]:
    now = _now_iso()
    with _LOCK:
        conn = _connect()
        try:
            for env in body.envelopes:
                conn.execute(
                    '''
                    INSERT OR REPLACE INTO sync_envelopes
                    (entity_table, entity_id, device_id, op, payload_json,
                     base_version, updated_at, deleted_at, server_time)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ''',
                    (
                        env.entity_table,
                        env.entity_id,
                        env.device_id,
                        env.op,
                        json.dumps(env.payload, ensure_ascii=False)
                        if env.payload is not None
                        else None,
                        int(env.base_version or 0),
                        env.updated_at,
                        env.deleted_at,
                        now,
                    ),
                )
            conn.commit()
        finally:
            conn.close()
    return {'received': len(body.envelopes), 'server_time': now}


@router.post('/sync/pull')
def sync_pull(body: PullBody, _: None = Depends(_verify_token)) -> dict[str, Any]:
    now = _now_iso()
    cols = (
        'entity_table, entity_id, device_id, op, payload_json, '
        'base_version, updated_at, deleted_at, server_time'
    )
    with _LOCK:
        conn = _connect()
        try:
            if body.since:
                rows = conn.execute(
                    f'SELECT {cols} FROM sync_envelopes '
                    'WHERE server_time > ? ORDER BY server_time',
                    (body.since,),
                ).fetchall()
            else:
                rows = conn.execute(
                    f'SELECT {cols} FROM sync_envelopes ORDER BY server_time'
                ).fetchall()
        finally:
            conn.close()

    envelopes = [
        {
            'device_id': r[2],
            'entity_table': r[0],
            'entity_id': r[1],
            'op': r[3],
            'payload': json.loads(r[4]) if r[4] else None,
            'base_version': r[5],
            'updated_at': r[6],
            'deleted_at': r[7],
        }
        for r in rows
    ]
    return {'envelopes': envelopes, 'server_time': now}


@router.get('/sync/manifest')
def sync_manifest(_: None = Depends(_verify_token)) -> dict[str, Any]:
    with _LOCK:
        conn = _connect()
        try:
            count = conn.execute('SELECT COUNT(*) FROM sync_envelopes').fetchone()[0]
        finally:
            conn.close()
    return {'count': count}
