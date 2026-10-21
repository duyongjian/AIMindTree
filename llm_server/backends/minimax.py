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

import httpx
from typing import Any, AsyncIterator

from backends.base import BackendHealth, Completion, LLMBackend, Message
from backends.protocols import create_protocol
from core.config import BackendConf
from core.logging import get_logger

_log = get_logger('backend')


class MiniMaxBackend(LLMBackend):
    """MiniMax：按 config 选协议，默认 openai_compat（2026-10-21 起）。"""

    def __init__(self, conf: BackendConf, api_key: str = '', **kwargs: object) -> None:
        super().__init__(conf)
        self._api_key = api_key or ''
        self._trust_env = bool(kwargs.get('trust_env', False))
        self._timeout_s = float(kwargs.get('timeout_s') or 120.0)
        self._connect_s = float(kwargs.get('connect_s') or 10.0)
        self._protocol = create_protocol(
            conf,
            api_key,
            timeout_s=self._timeout_s,
            connect_s=self._connect_s,
            trust_env=self._trust_env,
        )
        if not self._api_key:
            _log.warning(
                '后端 %s 未配置密钥（api_key_env=%s），调用会 401；'
                '请在 llm_server/.env 或管理后台 /admin 里设置。',
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

    async def balance(self) -> dict[str, Any]:
        """查询 MiniMax 余额/额度（Token 套餐剩余）。

        端点：``GET {base_url}{balance_path}``（balance_path 取自
        ``conf.extra.balance_path``，默认 ``/v1/token_plan/remains``），
        头 ``Authorization: Bearer <订阅Key>``，``trust_env=False``。

        **绝不抛异常**：成功 200 返回 ``{available:True, raw:<json>, error:None}``；
        非 200 / 异常返回 ``{available:False, error:<精简错误>, raw:None}``；
        密钥为空返回 ``{available:False, error:'no_api_key'}``。
        """
        base_url = (self.conf.base_url or '').rstrip('/')
        if not base_url:
            return {'available': False, 'error': 'no_base_url', 'raw': None}
        if not self._api_key:
            return {'available': False, 'error': 'no_api_key', 'raw': None}

        path = self.conf.extra.get('balance_path') or '/v1/token_plan/remains'
        url = f'{base_url}{path}'
        headers = {'Authorization': f'Bearer {self._api_key}'}
        try:
            async with httpx.AsyncClient(
                timeout=httpx.Timeout(connect=self._connect_s, read=10.0, write=10.0, pool=10.0),
                trust_env=self._trust_env,
            ) as client:
                resp = await client.get(url, headers=headers)
            if resp.status_code == 200:
                try:
                    raw: Any = resp.json()
                except Exception:  # noqa: BLE001 - 非 JSON 也原样返回文本
                    raw = resp.text
                # MiniMax 约定：base_resp.status_code == 0 才是成功。
                # 非 0（如 2062 "no active token plan subscription"）说明账号
                # 没有有效的 Token 套餐订阅；此时绝不能报 available=True，
                # 否则前端会误以为有额度（实际生成请求会 402 insufficient_balance）。
                if isinstance(raw, dict):
                    base = raw.get('base_resp') or {}
                    code = base.get('status_code', 0)
                    if code not in (0, None):
                        return {
                            'available': False,
                            'error': f"minimax_{code}: {base.get('status_msg') or 'error'}",
                            'raw': raw,
                        }
                return {'available': True, 'raw': raw, 'error': None}
            # 非 200：只保留精简错误，绝不把原始 body 甩出去
            return {
                'available': False,
                'error': f'http_{resp.status_code}',
                'raw': None,
            }
        except Exception as exc:  # noqa: BLE001 - 任何网络异常都包成结构化结果
            err = f'{type(exc).__name__}: {str(exc)[:160]}'
            _log.warning('MiniMax 余额查询失败（%s）：%s', url, err)
            return {'available': False, 'error': err, 'raw': None}
