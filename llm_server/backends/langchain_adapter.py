"""LangChain 适配层 —— **占位，本次不实现、不引入依赖**（D2 / §6.1）。

为什么留这个文件：
    将来若要把「多步编排 / 检索增强 / 工具调用」搬进服务端，LangChain 是可选
    路线之一。但 P0 的全部能力（提示词装载、两种协议、六层容错、SSE）
    用 fastapi + httpx 已经足够，引入 LangChain 会：

    ① 破坏「依赖只有 4 个」的约束（会拖进 pydantic / openai / tiktoken 等一整棵
       依赖树，Windows 上还有编译风险）；
    ② 把「HTTP 形态差异」藏进第三方抽象，反而更难对齐 App 侧的解析契约。

若将来要实现，落点建议：

    class LangChainBackend(LLMBackend):
        # 复用 core.prompt_store 的 PromptMeta 拿 system/user，
        # 用 ChatPromptTemplate 组装，再调用某个 ChatModel；
        # 返回值必须映射回 backends.base.Completion{text, model_id, usage, truncated}，
        # 这样 router 一行都不用改。

   然后在 backends/__init__.py 的 _REGISTRY 里加一行：
       'langchain': 'backends.langchain_adapter.LangChainBackend'

并把 langchain 加进 requirements.txt（**那时才加**）。
"""

from __future__ import annotations

# 故意不 import 任何东西：本文件只是文档占位。
