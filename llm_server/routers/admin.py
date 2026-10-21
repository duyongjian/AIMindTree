"""管理后台 API（S-06 扩展 + 完整管理后台 P0）。

保留已有的 ``POST /v1/admin/reload``（config.yaml 热加载），并新增：

- ``GET  /v1/admin/config``   —— 当前生效配置摘要（含 per-backend base_url / app / sync）
- ``POST /v1/admin/config``   —— 保存覆盖层（默认后端 / 默认模型 / minimax 协议 / key /
  per-backend 四字段 / app / sync / task_backends）
- ``GET  /v1/admin/models``   —— 某后端的可用模型列表（含兜底，允许前端自由输入）
- ``GET  /v1/admin/balance``  —— MiniMax 余额 / 额度查询
- ``GET  /v1/admin/routes``   —— 任务路由（AC-05）
- ``PUT  /v1/admin/routes``   —— 保存任务路由
- ``GET  /v1/admin/stats``    —— 调用统计（AC-08）

所有密钥一律**不回传明文**：只暴露 ``key_set``（是否设置）和 ``key_masked``（掩码）；
``sync`` 只回 ``token_set`` 布尔。
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Query, Request
from fastapi.responses import JSONResponse

from core.errors import invalid_request
from core.logging import get_logger
from core.stats import snapshot as stats_snapshot

router = APIRouter(tags=['admin'])
_log = get_logger('config')

#: 允许的后端类型 / 协议（与 config 的 protocol 字段对齐）
_VALID_PROTOCOLS = ('openai_compat', 'anthropic_compat')

#: 默认统计窗口（秒）。
_DEFAULT_WINDOW_S = 3600.0


@router.post('/v1/admin/reload')
async def reload_config(request: Request) -> JSONResponse:
    """重载 config.yaml，并清空后端实例缓存（地址/密钥可能变了）。"""
    state = request.app.state
    state.config.load()  # type: ignore[attr-defined]
    cleared = state.clear_backends()  # type: ignore[attr-defined]
    _log.info('配置已重载，清理 %d 个后端实例缓存', cleared)
    return JSONResponse(
        {
            'ok': True,
            'reloaded': True,
            'backends_cleared': cleared,
            'default_backend': state.config.default_backend,  # type: ignore[attr-defined]
            'backends': sorted(state.config.backends),  # type: ignore[attr-defined]
            'loaded_at': state.config._mtime,  # type: ignore[attr-defined]
        }
    )


def _config_summary(request: Request) -> dict:
    """构造 ``GET /v1/admin/config`` 的响应体（供 GET / POST 复用）。

    既有 4 个顶层字段与 6 个 per-backend 字段**一字不改**（C4），只在 per-backend
    上**新增** ``base_url`` / ``editable`` / ``for_app``，顶层**新增** ``app`` /
    ``sync``（均为非敏感字段，无密钥明文）。
    """
    state = request.app.state
    config = state.config  # type: ignore[attr-defined]
    default_backend = str(config.default_backend or '')
    backends: list[dict] = []
    for name, conf in config.backends.items():
        key = config.resolve_api_key(conf)
        backends.append(
            {
                'name': conf.name,
                'protocol': conf.protocol,
                'default_model': conf.model(),
                'key_set': bool(key),
                'key_masked': (config.mask(key) if key else None),
                'models': list(conf.models),
                # ↓↓↓ 新增字段（C4 允许新增，不允许改/删既有字段）↓↓↓
                'base_url': conf.base_url,
                'editable': True,
                'for_app': (conf.name == default_backend),
            }
        )
    minimax_balance_path = None
    if 'minimax' in config.backends:
        minimax_balance_path = config.backends['minimax'].extra.get(
            'balance_path', '/v1/token_plan/remains'
        )
    app = dict(config.app or {})
    sync = dict(config.sync or {})
    return {
        'default_backend': config.default_backend,
        'default_model': config.default_model,
        'backends': backends,
        'minimax_balance_path': minimax_balance_path,
        # 新增：非敏感下发段（密钥零扩散，sync 只回 token_set 布尔）
        'app': {
            'service_name': str(app.get('service_name') or ''),
            'console_url': str(app.get('console_url') or ''),
            'timeouts': config.app_timeouts(),
        },
        'sync': {
            'base_url': str(sync.get('base_url') or ''),
            'enabled': bool(sync.get('enabled', False)),
            'token_set': bool(str(sync.get('token') or '').strip()),
        },
    }


@router.get('/v1/admin/config')
async def get_admin_config(request: Request) -> JSONResponse:
    """返回当前生效配置摘要（密钥只给掩码）。"""
    return JSONResponse(_config_summary(request))


@router.post('/v1/admin/config')
async def post_admin_config(request: Request) -> JSONResponse:
    """保存覆盖层到 settings.json，并热重载配置 + 清理后端缓存。

    body（均可选）：
        - ``default_backend``：必须是已配置后端之一
        - ``default_model``：默认模型 id
        - ``minimax_protocol``：``openai_compat`` / ``anthropic_compat``
        - ``minimax_api_key``：MiniMax 订阅 Key（写入 settings.json，不碰 config.yaml）
        - ``backends``：``{name: {base_url, protocol, default_model, models, api_key}}``
        - ``app``：``{service_name, console_url, timeouts}``（无密钥）
        - ``sync``：``{base_url, enabled, token}``（token 落盘，永不回显）
        - ``task_backends``：``{T1: 'ollama' | {backend, model} | null}``
    """
    state = request.app.state
    config = state.config  # type: ignore[attr-defined]
    try:
        body = await request.json()
    except Exception as exc:
        raise invalid_request(f'请求体不是合法 JSON（{exc}）') from exc
    if not isinstance(body, dict):
        raise invalid_request('body 必须是 JSON 对象')

    default_backend = body.get('default_backend')
    if default_backend is not None:
        if not isinstance(default_backend, str) or default_backend not in config.backends:
            raise invalid_request(
                f'default_backend 必须是已配置后端之一：{sorted(config.backends)}'
            )

    default_model = body.get('default_model')
    if default_model is not None and not isinstance(default_model, str):
        raise invalid_request('default_model 必须是字符串')

    minimax_protocol = body.get('minimax_protocol')
    if minimax_protocol is not None and minimax_protocol not in _VALID_PROTOCOLS:
        raise invalid_request('minimax_protocol 必须是 openai_compat / anthropic_compat')

    minimax_api_key = body.get('minimax_api_key')
    if minimax_api_key is not None and not isinstance(minimax_api_key, str):
        raise invalid_request('minimax_api_key 必须是字符串')

    # 规范化为 settings 覆盖层（minimax_api_key → backends.minimax.api_key）
    canonical: dict = {}
    if default_backend:
        canonical['default_backend'] = default_backend
    if default_model:
        canonical['default_model'] = default_model
    if minimax_protocol:
        canonical['minimax_protocol'] = minimax_protocol

    # ★ 新增段：backends / app / sync / task_backends（AC-03/04/05）
    canonical.update(_validate_backends(body, config))
    canonical.update(_validate_app(body))
    canonical.update(_validate_sync(body))
    canonical.update(_validate_task_backends(body, config))

    # minimax_api_key 合并进 backends.minimax.api_key（旧字段继续支持）
    if minimax_api_key:
        existing_minimax = dict((canonical.get('backends') or {}).get('minimax') or {})
        existing_minimax['api_key'] = minimax_api_key
        merged_backends = dict(canonical.get('backends') or {})
        merged_backends['minimax'] = existing_minimax
        canonical['backends'] = merged_backends

    config.save_settings(canonical)  # type: ignore[attr-defined]
    config.load()  # type: ignore[attr-defined]  # 立即把新覆盖层生效到内存
    state.clear_backends()  # type: ignore[attr-defined]  # 旧后端实例（含旧 key）失效

    _log.info('管理后台已保存配置并热重载')
    return JSONResponse(_config_summary(request))


# ---------------------------------------------------------------- 校验器


def _validate_backends(body: dict, config: Any) -> dict:
    """校验 ``backends: {name: {base_url, protocol, default_model, models, api_key}}``。"""
    raw = body.get('backends')
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise invalid_request('backends 必须是 {"后端名": {...}} 对象')
    known = sorted(config.backends)
    out: dict[str, dict] = {}
    for name, sub in raw.items():
        key = str(name)
        if key not in config.backends:
            raise invalid_request(f'未知后端：{key}（可用：{known}）')
        if sub is None:
            continue
        if not isinstance(sub, dict):
            raise invalid_request(f'backends.{key} 必须是对象或 null')
        item: dict[str, Any] = {}
        for field in ('base_url', 'default_model'):
            value = sub.get(field)
            if value is None:
                continue
            if not isinstance(value, str):
                raise invalid_request(f'backends.{key}.{field} 必须是字符串或 null')
            item[field] = value
        protocol = sub.get('protocol')
        if protocol is not None:
            if protocol not in _VALID_PROTOCOLS:
                raise invalid_request(
                    f'backends.{key}.protocol 必须是 {list(_VALID_PROTOCOLS)} 之一或 null'
                )
            item['protocol'] = protocol
        models = sub.get('models')
        if models is not None:
            if not isinstance(models, list):
                raise invalid_request(f'backends.{key}.models 必须是字符串数组或 null')
            item['models'] = [str(m) for m in models]
        api_key = sub.get('api_key')
        if api_key is not None:
            if not isinstance(api_key, str):
                raise invalid_request(f'backends.{key}.api_key 必须是字符串或 null')
            item['api_key'] = api_key
        if item:
            out[key] = item
    return {'backends': out} if out else {}


def _validate_app(body: dict) -> dict:
    """校验 ``app: {service_name, console_url, timeouts}``（**不含任何密钥**）。"""
    raw = body.get('app')
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise invalid_request('app 必须是对象')
    out: dict[str, Any] = {}
    for field in ('service_name', 'console_url'):
        value = raw.get(field)
        if value is None:
            continue
        if not isinstance(value, str):
            raise invalid_request(f'app.{field} 必须是字符串')
        out[field] = value.strip()
    if out.get('console_url'):
        url = out['console_url']
        if not (url.startswith('http://') or url.startswith('https://')):
            raise invalid_request('app.console_url 必须以 http:// 或 https:// 开头')
    timeouts = raw.get('timeouts')
    if timeouts is not None:
        if not isinstance(timeouts, dict):
            raise invalid_request('app.timeouts 必须是对象')
        checked: dict[str, int] = {}
        for field in ('structured_s', 'chat_s', 'connect_s'):
            value = timeouts.get(field)
            if value is None:
                continue
            try:
                number = float(value)
            except (TypeError, ValueError) as exc:
                raise invalid_request(f'app.timeouts.{field} 必须是数值') from exc
            if number <= 0:
                raise invalid_request(f'app.timeouts.{field} 必须大于 0')
            checked[field] = int(number)
        if checked:
            out['timeouts'] = checked
    return {'app': out} if out else {}


def _validate_sync(body: dict) -> dict:
    """校验 ``sync: {base_url, enabled, token}``（token 落盘但**永不回显**）。"""
    raw = body.get('sync')
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise invalid_request('sync 必须是对象')
    out: dict[str, Any] = {}
    base_url = raw.get('base_url')
    if base_url is not None:
        if not isinstance(base_url, str):
            raise invalid_request('sync.base_url 必须是字符串')
        out['base_url'] = base_url.strip()
    enabled = raw.get('enabled')
    if enabled is not None:
        if not isinstance(enabled, bool):
            raise invalid_request('sync.enabled 必须是布尔值')
        out['enabled'] = enabled
    token = raw.get('token')
    if token is not None:
        if not isinstance(token, str):
            raise invalid_request('sync.token 必须是字符串')
        out['token'] = token
    return {'sync': out} if out else {}


def _validate_task_backends(body: dict, config: Any) -> dict:
    """校验 ``task_backends: {T1: 'ollama' | {backend, model} | null}``。"""
    raw = body.get('task_backends')
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise invalid_request('task_backends 必须是对象')
    out: dict[str, Any] = {}
    for task, value in raw.items():
        code = str(task).upper().strip()
        if not code:
            continue
        if value is None:
            out[code] = None
            continue
        if isinstance(value, str):
            name = value.strip()
            if name and name not in config.backends:
                raise invalid_request(f'未知后端：{name}（可用：{sorted(config.backends)}）')
            out[code] = name
            continue
        if not isinstance(value, dict):
            raise invalid_request(f'task_backends.{code} 必须是字符串 / 对象 / null')
        name = str(value.get('backend') or '').strip()
        if name and name not in config.backends:
            raise invalid_request(f'未知后端：{name}（可用：{sorted(config.backends)}）')
        model = value.get('model')
        if model is not None and not isinstance(model, str):
            raise invalid_request(f'task_backends.{code}.model 必须是字符串或 null')
        out[code] = {'backend': name, 'model': (model or '').strip()}
    return {'task_backends': out}


# ---------------------------------------------------------------- 任务路由


def _routes_payload(request: Request) -> dict:
    """``GET / PUT /v1/admin/routes`` 的同构响应体（PRD §6.4）。"""
    state = request.app.state
    config = state.config  # type: ignore[attr-defined]
    registry = state.registry  # type: ignore[attr-defined]

    task_backends: dict[str, Any] = {}
    tasks: list[dict] = []
    for meta in registry.store.list():
        backend, model = config.task_route(meta.task)
        task_backends[meta.task] = (
            None if (not backend and not model) else {'backend': backend, 'model': model}
        )
        tasks.append(
            {
                'task': meta.task,
                'variant': meta.variant,
                'backend': backend,
                'model': model,
                'structured': bool(meta.structured),
                'preferred_backend': meta.preferred_backend,
                'inputs': list(meta.inputs),
            }
        )
    tasks.sort(key=lambda row: (str(row['task']), str(row['variant'] or '')))
    return {
        'default_backend': config.default_backend,
        'default_model': config.default_model,
        'task_backends': task_backends,
        'tasks': tasks,
    }


@router.get('/v1/admin/routes')
async def get_admin_routes(request: Request) -> JSONResponse:
    """任务路由总览（AC-05）：全局默认 + 逐任务后端/模型 + 全部任务清单。"""
    return JSONResponse(_routes_payload(request))


@router.put('/v1/admin/routes')
async def put_admin_routes(request: Request) -> JSONResponse:
    """保存任务路由（AC-05）：落 settings.json → 热重载 → 返回同构响应。

    body::

        {"task_backends": {"T1": {"backend": "minimax", "model": "MiniMax-M2.5"},
                           "T3": "ollama", "T4": null}}
    """
    state = request.app.state
    config = state.config  # type: ignore[attr-defined]
    try:
        body = await request.json()
    except Exception as exc:
        raise invalid_request(f'请求体不是合法 JSON（{exc}）') from exc
    if not isinstance(body, dict):
        raise invalid_request('body 必须是 JSON 对象')

    canonical = _validate_task_backends(body, config)
    if not canonical:
        # 顶层没有 task_backends 键 → 视为漏传，报错要求显式给出；
        # 显式传 null → 「不修改」，直接返回当前路由（与数组元素里 null=跟随全局 不冲突）。
        if 'task_backends' not in body:
            raise invalid_request(
                '缺少 task_backends（形如 {"T1": {"backend": "...", "model": "..."}}）'
            )
        return JSONResponse(_routes_payload(request))

    config.save_settings(canonical)
    config.load()
    state.clear_backends()  # type: ignore[attr-defined]
    _log.info('管理后台已保存任务路由：%s', sorted(canonical['task_backends']))
    return JSONResponse(_routes_payload(request))


# ---------------------------------------------------------------- 统计


@router.get('/v1/admin/stats')
async def get_admin_stats(
    request: Request,
    window_s: float | None = Query(default=None),
) -> JSONResponse:
    """调用统计（AC-08）：环形缓冲窗口聚合；空缓冲返回空数组而非 null。

    ``window_s`` 非正数或非法 → 回落 3600。
    """
    payload = stats_snapshot(window_s if window_s is not None else _DEFAULT_WINDOW_S)
    return JSONResponse(payload, headers={'Cache-Control': 'no-store'})


@router.get('/v1/admin/models')
async def get_admin_models(
    request: Request,
    backend: str | None = Query(default=None),
) -> JSONResponse:
    """返回某后端的可用模型列表（含兜底），允许前端自由输入自定义模型名。

    优先尝试 ``GET {base_url}/v1/models``（用 key，trust_env=False）解析 ``data[].id``；
    失败则退化为 ``conf.models`` + 当前 ``default_model``；并始终把 ``default_model``
    与常见模型（如 ``MiniMax-M3.1-Flash``）包含进去，方便前端下拉。
    """
    state = request.app.state
    config = state.config  # type: ignore[attr-defined]
    name = backend or config.default_backend
    try:
        conf = config.backend(name)
    except Exception as exc:
        raise invalid_request(f'未知后端：{name}（{exc}）') from exc

    models: list[str] = []
    try:
        b = state.get_backend(name)  # type: ignore[attr-defined]
        fetched = await b.list_models()
        if fetched:
            models = list(fetched)
    except Exception as exc:  # noqa: BLE001 - 远端不可达时退化
        _log.warning('获取后端 %s 模型列表失败，退化到配置：%s', name, exc)

    if not models:
        models = list(conf.models)

    # 始终包含默认模型
    dm = conf.model()
    if dm and dm not in models:
        models.append(dm)

    # MiniMax 常见模型兜底（前端下拉友好）
    if conf.name == 'minimax':
        for common in ('MiniMax-M2.5', 'MiniMax-M3.1-Flash', 'MiniMax-Text-01'):
            if common not in models:
                models.append(common)

    return JSONResponse({'models': models, 'editable': True})


@router.get('/v1/admin/balance')
async def get_admin_balance(request: Request) -> JSONResponse:
    """查询 MiniMax 余额 / 额度（调用 minimax 后端 ``balance()``，返回结构化 dict）。"""
    state = request.app.state
    try:
        backend = state.get_backend('minimax')  # type: ignore[attr-defined]
        result = await backend.balance()
    except Exception as exc:  # noqa: BLE001 - 后端未配置等
        return JSONResponse(
            {'available': False, 'error': f'{type(exc).__name__}: {str(exc)[:160]}', 'raw': None}
        )
    return JSONResponse(result)
