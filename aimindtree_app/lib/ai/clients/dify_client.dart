/// Dify 客户端（第三类 AI 后端，ARCHITECTURE §6）。
///
/// - 一个 Dify 应用 = 一条 `ai_providers` 行 = 一个本类实例（自带 base_url +
///   appApiKey，**应用级 Key，非账号 Key**）。
/// - `runTask` → `POST /v1/workflows/run`（blocking，具名 inputs/outputs，
///   T1/T2/T3/T9 等结构化任务）。
/// - `streamChat` → `POST /v1/chat-messages`（T5/T6/T7/T10/T11 多轮对话）。
///   P0 为 blocking 单块实现，SSE 增量流在 T05/T06 UI 接入时升级。
/// - 安全边界（§6-5）：本地 Dify 直连仅限桌面端开发期；公网 Dify 一律走
///   supabase ai-proxy，Web 端不支持直连本地 Dify（CORS）。
/// - 实测坑（已内置防御，勿删）：
///   ① `/v1/workflows/run` 必填 `user`；
///   ② 中文 body 必须显式 UTF-8 编码（`req.add(utf8.encode(...))`），否则
///     latin1 默认编码直接抛 `Invalid argument`；
///   ③ 推理模型会输出 `<think>...</think>` 思考块包裹 JSON，解析前必须剥离。
library;

import 'dart:convert';
import 'dart:io';

import '../ai_provider.dart';
import '../ai_task.dart';

/// Dify 返回的统一结构（结构化任务）。
class DifyResult {
  const DifyResult({
    required this.raw,
    required this.parsed,
    this.workflowRunId,
    this.elapsedMs = 0,
  });

  final String raw;
  final Object? parsed;
  final String? workflowRunId;
  final int elapsedMs;

  factory DifyResult.fromRaw(String raw,
      {String? workflowRunId, int elapsedMs = 0}) {
    return DifyResult(
      raw: raw,
      parsed: parseStructured(raw),
      workflowRunId: workflowRunId,
      elapsedMs: elapsedMs,
    );
  }

  /// 把 Dify 的结构化输出文本解析为 JSON。
  ///
  /// 四层容错（实测必踩）：
  /// - 推理模型（DeepSeek-R1 / Qwen 等）在 JSON 前加 `<think>...</think>`，
  ///   且**可能不闭合**；
  /// - 模型偶尔用 ` ```json ... ``` ` 包裹；
  /// - 前后可能夹带无关文字；
  /// - 输出偶尔被 token 上限截断（JSON 不闭合）。
  ///
  /// ⚠️ **不要用「首 `{` → 末 `}`」硬切**（旧实现，已踩坑）：思考块里若含 `{`，
  /// 切片起点会落进思考文字里，拼出来的串不是合法 JSON，解析直接失败 →
  /// 静默返回 null → 上层无声退回本地兜底，AI 等于没跑。
  /// 正确做法是 [_scanJson]：逐个起点做**括号配对**，配对成功才解码。
  static Object? parseStructured(String raw) {
    var s = raw.trim();

    // ① 整体就是合法 JSON（最理想路径）
    final direct = _tryDecode(s);
    if (direct != null) return direct;

    // ② 剥离闭合的 <think>...</think>
    s = s
        .replaceAllMapped(
          RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
          (_) => '',
        )
        .trim();
    final afterThink = _tryDecode(s);
    if (afterThink != null) return afterThink;

    // ③ 剥离 ```json 代码块
    final fence =
        RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false);
    final m = fence.firstMatch(s);
    if (m != null) {
      final inner = m.group(1)!.trim();
      final decoded = _tryDecode(inner);
      if (decoded != null) return decoded;
      s = inner;
    }

    // ④ 扫描第一个「括号完整配对且能解码」的 JSON（关键修复）
    final scanned = _scanJson(s);
    if (scanned != null) return scanned;

    // ⑤ 最后退回首尾硬切（兼容旧行为，尽力而为）
    final start = s.indexOf(RegExp(r'[\{\[]'));
    final end = s.lastIndexOf(RegExp(r'[\}\]]'));
    if (start != -1 && end != -1 && end > start) {
      return _tryDecode(s.substring(start, end + 1));
    }
    return null;
  }

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

/// Dify 调用异常，便于上层做降级（§6-4 降级链）。
class DifyException implements Exception {
  const DifyException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;
  @override
  String toString() => 'DifyException($statusCode): $message';
}

/// 各任务的默认输出变量名（约定 inputs/outputs 命名，§6-工作流配置模型）。
///
/// - T1：知识点列表；
/// - T3：前置关系（DSL 契约见 scripts/dify_t3_prerequisite.yaml）；
/// - T4：缺口建议（DSL 契约见 scripts/dify_t4_gap_analysis.yaml）。
const _taskOutputKey = <AiTask, String>{
  AiTask.t1Extract: 'knowledge_points',
  AiTask.t3Prerequisite: 'prerequisites',
  AiTask.t4GapAnalysis: 'gaps',
};

/// Dify 应用客户端。
class DifyClient implements AiProvider {
  DifyClient({
    required this.id,
    required this.baseUrl,
    required this.appApiKey,
    this.model,
    this.isLocal = true,
    HttpClient? client,
  })  : assert(baseUrl.isNotEmpty),
        assert(appApiKey.isNotEmpty),
        _client = client ?? HttpClient();

  @override
  final String id;

  /// 形如 `http://localhost:8080`（nginx 端口，非容器内部 5001）。
  final String baseUrl;

  /// 该 Dify 应用的 API Key（应用 → 访问 API 处获取）。
  final String appApiKey;

  final String? model;

  /// 是否本地部署（本地仅限桌面端开发期直连）。
  final bool isLocal;

  final HttpClient _client;

  @override
  String get protocol => 'dify';

  String get _apiBase =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $appApiKey',
        // 必须声明 charset，否则 Dart 侧按 latin1 编码会导致中文 body 抛异常。
        'Content-Type': 'application/json; charset=utf-8',
      };

  // ================= AiProvider: 结构化任务 =================

  @override
  Future<AiTaskResult> runTask(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final r = await runWorkflow(
      inputs,
      outputKey: _taskOutputKey[task],
      user: user ?? 'aimindtree-app',
      timeout: timeout,
    );
    return AiTaskResult(
      content: r.raw,
      parsed: r.parsed,
      latencyMs: r.elapsedMs,
      modelId: model,
    );
  }

  // ================= AiProvider: 多轮对话 =================

  /// P0：blocking 单块实现；SSE 增量流在 T05/T06 接入时升级（§6）。
  @override
  Stream<AiChunk> streamChat(
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 120),
  }) async* {
    final (answer, cid) = await chatMessages(
      query,
      conversationId: conversationId,
      user: user ?? 'aimindtree-app',
      timeout: timeout,
    );
    yield AiChunk(delta: answer, conversationId: cid, done: true);
  }

  // ================= Dify 原生端点 =================

  /// 运行 Workflow（T1/T2/T3/T9）。[inputs] 为工作流定义的具名输入变量。
  Future<DifyResult> runWorkflow(
    Map<String, dynamic> inputs, {
    String? outputKey,
    String user = 'aimindtree-app',
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final url = Uri.parse('$_apiBase/v1/workflows/run');
    final body = jsonEncode({
      'inputs': inputs,
      'response_mode': 'blocking',
      'user': user,
      if (model != null) 'model': model,
    });

    final sw = Stopwatch()..start();
    late final HttpClientRequest req;
    try {
      req = await _client.postUrl(url).timeout(timeout);
    } on Object catch (e) {
      throw DifyException('无法连接 Dify（$baseUrl）：$e');
    }
    _headers.forEach(req.headers.set);
    req.add(utf8.encode(body));
    late final HttpClientResponse resp;
    try {
      resp = await req.close().timeout(timeout);
    } on Object catch (e) {
      throw DifyException('Dify 请求超时或中断：$e');
    }
    final payload = await resp.transform(utf8.decoder).join();
    sw.stop();

    if (resp.statusCode != 200) {
      throw DifyException(
        _friendlyError(resp.statusCode, payload),
        resp.statusCode,
      );
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(payload) as Map<String, dynamic>;
    } on Object {
      throw DifyException('Dify 返回非 JSON：$payload');
    }

    final data = json['data'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final outputs =
        data['outputs'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final runId = data['id'] as String?;

    final String raw;
    if (outputKey != null && outputs.containsKey(outputKey)) {
      final v = outputs[outputKey];
      raw = v is String ? v : jsonEncode(v);
    } else if (outputs.isNotEmpty) {
      final first = outputs.entries.first.value;
      raw = first is String ? first : jsonEncode(first);
    } else {
      raw = payload;
    }

    return DifyResult.fromRaw(raw,
        workflowRunId: runId, elapsedMs: sw.elapsedMilliseconds);
  }

  /// 把 Dify 的常见 HTTP 错误翻译成可操作的中文提示（避免甩原始 JSON/HTML 给用户）。
  String _friendlyError(int code, String payload) {
    // 400 invalid_param：最常见的是输入字段被建成「短文本」（平台级 256 上限）。
    if (code == 400 && payload.contains('invalid_param')) {
      final msg =
          RegExp(r'"message"\s*:\s*"([^"]*)"').firstMatch(payload)?.group(1) ??
              payload;
      if (msg.contains('must be less than')) {
        final cap = RegExp(r'less than (\d+) characters').firstMatch(msg)?.group(1);
        return '工作流输入字段超长（上限 ${cap ?? 256} 字符）。'
            '修复：打开 Dify → 对应工作流 → 「开始」节点 → 把该输入字段的类型从'
            '「短文本」改为「段落（Paragraph）」→ 保存并发布（API 只用已发布版本）。'
            '原始错误：$msg';
      }
      return 'Dify 工作流参数无效：$msg';
    }
    // 502/503：nginx 活着但上游 api 容器没就绪（Dify 冷启动约 1-2 分钟）。
    if (code == 502 || code == 503) {
      return 'Dify 服务还没就绪（nginx 已启动，但 api 容器未就绪，冷启动约 1-2 分钟），'
          '请稍候在设置页「测试连接」或重试当前操作。';
    }
    return 'Dify workflows/run 返回 $code：$payload';
  }

  /// 多轮对话（blocking）。[conversationId] 为空时 Dify 新建会话。
  Future<(String answer, String conversationId)> chatMessages(
    String query, {
    String? conversationId,
    String user = 'aimindtree-app',
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final url = Uri.parse('$_apiBase/v1/chat-messages');
    final body = jsonEncode({
      'inputs': <String, dynamic>{},
      'query': query,
      'response_mode': 'blocking',
      'conversation_id': conversationId ?? '',
      'user': user,
      if (model != null) 'model': model,
    });

    late final HttpClientRequest req;
    try {
      req = await _client.postUrl(url);
    } on Object catch (e) {
      throw DifyException('无法连接 Dify（$baseUrl）：$e');
    }
    _headers.forEach(req.headers.set);
    req.add(utf8.encode(body));
    final resp = await req.close().timeout(timeout);
    final payload = await resp.transform(utf8.decoder).join();

    if (resp.statusCode != 200) {
      throw DifyException(
        'Dify chat-messages 返回 ${resp.statusCode}：$payload',
        resp.statusCode,
      );
    }
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final answer = (json['answer'] as String?) ?? '';
    final newCid = (json['conversation_id'] as String?) ?? conversationId ?? '';
    return (answer, newCid);
  }

  @override
  void dispose() => _client.close(force: true);
}
