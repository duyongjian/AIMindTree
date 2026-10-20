"""后端工厂：``create_backend(conf, api_key) -> LLMBackend``。

backend（config 里的名字）与 protocol（HTTP 形态）解耦：
同一个 protocol 可以被多个 backend 复用，新增后端只需加一个文件 + 一段 config，
**不改任何 router**。
"""

from __future__ import annotations

from core.config import BackendConf
from core.logging import get_logger

from backends.base import LLMBackend

_log = get_logger('backend')

#: type → 实现类（懒加载，避免 import 循环）
_REGISTRY: dict[str, str] = {
    'ollama': 'backends.ollama.OllamaBackend',
    'minimax': 'backends.minimax.MiniMaxBackend',
    'openai_compat': 'backends.openai_compat.OpenAICompatBackend',
}


def create_backend(
    conf: BackendConf,
    api_key: str = '',
    *,
    trust_env: bool = False,
    **kwargs: object,
) -> LLMBackend:
    """按 ``conf.type`` 实例化后端。

    Args:
        conf: 后端配置。
        api_key: 由 ``Config.resolve_api_key(conf)`` 解出的密钥（本地后端为空串）。
        trust_env: 是否让 httpx 跟随环境变量里的 HTTP(S)_PROXY。
            **默认 False** —— 本机常有开发代理，会把 127.0.0.1 的本地后端请求
            也发给代理，造成「本机 Ollama 连不上」的假故障。
        **kwargs: ``timeout_s`` / ``connect_s`` 透传给协议层。

    Raises:
        LlmError: ``backend_unknown`` —— type 不在注册表里。
    """
    from core.errors import LlmError

    dotted = _REGISTRY.get((conf.type or '').strip())
    if dotted is None:
        raise LlmError(
            'backend_unknown',
            f'未实现的后端类型：{conf.type}（已实现：{" / ".join(sorted(_REGISTRY))}）',
        )
    module_name, _, cls_name = dotted.rpartition('.')
    module = __import__(module_name, fromlist=[cls_name])
    cls = getattr(module, cls_name)
    backend: LLMBackend = cls(conf, api_key, trust_env=trust_env, **kwargs)
    _log.info(
        '后端 %s 就绪：protocol=%s base_url=%s model=%s',
        backend.name,
        conf.protocol,
        conf.base_url,
        conf.model() or '(未指定)',
    )
    return backend


def available_types() -> list[str]:
    """已实现的后端类型名。"""
    return sorted(_REGISTRY)
