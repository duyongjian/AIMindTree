/// AI 任务级路由 DAO（T04，起因：Dify Key 按应用签发，§6）。
///
/// 解析优先级在 [AiTaskRouter]：
/// ① `ai_task_routes` 命中该任务 → 用其 provider；
/// ② 未命中 → 回落 AiService 默认供应商。
/// OpenAI/Anthropic/Ollama 一把 Key 通吃，无需建行；只有 Dify 多应用才需要。
library;

import 'package:drift/drift.dart';

import '../../ai/ai_task.dart';
import '../db/drift_database.dart';
import '../db/tables.dart';

part 'ai_task_route_dao.g.dart';

@DriftAccessor(tables: [AiTaskRoutes])
class AiTaskRouteDao extends DatabaseAccessor<AppDatabase>
    with _$AiTaskRouteDaoMixin {
  AiTaskRouteDao(super.db);

  /// 查该任务的路由绑定；未配置返回 null（走默认回落）。
  Future<AiTaskRouteRow?> findForTask(AiTask task) async {
    final rows =
        await (select(attachedDatabase.aiTaskRoutes)
              ..where((t) => t.aiTask.equals(task.code))
              ..limit(1))
            .get();
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<AiTaskRouteRow>> all() =>
      select(attachedDatabase.aiTaskRoutes).get();

  /// 绑定（同任务重复绑定即覆盖语义：先删后插）。
  Future<void> bind({
    required AiTask task,
    required String providerId,
    String? apiKeyRefOverride,
    String? endpointOverride,
  }) async {
    await (delete(
      attachedDatabase.aiTaskRoutes,
    )..where((t) => t.aiTask.equals(task.code))).go();
    await into(attachedDatabase.aiTaskRoutes).insert(
      AiTaskRoutesCompanion(
        id: Value(task.code),
        aiTask: Value(task.code),
        providerId: Value(providerId),
        apiKeyRefOverride: Value(apiKeyRefOverride),
        endpointOverride: Value(endpointOverride),
      ),
    );
  }

  Future<void> unbind(AiTask task) => (delete(
    attachedDatabase.aiTaskRoutes,
  )..where((t) => t.aiTask.equals(task.code))).go();

  /// 解绑指向某 provider 的所有任务（删除 provider 时调用，避免悬挂引用）。
  ///
  /// 悬挂引用的后果：`resolve` 命中路由但 `providers[providerId]` 为 null，
  /// 通用任务会静默回落、T3/T4 直接返回 null —— 比「未绑定」更难排查。
  Future<int> unbindProvider(String providerId) => (delete(
    attachedDatabase.aiTaskRoutes,
  )..where((t) => t.providerId.equals(providerId))).go();
}
