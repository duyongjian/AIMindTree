/// AiService：15 类任务的统一入口（ARCHITECTURE §6）。
///
/// 职责：按 [AiTask] 选调用形态（runTask / streamChat）、经 [AiTaskRouter]
/// 路由到具体 Provider、结构化输出解析兜底（三层保障的轻量实现）。
/// 上层（ExtractionService / UI）只面对 AiService，不感知协议与供应商。
library;

import 'ai_provider.dart';
import 'ai_task.dart';
import 'ai_task_router.dart';
import '../core/logger.dart';
import '../core/result.dart';
import 'llm_channel.dart';

class AiService {
  AiService({required this.router, AiProvider? defaultProvider})
      : fallback = defaultProvider ?? router.fallback;

  final AiTaskRouter router;
  final AiProvider? fallback;

  static final AppLog _log = AppLog('ai_service');

  /// 一次性结构化任务（T1/T2/T3/T9/T12…）。
  ///
  /// [variant] 为**可选**参数，仅供「按任务装载提示词」的实现使用
  /// （如 `LlmServerClient` 用 `variant='keypoints'` 选
  /// `t1_extract__keypoints.md`，即同一任务码下的提示词变体）；
  /// 不传不影响既有实现。
  Future<Result<AiTaskResult>> run(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 900),
    String? variant,
  }) async {
    if (task.isLocalOnly) {
      return Failure(ArgumentError('${task.code} 是纯本地任务，不走 AiService'));
    }
    if (!task.structured) {
      return Failure(ArgumentError(
          '${task.code} 是会话类任务，请用 chat()/streamChat'));
    }

    final provider = await router.resolve(task);
    if (provider == null) {
      // 设置页已不再有 Provider 增删改 UI（已迁至管理后台），所以引导文案
      // 指向「AI 服务状态」与「管理后台」，不再指向已移除的配置页。
      return Failure(StateError(
        'AI 服务未连接。请在「设置 → AI 服务状态」点重新连接，'
        '或打开管理后台检查配置。',
      ));
    }

    // 全局单通道：一次只放一个请求到模型（见 llm_channel.dart 顶部说明）。
    final ticket = await LlmChannel.instance.acquire(label: _channelLabel(task));
    try {
      var result = await provider.runTask(task, inputs,
          user: user, timeout: timeout, variant: variant);

      // 三层保障（轻量）：结构化任务解析失败 → 原样重跑一次。
      // Dify 工作流的输出契约由工作流定义保证，这里只兜模型偶发抽风。
      if (result.parsed == null) {
        _log.w('${task.code} 首次输出解析失败，重试一次');
        result = await provider.runTask(task, inputs,
            user: user, timeout: timeout, variant: variant);
      }
      return Success(result);
    } on Object catch (e, s) {
      _log.e('${task.code} 执行失败（${provider.id}）',
          error: e, stackTrace: s);
      return Failure(e, s);
    } finally {
      ticket.release();
    }
  }

  /// 多轮对话任务（T5/T6/T7/T10/T11）。
  Stream<AiChunk> chat(
    AiTask task,
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 900),
    String? variant,
  }) async* {
    // 全局单通道（FIFO）：真正的模型请求一次只放一个。
    //
    // 若本方法运行在某个 `runDetached` 执行体内（zone 带 kLlmChannelZoneKey），
    // 通道已由那个任务持有，[LlmChannel.acquire] 会直接发免排队票 ——
    // 这既避免了自锁，也保证一个后台任务的多段生成不会在中途被别人插队。
    final ticket = await LlmChannel.instance.acquire(label: _channelLabel(task));
    try {
      final provider = await router.resolve(task) ?? fallback;
      if (provider == null) {
        throw StateError(
          'AI 服务未连接。请在「设置 → AI 服务状态」点重新连接，'
          '或打开管理后台检查配置。',
        );
      }
      yield* provider.streamChat(
        query,
        conversationId: conversationId,
        user: user,
        timeout: timeout,
        task: task,
        variant: variant,
      );
    } finally {
      // `await for` 被 break / 订阅被取消时，async* 的 finally 一定会跑到，
      // 通道不会因为调用方提前退订而永久泄漏。
      ticket.release();
    }
  }

  /// 通道上显示的任务名（托盘「当前：xxx」用它）。
  static String _channelLabel(AiTask task) => switch (task) {
        AiTask.t5Ask => 'AI 问答',
        AiTask.t6Explain => '老师讲解',
        _ => task.code,
      };
}
