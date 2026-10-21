"""统一错误模型（S-11）。

任何非 2xx 响应都必须是 ``{"error": {"code", "message", "backend", "retryable"}}``
这一形状，**绝不把上游原始 HTML / JSON 甩给客户端**（App 侧
``LlmServerException`` 直接消费这四个字段）。

retryable 判定规则（写死，见设计 §2.3）：
    超时 / 限流 / 不可达 / 上游错误 / bad_json = True
    参数类 / 鉴权 / 配置类 / 未知任务        = False
"""

from __future__ import annotations

from typing import Any

# ---- 错误码 → 默认 HTTP 状态码 ----
#: 前 12 个为 S-11 既有码；``lock_conflict`` 是 2026-10-22 任务队列新增
#: （仅 ``POST /v1/jobs`` 用：资源锁被其它任务占用，App 侧据此禁用入口）。
CODE_STATUS: dict[str, int] = {
    'unknown_task': 400,
    'missing_input': 400,
    'prompt_not_found': 500,
    'backend_unknown': 400,
    'backend_unreachable': 502,
    'backend_timeout': 504,
    'auth_failed': 401,
    'rate_limited': 429,
    'bad_json': 502,
    'upstream_error': 502,
    'invalid_request': 400,
    'internal': 500,
    'lock_conflict': 409,
}

#: 可重试的错误码（客户端可原样重跑）。
RETRYABLE_CODES: frozenset[str] = frozenset(
    {
        'backend_unreachable',
        'backend_timeout',
        'rate_limited',
        'bad_json',
        'upstream_error',
    }
)


class LlmError(Exception):
    """服务端统一异常。

    Attributes:
        code: 12 个错误码之一（见 :data:`CODE_STATUS`）。
        message: **面向用户**的中文文案，含可操作建议。
        backend: 出错的后端名（可能为 None，如参数类错误）。
        retryable: 客户端是否可以原样重试。
        http_status: HTTP 状态码，默认由 code 推导。
    """

    def __init__(
        self,
        code: str,
        message: str,
        *,
        backend: str | None = None,
        retryable: bool | None = None,
        http_status: int | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.backend = backend
        self.retryable = (code in RETRYABLE_CODES) if retryable is None else retryable
        self.http_status = http_status or CODE_STATUS.get(code, 500)

    def to_dict(self) -> dict[str, Any]:
        """转成统一响应体（唯一出口，router 只调这个）。"""
        return {
            'error': {
                'code': self.code,
                'message': self.message,
                'backend': self.backend,
                'retryable': self.retryable,
            }
        }

    def __str__(self) -> str:  # pragma: no cover - 调试友好
        return f'[{self.code}] {self.message} (backend={self.backend})'


def unknown_task(task_code: str, loaded: int) -> LlmError:
    """``task_code`` 不在已加载提示词里。"""
    return LlmError(
        'unknown_task',
        f'未知任务代码：{task_code}（已加载 {loaded} 个提示词，见 GET /v1/prompts）',
    )


def missing_input(fields: list[str], task: str) -> LlmError:
    """请求 ``inputs`` 缺 front-matter 声明的字段。"""
    return LlmError(
        'missing_input',
        f'缺少必填输入字段：{"、".join(fields)}（{task} 需要 {"、".join(fields)}）',
    )


def prompt_not_found(file_name: str, reason: str) -> LlmError:
    """提示词文件缺失 / front-matter 解析失败。"""
    return LlmError('prompt_not_found', f'提示词 {file_name} 加载失败：{reason}')


def backend_unknown(name: str, available: list[str]) -> LlmError:
    """请求里的 ``backend`` 不在 config.yaml。"""
    return LlmError(
        'backend_unknown',
        f'未配置的后端：{name}（可用：{" / ".join(available)}）',
    )


def backend_unreachable(name: str, base_url: str, detail: str = '') -> LlmError:
    """连不上后端（ConnectError / DNS 失败）。"""
    msg = f'无法连接后端 {name}（{base_url}）。'
    if name == 'ollama':
        msg += '本机模式请先启动 Ollama（ollama serve），或把 config.yaml 的 default_backend 换成其它后端。'
    if detail:
        msg += f' 底层错误：{detail}'
    return LlmError('backend_unreachable', msg, backend=name)


def backend_timeout(name: str, seconds: float) -> LlmError:
    """单次请求超时。"""
    return LlmError(
        'backend_timeout',
        f'后端 {name} 在 {seconds:g}s 内未返回。'
        '可在 config.yaml 调大 timeouts.structured_s，或换更小的模型。',
        backend=name,
    )


def auth_failed(name: str, env_name: str) -> LlmError:
    """上游 401 / 403。"""
    return LlmError(
        'auth_failed',
        f'后端 {name} 鉴权失败：请检查 llm_server/.env 里的 {env_name}'
        + ('' if env_name else f'（后端 {name} 未配置 api_key_env）'),
        backend=name,
    )


def rate_limited(name: str) -> LlmError:
    """上游 429。"""
    return LlmError('rate_limited', f'后端 {name} 触发限流，请稍后重试。', backend=name)


def bad_json(name: str, attempts: int) -> LlmError:
    """六层容错后 parsed 仍为 None（仅结构化任务）。"""
    return LlmError(
        'bad_json',
        f'模型输出不是合法 JSON（已重试 {attempts - 1} 次）。'
        f'建议换更强的模型，或在 config.yaml 把该任务切到 minimax。',
        backend=name,
    )


def upstream_error(name: str, status: int | str, detail: str = '') -> LlmError:
    """上游 5xx / 协议解析失败。"""
    msg = f'后端 {name} 返回异常（HTTP {status}），已做归一化。'
    if detail:
        msg += f' 细节：{detail}'
    return LlmError('upstream_error', msg, backend=name)


def invalid_request(detail: str) -> LlmError:
    """请求体不是 JSON / 字段类型错。"""
    return LlmError('invalid_request', f'请求体不合法：{detail}')


def internal(detail: str) -> LlmError:
    """兜底未捕获异常。"""
    return LlmError('internal', f'服务端内部错误：{detail}（详见日志 llmserver.task）')
