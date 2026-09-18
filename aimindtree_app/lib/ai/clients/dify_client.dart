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
  /// 三层容错（实测必踩）：
  /// - 推理模型（DeepSeek-R1 / Qwen 等）在 JSON 前加 `<think>...</think>`；
  /// - 模型偶尔用 ` ```json ... ``` ` 包裹；
  /// - 前后可能夹带无关文字。
  static Object? parseStructured(String raw) {
    var s = raw.trim();
    s = s
        .replaceAllMapped(
          RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
          (_) => '',
        )
        .trim();
    final fence =
        RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false);
    final m = fence.firstMatch(s);
    if (m != null) s = m.group(1)!.trim();
    final start = s.indexOf(RegExp(r'[\{\[]'));
    final end = s.lastIndexOf(RegExp(r'[\}\]]'));
    if (start != -1 && end != -1 && end > start) {
      s = s.substring(start, end + 1);
    }
    try {
      return jsonDecode(s);
    } on Object {
      return null;
    }
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
