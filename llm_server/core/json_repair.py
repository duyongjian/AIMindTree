"""六层 JSON 容错（设计 §C2，与 Flutter 侧 ``lib/ai/structured_parse.dart`` 逐层等价）。

模型输出永远不可信。本模块把「尽力解析出结构」这件事收敛在一处，
**逐层降级、绝不编造内容**。

层序（不可调）：

===== ============================================================ ==============================
层     逻辑                                                         备注
===== ============================================================ ==============================
0      剥离 ``<think>`` / ``<thinking>`` / ``<reasoning>``          未闭合时截到末尾再丢弃
1      整体 ``json.loads``                                          最理想路径
2      剥离**闭合**的 ``<think>…</think>`` 后再解                    与第 0 层互补
3      剥离 ```` ```json … ``` ```` 围栏后再解                       常见
4      **括号配对扫描**：逐个 ``{``/``[`` 起点配对，取首个可解码片段  关键修复（内含 5）
5      **截断抢救**：回退到最后一个完整元素，补未闭合括号             绝不补全/编造
6      首尾硬切                                                     尽力而为
===== ============================================================ ==============================

⚠️ 两条禁止事项（踩坑结论，勿删）：

1. **不要「首 ``{`` → 末 ``}``」硬切**：思考块里若含 ``{``，切片起点会落进
   思考文字，拼出来的串不是合法 JSON → 静默失败 → 上层无声退回本地兜底。
2. **不得退而求其次解析内层片段**：``{"gaps":[{"name":"力"}]}`` 里的内层
   ``{"name":"力"}`` 本身合法但形状不对，调用方取不到 ``gaps`` 却以为成功。
"""

from __future__ import annotations

import json
import re
from typing import Any

#: 思考块正则。**含未闭合形态**（末尾用 ``$`` 兜底）。
#: 与 Flutter 侧 ``StructuredText.stripThinkBlocks`` 使用同一套模式。
THINK_RE = re.compile(
    r'<(think|thinking|reasoning)>[\s\S]*?(?:</(think|thinking|reasoning)>|$)',
    re.IGNORECASE,
)

#: 闭合的 ``<think>…</think>``（第 2 层，与第 0 层互补）。
THINK_CLOSED_RE = re.compile(r'<think>[\s\S]*?</think>', re.IGNORECASE)

#: ```json 围栏（第 3 层）。
FENCE_RE = re.compile(r'```(?:json)?\s*([\s\S]*?)```', re.IGNORECASE)

_JSON_START = ('{', '[')
_JSON_END = ('}', ']')


def strip_think_blocks(text: str) -> str:
    """剥离三种思考标记（含未闭合形态）。

    未闭合时从标记处截到**末尾**再丢弃 —— 宁可丢正文也不让思考块污染起点。
    若因此把 JSON 也吃掉了（结果为空串），调用方 [:func:`repair`] 会回退到
    原文继续扫描，不会静默失败。
    """
    return THINK_RE.sub('', text)


def repair(raw: str) -> tuple[Any | None, str]:
    """尽力把模型输出解析为 JSON。

    Args:
        raw: 模型原始输出（可能含思考块 / 围栏 / 前后杂文 / 被截断）。

    Returns:
        ``(parsed, cleaned)``：``parsed`` 为 ``dict`` / ``list`` / 标量，
        彻底失败为 ``None``；``cleaned`` 是本函数实际使用的文本
        （已剥离思考块），回填给响应的 ``content`` 字段。
    """
    text = (raw or '').strip()

    # ⓪ 剥离思考块（含未闭合）
    no_think = strip_think_blocks(text).strip()
    if no_think:
        parsed = _try_decode(no_think)
        if parsed is not None:
            return parsed, no_think

    # ① 整体就是合法 JSON
    parsed = _try_decode(text)
    if parsed is not None:
        return parsed, text

    # ② 剥离闭合的 <think>…</think>
    stage = THINK_CLOSED_RE.sub('', text).strip()
    parsed = _try_decode(stage)
    if parsed is not None:
        return parsed, stage

    # ③ 剥离 ```json 围栏
    match = FENCE_RE.search(stage)
    if match:
        inner = match.group(1).strip()
        parsed = _try_decode(inner)
        if parsed is not None:
            return parsed, inner
        stage = inner

    # ④ 括号配对扫描（内含 ⑤ 截断抢救）
    parsed = _scan_json(stage)
    if parsed is not None:
        return parsed, stage

    # ⓪ 的补充：用「只剥思考块」的版本再扫一次（覆盖「未闭合思考块 + 围栏」组合）
    if no_think and no_think != stage:
        parsed = _scan_json(no_think)
        if parsed is not None:
            return parsed, no_think

    # ⑥ 最后退回首尾硬切（尽力而为）
    start = _find_any(stage, _JSON_START)
    end = _rfind_any(stage, _JSON_END)
    if start != -1 and end != -1 and end > start:
        parsed = _try_decode(stage[start : end + 1])
        if parsed is not None:
            return parsed, stage[start : end + 1]

    return None, no_think or text


def _try_decode(text: str) -> Any | None:
    """尝试解码；失败返回 None（不抛）。"""
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        return None


def _scan_json(text: str) -> Any | None:
    """扫描第一个「括号完整配对且能解码」的 JSON 值。

    逐个尝试每个 ``{`` / ``[`` 起点：先用 [:func:`_match_end`] 找配对终点再解码；
    这样即使前面夹着**未闭合**的思考块（里面可能带 ``{``）也不会被带偏。
    """
    for i, ch in enumerate(text):
        if ch not in _JSON_START:
            continue
        end = _match_end(text, i)
        if end != -1:
            decoded = _try_decode(text[i : end + 1])
            if decoded is not None:
                return decoded
            # 能闭合但解码失败 → 多半是前面杂文里的假结构符，换下一个起点。
            continue
        # 未闭合：① 输出被 token 上限截断；② 这里根本不是 JSON 起点。
        # ⚠️ 绝不能退而求其次解析内层片段 —— 先抢救外层，救不出来才换起点。
        salvaged = _salvage(text, i)
        if salvaged is not None:
            return salvaged
    return None


def _salvage(text: str, start: int) -> Any | None:
    """抢救被截断的输出：截到**最后一个完整元素**，补上未闭合的括号。

    只保留完整的条目，被截断的那一条直接丢弃 —— 绝不补全或编造内容。
    """
    k = -1
    for i in range(len(text) - 1, start - 1, -1):
        if text[i] in _JSON_END:
            k = i
            break
    if k == -1:
        return None
    stack = _stack_at(text, start, k)
    if not stack:
        return None
    closers = ''.join('}' if c == '{' else ']' for c in reversed(stack))
    return _try_decode(text[start : k + 1] + closers)


def _stack_at(text: str, start: int, end: int) -> list[str] | None:
    """从 ``start`` 扫到 ``end``（含），返回**仍未闭合**的开括号栈；括号不匹配返回 None。

    字符串内的括号不参与配对，转义字符正确处理。
    """
    stack: list[str] = []
    in_string = False
    escaped = False
    for i in range(start, min(end, len(text) - 1) + 1):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
            continue
        if ch in _JSON_START:
            stack.append(ch)
            continue
        if ch in _JSON_END:
            if not stack:
                return None
            opener = stack.pop()
            if (opener == '{' and ch != '}') or (opener == '[' and ch != ']'):
                return None
    return stack


def _match_end(text: str, start: int) -> int:
    """从 ``start``（必须是 ``{`` 或 ``[``）扫到配对的 ``}`` / ``]``，返回其下标；未闭合返回 -1。"""
    stack: list[str] = []
    in_string = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
            continue
        if ch in _JSON_START:
            stack.append(ch)
            continue
        if ch in _JSON_END:
            if not stack:
                return -1
            opener = stack.pop()
            if (opener == '{' and ch != '}') or (opener == '[' and ch != ']'):
                return -1
            if not stack:
                return i
    return -1


def _find_any(text: str, chars: tuple[str, ...]) -> int:
    for i, ch in enumerate(text):
        if ch in chars:
            return i
    return -1


def _rfind_any(text: str, chars: tuple[str, ...]) -> int:
    for i in range(len(text) - 1, -1, -1):
        if text[i] in chars:
            return i
    return -1
