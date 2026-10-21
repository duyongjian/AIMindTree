"""管理后台 API（S-06 扩展）。

保留已有的 ``POST /v1/admin/reload``（config.yaml 热加载），并新增：

- ``GET  /v1/admin/config``   —— 当前生效配置摘要
- ``POST /v1/admin/config``   —— 保存覆盖层（默认后端 / 默认模型 / minimax 协议 / key）
- ``GET  /v1/admin/models``   —— 某后端的可用模型列表（含兜底，允许前端自由输入）
- ``GET  /v1/admin/balance``  —— MiniMax 余额 / 额度查询

所有密钥一律**不回传明文**：只暴露 ``key_set``（是否设置）和 ``key_masked``（掩码）。
"""

from __future__ import annotations

from fastapi import APIRouter, Query, Request
from fastapi.responses import JSONResponse

from core.errors import invalid_request
from core.logging import get_logger

router = APIRouter(tags=['admin'])
_log = get_logger('config')

#: 允许的后端类型 / 协议（与 config 的 protocol 字段对齐）
_VALID_PROTOCOLS = ('openai_compat', 'anthropic_compat')


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
    """构造 ``GET /v1/admin/config`` 的响应体（供 GET / POST 复用）。"""
    state = request.app.state
    config = state.config  # type: ignore[attr-defined]
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
            }
        )
    minimax_balance_path = None
    if 'minimax' in config.backends:
        minimax_balance_path = config.backends['minimax'].extra.get(
            'balance_path', '/v1/token_plan/remains'
        )
    return {
        'default_backend': config.default_backend,
        'default_model': config.default_model,
        'backends': backends,
        'minimax_balance_path': minimax_balance_path,
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
    if minimax_api_key:
        canonical['backends'] = {'minimax': {'api_key': minimax_api_key}}

    config.save_settings(canonical)  # type: ignore[attr-defined]
    config.load()  # type: ignore[attr-defined]  # 立即把新覆盖层生效到内存
    state.clear_backends()  # type: ignore[attr-defined]  # 旧后端实例（含旧 key）失效

    _log.info('管理后台已保存配置并热重载')
    return JSONResponse(_config_summary(request))


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
