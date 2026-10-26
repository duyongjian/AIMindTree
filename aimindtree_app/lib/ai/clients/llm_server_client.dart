/// LLM Server 客户端（**第四类协议**，ARCHITECTURE §6）。
///
/// 与 DifyClient 的根本差别：
/// - **无密钥**：密钥由服务端 `llm_server/.env` 持有，App 只认地址；
/// - **提示词在服务端**：`POST /v1/task/{code}` 只传 `inputs`，由服务端装载
///   `prompts/*.md`、渲染 `{{占位符}}`、做六层 JSON 容错后回填 `parsed`；
/// - **真流式**：`POST /v1/chat` 返回 SSE，本类解析 `data:` 行转 [AiChunk]。
///
/// 客户端仍保留一份 [StructuredText] 解析做**双保险**（D10）：服务端 `parsed`
/// 为空时用 `content` 再解一次，避免服务端容错升级前后行为不一致。
///
/// 实测坑（继承自立 DifyClient，勿删）：
///   ① 中文 body 必须显式 UTF-8 编码（`req.add(utf8.encode(...))`），否则
///     latin1 默认编码直接抛 `Invalid argument`；
///   ② `Content-Type` 必须显式带 `charset=utf-8`；
///   ③ 推理模型会输出 `<think>` 思考块包裹 JSON，解析前必须剥离（服务端已做，
///     客户端 [StructuredText] 再兜一层）。
library;

import 'dart:convert';
import 'dart:io';

import '../ai_provider.dart';
import '../ai_task.dart';
import '../structured_parse.dart';
import '../../core/logger.dart';

/// 协议标识（`AiProvider.protocol` / `ai_providers.protocol` 列）。
const String kLlmServerProtocol = 'llm_server';

/// 默认服务地址（**不要写 `localhost`**，Windows 上 IPv6 解析会慢半拍）。
const String kLlmServerDefaultBaseUrl = 'http://127.0.0.1:8787';

/// 降级开关：`true` = `streamChat` 走 `POST /v1/chat`（`stream:false`）一次性
/// 返回，而非 SSE。仅在 SSE 被代理/防火墙破坏时打开（A-03 的 P0 兜底）。
///
/// 之所以做成**运行时字段** [LlmServerClient.blockingChat] 的默认值而不是
/// 直接写 `if (kLlmServerBlockingChat)`：后者会被静态分析判为 dead_code。
const bool kLlmServerBlockingChat = false;

/// 后端取值：`auto` = 跟随服务端 `config.yaml` 的 `default_backend`。
///
/// `llama_cpp` 是本地 llama-server（127.0.0.1:8085）的逻辑后端名，
/// 2026-10-27 起取代 ollama 成为服务端默认。名字必须与
/// `llm_server/config.yaml` 的 `backends.<name>` 一致，否则
/// `settings_repository.dart` 会把它降级成 `auto`。
const List<String> kLlmServerBackends = <String>[
  'auto',
  'llama_cpp',
  'ollama',
  'minimax',
  'openai_compat',
];

/// LLM Server 返回的错误（与服务端 `core/errors.py` 的 12 个错误码对齐）。
class LlmServerException implements Exception {
  const LlmServerException(
    this.message, {
    this.code = 'upstream_error',
    this.retryable = false,
    this.statusCode,
  });

  final String message;
  final String code;
  final bool retryable;
  final int? statusCode;

  @override
  String toString() =>
      'LlmServerException($code/${statusCode ?? '-'}): $message';
}

/// LLM 服务客户端：一个 `ai_providers` 行 = 一个本类实例。
class LlmServerClient implements AiProvider {
  LlmServerClient({
    required this.id,
    required this.baseUrl,
    this.backend = 'auto',
    this.model,
    bool? blockingChat,
    HttpClient? client,
  })  : assert(baseUrl.isNotEmpty),
        blockingChat = blockingChat ?? kLlmServerBlockingChat,
        // 只与本机 llm_server 通信：强制不走系统代理（否则本机 HTTP_PROXY 会
        // 把 127.0.0.1 请求发往代理而「假连不上」，AI 调用/队列提交失败）。
        _client = client ?? (HttpClient()..findProxy = (Uri uri) => 'DIRECT');

  @override
  final String id;

  /// 形如 `http://127.0.0.1:8787`。
  final String baseUrl;

  /// 后端名（落 `ai_providers.type` 列）：`auto` / `llama_cpp` / `ollama` /
  /// `minimax` / `openai_compat`（即 [kLlmServerBackends]）。
  /// `auto` 表示「不覆盖，跟随服务端配置」。
  final String backend;

  /// 模型覆盖（空 = 用后端默认模型）。
  final String? model;

  /// 见 [kLlmServerBlockingChat]。
  final bool blockingChat;

  final HttpClient _client;

  static final AppLog _log = AppLog('llm_server');

  @override
  String get protocol => kLlmServerProtocol;

  String get _apiBase =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  /// 显式带 `charset=utf-8`：否则 Dart 侧按 latin1 编码会导致中文 body 抛异常。
  Map<String, String> get _headers => <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
      };

  Map<String, String> get _sseHeaders => <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
      };

  // ================= AiProvider: 结构化任务 =================

  /// `POST /v1/task/{code}`。
  ///
  /// 服务端已做六层容错并回填 `parsed`；这里只在 `parsed` 为空时用
  /// [StructuredText] 再解一次（双保险，D10）。
  ///
  /// [variant] 走 **body 穿透**（与 [streamChat] 同口径）：服务端按
  /// `(task, variant)` 二元组检索提示词，所以同一任务码可以有多份提示词变体
  /// （如 T1 的 `keypoints` / `both`）。URL 里只放 `task.code`——变体不是
  /// 新任务码，写进 URL 会拼出 `/v1/task/T1.keypoints` 这种不存在的端点。
  @override
  Future<AiTaskResult> runTask(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 120),
    String? variant,
  }) async {
    final sw = Stopwatch()..start();
    final body = <String, dynamic>{
      'inputs': inputs,
      if (_backendOrNull != null) 'backend': _backendOrNull,
      if (model != null && model!.isNotEmpty) 'model': model,
      'user': user ?? 'aimindtree-app',
      'timeout_s': timeout.inSeconds,
      if (variant != null && variant.isNotEmpty) 'variant': variant,
    };
    final json = await _postJson('/v1/task/${task.code}', body, timeout);
    sw.stop();

    final content = (json['content'] as String?) ?? '';
    final parsed = json['parsed'];
    final usage = json['usage'] is Map
        ? Map<String, dynamic>.from(json['usage'] as Map)
        : null;
    final latencyMs = (json['latency_ms'] as num?)?.toInt() ?? sw.elapsedMilliseconds;
    final modelId = (json['model_id'] as String?) ?? model;

    if (parsed == null) {
      _log.w('${task.code} 服务端未给出 parsed，客户端兜底解析');
    }
    return AiTaskResult(
      content: content,
      parsed: parsed ?? StructuredText.parse(content),
      usage: usage,
      latencyMs: latencyMs,
      modelId: modelId,
    );
  }

  // ================= AiProvider: 多轮对话 =================

  /// `POST /v1/chat`（SSE 增量流）。
  ///
  /// [task] / [variant] 仅用于让服务端装载对应提示词（如 T5 的 `detect` 变体）；
  /// 不传则服务端按「纯 chat、兜底人格」处理。
  @override
  Stream<AiChunk> streamChat(
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 120),
    AiTask? task,
    String? variant,
  }) async* {
    final body = <String, dynamic>{
      'query': query,
      if (task != null) 'task': task.code,
      if (variant != null) 'variant': variant,
      if (conversationId != null && conversationId.isNotEmpty)
        'conversation_id': conversationId,
      if (_backendOrNull != null) 'backend': _backendOrNull,
      if (model != null && model!.isNotEmpty) 'model': model,
      'stream': !blockingChat,
      'user': user ?? 'aimindtree-app',
      'timeout_s': timeout.inSeconds,
    };

    if (blockingChat) {
      final json = await _postJson('/v1/chat', body, timeout);
      final content = (json['content'] as String?) ?? '';
      final parsed = json['parsed'];
      yield AiChunk(
        delta: content,
        structured: parsed,
        usage: json['usage'] is Map
            ? Map<String, dynamic>.from(json['usage'] as Map)
            : null,
        conversationId: (json['conversation_id'] as String?) ?? conversationId,
        done: true,
      );
      return;
    }

    final buf = StringBuffer();
    await for (final evt in _openSse('/v1/chat', body, timeout)) {
      final delta = evt['delta'] as String?;
      if (delta != null) {
        buf.write(delta);
        yield AiChunk(delta: delta);
        continue;
      }
      if (evt['done'] == true) {
        final parsed = evt['parsed'];
        final content = (evt['content'] as String?) ?? buf.toString();
        yield AiChunk(
          delta: null,
          structured: parsed ?? StructuredText.parse(content),
          usage: evt['usage'] is Map
              ? Map<String, dynamic>.from(evt['usage'] as Map)
              : null,
          conversationId:
              (evt['conversation_id'] as String?) ?? conversationId,
          done: true,
        );
        return;
      }
      // 终态前若服务端先抛错（非 2xx 已在 _openSse 抛过，这里是带内 error）
      if (evt['error'] is Map) {
        final e = evt['error'] as Map;
        throw LlmServerException(
          (e['message'] as String?) ?? '服务端返回错误',
          code: (e['code'] as String?) ?? 'upstream_error',
          retryable: (e['retryable'] as bool?) ?? false,
        );
      }
    }
    // 流结束却没收到 done：把累积文本当作最终结果（绝不静默丢内容）。
    yield AiChunk(
      delta: null,
      structured: StructuredText.parse(buf.toString()),
      conversationId: conversationId,
      done: true,
    );
  }

  // ================= HTTP 底层 =================

  /// `auto` 视为「不覆盖」，不写进 body。
  String? get _backendOrNull =>
      (backend.isEmpty || backend == 'auto') ? null : backend;

  /// 一次性 POST + JSON 响应；非 2xx 抛 [LlmServerException]。
  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body,
    Duration timeout,
  ) async {
    final url = Uri.parse('$_apiBase$path');
    late final HttpClientRequest req;
    try {
      req = await _client.postUrl(url).timeout(timeout);
    } on Object catch (e) {
      throw LlmServerException(
        '无法连接 LLM 服务（$_apiBase）：$e。'
        '请确认已启动 llm_server（scripts/run_llm_server.bat）。',
        code: 'backend_unreachable',
        retryable: true,
      );
    }
    _headers.forEach(req.headers.set);
    req.add(utf8.encode(jsonEncode(body)));
    late final HttpClientResponse resp;
    try {
      resp = await req.close().timeout(timeout);
    } on Object catch (e) {
      throw LlmServerException(
        'LLM 服务请求超时或中断：$e',
        code: 'backend_timeout',
        retryable: true,
      );
    }
    final payload = await resp.transform(utf8.decoder).join().timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw _errorFrom(resp.statusCode, payload);
    }
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) {
      throw LlmServerException(
        'LLM 服务返回非 JSON 对象：$payload',
        code: 'upstream_error',
        retryable: true,
        statusCode: resp.statusCode,
      );
    }
    return decoded;
  }

  /// 打开 SSE 流，逐条 yield `data:` 行里的 JSON 对象。
  ///
  /// `.timeout()` 挂在**行流**上：每收到一行就重置计时器，正好表达
  /// 「卡住超过 [timeout] 就报错」，而不是「整段必须在 timeout 内结束」。
  Stream<Map<String, dynamic>> _openSse(
    String path,
    Map<String, dynamic> body,
    Duration timeout,
  ) async* {
    final url = Uri.parse('$_apiBase$path');
    late final HttpClientRequest req;
    try {
      req = await _client.postUrl(url).timeout(timeout);
    } on Object catch (e) {
      throw LlmServerException(
        '无法连接 LLM 服务（$_apiBase）：$e',
        code: 'backend_unreachable',
        retryable: true,
      );
    }
    _sseHeaders.forEach(req.headers.set);
    req.add(utf8.encode(jsonEncode(body)));
    late final HttpClientResponse resp;
    try {
      resp = await req.close().timeout(timeout);
    } on Object catch (e) {
      throw LlmServerException(
        'LLM 服务请求超时或中断：$e',
        code: 'backend_timeout',
        retryable: true,
      );
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final payload = await resp.transform(utf8.decoder).join();
      throw _errorFrom(resp.statusCode, payload);
    }
    yield* resp
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(_parseSseLine)
        .expand(_flattenNullable)
        .timeout(
          timeout,
          onTimeout: (sink) => sink.addError(
            LlmServerException(
              'LLM 服务流式响应超过 ${timeout.inSeconds}s 无新数据',
              code: 'backend_timeout',
              retryable: true,
            ),
          ),
        );
  }

  /// `expand` 的转换器：把「可能为 null 的解析结果」压平成 0/1 个事件。
  ///
  /// （不用 `whereType` —— 当前 SDK 的 `Stream` 未暴露该方法。）
  static Iterable<Map<String, dynamic>> _flattenNullable(
    Map<String, dynamic>? m,
  ) sync* {
    if (m != null) yield m;
  }

  /// 解析一行 SSE；非 `data:` 行 / 非 JSON 返回 null（由 [_flattenNullable] 过滤）。
  static Map<String, dynamic>? _parseSseLine(String line) {
    final s = line.trim();
    if (!s.startsWith('data:')) return null;
    final payload = s.substring(5).trim();
    if (payload.isEmpty || payload == '[DONE]') return null;
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  /// 把服务端统一错误结构 `{error:{code,message,retryable}}` 转成异常。
  ///
  /// 解析不出来就退化成 `upstream_error`，**绝不把上游原始 HTML/JSON 直接抛给用户**。
  static LlmServerException _errorFrom(int status, String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map && decoded['error'] is Map) {
        final e = decoded['error'] as Map;
        return LlmServerException(
          (e['message'] as String?) ?? payload,
          code: (e['code'] as String?) ?? 'upstream_error',
          retryable: (e['retryable'] as bool?) ?? false,
          statusCode: status,
        );
      }
    } on Object {
      // 落到下面统一兜底。
    }
    final preview = payload.length <= 200 ? payload : '${payload.substring(0, 200)}…';
    return LlmServerException(
      payload.isEmpty ? 'LLM 服务返回 HTTP $status' : 'LLM 服务返回 HTTP $status：$preview',
      statusCode: status,
    );
  }

  @override
  void dispose() => _client.close(force: true);
}
