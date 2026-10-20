"""Ollama 后端（默认，D3）。

= ``openai_compat`` 协议 + Ollama 专属探活（``GET /api/tags``）
+ ``format="json"`` 选项（P0 只做「能带就带」，结果不依赖它，D9）。

Ollama 需要先 ``ollama serve`` 并拉过模型（如 ``ollama pull qwen2.5:7b``）；
未安装时 ``GET /health`` 里该项 ``reachable=false``，服务本身仍是 ``ok``。
"""

from __future__ import annotations

from typing import AsyncIterator

from backends.base import BackendHealth, Completion, LLMBackend, Message
from backends.protocols import create_protocol
from core.config import BackendConf

#: Ollama 原生探活路径（不是 OpenAI 的 /v1/models）
HEALTH_PATH = '/api/tags'


class OllamaBackend(LLMBackend):
    """Ollama：本地推理，无密钥。"""

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
        path = self.conf.health_path or HEALTH_PATH
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
