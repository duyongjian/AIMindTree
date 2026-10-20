/// 结构化文本解析（**与后端 `llm_server/core/json_repair.py` 逐层等价**）。
///
/// 来源：`lib/ai/clients/dify_client.dart:61-225`（`DifyResult.parseStructured`）
/// 的六层容错，1:1 搬运到独立文件，使解析能力**不再绑定任何协议实现**
/// （Dify 整段停用后仍可被 `LlmServerClient` 复用做客户端双保险，D10）。
///
/// 七层容错（实测必踩，层序不可调）：
/// - ⓪ 剥离思考块 `<think>` / `<thinking>` / `<reasoning>`，**含未闭合形态**；
/// - ① 整体就是合法 JSON（最理想路径）；
/// - ② 剥离**闭合**的 `<think>…</think>` 后再解；
/// - ③ 剥离 ` ```json … ``` ` 围栏后再解；
/// - ④ **括号配对扫描**：逐个 `{` / `[` 起点做字符串/转义感知配对，
///   取第一个「能配对且能解码」的片段（内含 ⑤ 截断抢救）；
/// - ⑥ 最后退回首尾硬切（尽力而为）。
///
/// ⚠️ **禁止事项（踩坑结论，勿删）**
/// 1. **不要用「首 `{` → 末 `}`」硬切**：思考块里若含 `{`，切片起点会落进
///    思考文字里，拼出来的串不是合法 JSON → 解析失败 → 静默返回 null →
///    上层无声退回本地兜底，AI 等于没跑。
/// 2. **不得退而求其次解析内层片段**：`{"gaps":[{"name":"力"}]}` 里的内层
///    `{"name":"力"}` 本身合法但形状不对，调用方取不到 `gaps` 却以为成功。
/// 3. 截断抢救时**绝不补全或编造内容**，只保留完整条目。
///
/// 只 import `dart:convert`：本文件刻意不依赖 `ai_task.dart` /
/// `ai_provider.dart`，保持纯函数、零耦合（也避免 `unused_import`）。
library;

import 'dart:convert';

/// 结构化文本解析工具（纯静态，私有构造）。
class StructuredText {
  const StructuredText._();

  /// 把模型输出文本尽力解析为 JSON 对象 / 数组；彻底失败返回 null（不抛）。
  ///
  /// 调用方（[AiProvider] 实现）拿到 null 时应按「AI 未产出可用结构」处理，
  /// 而不是当作空结果 —— 二者语义完全不同。
  static Object? parse(String raw) {
    final s = raw.trim();

    // ⓪ 剥离思考块（含未闭合形态）后先试一次。
    //    ⚠️ 未闭合时正则会把「标记 → 末尾」整段吃掉（宁可丢正文也不让思考块
    //    污染起点）。若因此把 JSON 也一起吃掉了（结果是空串），**绝不能就此
    //    放弃**：回退到原文继续走 ①~⑥，由括号配对扫描去救。
    //    （对应回归用例：未闭合 <think> 且块内含 `{`。）
    final noThink = stripThinkBlocks(s).trim();
    if (noThink.isNotEmpty) {
      final afterStrip = _tryDecode(noThink);
      if (afterStrip != null) return afterStrip;
    }

    // ① 整体就是合法 JSON（最理想路径）
    final direct = _tryDecode(s);
    if (direct != null) return direct;

    // ② 剥离闭合的 <think>...</think>
    var t = s
        .replaceAllMapped(
          RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
          (_) => '',
        )
        .trim();
    final afterThink = _tryDecode(t);
    if (afterThink != null) return afterThink;

    // ③ 剥离 ```json 代码块
    final fence =
        RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false);
    final m = fence.firstMatch(t);
    if (m != null) {
      final inner = m.group(1)!.trim();
      final decoded = _tryDecode(inner);
      if (decoded != null) return decoded;
      t = inner;
    }

    // ④ 扫描第一个「括号完整配对且能解码」的 JSON（关键修复）
    final scanned = _scanJson(t);
    if (scanned != null) return scanned;

    // ⓪ 的补充：④ 用的是剥离/去围栏后的 text；若那里没救回来，
    //    再拿「只剥思考块」的版本扫一次（覆盖「未闭合思考块 + 围栏」组合）。
    if (noThink.isNotEmpty && noThink != t) {
      final scannedNoThink = _scanJson(noThink);
      if (scannedNoThink != null) return scannedNoThink;
    }

    // ⑥ 最后退回首尾硬切（兼容旧行为，尽力而为）
    final start = t.indexOf(RegExp(r'[\{\[]'));
    final end = t.lastIndexOf(RegExp(r'[\}\]]'));
    if (start != -1 && end != -1 && end > start) {
      return _tryDecode(t.substring(start, end + 1));
    }
    return null;
  }

  /// 剥离 `<think>` / `<thinking>` / `<reasoning>` 思考块（**含未闭合形态**）。
  ///
  /// 与 `llm_server/core/json_repair.py::strip_think_blocks` 使用**同一套正则**：
  /// `<(think|thinking|reasoning)>[\s\S]*?(?:</(think|thinking|reasoning)>|$)`
  ///
  /// 未闭合时从标记处截到**末尾**再丢弃 —— 宁可丢正文也不让思考块污染起点
  /// （残余空串由 [parse] 的回退分支兜住，见 ⓪ 的注释）。
  static String stripThinkBlocks(String s) => s.replaceAllMapped(
        RegExp(
          r'<(think|thinking|reasoning)>[\s\S]*?(?:</(think|thinking|reasoning)>|$)',
          caseSensitive: false,
        ),
        (_) => '',
      );

  /// 尝试解码，失败返回 null（不抛）。
  static Object? _tryDecode(String s) {
    try {
      return jsonDecode(s);
    } on Object {
      return null;
    }
  }

  /// 在 [s] 中扫描第一个「括号完整配对且能解码」的 JSON 值。
  ///
  /// 逐个尝试每个 `{` / `[` 起点，用 [_matchEnd] 找到配对结束位置再解码；
  /// 这样即使前面夹着**未闭合**的 `<think>` 思考块（里面可能带 `{`）也不会被带偏。
  static Object? _scanJson(String s) {
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch != '{' && ch != '[') continue;
      final end = _matchEnd(s, i);
      if (end != -1) {
        final decoded = _tryDecode(s.substring(i, end + 1));
        if (decoded != null) return decoded;
        continue; // 能闭合但解码失败 → 多半是前面杂文里的假结构符，换下一个
      }
      // 未闭合：两种可能 —— ① 输出被 token 上限截断；② 这里根本不是 JSON 起点
      // （例如未闭合的 <think> 思考块里有个 '{'）。
      // ⚠️ 绝不能退而求其次去解析**内层片段**：
      // `{"gaps":[{"name":"力","level":1},{"name":"加速` 里内层
      // `{"name":"力","level":1}` 本身合法，但形状不对，调用方取不到 `gaps`
      // 却以为成功。所以先尝试「抢救外层」，抢救不出来才换下一个起点。
      final salvaged = _salvage(s, i);
      if (salvaged != null) return salvaged;
    }
    return null;
  }

  /// 抢救被截断的输出：截到**最后一个完整元素**，补上未闭合的括号。
  ///
  /// 只保留完整的条目，被截断的那一条直接丢弃——绝不补全或编造内容。
  static Object? _salvage(String s, int start) {
    var k = -1;
    for (var i = s.length - 1; i >= start; i--) {
      final ch = s[i];
      if (ch == '}' || ch == ']') {
        k = i;
        break;
      }
    }
    if (k == -1) return null;
    final stack = _stackAt(s, start, k);
    if (stack == null || stack.isEmpty) return null;
    final closers = stack.reversed.map((c) => c == '{' ? '}' : ']').join();
    return _tryDecode(s.substring(start, k + 1) + closers);
  }

  /// 从 [start] 扫到 [end]（含），返回扫描结束时**仍未闭合**的开括号栈；
  /// 括号不匹配返回 null。字符串内的括号不参与配对。
  static List<String>? _stackAt(String s, int start, int end) {
    final stack = <String>[];
    var inString = false;
    var escaped = false;
    for (var i = start; i <= end && i < s.length; i++) {
      final ch = s[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
        continue;
      }
      if (ch == '{' || ch == '[') {
        stack.add(ch);
        continue;
      }
      if (ch == '}' || ch == ']') {
        if (stack.isEmpty) return null;
        final open = stack.removeLast();
        if ((open == '{' && ch != '}') || (open == '[' && ch != ']')) return null;
      }
    }
    return stack;
  }

  /// 从 [start]（必须是 `{` 或 `[`）扫到配对的 `}` / `]`，返回其下标；
  /// 未闭合返回 -1。正确处理字符串与转义，避免把字符串里的括号当成结构符号。
  static int _matchEnd(String s, int start) {
    final stack = <String>[];
    var inString = false;
    var escaped = false;
    for (var i = start; i < s.length; i++) {
      final ch = s[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
        continue;
      }
      if (ch == '{' || ch == '[') {
        stack.add(ch);
        continue;
      }
      if (ch == '}' || ch == ']') {
        if (stack.isEmpty) return -1;
        final open = stack.removeLast();
        if ((open == '{' && ch != '}') || (open == '[' && ch != ']')) return -1;
        if (stack.isEmpty) return i;
      }
    }
    return -1;
  }
}
