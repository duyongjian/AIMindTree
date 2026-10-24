"""云端同步中继的**管理 API** 代理（M11「云端同步」面板）。

本地 llm_server 不直接读云端存储，而是把请求转发给中继自己的管理 API
（前缀 ``/admin``，鉴权 ``Authorization: Bearer <ADMIN_TOKEN>``）：

- ``GET    /v1/admin/relay/config``            —— 各后端的 base_url / token_set / token_masked
- ``PUT    /v1/admin/relay/config``            —— 保存某后端的 base_url / token（token 只落盘）
- ``GET    /v1/admin/relay/ping|stats|users``  —— 概览数据
- ``POST   /v1/admin/relay/reset``             —— 重置（``scope=all|envelopes|user``）
- ``DELETE /v1/admin/relay/user/{user_id}``    —— 删除单个云端用户
- ``GET    /v1/admin/relay/export``            —— 导出（JSON）

三条铁律（面板与验收脚本都按此断言）：

1. **令牌永不回显**：只给 ``token_set`` / ``token_masked``；令牌也不进日志、
   不进错误消息（日志只打「方法 + 子路径 + 后端名」，错误只打 base_url）。
2. **上游非 2xx 原样透传**状态码与 body —— 面板要把中继的原始错误显示出来，
   不许在这里二次包装成 ``internal``。
3. 网络 / 超时（15s）→ 502 ``backend_unreachable``；该后端未配置 →
   400 ``relay_not_configured``。
"""

from __future__ import annotations

from typing import Any
from urllib.parse import quote

import httpx
from fastapi import APIRouter, Query, Request
from fastapi.responses import JSONResponse, Response

from core.config import RELAY_BACKENDS, Config
from core.errors import LlmError, invalid_request
from core.logging import get_logger

router = APIRouter(tags=['admin'])
_log = get_logger('config')

#: 中继管理 API 的单次请求超时（秒）。
_RELAY_TIMEOUT_S = 15.0

#: ``POST /v1/admin/relay/reset`` 允许的 scope 取值。
_VALID_SCOPES = ('all', 'envelopes', 'user')


# ---------------------------------------------------------------- 公共工具


def _mask_token(token: str) -> str | None:
    """面板用的短掩码（前 4 … 后 4）；空令牌返回 ``None``。"""
    if not token:
        return None
    if len(token) <= 8:
        return f'{token[:2]}…'
    return f'{token[:4]}…{token[-4:]}'


def _configured(conf: dict[str, str]) -> bool:
    """``base_url`` 与 ``token`` 都在才算「已配置」。"""
    return bool(conf.get('base_url')) and bool(conf.get('token'))


def _default_backend(config: Config) -> str:
    """未指定 backend 时：第一个已配置的后端，否则 cloudflare。"""
    for name in RELAY_BACKENDS:
        if _configured(config.relay_conf(name)):
            return name
    return RELAY_BACKENDS[0]


def _backend_name(config: Config, raw: Any) -> str:
    """校验并归一化 backend 名（空 = 取默认；非法 → 400 invalid_request）。"""
    name = str(raw or '').strip()
    if not name:
        return _default_backend(config)
    if name not in RELAY_BACKENDS:
        raise invalid_request(f'backend 必须是 {list(RELAY_BACKENDS)} 之一（收到 {name}）')
    return name


def _resolve(config: Config, raw: Any) -> str:
    """校验 backend 名 + 确认已配置；未配置 → 400 ``relay_not_configured``。"""
    name = _backend_name(config, raw)
    conf = config.relay_conf(name)
    if not conf['base_url']:
        raise LlmError(
            'relay_not_configured',
            f'云端中继 {name} 还没配管理 API 地址（base_url），先在「中继连接」里保存。',
            http_status=400,
        )
    if not conf['token']:
        raise LlmError(
            'relay_not_configured',
            f'云端中继 {name} 还没配管理令牌（ADMIN_TOKEN），先在「中继连接」里保存。',
            http_status=400,
        )
    return name


async def _json_body(request: Request) -> dict:
    """读 JSON body（非对象 / 非 JSON → 400 invalid_request）。"""
    try:
        body = await request.json()
    except Exception as exc:
        raise invalid_request(f'请求体不是合法 JSON（{exc}）') from exc
    if not isinstance(body, dict):
        raise invalid_request('body 必须是 JSON 对象')
    return body


async def _forward(
    config: Config,
    name: str,
    method: str,
    path: str,
    *,
    params: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
) -> Response:
    """把请求转发到 ``<base_url><path>``，**原样透传**上游状态码与 body。

    Args:
        path: 中继侧的子路径（如 ``/admin/stats``），必须已含前缀 ``/admin``。
        params: query 参数（值为 ``None`` 的键会被丢掉）。
        body: POST 的 JSON body（``None`` = 不带 body）。
    """
    conf = config.relay_conf(name)
    base = conf['base_url']
    url = f'{base}{path}'
    # 只打「方法 + 子路径 + 后端名」：令牌与完整 query 都不进日志。
    _log.info('中继代理 %s %s → %s', method, path, name)
    headers = {
        'Authorization': f"Bearer {conf['token']}",
        'Accept': 'application/json',
    }
    clean = {k: v for k, v in (params or {}).items() if v}
    try:
        async with httpx.AsyncClient(timeout=_RELAY_TIMEOUT_S, trust_env=False) as client:
            resp = await client.request(
                method, url, params=clean or None, json=body, headers=headers
            )
    except httpx.TimeoutException as exc:
        raise LlmError(
            'backend_unreachable',
            f'云端中继 {name} 在 {_RELAY_TIMEOUT_S:g}s 内没有响应（{base}）。',
            http_status=502,
        ) from exc
    except httpx.HTTPError as exc:
        raise LlmError(
            'backend_unreachable',
            f'无法连接云端中继 {name}（{base}）：{type(exc).__name__}。'
            '请检查网络，或确认该中继已部署 / base_url 正确。',
            http_status=502,
        ) from exc

    content_type = resp.headers.get('content-type') or 'application/json'
    _log.info('中继代理 %s %s ← HTTP %s', method, path, resp.status_code)
    # 原样透传：状态码 + body + content-type（面板据此显示上游原始错误）。
    return Response(
        content=resp.content,
        status_code=resp.status_code,
        media_type=content_type,
        headers={'Cache-Control': 'no-store'},
    )


def _relay_config_payload(config: Config) -> dict:
    """``GET / PUT /v1/admin/relay/config`` 的同构响应体（**无令牌明文**）。"""
    backends: list[dict[str, Any]] = []
    for name in RELAY_BACKENDS:
        conf = config.relay_conf(name)
        token = conf['token']
        backends.append(
            {
                'name': name,
                'base_url': conf['base_url'],
                'token_set': bool(token),
                'token_masked': _mask_token(token),
                # 派生字段：面板据此判断「能不能直接拉数据」（避免前端重复拼规则）
                'configured': _configured(conf),
            }
        )
    return {'backends': backends}


# ---------------------------------------------------------------- 配置


@router.get('/v1/admin/relay/config')
async def get_relay_config(request: Request) -> JSONResponse:
    """各中继后端的管理配置（``base_url`` / ``token_set`` / ``token_masked``）。"""
    config = request.app.state.config  # type: ignore[attr-defined]
    return JSONResponse(
        _relay_config_payload(config), headers={'Cache-Control': 'no-store'}
    )


@router.put('/v1/admin/relay/config')
async def put_relay_config(request: Request) -> JSONResponse:
    """保存某中继后端的管理配置到 settings.json 的 ``relay_admin`` 段。

    body::

        {"backend": "cloudflare", "base_url": "https://...", "token": "..."}

    ``backend`` 必填且在 :data:`RELAY_BACKENDS` 内；``base_url`` / ``token``
    均可选（**缺 key = 不修改**）：``base_url`` 空串 = 回落默认地址，
    ``token`` 空串 = 清空令牌。类型不对 → 400 ``invalid_request``。
    """
    state = request.app.state
    config = state.config  # type: ignore[attr-defined]
    body = await _json_body(request)

    raw_name = body.get('backend')
    if not isinstance(raw_name, str) or raw_name.strip() not in RELAY_BACKENDS:
        raise invalid_request(f'backend 必须是 {list(RELAY_BACKENDS)} 之一')
    name = raw_name.strip()

    patch: dict[str, Any] = {}
    if 'base_url' in body:
        base_url = body.get('base_url')
        if base_url is None:
            patch['base_url'] = ''
        elif isinstance(base_url, str):
            patch['base_url'] = base_url.strip()
        else:
            raise invalid_request('base_url 必须是字符串或 null')
        if patch['base_url'] and not (
            patch['base_url'].startswith('http://') or patch['base_url'].startswith('https://')
        ):
            raise invalid_request('base_url 必须以 http:// 或 https:// 开头')
    if 'token' in body:
        token = body.get('token')
        if token is None:
            patch['token'] = ''
        elif isinstance(token, str):
            patch['token'] = token.strip()  # 空串 / 纯空白 = 清空
        else:
            raise invalid_request('token 必须是字符串或 null')

    if not patch:
        # 两个键都没传 → 视为「不修改」（与 sync / routes 口径一致）。
        return JSONResponse(
            _relay_config_payload(config), headers={'Cache-Control': 'no-store'}
        )

    config.save_settings({'relay_admin': {name: patch}})  # type: ignore[attr-defined]
    config.load()  # type: ignore[attr-defined]  # 立即生效
    _log.info(
        '已保存云端中继配置（backend=%s，base_url=%s，token_set=%s）',
        name,
        patch.get('base_url', '—'),
        bool(patch.get('token')),
    )
    return JSONResponse(_relay_config_payload(config), headers={'Cache-Control': 'no-store'})


# ---------------------------------------------------------------- 数据代理


@router.get('/v1/admin/relay/ping')
async def relay_ping(
    request: Request,
    backend: str | None = Query(default=None),
) -> Response:
    """``GET /admin/ping`` —— 连通性 / 存储类型 / 服务器时间。"""
    config = request.app.state.config  # type: ignore[attr-defined]
    name = _resolve(config, backend)
    return await _forward(config, name, 'GET', '/admin/ping')


@router.get('/v1/admin/relay/stats')
async def relay_stats(
    request: Request,
    backend: str | None = Query(default=None),
) -> Response:
    """``GET /admin/stats`` —— 用户数 / 令牌数 / 数据行数 / 逐用户明细。"""
    config = request.app.state.config  # type: ignore[attr-defined]
    name = _resolve(config, backend)
    return await _forward(config, name, 'GET', '/admin/stats')


@router.get('/v1/admin/relay/users')
async def relay_users(
    request: Request,
    backend: str | None = Query(default=None),
) -> Response:
    """``GET /admin/users`` —— 云端账号列表（含令牌数 / 行数）。"""
    config = request.app.state.config  # type: ignore[attr-defined]
    name = _resolve(config, backend)
    return await _forward(config, name, 'GET', '/admin/users')


@router.post('/v1/admin/relay/reset')
async def relay_reset(
    request: Request,
    backend: str | None = Query(default=None),
) -> Response:
    """``POST /admin/reset`` —— 重置云端数据（危险操作）。

    body::

        {"backend": "cloudflare", "scope": "all|envelopes|user",
         "user_id": "u_xxx", "confirm": "RESET"}

    ``confirm`` 由中继校验（不是 ``RESET`` → 上游 400 ``confirm_required``，
    这里**原样透传**，不在本地做二次校验）。
    """
    config = request.app.state.config  # type: ignore[attr-defined]
    body = await _json_body(request)
    name = _resolve(config, body.get('backend') or backend)

    scope = str(body.get('scope') or '').strip()
    if scope not in _VALID_SCOPES:
        raise invalid_request(f'scope 必须是 {list(_VALID_SCOPES)} 之一')

    payload: dict[str, Any] = {
        'scope': scope,
        'confirm': str(body.get('confirm') or ''),
    }
    user_id = str(body.get('user_id') or '').strip()
    if scope == 'user':
        if not user_id:
            raise invalid_request('scope=user 时必须给 user_id')
        payload['user_id'] = user_id
    elif user_id:
        payload['user_id'] = user_id  # 透传但不参与；中继按 scope 决定是否使用
    return await _forward(config, name, 'POST', '/admin/reset', body=payload)


@router.delete('/v1/admin/relay/user/{user_id}')
async def relay_delete_user(
    request: Request,
    user_id: str,
    backend: str | None = Query(default=None),
) -> Response:
    """``DELETE /admin/user/{id}`` —— 删除单个云端账号及其数据。

    用户不存在时上游返回 404 ``{"error":"user_not_found"}``，原样透传。
    """
    config = request.app.state.config  # type: ignore[attr-defined]
    name = _resolve(config, backend)
    uid = str(user_id or '').strip()
    if not uid:
        raise invalid_request('user_id 不能为空')
    return await _forward(config, name, 'DELETE', f'/admin/user/{quote(uid, safe="")}')


@router.get('/v1/admin/relay/export')
async def relay_export(
    request: Request,
    backend: str | None = Query(default=None),
    user_id: str | None = Query(default=None),
) -> Response:
    """``GET /admin/export?user_id=`` —— 导出云端数据（JSON，可能很大）。

    不落盘、不缓存，直接回给前端（面板用 Blob 下载）。
    """
    config = request.app.state.config  # type: ignore[attr-defined]
    name = _resolve(config, backend)
    params = {'user_id': str(user_id).strip()} if user_id else None
    return await _forward(config, name, 'GET', '/admin/export', params=params)
