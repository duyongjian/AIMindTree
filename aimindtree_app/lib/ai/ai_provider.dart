/// AI Provider 统一接口（ARCHITECTURE §6）。
///
/// **协议无关**：openai / anthropic / dify 三类协议的差异全部封装在各自
/// Client 内部，归一化到 [AiChunk] / [AiTaskResult]，上层 [AiService] 不感知
/// 底层协议，靠配置（`ai_providers.protocol`）区分，可插拔不绑一家。
///
/// 接口只暴露两个方法（§6-3 接口边界）：
/// - [runTask]：一次性结构化执行（T1/T2/T3/T9/T12…）
/// - [streamChat]：多轮流式对话（T5/T6/T7/T10/T11…）
library;

import 'ai_task.dart';

/// 一次性结构化任务的统一返回。
class AiTaskResult {
  const AiTaskResult({
    required this.content,
    this.parsed,
    this.usage,
    this.latencyMs = 0,
    this.modelId,
  });

  /// 原始文本输出（如工作流 End 变量的值 / chat answer）。
  final String content;

  /// 尽力解析出的结构化结果（Map/List）；解析失败为 null。
  final Object? parsed;

  /// token 用量（P1 成本视图用）。
  final Map<String, dynamic>? usage;

  final int latencyMs;
  final String? modelId;
}

/// 流式对话的统一增量块。
///
/// 须同时容纳 OpenAI 的 delta 与 Dify 的 workflow/message 事件模型（§6）：
/// [delta] 为文本增量；[structured] 仅在终态事件携带（Dify workflow_finished）；
/// [done] 标记流结束。
class AiChunk {
  const AiChunk({
    this.delta,
    this.structured,
    this.usage,
    this.conversationId,
    this.done = false,
  });

  final String? delta;
  final Object? structured;
  final Map<String, dynamic>? usage;
  final String? conversationId;
  final bool done;
}

/// AI 供应商客户端抽象。
abstract class AiProvider {
  /// 供应商标识（对应 `ai_providers.id`）。
  String get id;

  /// 端点协议：`openai` / `anthropic` / `dify`（已停用，保留仅为回退）/
  /// `llm_server`（自研本地 LLM 服务，见 `llm_server/`）。
  String get protocol;

  /// 一次性结构化执行。
  ///
  /// Dify 实现映射 `/v1/workflows/run`（blocking，具名 inputs/outputs）；
  /// OpenAI/Anthropic 实现映射 chat completion（JSON mode + 三层保障）。
  ///
  /// [variant] 为**可选**参数，仅供「按任务装载提示词」的实现使用
  /// （如 `LlmServerClient` 用 `variant='keypoints'` 选
  /// `t1_extract__keypoints.md`，即同一任务码下的提示词变体）；
  /// 不传不影响既有实现，Dify 类实现可直接忽略。
  Future<AiTaskResult> runTask(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 900),
    String? variant,
  });

  /// 多轮流式对话。
  ///
  /// [conversationId] 为空时新建会话；返回的 [AiChunk.conversationId] 携带
  /// 新会话 id 供续聊。
  ///
  /// [task] / [variant] 为**可选**参数，仅供「按任务装载提示词」的实现使用
  /// （如 `LlmServerClient` 用 `variant='detect'` 选 `t5_ask__detect.md`）；
  /// 不传不影响既有实现，Dify 类实现可直接忽略。
  Stream<AiChunk> streamChat(
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 900),
    AiTask? task,
    String? variant,
    String? jobId,
  });

  void dispose();
}
