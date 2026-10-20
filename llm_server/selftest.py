"""无外网依赖自检（PRD §8）。

两组检查：

**A. 六层容错 7 个坏样本**（必全绿）
    ① 纯 JSON  ② 闭合 <think>  ③ 未闭合 <think> 且块内含 `{`
    ④ ```json 围栏  ⑤ 前后杂文  ⑥ 输出被截断  ⑦ 未闭合 <reasoning>

    其中 ③⑥ 是**回归保护点**：
    - ③ 旧实现（「首 `{` → 末 `}`」硬切）必挂；
    - ⑥ 必须抢救出外层，且**绝不能**退化成内层片段
      ``{"name":"力","level":1}``（形状不对，会让上层误判成功）。

**B. 提示词契约**
    14 个任务的 structured / json_output / output_key / inputs 必须与 App 侧
    解析器契约一致（字段名逐字对齐）。已加载的逐个校验，未加载的列为 INFO。

用法::

    python llm_server/selftest.py
    python llm_server/selftest.py --prompts llm_server/prompts
"""

from __future__ import annotations

import sys
import time
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from core.json_repair import repair  # noqa: E402
from core.prompt_store import PromptStore  # noqa: E402

# ---------------------------------------------------------------- A. 坏样本

#: (名称, 原始输出, 期望断言函数)
def _expect_gaps_len_1(parsed: Any) -> tuple[bool, str]:
    if not isinstance(parsed, dict):
        return False, f'期望 dict，实际 {type(parsed).__name__}'
    gaps = parsed.get('gaps')
    if not isinstance(gaps, list):
        return False, f'期望含 gaps 列表，实际 keys={list(parsed)}'
    if len(gaps) != 1:
        return False, f'期望 gaps 长度 1，实际 {len(gaps)}'
    first = gaps[0]
    if not isinstance(first, dict) or first.get('name') != '力':
        return False, f'期望首条 name=力，实际 {first!r}'
    return True, 'gaps=1 且首条完整'


def _expect_not_null(parsed: Any) -> tuple[bool, str]:
    return (parsed is not None), ('解析成功' if parsed is not None else '解析为 None')


def _expect_quotes_safe(parsed: Any) -> tuple[bool, str]:
    if not isinstance(parsed, dict):
        return False, f'期望 dict，实际 {type(parsed).__name__}'
    gaps = parsed.get('gaps')
    if not isinstance(gaps, list) or not gaps:
        return False, '期望非空 gaps'
    first = gaps[0]
    if not isinstance(first, dict):
        return False, '期望 gaps[0] 是 dict'
    if first.get('name') != 'a}b' or first.get('definition') != 'x{y':
        return False, f'字符串内的括号被误判：{first!r}'
    return True, '字符串内的 } / { 未被当作结构符号'


SAMPLES: list[tuple[str, str, Any]] = [
    ('① 纯 JSON', '{"gaps":[{"name":"力","level":1}]}', _expect_gaps_len_1),
    (
        '② 闭合的 <think>',
        '<think>让我分析一下 F=ma</think>\n{"gaps":[{"name":"力","level":1}]}',
        _expect_gaps_len_1,
    ),
    (
        '③ 未闭合的 <think> 且块内含 { —— 旧实现必挂',
        '<think>\n'
        '考虑 F=ma 的情形 { 这里没闭合\n'
        '牛顿第二定律涉及力与加速度\n'
        '{"gaps":[{"name":"力","definition":"物体间的相互作用","level":1}]}',
        _expect_gaps_len_1,
    ),
    (
        '④ ```json 围栏',
        '```json\n{"gaps":[{"name":"力","level":1}]}\n```',
        _expect_gaps_len_1,
    ),
    (
        '⑤ 前后夹带无关文字',
        '好的，分析结果如下：\n{"gaps":[{"name":"力","level":1}]}\n希望对你有帮助。',
        _expect_gaps_len_1,
    ),
    (
        '⑥ 输出被截断 → 抢救外层，绝不退化成内层片段',
        '{"gaps":[{"name":"力","level":1},{"name":"加速',
        _expect_gaps_len_1,
    ),
    (
        '⑦ 未闭合的 <reasoning>',
        '<reasoning>\n先想想力与加速度的关系\n{"gaps":[{"name":"力","level":1}]}',
        _expect_gaps_len_1,
    ),
]

#: 额外的「反例」断言：⑥ 绝不能解析成内层片段。
_ANTI_INNER_FRAGMENT = '{"name":"力","level":1}'

#: 补测：字符串里的括号不能被当结构符号
EXTRA_SAMPLES: list[tuple[str, str, Any]] = [
    ('⑧ 字符串值内含 } / {', '{"gaps":[{"name":"a}b","definition":"x{y","level":1}]}', _expect_quotes_safe),
    ('⑨ 纯文本（无 JSON）→ 应返回 None 而不是抛异常', '抱歉，我无法回答。', lambda p: (p is None, 'p is None' if p is None else f'{p!r}')),
    ('⑩ 空字符串 → 返回 None', '', lambda p: (p is None, 'p is None' if p is None else f'{p!r}')),
]


def run_repair_samples() -> int:
    """跑 7 个必过样本 + 3 个补充样本，返回失败数。"""
    failures = 0
    for name, raw, check in SAMPLES + EXTRA_SAMPLES:
        try:
            parsed, cleaned = repair(raw)
        except Exception as exc:  # noqa: BLE001
            print(f'  ❌ {name}\n      repair() 抛异常：{type(exc).__name__}: {exc}')
            failures += 1
            continue
        ok, detail = check(parsed)
        # ⑥ 的反例断言
        if name.startswith('⑥') and isinstance(parsed, dict) and 'gaps' not in parsed:
            ok = False
            detail = f'退化成了内层片段 {parsed!r}（形状不对，上层会误判成功）'
        if ok:
            print(f'  ✅ {name}\n      parsed={_brief(parsed)}  cleaned={_brief(cleaned)}')
        else:
            print(f'  ❌ {name}\n      {detail}\n      parsed={_brief(parsed)}')
            failures += 1
    return failures


def _brief(value: Any, limit: int = 70) -> str:
    text = repr(value)
    return text if len(text) <= limit else text[: limit - 1] + '…'


# ---------------------------------------------------------------- B. 契约

#: 任务 → (structured, json_output, output_key, inputs)。
#: 与 App 侧解析器契约逐字对齐（设计 §2.7 / PRD §C1）。
EXPECTED_CONTRACT: dict[str, tuple[bool, bool, str | None, tuple[str, ...]]] = {
    'T1': (True, True, 'knowledge_points', ('note_text',)),
    'T2': (True, True, 'normalized', ('kps',)),
    'T3': (True, True, 'prerequisites', ('points',)),
    'T4': (True, True, 'gaps', ('target', 'depth')),
    'T5': (False, False, None, ('query',)),
    'T5.detect': (False, True, None, ('query',)),
    'T6': (False, False, None, ('query',)),
    'T7': (False, False, None, ('query',)),
    'T8': (False, True, None, ('query',)),
    'T9': (True, True, 'grade', ('question', 'answer', 'user_answer')),
    'T10': (False, False, None, ('query',)),
    'T11': (False, False, None, ('query',)),
    'T12': (True, True, 'title_tags', ('content',)),
    'T13': (True, True, 'similarities', ('pairs',)),
}


def run_contract_check(store: PromptStore) -> tuple[int, int]:
    """校验已加载提示词的契约，返回 ``(failures, missing)``。"""
    failures = 0
    missing = 0
    for key, (structured, json_output, output_key, inputs) in EXPECTED_CONTRACT.items():
        task, _, variant = key.partition('.')
        try:
            meta = store.get(task, variant or None)
        except Exception:
            print(f'  ⚪ {key} 未加载（不影响通过，T05 补齐后应为 14/14）')
            missing += 1
            continue
        problems: list[str] = []
        if meta.structured != structured:
            problems.append(f'structured 期望 {structured}，实际 {meta.structured}')
        if meta.json_output != json_output:
            problems.append(f'json_output 期望 {json_output}，实际 {meta.json_output}')
        if (meta.output_key or None) != (output_key or None):
            problems.append(f'output_key 期望 {output_key!r}，实际 {meta.output_key!r}')
        if tuple(meta.inputs) != inputs:
            problems.append(f'inputs 期望 {list(inputs)}，实际 {list(meta.inputs)}')
        if meta.placeholders_mismatch:
            problems.append(
                f'占位符 {list(meta.placeholders)} 与 inputs {list(meta.inputs)} 不一致'
            )
        if meta.json_output:
            text = meta.user + '\n' + meta.system
            if '只输出' not in text and 'JSON' not in text:
                problems.append('json_output=True 的提示词缺少 JSON-only 收尾段')
        if problems:
            print(f'  ❌ {key}（{meta.file_name}）')
            for p in problems:
                print(f'      {p}')
            failures += 1
        else:
            print(f'  ✅ {key} → {meta.file_name}')
    return failures, missing


# ---------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    started = time.time()

    print('=' * 72)
    print('A. 六层容错（json_repair.repair）—— 7 个坏样本 + 3 个补充样本')
    print('=' * 72)
    repair_failures = run_repair_samples()

    print()
    print('=' * 72)
    print('B. 提示词契约（structured / json_output / output_key / inputs）')
    print('=' * 72)
    store = PromptStore(args.prompts)
    contract_failures, missing = run_contract_check(store)

    print()
    print('-' * 72)
    print(f'提示词目录：{store.dir}')
    print(f'已加载 {store.count()} 个，跳过 {len(store.skipped)}，错误 {len(store.errors)}')
    for err in store.errors:
        print(f'  ⚠️ {err}')
    print(
        f'结果：容错 {len(SAMPLES) + len(EXTRA_SAMPLES) - repair_failures}'
        f'/{len(SAMPLES) + len(EXTRA_SAMPLES)} 通过，'
        f'契约 {len(EXPECTED_CONTRACT) - missing - contract_failures}'
        f'/{len(EXPECTED_CONTRACT)} 通过（未加载 {missing}）'
    )
    print(f'耗时 {time.time() - started:.2f}s')

    if repair_failures or contract_failures or store.errors:
        print('❌ selftest FAILED')
        print(f'   反例提醒：截断样本绝不能产出 {_ANTI_INNER_FRAGMENT} 这种内层片段。')
        return 1
    print('✅ selftest PASSED')
    return 0


def _parse_args(argv: list[str] | None) -> Any:
    import argparse

    parser = argparse.ArgumentParser(description='llm_server 自检（无外网依赖）')
    parser.add_argument(
        '--prompts',
        default=str(_HERE / 'prompts'),
        help='提示词目录（默认 llm_server/prompts）',
    )
    return parser.parse_args(argv)


if __name__ == '__main__':
    raise SystemExit(main())
