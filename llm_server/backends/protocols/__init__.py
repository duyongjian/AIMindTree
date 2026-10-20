"""协议层：把「HTTP 形态」从后端里剥离出来。

目前两类：

- ``openai_compat``    → ``POST {base}/v1/chat/completions``
  （OpenAI / Ollama / DeepSeek / 通义 / Kimi / 硅基流动…）
- ``anthropic_compat`` → ``POST {base}<anthropic_path>``
  （Anthropic / MiniMax 的 Anthropic 通道）

两者对外都只暴露 ``complete`` / ``stream_complete`` / ``list_models`` / ``probe``，
并统一返回 ``Completion``，usage 一律重命名为
``prompt_tokens`` / ``completion_tokens``。
"""

from __future__ import annotations

from core.config import BackendConf
from core.logging import get_logger

from backends.protocols.anthropic_compat import AnthropicCompatProtocol
from backends.protocols.base import BaseProtocol
from backends.protocols.openai_compat import OpenAICompatProtocol

_log = get_logger('backend')

_PROTOCOLS: dict[str, type[BaseProtocol]] = {
    'openai_compat': OpenAICompatProtocol,
    'anthropic_compat': AnthropicCompatProtocol,
}


def create_protocol(
    conf: BackendConf,
    api_key: str = '',
    *,
    timeout_s: float = 120.0,
    connect_s: float = 10.0,
    trust_env: bool = False,
) -> BaseProtocol:
    """按 ``conf.protocol`` 实例化协议。

    Raises:
        LlmError: ``backend_unknown`` —— 协议名不在注册表里。
    """
    from core.errors import LlmError

    name = (conf.protocol or 'openai_compat').strip()
    cls = _PROTOCOLS.get(name)
    if cls is None:
        raise LlmError(
            'backend_unknown',
            f'未实现的协议：{name}（可用：{" / ".join(sorted(_PROTOCOLS))}）',
        )
    protocol = cls(
        conf,
        api_key,
        timeout_s=timeout_s,
        connect_s=connect_s,
        trust_env=trust_env,
    )
    _log.debug('协议 %s → %s%s', name, conf.base_url, protocol.path)
    return protocol


__all__ = [
    'BaseProtocol',
    'OpenAICompatProtocol',
    'AnthropicCompatProtocol',
    'create_protocol',
]
