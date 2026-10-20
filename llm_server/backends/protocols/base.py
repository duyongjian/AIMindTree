"""协议基类：HTTP 形态的公共部分（客户端、超时、错误归一化、SSE 解析）。

子类只需实现「怎么拼请求体 / 怎么解析响应 / 怎么从 SSE 事件取文本」三件事，
重试、超时、错误码翻译这些横切逻辑全部在这里。
"""

from __future__ import annotations

import json
from abc import ABC, abstractmethod
from typing import Any, AsyncIterator, Iterable

import httpx

from backends.base import Completion, Message
from core.config import BackendConf
from core.errors import (
    LlmError,
    auth_failed,
    backend_timeout,
    backend_unreachable,
    rate_limited,
    upstream_error,
)
from core.logging import get_logger

_log = get_logger('backend')


class BaseProtocol(ABC):
    """一个「HTTP 形态」的实现。"""

    #: 协议名（与 config 的 ``protocol`` 字段对应）
    name: str = 'base'
    #: chat 路径（相对 base_url）
    path: str = ''
    #: 模型列表路径
    models_path: str = '/v1/models'

    def __init__(
        self,
        conf: BackendConf,
        api_key: str = '',
        *,
        timeout_s: float = 120.0,
        connect_s: float = 10.0,
        trust_env: bool = False,
    ) -> None:
        self.conf = conf
        self.base_url = (conf.base_url or '').rstrip('/')
        self.api_key = api_key or ''
        self.timeout_s = timeout_s
        self.connect_s = connect_s
        # ⚠️ 默认 False：本机常有 HTTP_PROXY / HTTPS_PROXY（例如 127.0.0.1:44166 这类
        # 开发代理），httpx 默认 trust_env=True 会把 **127.0.0.1:11434 的 Ollama 请求
        # 也发给代理**，代理直接拒绝 → 表现为「本机 Ollama 连不上」的假故障。
        # 需要走公司代理访问云端后端时，在 config.yaml 设 server.trust_env_proxy: true。
        self.trust_env = trust_env

    # ---------- 子类实现 ----------

    @abstractmethod
    def headers(self) -> dict[str, str]:
        """请求头（含鉴权）。"""

    @abstractmethod
    def build_body(
        self,
        model: str,
        messages: list[Message],
        *,
        temperature: float,
        max_tokens: int,
        stream: bool,
        json_mode: bool,
    ) -> dict[str, Any]:
        """请求体。"""

    @abstractmethod
    def extract_text(self, data: dict[str, Any]) -> str:
        """从非流式响应取文本。"""

    @abstractmethod
    def extract_usage(self, data: dict[str, Any]) -> dict[str, Any] | None:
        """从非流式响应取 usage（统一成 ``prompt_tokens`` / ``completion_tokens``）。"""

    @abstractmethod
    def extract_finish(self, data: dict[str, Any]) -> str | None:
        """finish_reason / stop_reason（用于判断 truncated）。"""

    @abstractmethod
    def sse_text(self, payload: str) -> str | None:
        """从一条 SSE ``data:`` 取文本 delta；不是文本事件返回 None。"""

    # ---------- 公共：超时 / 客户端 ----------

    def _timeout(self, timeout_s: float | None) -> httpx.Timeout:
        total = float(timeout_s or self.timeout_s)
        return httpx.Timeout(connect=self.connect_s, read=total, write=30.0, pool=30.0)

    def _client(self, timeout_s: float | None = None) -> httpx.AsyncClient:
        """统一的 httpx 客户端（trust_env 见 :attr:`trust_env` 的注释）。"""
        return httpx.AsyncClient(timeout=self._timeout(timeout_s), trust_env=self.trust_env)

    def url(self) -> str:
        return f'{self.base_url}{self.path}'

    def models_url(self) -> str:
        return f'{self.base_url}{self.models_path}'

    # ---------- 公共：错误归一化 ----------

    def _translate(self, status: int, body: str, name: str) -> LlmError:
        """把上游状态码翻译成统一错误（**绝不把原始 body 直接抛给客户端**）。"""
        detail = (body or '')[:200].replace('\n', ' ')
        if status in (401, 403):
            return auth_failed(name, self.conf.api_key_env)
        if status == 429:
            return rate_limited(name)
        return upstream_error(name, status, detail)

    def _wrap_exception(self, exc: BaseException, name: str, timeout_s: float) -> LlmError:
        if isinstance(exc, httpx.ConnectError) or isinstance(exc, httpx.UnsupportedProtocol):
            return backend_unreachable(name, self.base_url, str(exc)[:200])
        if isinstance(exc, httpx.TimeoutException):
            return backend_timeout(name, timeout_s)
        if isinstance(exc, httpx.HTTPError):
            return backend_unreachable(name, self.base_url, str(exc)[:200])
        return upstream_error(name, type(exc).__name__, str(exc)[:200])

    # ---------- 公共：非流式 ----------

    async def complete(
        self,
        model: str,
        messages: list[Message],
        *,
        temperature: float = 0.2,
        max_tokens: int = 4096,
        json_mode: bool = False,
        timeout_s: float | None = None,
    ) -> Completion:
        """一次性完成 → :class:`Completion`。"""
        total = float(timeout_s or self.timeout_s)
        body = self.build_body(
            model,
            messages,
            temperature=temperature,
            max_tokens=max_tokens,
            stream=False,
            json_mode=json_mode,
        )
        try:
            async with self._client(total) as client:
                resp = await client.post(self.url(), json=body, headers=self.headers())
        except LlmError:
            raise
        except BaseException as exc:  # noqa: BLE001 - 统一归一化
            raise self._wrap_exception(exc, self.conf.name, total) from exc

        if resp.status_code < 200 or resp.status_code >= 300:
            raise self._translate(resp.status_code, resp.text, self.conf.name)

        try:
            data = resp.json()
        except Exception as exc:
            raise upstream_error(self.conf.name, '非 JSON 响应', resp.text[:200]) from exc
        if not isinstance(data, dict):
            raise upstream_error(self.conf.name, '响应不是对象', resp.text[:200])

        finish = self.extract_finish(data)
        return Completion(
            text=self.extract_text(data),
            model_id=str(data.get('model') or model or ''),
            usage=self.extract_usage(data),
            truncated=(finish == 'length'),
        )

    # ---------- 公共：流式 ----------

    async def stream_complete(
        self,
        model: str,
        messages: list[Message],
        *,
        temperature: float = 0.2,
        max_tokens: int = 4096,
        timeout_s: float | None = None,
    ) -> AsyncIterator[str]:
        """流式完成；**只 yield 纯文本 delta**（SSE 封装不在这里做）。"""
        total = float(timeout_s or self.timeout_s)
        body = self.build_body(
            model,
            messages,
            temperature=temperature,
            max_tokens=max_tokens,
            stream=True,
            json_mode=False,
        )
        try:
            async with self._client(total) as client:
                async with client.stream(
                    'POST', self.url(), json=body, headers=self.headers()
                ) as resp:
                    if resp.status_code < 200 or resp.status_code >= 300:
                        text = (await resp.aread()).decode('utf-8', 'replace')
                        raise self._translate(resp.status_code, text, self.conf.name)
                    async for line in resp.aiter_lines():
                        if not line:
                            continue
                        payload = self._data_line(line)
                        if payload is None:
                            continue
                        delta = self.sse_text(payload)
                        if delta:
                            yield delta
        except LlmError:
            raise
        except BaseException as exc:  # noqa: BLE001
            raise self._wrap_exception(exc, self.conf.name, total) from exc

    @staticmethod
    def _data_line(line: str) -> str | None:
        """取 SSE 的 ``data:`` 负载；``[DONE]`` 返回 None。"""
        line = line.strip()
        if not line.startswith('data:'):
            return None
        payload = line[5:].strip()
        if not payload or payload == '[DONE]':
            return None
        return payload

    @staticmethod
    def _json_or_none(payload: str) -> dict[str, Any] | None:
        try:
            data = json.loads(payload)
        except Exception:
            return None
        return data if isinstance(data, dict) else None

    # ---------- 公共：探活 / 模型列表 ----------

    async def fetch_json(self, path: str, timeout_s: float | None = None) -> Any | None:
        """GET 一个路径并解析 JSON；**失败返回 None 不打错误日志级别**（探活用）。"""
        total = float(timeout_s or self.timeout_s)
        url = f'{self.base_url}{path}'
        try:
            async with self._client(total) as client:
                resp = await client.get(url, headers=self.headers())
            if resp.status_code < 200 or resp.status_code >= 300:
                return None
            return resp.json()
        except BaseException:  # noqa: BLE001 - 探活失败静默
            return None

    async def list_models(self, timeout_s: float | None = None) -> list[str]:
        """列模型；失败退化为 config 里配置的 ``models``。"""
        data = await self.fetch_json(self.models_path, timeout_s=timeout_s)
        ids = self._extract_model_ids(data)
        return ids or list(self.conf.models)

    @staticmethod
    def _extract_model_ids(data: Any) -> list[str]:
        if isinstance(data, dict):
            rows = data.get('data')
            if isinstance(rows, list):
                return [str(r.get('id')) for r in rows if isinstance(r, dict) and r.get('id')]
        if isinstance(data, list):
            # Ollama /api/tags 的形状：{"models":[{"name":...}]}
            if data and isinstance(data[0], dict) and 'name' in data[0]:
                return [str(r.get('name')) for r in data if isinstance(r, dict) and r.get('name')]
        if isinstance(data, dict) and isinstance(data.get('models'), list):
            rows = data['models']
            key = 'name' if (rows and isinstance(rows[0], dict) and 'name' in rows[0]) else 'id'
            return [str(r.get(key)) for r in rows if isinstance(r, dict) and r.get(key)]
        return []

    async def probe(self, path: str, timeout_s: float | None = None) -> tuple[bool, list[str], str | None]:
        """探活：``(reachable, models, error)``。不抛异常。"""
        data = await self.fetch_json(path, timeout_s=timeout_s)
        if data is None:
            return False, [], 'unreachable'
        return True, self._extract_model_ids(data), None

    # ---------- 辅助 ----------

    @staticmethod
    def _messages_payload(messages: Iterable[Message], system_mode: str) -> list[dict[str, str]]:
        """把 Message 列表转成协议的消息数组。

        Args:
            system_mode: ``'inline'`` = system 作为 messages 里的一条（OpenAI）；
                ``'exclude'`` = system 不进 messages，由子类放到顶层（Anthropic）。
        """
        out: list[dict[str, str]] = []
        for m in messages:
            if m.role == 'system' and system_mode == 'exclude':
                continue
            out.append({'role': m.role, 'content': m.content})
        return out

    @staticmethod
    def _system_text(messages: Iterable[Message]) -> str:
        """把 system 消息拼成顶层 system 字段。"""
        parts = [m.content for m in messages if m.role == 'system' and m.content]
        return '\n\n'.join(parts)
