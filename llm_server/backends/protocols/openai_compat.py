"""协议实现一：OpenAI 兼容（``POST {base}/v1/chat/completions``）。

适用：OpenAI / Ollama（``/v1``）/ DeepSeek / 通义 / Kimi / 硅基流动等
一切「chat/completions 形态」的端点。
"""

from __future__ import annotations

from typing import Any

from backends.base import Message
from backends.protocols.base import BaseProtocol
from core.config import BackendConf


class OpenAICompatProtocol(BaseProtocol):
    """``/v1/chat/completions``（REST + SSE）。"""

    name = 'openai_compat'

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
        self.path = path or conf.openai_path or '/v1/chat/completions'

    # ---------- 请求 ----------

    def headers(self) -> dict[str, str]:
        headers = {'Content-Type': 'application/json'}
        if self.api_key:
            headers['Authorization'] = f'Bearer {self.api_key}'
        return headers

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
        body: dict[str, Any] = {
            'model': model,
            'messages': self._messages_payload(messages, 'inline'),
            'temperature': temperature,
            'max_tokens': max_tokens,
            'stream': stream,
        }
        if json_mode:
            # D9：只做「能带就带」，失败不报错、结果不依赖它。
            if (self.conf.type or '') == 'ollama' or '11434' in self.base_url:
                body['format'] = 'json'
            else:
                body['response_format'] = {'type': 'json_object'}
        # Ollama 的上下文等透传参数
        for key, value in (self.conf.extra or {}).items():
            if key in ('num_ctx', 'num_predict', 'top_p', 'repeat_penalty'):
                body[key] = value
        if stream:
            body['stream_options'] = {'include_usage': True}
        return body

    # ---------- 响应 ----------

    def extract_text(self, data: dict[str, Any]) -> str:
        choices = data.get('choices')
        if isinstance(choices, list) and choices:
            first = choices[0]
            if isinstance(first, dict):
                message = first.get('message')
                if isinstance(message, dict):
                    content = message.get('content')
                    return self._stringify_content(content)
        # 兜底：少数端点直接给 content / text
        for key in ('content', 'text', 'response'):
            if key in data:
                return self._stringify_content(data[key])
        return ''

    def extract_usage(self, data: dict[str, Any]) -> dict[str, Any] | None:
        usage = data.get('usage')
        if not isinstance(usage, dict):
            return None
        prompt = usage.get('prompt_tokens')
        completion = usage.get('completion_tokens')
        total = usage.get('total_tokens')
        out: dict[str, Any] = {}
        if prompt is not None:
            out['prompt_tokens'] = int(prompt)
        if completion is not None:
            out['completion_tokens'] = int(completion)
        if total is not None:
            out['total_tokens'] = int(total)
        return out or None

    def extract_finish(self, data: dict[str, Any]) -> str | None:
        choices = data.get('choices')
        if isinstance(choices, list) and choices and isinstance(choices[0], dict):
            reason = choices[0].get('finish_reason')
            return str(reason) if reason is not None else None
        return None

    # ---------- SSE ----------

    def sse_text(self, payload: str) -> str | None:
        data = self._json_or_none(payload)
        if data is None:
            return None
        choices = data.get('choices')
        if isinstance(choices, list) and choices:
            first = choices[0]
            if isinstance(first, dict):
                delta = first.get('delta')
                if isinstance(delta, dict):
                    return self._stringify_content(delta.get('content')) or None
        # 少数端点把整段文本放在 data.content
        if 'content' in data:
            return self._stringify_content(data['content']) or None
        return None

    # ---------- 辅助 ----------

    @staticmethod
    def _stringify_content(content: Any) -> str:
        """OpenAI 的 content 可能是 str，也可能是 ``[{'type':'text','text':...}]``。"""
        if content is None:
            return ''
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts: list[str] = []
            for item in content:
                if isinstance(item, dict):
                    text = item.get('text') or item.get('content')
                    if isinstance(text, str):
                        parts.append(text)
            return ''.join(parts)
        return str(content)
