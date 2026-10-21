"""后端抽象（S-05）。

**统一契约**：三个后端（ollama / minimax / openai_compat）对外**完全一致**，
协议差异（``/v1/chat/completions`` vs ``/v1/messages``）全部收敛到
``backends/protocols/`` 的两个类里。

- ``Completion{text, model_id, usage, truncated}`` —— 协议差异到这一层为止，
  router 只见 ``Completion``。
- ``stream_complete`` 只 yield **纯文本 delta**；SSE 封装只在 ``routers/chat.py``
  一处，三个后端零重复。
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any, AsyncIterator

from core.config import BackendConf


@dataclass(frozen=True)
class Message:
    """一条对话消息。"""

    role: str  # system | user | assistant
    content: str

    def to_dict(self) -> dict[str, str]:
        return {'role': self.role, 'content': self.content}


@dataclass(frozen=True)
class Completion:
    """一次非流式完成的统一结果。"""

    text: str
    model_id: str
    usage: dict[str, Any] | None
    truncated: bool


@dataclass(frozen=True)
class BackendHealth:
    """探活结果（``GET /health`` 用）。"""

    name: str
    reachable: bool
    base_url: str
    models: list[str]
    error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            'name': self.name,
            'reachable': self.reachable,
            'base_url': self.base_url,
            'models': list(self.models),
            'error': self.error,
        }


class LLMBackend(ABC):
    """LLM 后端抽象。

    新增第四个后端 = 继承本类 + 复用某个 protocol + 在 config.yaml 加一段，
    **不改任何 router**。
    """

    def __init__(self, conf: BackendConf) -> None:
        self.conf = conf

    @property
    def name(self) -> str:
        return self.conf.name

    @abstractmethod
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
        """一次性完成。"""

    @abstractmethod
    async def stream_complete(
        self,
        messages: list[Message],
        *,
        temperature: float = 0.2,
        max_tokens: int = 4096,
        timeout_s: float | None = None,
        model: str | None = None,
    ) -> AsyncIterator[str]:
        """流式完成；**只 yield 纯文本 delta**。"""

    @abstractmethod
    async def health(self, timeout_s: float | None = None) -> BackendHealth:
        """探活（不抛异常，失败体现在 ``reachable=False``）。"""

    async def list_models(self, timeout_s: float | None = None) -> list[str]:
        """可用模型 id 列表（含默认模型兜底），失败退化为 ``conf.models``。"""
        protocol = getattr(self, '_protocol', None)
        models: list[str] = []
        if protocol is not None and hasattr(protocol, 'list_models'):
            try:
                models = list(await protocol.list_models(timeout_s=timeout_s or 5.0))
            except Exception:  # noqa: BLE001 - 远端不可达时退化
                models = []
        if not models:
            models = list(self.conf.models)
        dm = self.conf.model()
        if dm and dm not in models:
            models.append(dm)
        return models

    async def balance(self) -> dict[str, Any]:
        """查询余额/额度；默认实现不支持，返回结构化结果（**绝不抛异常**）。

        子类（如 MiniMaxBackend）覆盖为真实实现；其它后端返回 ``unsupported``。
        """
        return {'available': False, 'error': 'unsupported', 'raw': None}

    def model_id(self, override: str | None = None) -> str:
        """本次请求真正使用的模型 id。"""
        return (override or '').strip() or self.conf.model()
