"""协议实现二：Anthropic 兼容（``POST {base}<anthropic_path>``）。

适用：Anthropic 官方、以及 **MiniMax 的 Anthropic 通道**
（``https://api.minimaxi.com/anthropic/v1/messages``，Q-D 默认值）。

与 openai_compat 的三处关键差异：
- 鉴权头是 ``x-api-key`` + ``anthropic-version``，不是 Bearer；
- ``system`` 是**顶层字段**，不能出现在 messages 里；
- 响应文本在 ``content[0].text``（块数组），usage 字段叫
  ``input_tokens`` / ``output_tokens``（这里统一重命名）。
"""

from __future__ import annotations

from typing import Any

from backends.base import Message
from backends.protocols.base import BaseProtocol
from core.config import BackendConf


class AnthropicCompatProtocol(BaseProtocol):
    """``/v1/messages``（REST + SSE）。"""

    name = 'anthropic_compat'

    def __init__(
        self,
        conf: BackendConf,
        api_key: str = '',
        *,
        timeout_s: float = 120.0,
        connect_s: float = 10.0,
        path: str | None = None,
        trust_env: bool = False,
    ) -> None:
        super().__init__(
            conf,
            api_key,
            timeout_s=timeout_s,
            connect_s=connect_s,
            trust_env=trust_env,
        )
        self.path = path or conf.anthropic_path or '/anthropic/v1/messages'
        self.anthropic_version = conf.anthropic_version or '2023-06-01'

    # ---------- 请求 ----------

    def headers(self) -> dict[str, str]:
        return {
            'Content-Type': 'application/json',
            'x-api-key': self.api_key,
            'anthropic-version': self.anthropic_version,
        }

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
        # anthropic 的 messages 只允许 user / assistant，且首尾必须是 user
        payload = self._messages_payload(messages, 'exclude')
        if not payload:
            payload = [{'role': 'user', 'content': ' '}]
        body: dict[str, Any] = {
            'model': model,
            'messages': payload,
            'max_tokens': max_tokens,
            'temperature': temperature,
            'stream': stream,
        }
        system = self._system_text(messages)
        if system:
            body['system'] = system
        # anthropic 不支持 response_format：json_mode 靠提示词约束（D9）
        if json_mode:
            body['metadata'] = {'json_mode': True}
        return body

    # ---------- 响应 ----------

    def extract_text(self, data: dict[str, Any]) -> str:
        content = data.get('content')
        if isinstance(content, list):
            parts: list[str] = []
            for block in content:
                if isinstance(block, dict) and block.get('type') == 'text':
                    text = block.get('text')
                    if isinstance(text, str):
                        parts.append(text)
            return ''.join(parts)
        if isinstance(content, str):
            return content
        text = data.get('text')
        return text if isinstance(text, str) else ''

    def extract_usage(self, data: dict[str, Any]) -> dict[str, Any] | None:
        usage = data.get('usage')
        if not isinstance(usage, dict):
            return None
        out: dict[str, Any] = {}
        if usage.get('input_tokens') is not None:
            out['prompt_tokens'] = int(usage['input_tokens'])
        if usage.get('output_tokens') is not None:
            out['completion_tokens'] = int(usage['output_tokens'])
        if len(out) == 2:
            out['total_tokens'] = out['prompt_tokens'] + out['completion_tokens']
        return out or None

    def extract_finish(self, data: dict[str, Any]) -> str | None:
        reason = data.get('stop_reason')
        if reason is None:
            return None
        # 统一成 OpenAI 的语义，便于 router 判 truncated
        return {'max_tokens': 'length'}.get(str(reason), str(reason))

    # ---------- SSE ----------

    def sse_text(self, payload: str) -> str | None:
        data = self._json_or_none(payload)
        if data is None:
            return None
        kind = data.get('type')
        if kind == 'content_block_delta':
            delta = data.get('delta')
            if isinstance(delta, dict) and delta.get('type') == 'text_delta':
                text = delta.get('text')
                return text if isinstance(text, str) and text else None
            return None
        if kind == 'content_block_start':
            block = data.get('content_block')
            if isinstance(block, dict):
                text = block.get('text')
                return text if isinstance(text, str) and text else None
            return None
        # 部分兼容端点直接给 {"delta":{"text":...}} 或 {"text":...}
        delta = data.get('delta')
        if isinstance(delta, dict):
            text = delta.get('text') or delta.get('content')
            if isinstance(text, str) and text:
                return text
        text = data.get('text')
        return text if isinstance(text, str) and text else None
