"""任务注册表（S-02）：提示词元信息 + 输入校验 + 后端选择。

 Router 只跟本类打交道，不直接碰 PromptStore / Config，保证「任务语义」集中一处。
"""

from __future__ import annotations

from typing import Any, Mapping

from core.config import BackendConf, Config
from core.errors import LlmError, missing_input
from core.logging import get_logger
from core.prompt_store import PromptMeta, PromptStore

_log = get_logger('task')


class TaskRegistry:
    """任务 → 提示词 / 输入校验 / 后端 的绑定层。"""

    def __init__(self, store: PromptStore, config: Config) -> None:
        self.store = store
        self.config = config

    # ---------- 提示词 ----------

    def get(self, task: str, variant: str | None = None) -> PromptMeta:
        """取提示词（未找到抛 ``unknown_task``）。"""
        return self.store.get(task, variant)

    def has(self, task: str, variant: str | None = None) -> bool:
        try:
            self.store.get(task, variant)
            return True
        except LlmError:
            return False

    # ---------- 输入 ----------

    def validate_inputs(self, meta: PromptMeta, inputs: Mapping[str, Any] | None) -> list[str]:
        """校验必填输入字段，返回**缺失字段名列表**（空列表 = 通过）。

        只校验「存在且非空字符串」：数值 0 / False 是合法输入，不能误判为缺失。
        """
        provided = inputs or {}
        missing: list[str] = []
        for name in meta.inputs:
            if name not in provided:
                missing.append(name)
                continue
            value = provided[name]
            if value is None:
                missing.append(name)
                continue
            if isinstance(value, str) and not value.strip():
                missing.append(name)
        return missing

    def require_inputs(self, meta: PromptMeta, inputs: Mapping[str, Any] | None) -> dict[str, Any]:
        """校验并在缺失时抛 ``missing_input``。"""
        missing = self.validate_inputs(meta, inputs)
        if missing:
            raise missing_input(missing, meta.task)
        return dict(inputs or {})

    # ---------- 后端 ----------

    def resolve_backend(self, task: str, override: str | None = None) -> BackendConf:
        """决定用哪个后端（D11：**不做按任务强制**）。

        优先级：请求里的 ``backend`` 覆盖 > ``task_backends``（可选，默认空）
        > ``default_backend``。前两者都为空时，提示词的 ``preferred_backend``
        **只在日志里作为建议**，不生效。
        """
        name = (override or '').strip()
        if not name:
            name = (self.config.task_backends.get(str(task).upper()) or '').strip()
        if not name:
            name = self.config.default_backend
        conf = self.config.backend(name)
        try:
            meta = self.store.get(task, None)
            if meta.preferred_backend and meta.preferred_backend != conf.name:
                _log.debug(
                    '%s 的 preferred_backend=%s，实际使用 %s（D11：不强制）',
                    task,
                    meta.preferred_backend,
                    conf.name,
                )
        except LlmError:
            pass
        return conf

    def resolve_model(self, task: str) -> str | None:
        """某任务的模型覆盖；``None`` = 跟随后端默认模型（AC-06）。

        只在**请求未显式带 model** 时被调用（router 层，D2），因此不会覆盖
        调用方显式指定的模型。任意字符串都被接受（模型列表可能随时变，
        不做存在性校验），由后端在请求时报错。
        """
        _, model = self.config.task_route(str(task or '').upper())
        return model
