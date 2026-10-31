/// AI 不可用时的空对象（Null Object，AC-18 / D5）。
///
/// 存在的理由：`AiTaskRouter.fallback` 是**非空** `AiProvider`，而 C11 禁止改
/// `AiTaskRouter.resolve`。与其把 `fallback` 改成可空（会波及 `AiService` /
/// 各业务页），不如给一个「什么都不做、只报未连接」的实现：`AiService.run`
/// 已有 `try/on Object` 会把它转成 `Failure(StateError)`，上层 UI 行为与
/// 「服务宕机」一致 —— 笔记 / 画布 / 离线功能完全不受影响。
library;

import 'ai_provider.dart';
import 'ai_task.dart';

/// 永远「不可用」的 Provider。
class UnavailableAiProvider implements AiProvider {
  UnavailableAiProvider([this.reason = 'AI 服务未连接']);

  /// 展示给用户的原始原因（会被包装成完整引导句）。
  final String reason;

  /// 完整引导文案（去掉「在设置里配置 Provider」这种已失效的引导）。
  String get _message =>
      '$reason。请在「设置 → AI 服务状态」点重新连接，或打开管理后台检查配置。';

  @override
  String get id => 'unavailable';

  @override
  String get protocol => 'unavailable';

  @override
  Future<AiTaskResult> runTask(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 900),
    String? variant,
  }) async {
    throw StateError(_message);
  }

  @override
  Stream<AiChunk> streamChat(
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 900),
    AiTask? task,
    String? variant,
    String? jobId,
  }) async* {
    throw StateError(_message);
  }

  @override
  void dispose() {}
}
