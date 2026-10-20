"""MiniMax 后端。

**关键设计**：MiniMax 同时提供 OpenAI 形态与 Anthropic 形态的端点，
所以本后端自己不实现 HTTP，而是按 ``config.yaml`` 的 ``protocol`` 字段
在 ``openai_compat`` / ``anthropic_compat`` 之间二选一（**默认 anthropic**，Q-D）。

切换方式（一行）：

.. code-block:: yaml

    backends:
      minimax:
        protocol: openai_compat   # 默认是 anthropic_compat
"""

from __future__ import annotations

from typing import AsyncIterator

from backends.base import BackendHealth, Completion, LLMBackend, Message
from backends.protocols import create_protocol
from core.config import BackendConf
from core.logging import get_logger

_log = get_logger('backend')


class MiniMaxBackend(LLMBackend):
    """MiniMax：按 config 选协议，默认 anthropic_compat。"""

    def __init__(self, conf: BackendConf, api_key: str = '', **kwargs: object) -> None:
        super().__init__(conf)
        self._timeout_s = float(kwargs.get('timeout_s') or 120.0)
        self._connect_s = float(kwargs.get('connect_s') or 10.0)
        self._protocol = create_protocol(
            conf,
            api_key,
            timeout_s=self._timeout_s,
            connect_s=self._connect_s,
            trust_env=bool(kwargs.get('trust_env', False)),
        )
        if not api_key:
            _log.warning(
                '后端 %s 未配置密钥（api_key_env=%s），调用会 401；'
                '请在 llm_server/.env 里设置。',
                conf.name,
                conf.api_key_env or '(未设置)',
            )

    @property
    def protocol_name(self) -> str:
        return self.conf.protocol

    async def complete(
        self,
        messages: list[Message],
        *,
        temperature: float = 0.2,
        max_tokens: int = 4096,
        json_mode: bool = False,
        timeout_s: float | None = None,
        model: str | None = None,
    ) -> Completion:
        return await self._protocol.complete(
            self.model_id(model),
            messages,
            temperature=temperature,
            max_tokens=max_tokens,
            json_mode=json_mode,
            timeout_s=timeout_s or self._timeout_s,
        )

    async def stream_complete(
        self,
        messages: list[Message],
        *,
        temperature: float = 0.2,
        max_tokens: int = 4096,
        timeout_s: float | None = None,
        model: str | None = None,
    ) -> AsyncIterator[str]:
        async for delta in self._protocol.stream_complete(
            self.model_id(model),
            messages,
            temperature=temperature,
            max_tokens=max_tokens,
            timeout_s=timeout_s or self._timeout_s,
        ):
            yield delta

    async def health(self, timeout_s: float | None = None) -> BackendHealth:
        path = self.conf.health_path or '/v1/models'
        reachable, models, error = await self._protocol.probe(
            path, timeout_s=timeout_s or 5.0
        )
        if not models:
            models = list(self.conf.models)
        return BackendHealth(
            name=self.name,
            reachable=reachable,
            base_url=self.conf.base_url,
            models=models,
            error=(None if reachable else (error or 'unreachable')),
        )
