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
  }
}
