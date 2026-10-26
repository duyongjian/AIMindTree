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
    18 个任务（含 T1 的 keypoints/both 两个变体与 T14/T15）的
    structured / json_output / output_key / inputs 必须与 App 侧
    解析器契约一致（字段名逐字对齐）。已加载的逐个校验，未加载的列为 INFO。

**C. App 端 inputs ↔ front-matter inputs 双向对账**（防静默丢弃）

**D. 管理后台**（settings 覆盖层往返 + balance 结构化）

**E. 同步配置**（``GET/PUT /v1/admin/sync`` + ``/v1/app/config`` 的 sync 段：
    4 键契约 / 空串清空 / 缺 key 不修改 / 400 校验 / settings.json 落盘。
    TestClient 进程内 + 临时目录，不污染仓库）。

用法::

    python llm_server/selftest.py
    python llm_server/selftest.py --prompts llm_server/prompts
"""

from __future__ import annotations

import asyncio
import json
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
    'T4': (True, True, 'gaps', ('target', 'depth', 'depth_instruction')),
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
    'T14': (True, True, 'duplicates', ('pairs',)),
    # T1 的两个变体（variant 走 body，与主形态同为 knowledge_points 数组契约）：
    # keypoints = 只提取「要点重点」；both = 知识点 + 要点都要。
    'T1.keypoints': (True, True, 'knowledge_points', ('note_text',)),
    'T1.both': (True, True, 'knowledge_points', ('note_text',)),
    # T15 划词提取：单对象契约（output_key 单数），App 端 _mapSingleToRaw 解析。
    'T15': (True, True, 'knowledge_point', ('selection', 'note_text')),
}


# ------------------------------------------------- C. App 端 inputs 对账

#: App 端**实际传入**的 inputs 字段名，逐字取自 Flutter 调用点。
#: ``None`` = 该任务 App 端尚未接线（P2 预留），跳过对账但仍列出。
#:
#: ⚠️ 这张表是**回归护栏**。服务端只校验「声明的字段是否缺失」，**不拒绝多余字段**，
#: 所以「App 端多传、服务端没声明」不会报 400，而是被**静默丢弃** —— 用户看到的是
#: 功能悄悄失效且无任何提示（T4 的 depth_instruction 就是这么丢的）。
#: 只有这里做双向对账才能兜住。改任何一侧都要同步改这里。
APP_INPUTS: dict[str, tuple[str, ...] | None] = {
    'T1': ('note_text',),
    'T2': None,          # P2 未接线
    'T3': ('points',),
    'T4': ('target', 'depth', 'depth_instruction'),
    'T5': ('query',),
    'T5.detect': ('query',),
    'T6': ('query',),
    'T7': None,          # P2 未接线
    'T8': ('query',),
    'T9': None,          # P2 未接线
    'T10': None,         # P2 未接线
    'T11': None,         # P2 未接线
    'T12': None,         # P2 未接线
    'T13': None,         # P2 未接线
    'T14': ('pairs',),
    'T1.keypoints': ('note_text',),
    'T1.both': ('note_text',),
    'T15': ('selection', 'note_text'),
}

#: App 端调用点（报错时给出确切位置，省得再翻代码）。
APP_CALL_SITES: dict[str, str] = {
    'T1': 'lib/ai/extraction_service.dart  extract()  ai.run(T1, {"note_text": ...})',
    # T1 变体：同一调用点，variant 走 body（tasks.py:96 只认 body）。
    'T1.keypoints': 'lib/ai/extraction_service.dart  extract(variant: "keypoints")',
    'T1.both': 'lib/ai/extraction_service.dart  extract(variant: "both")',
    # T15 划词提取：单对象输出，客户端权威覆盖 source_quote=选中文字。
    'T15': 'lib/ai/extraction_service.dart  extractFromSelection()  ai.run(T15, {"selection", "note_text"})',
    # T3 的 points 是 JSON 字符串：按组连线（:233）会在每个元素里多带
    # group / group_order / foundation_level 三个附加字段，字段名对外仍是 points，
    # 但提示词正文必须说明其含义（见 t3_prerequisite.md 第 7 条）。
    'T3': 'lib/ai/auto_graph_service.dart:152 / :233  {"points": jsonEncode([...])}',
    'T4': 'lib/ai/auto_graph_service.dart:377  {"target","depth","depth_instruction"}',
    'T5': 'lib/features/agent/agent_page.dart:131 / teacher_page.dart:140  chat(query)',
    'T5.detect': 'lib/features/agent/agent_page.dart:209  chat(prompt, variant:"detect")',
    'T6': 'lib/features/teacher/teacher_page.dart:99  chat(query)',
    'T8': 'lib/features/homework/homework_page.dart:187  chat(_buildPrompt())',
}


def run_app_inputs_check(store: PromptStore) -> tuple[int, int]:
    """App 端 inputs ↔ front-matter ``inputs`` **双向对账**。

    两种不一致都是 bug，但表现相反：

    - **App 多传、服务端没声明** → 字段被静默丢弃，**静默失效**（最危险，无报错）。
    - **服务端声明、App 没传** → ``missing_input`` 400，直接炸（吵但好查）。

    Returns:
        ``(failures, unwired)``
    """
    failures = 0
    unwired = 0
    for key, app_fields in APP_INPUTS.items():
        task, _, variant = key.partition('.')
        if app_fields is None:
            print(f'  ⚪ {key} App 端未接线（P2 预留），跳过对账')
            unwired += 1
            continue
        try:
            meta = store.get(task, variant or None)
        except Exception:
            print(f'  ⚪ {key} 提示词未加载，跳过对账')
            continue

        dropped = [f for f in app_fields if f not in meta.inputs]
        missing = [f for f in meta.inputs if f not in app_fields]
        site = APP_CALL_SITES.get(key, '(调用点未登记)')
        if not dropped and not missing:
            print(f'  ✅ {key} → {meta.file_name}  inputs={list(meta.inputs)}')
            continue
        failures += 1
        print(f'  ❌ {key} → {meta.file_name}')
        print(f'      App 端：{site}')
        if dropped:
            print(
                f'      App 多传但服务端没声明：{dropped} → **被静默丢弃**，'
                f'功能悄悄失效且无报错（必须修提示词的 inputs + 正文渲染）'
            )
        if missing:
            print(
                f'      服务端声明但 App 没传：{missing} → 会 400 missing_input'
                f'（必须修 App 端，或确认该字段确属多余）'
            )
    return failures, unwired


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


# ---------------------------------------------------------------- D. 管理后台

#: 临时 config.yaml 样例（用于 settings 覆盖层往返测试，写到系统临时目录，不污染仓库）。
_SAMPLE_CONFIG_YAML = """
server:
  host: 127.0.0.1
  port: 8787
default_backend: minimax
backends:
  minimax:
    type: minimax
    protocol: anthropic_compat
    base_url: https://api.minimax.cn
    api_key_env: MINIMAX_API_KEY
    default_model: MiniMax-Text-01
    openai_path: /v1/chat/completions
    anthropic_path: /anthropic/v1/messages
    extra:
      balance_path: /v1/token_plan/remains
  ollama:
    type: ollama
    protocol: openai_compat
    base_url: http://127.0.0.1:11434
    default_model: llama3
    models: [llama3]
  llama_cpp:
    type: openai_compat
    protocol: openai_compat
    base_url: http://127.0.0.1:8085
    api_key_env: ""
    default_model: Qwen3.8-27B-Uncensored
    models: [Qwen3.8-27B-Uncensored]
    health_path: /v1/models
  openai_compat:
    type: openai_compat
    protocol: openai_compat
    base_url: https://api.openai.com/v1
    api_key_env: OPENAI_API_KEY
    default_model: gpt-4o-mini
"""

#: llama_cpp 后端专用夹具：**默认后端故意先写成 ollama**，用来演练
#:「把默认后端切成 llama_cpp」这一步（2026-10-27 起项目改用 llama.cpp）。
_LLAMA_CPP_CONFIG_YAML = """
server:
  host: 127.0.0.1
  port: 8787
default_backend: ollama
backends:
  ollama:
    type: ollama
    protocol: openai_compat
    base_url: http://127.0.0.1:11434
    default_model: llama3
    models: [llama3]
  llama_cpp:
    type: openai_compat
    protocol: openai_compat
    base_url: http://127.0.0.1:8085
    api_key_env: ""
    default_model: Qwen3.8-27B-Uncensored
    models: [Qwen3.8-27B-Uncensored]
    health_path: /v1/models
"""


#: 管理后台自检的断言点数（全部通过时 admin_failures=0）。
_ADMIN_TOTAL = 13


def run_admin_checks() -> int:
    """D. 管理后台相关自检（离线、不污染仓库）。

    1. settings.json 覆盖层往返：protocol / default_model / api_key 覆盖生效，
       且优先级高于 config.yaml；mask 不泄露完整密钥。
    2. MiniMaxBackend.balance() 在无 key / 无 base_url 时返回结构化 dict（绝不抛异常）。

    Returns:
        失败数。
    """
    failures = 0
    failures += _check_settings_roundtrip()
    failures += asyncio.run(_check_balance_structured())
    failures += _check_llama_cpp_backend()
    return failures


def _check_llama_cpp_backend() -> int:
    """本地 llama.cpp 后端（``llama_cpp``）自检。

    2026-10-27 起项目不再使用 Ollama，默认后端改为 llama.cpp 的 llama-server
    （127.0.0.1:8085）。它**不新增 Python 后端类**，而是复用现成的
    ``type: openai_compat`` + ``protocol: openai_compat``，所以这里只验证
    「配置解析 + 空密钥可实例化 + 请求路径正确 + 默认后端可切换」。

    全程离线（不发任何网络请求）、临时目录（不污染仓库）。
    """
    import tempfile

    from backends import create_backend
    from core.config import Config

    failures = 0
    d = tempfile.mkdtemp(prefix='aimindtree_llama_cpp_')
    cfg_path = Path(d) / 'config.yaml'
    cfg_path.write_text(_LLAMA_CPP_CONFIG_YAML, encoding='utf-8')

    config = Config(cfg_path)

    # ① 默认后端可被切成 llama_cpp（settings.json 覆盖层优先于 config.yaml）
    config.save_settings({'default_backend': 'llama_cpp'})
    switched = Config(cfg_path)
    if switched.default_backend != 'llama_cpp':
        print('  ❌ 默认后端切换失败，实际 %r' % switched.default_backend)
        failures += 1
    else:
        print('  ✅ 默认后端可切换为 llama_cpp（settings 覆盖层生效）')

    try:
        conf = switched.backend('llama_cpp')
    except Exception as exc:  # noqa: BLE001
        print('  ❌ backends 里取不到 llama_cpp：%r' % exc)
        return failures + 4
    if conf.model() != 'Qwen3.8-27B-Uncensored':
        print('  ❌ llama_cpp 默认模型应为 --alias 的值，实际 %r' % conf.model())
        failures += 1
    else:
        print('  ✅ llama_cpp 默认模型 = Qwen3.8-27B-Uncensored（与 --alias 一致）')

    # ② 空密钥可创建后端（本地 llama-server 无鉴权，api_key_env 为空串）
    try:
        backend = create_backend(conf, switched.resolve_api_key(conf))
    except Exception as exc:  # noqa: BLE001 - 这是要抓的违规
        print('  ❌ 空密钥创建 llama_cpp 后端失败：%r' % exc)
        return failures + 3
    print('  ✅ 空密钥可创建 llama_cpp 后端（type=openai_compat，复用现成协议层）')

    # ③ 空密钥 → 不带 Authorization 头
    proto = getattr(backend, '_protocol', None)
    if proto is None or not hasattr(proto, 'headers') or not hasattr(proto, 'url'):
        print('  ❌ OpenAICompatBackend 未挂上协议对象，无法继续断言')
        return failures + 3
    headers = proto.headers()
    if 'Authorization' in headers:
        print('  ❌ 空密钥仍带了 Authorization 头：%r' % headers)
        failures += 1
    else:
        print('  ✅ 空密钥不带 Authorization 头')

    # ④ chat 路径：base_url 不带 /v1，由默认 openai_path 补上
    url = proto.url()
    if url != 'http://127.0.0.1:8085/v1/chat/completions':
        print('  ❌ chat URL 应为 http://127.0.0.1:8085/v1/chat/completions，实际 %r' % url)
        failures += 1
    else:
        print('  ✅ chat URL = http://127.0.0.1:8085/v1/chat/completions')

    if conf.health_path != '/v1/models':
        print('  ❌ health_path 应为 /v1/models，实际 %r' % conf.health_path)
        failures += 1
    else:
        print('  ✅ health_path = /v1/models')

    return failures


def _check_settings_roundtrip() -> int:
    import tempfile

    from core.config import Config

    failures = 0
    d = tempfile.mkdtemp(prefix='aimindtree_selftest_')
    cfg_path = Path(d) / 'config.yaml'
    cfg_path.write_text(_SAMPLE_CONFIG_YAML, encoding='utf-8')

    config = Config(cfg_path)
    if config.backends['minimax'].protocol != 'anthropic_compat':
        print('  ❌ 基线 minimax protocol 应为 anthropic_compat')
        failures += 1
    else:
        print('  ✅ 基线 minimax protocol = anthropic_compat（config.yaml 读取正常）')

    # 写入覆盖层
    config.save_settings(
        {
            'default_backend': 'minimax',
            'default_model': 'MiniMax-M3.1-Flash',
            'minimax_protocol': 'openai_compat',
            'backends': {'minimax': {'api_key': 'sk-selftest-secret'}},
        }
    )
    # 从磁盘重新加载，验证覆盖层被应用
    config2 = Config(cfg_path)
    if config2.backends['minimax'].protocol != 'openai_compat':
        print('  ❌ settings 未覆盖 minimax protocol')
        failures += 1
    else:
        print('  ✅ settings 覆盖 minimax protocol → openai_compat')

    if config2.default_model != 'MiniMax-M3.1-Flash':
        print('  ❌ settings 未覆盖 default_model（实际 %r）' % config2.default_model)
        failures += 1
    else:
        print('  ✅ settings 覆盖 default_model → MiniMax-M3.1-Flash')

    if config2.resolve_api_key(config2.backend('minimax')) != 'sk-selftest-secret':
        print('  ❌ settings 未覆盖 minimax api_key')
        failures += 1
    else:
        print('  ✅ settings 覆盖 minimax api_key（优先级高于 .env / 环境变量）')

    # 掩码不得泄露完整密钥
    masked = config2.mask('sk-selftest-secret')
    if 'selftest-secret' in masked:  # noqa: S105 - 故意检查是否泄露
        print('  ❌ mask 泄露了完整密钥：%s' % masked)
        failures += 1
    else:
        print('  ✅ mask 掩码正确：%s' % masked)

    # config.yaml 未被改动（覆盖层只写 settings.json）
    reread = Config(cfg_path)
    if reread.backends['minimax'].protocol != 'openai_compat':
        print('  ❌ 重载后 protocol 丢失（settings.json 应被读取）')
        failures += 1
    return failures


async def _check_balance_structured() -> int:
    from backends.minimax import MiniMaxBackend
    from core.config import BackendConf

    failures = 0
    # 无 base_url / 无 key：应直接返回结构化 dict，绝不抛异常、绝不发起网络请求。
    conf = BackendConf(name='minimax', type='minimax', base_url='', api_key_env='')
    backend = MiniMaxBackend(conf, api_key='')
    try:
        result = await backend.balance()
    except Exception as exc:  # noqa: BLE001 - 这是要抓的违规
        print('  ❌ balance() 抛出了异常（应永不抛异常）：%r' % exc)
        return 1
    if not isinstance(result, dict) or 'available' not in result or 'error' not in result or 'raw' not in result:
        print('  ❌ balance() 未返回结构化 dict（available/error/raw）：%r' % result)
        failures += 1
    else:
        print(
            '  ✅ balance() 返回结构化 dict：available=%s error=%s'
            % (result['available'], result['error'])
        )
    return failures


# ---------------------------------------------------------------- E. 同步配置


def run_sync_checks() -> tuple[int, int]:
    """E. 同步配置自检：``GET/PUT /v1/admin/sync`` + ``/v1/app/config`` 的 sync 段。

    覆盖（App 契约 + 管理接口语义）：
    1. ``GET /v1/admin/sync`` 形状 = ``{base_url, enabled, token_set, token_masked}``，
       初始无 token、**无 token 明文**；
    2. ``PUT`` 保存后 ``token_set=True``、回显仍无明文；
    3. ``sync`` 段落盘 ``settings.json``；
    4. ``/v1/app/config`` 的 ``sync`` = ``{base_url, enabled, token, token_set}``，
       且 ``token`` 为明文（localhost 假设下随配置下发，唯一例外）；
    5. ``token`` 空串 = 清空；缺 key = 不修改；
    6. 类型错误 → 400 ``invalid_request``；
    7. 重载 ``Config`` 后 sync 段仍生效。

    全程 TestClient 进程内 + 临时目录（config.yaml / settings.json 都写在
    临时目录），**不污染仓库**。返回 ``(failures, total)``。
    """
    import tempfile

    from fastapi.testclient import TestClient

    from core.config import Config
    from server import create_app

    state = {'total': 0, 'fail': 0}

    def expect(cond: bool, name: str, detail: str = '') -> None:
        state['total'] += 1
        if cond:
            print(f'  ✅ {name}' + (f'  —— {detail}' if detail else ''))
        else:
            state['fail'] += 1
            print(f'  ❌ {name}' + (f'\n      {detail}' if detail else ''))

    d = tempfile.mkdtemp(prefix='aimindtree_sync_')
    cfg_path = Path(d) / 'config.yaml'
    cfg_path.write_text(_SAMPLE_CONFIG_YAML, encoding='utf-8')
    settings_path = Path(d) / 'settings.json'
    token = 'sync-selftest-token-abcdef'

    app = create_app(cfg_path)
    with TestClient(app) as c:
        # ① GET 初始形状（无 token）
        r = c.get('/v1/admin/sync')
        expect(r.status_code == 200, 'GET /v1/admin/sync 返回 200', f'实际 {r.status_code}')
        body = r.json() if r.status_code == 200 else {}
        expect(
            set(body) == {'base_url', 'enabled', 'token_set', 'token_masked'},
            'GET 形状 = {base_url, enabled, token_set, token_masked}',
            str(sorted(body)),
        )
        expect(
            body.get('token_set') is False and body.get('token_masked') is None
            and 'token' not in body,
            '初始无 token：token_set=False、token_masked=None、无明文',
            str(body),
        )

        # ② PUT 保存（含 token）
        r = c.put('/v1/admin/sync', json={
            'base_url': 'https://demo.supabase.co', 'enabled': True, 'token': token,
        })
        expect(r.status_code == 200, 'PUT /v1/admin/sync 返回 200', f'实际 {r.status_code}')
        body = r.json() if r.status_code == 200 else {}
        expect(
            body.get('base_url') == 'https://demo.supabase.co' and body.get('enabled') is True,
            'PUT 回显 base_url / enabled 已生效',
            str(body),
        )
        expect(
            body.get('token_set') is True and 'token' not in body
            and bool(body.get('token_masked')),
            'PUT 回显 token_set=True + token_masked，无 token 明文',
            str(sorted(body)),
        )

        # ③ settings.json 落盘（sync 段）
        expect(
            settings_path.is_file()
            and (json.loads(settings_path.read_text(encoding='utf-8'))
                 .get('sync', {}).get('token') == token),
            'sync 段已写入 settings.json（token 只落盘）',
        )

        # ④ /v1/app/config 契约：{base_url, enabled, token, token_set}
        psync = c.get('/v1/app/config').json().get('sync') or {}
        expect(
            set(psync) == {'base_url', 'enabled', 'token', 'token_set'},
            '下发 sync 键集合 = {base_url, enabled, token, token_set}（App 契约）',
            str(sorted(psync)),
        )
        expect(
            psync.get('token') == token and psync.get('token_set') is True
            and psync.get('enabled') is True
            and psync.get('base_url') == 'https://demo.supabase.co',
            '下发 sync 内容与保存值一致（token 明文随配置下发）',
            str(psync.get('base_url')),
        )

        # ⑤ 空串 = 清空
        r = c.put('/v1/admin/sync', json={'token': ''})
        body = r.json() if r.status_code == 200 else {}
        expect(
            r.status_code == 200 and body.get('token_set') is False
            and body.get('token_masked') is None,
            'PUT token="" → 清空（token_set=False）',
            str(body),
        )
        psync = c.get('/v1/app/config').json().get('sync') or {}
        expect(
            psync.get('token') is None and psync.get('token_set') is False,
            '清空后下发 sync.token=None、token_set=False',
            str(psync),
        )

        # ⑥ 缺 key = 不修改（只传 enabled，base_url 应保持）
        r = c.put('/v1/admin/sync', json={'enabled': False})
        body = r.json() if r.status_code == 200 else {}
        expect(
            body.get('enabled') is False
            and body.get('base_url') == 'https://demo.supabase.co',
            'PUT 只传 enabled → base_url 不修改（缺 key 语义）',
            str(body),
        )

        # ⑦ 类型错误 → 400 invalid_request
        for field, value in (('base_url', 123), ('enabled', 'yes'), ('token', 5)):
            rr = c.put('/v1/admin/sync', json={field: value})
            expect(
                rr.status_code == 400
                and rr.json().get('error', {}).get('code') == 'invalid_request',
                f'PUT {field} 非预期类型（{value!r}）→ 400 invalid_request',
                f'{rr.status_code} {rr.text[:80]}',
            )

        # ⑧ 持久化：重新加载 Config 后 sync 仍生效（enabled=False 已落盘）
        reloaded = Config(cfg_path)
        expect(
            reloaded.sync.get('enabled') is False
            and reloaded.sync.get('base_url') == 'https://demo.supabase.co'
            and reloaded.sync.get('token') == '',
            '重载 Config：sync 段从 settings.json 恢复（enabled=False, token 已清空）',
            str(reloaded.sync),
        )

    return state['fail'], state['total']


# ---------------------------------------------------------------- main

# ------------------------------------------------ F. T1 变体解析（TestClient）


def run_variant_resolution_checks() -> tuple[int, int]:
    """F. ``POST /v1/task`` 的 variant 解析语义（回归护栏）。

    提示词按 ``(task, variant)`` 二元组注册：T1 的 keypoints/both 变体
    front-matter 是 ``task: T1`` + ``variant: keypoints|both``，服务端
    **只从 body 读 variant**（routers/tasks.py:96）。曾经有实现把变体塞进
    任务码（``AiTask('T1.keypoints')`` → ``POST /v1/task/T1.keypoints``），
    服务端按 ``('T1.KEYPOINTS', None)`` 检索不到 → unknown_task，整条提取
    链路静默死亡。本节把两种形态的语义钉死：

    1. ``POST /v1/task/T1`` + body ``{"variant": "keypoints"}`` → 越过提示词
       解析：缺 inputs 时报 ``missing_input``（**不是** unknown_task）；
    2. 同上 ``"both"``；
    3. ``POST /v1/task/T15`` → ``missing_input``，文案含 selection/note_text；
    4. 反例：``POST /v1/task/T1.keypoints``（点号码 + 无 variant）→
       ``unknown_task``（点号形态只是 index.yaml / 本文件的逻辑键，
       **不是** URL 任务码）；
    5. ``POST /v1/task/T1`` 无 variant → 主形态仍解析成功（保旧行为）。

    探针选「缺 inputs」：``require_inputs`` 在 ``registry.get`` 之后
    （tasks.py:99 → :105），``missing_input`` 即证明提示词已解析成功，
    全程不调模型、不外网。
    """
    import tempfile

    from fastapi.testclient import TestClient

    from server import create_app

    failures = 0
    total = 0

    def expect(cond: bool, name: str, detail: str = '') -> None:
        nonlocal failures, total
        total += 1
        if cond:
            print(f'  ✅ {name}' + (f'  —— {detail}' if detail else ''))
        else:
            failures += 1
            print(f'  ❌ {name}' + (f'\n      {detail}' if detail else ''))

    d = tempfile.mkdtemp(prefix='aimindtree_variant_')
    cfg_path = Path(d) / 'config.yaml'
    cfg_path.write_text(_SAMPLE_CONFIG_YAML, encoding='utf-8')

    app = create_app(cfg_path)
    with TestClient(app) as c:

        def probe(task_code: str, variant: str | None = None):
            body: dict = {'inputs': {}}
            if variant:
                body['variant'] = variant
            return c.post(f'/v1/task/{task_code}', json=body)

        def err_of(r) -> dict:
            return (r.json().get('error') or {}) if r.status_code != 200 else {}

        def show(r) -> str:
            err = err_of(r)
            return f'{r.status_code} {err.get("code")} {str(err.get("message"))[:70]}'

        # ① keypoints 变体（body 形态）
        r = probe('T1', 'keypoints')
        err = err_of(r)
        expect(
            r.status_code == 400
                and err.get('code') == 'missing_input'
                and 'note_text' in str(err.get('message', '')),
            'T1 + variant=keypoints → 提示词解析成功（missing_input 探针）',
            show(r),
        )

        # ② both 变体（body 形态）
        r = probe('T1', 'both')
        err = err_of(r)
        expect(
            r.status_code == 400
                and err.get('code') == 'missing_input'
                and 'note_text' in str(err.get('message', '')),
            'T1 + variant=both → 提示词解析成功（missing_input 探针）',
            show(r),
        )

        # ③ T15 独立任务码（单对象契约）
        r = probe('T15')
        err = err_of(r)
        expect(
            r.status_code == 400
                and err.get('code') == 'missing_input'
                and 'selection' in str(err.get('message', ''))
                and 'note_text' in str(err.get('message', '')),
            'T15 → 提示词解析成功（missing_input 含 selection/note_text）',
            show(r),
        )

        # ④ 反例：点号任务码必须失败（变体不许塞进 URL）
        r = probe('T1.keypoints')
        err = err_of(r)
        expect(
            r.status_code == 400 and err.get('code') == 'unknown_task',
            '反例：T1.keypoints 点号任务码 → unknown_task',
            show(r),
        )

        # ⑤ 主形态不传 variant 仍解析成功（保旧行为）
        r = probe('T1')
        err = err_of(r)
        expect(
            r.status_code == 400 and err.get('code') == 'missing_input',
            'T1 无 variant → 主形态仍解析成功（保旧行为）',
            show(r),
        )

    return failures, total


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
    print('=' * 72)
    print('C. App 端 inputs ↔ front-matter inputs 双向对账（防静默丢弃）')
    print('=' * 72)
    app_failures, unwired = run_app_inputs_check(store)

    print()
    print('=' * 72)
    print('D. 管理后台（settings 覆盖层往返 + balance 结构化）')
    print('=' * 72)
    admin_failures = run_admin_checks()

    print()
    print('=' * 72)
    print('E. 同步配置（GET/PUT /v1/admin/sync + /v1/app/config 的 sync 段）')
    print('=' * 72)
    sync_failures, sync_total = run_sync_checks()

    print()
    print('=' * 72)
    print('F. T1 变体解析（POST /v1/task 的 variant 语义）')
    print('=' * 72)
    variant_failures, variant_total = run_variant_resolution_checks()

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
        f'/{len(EXPECTED_CONTRACT)} 通过（未加载 {missing}），'
        f'App 对账 {len(APP_INPUTS) - unwired - app_failures}'
        f'/{len(APP_INPUTS) - unwired} 通过（未接线 {unwired}），'
        f'管理后台 {_ADMIN_TOTAL - admin_failures}'
        f'/{_ADMIN_TOTAL} 通过，'
        f'同步配置 {sync_total - sync_failures}/{sync_total} 通过，'
        f'变体解析 {variant_total - variant_failures}/{variant_total} 通过'
    )
    print(f'耗时 {time.time() - started:.2f}s')

    if (
        repair_failures
        or contract_failures
        or app_failures
        or store.errors
        or admin_failures
        or sync_failures
        or variant_failures
    ):
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
