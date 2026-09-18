/// AI 任务级路由（ARCHITECTURE §6：解析优先级落在这里）。
///
/// ① 查 `ai_task_routes` 是否有该任务命中行 → 用其 provider_id 的实例；
/// ② 专属任务（T3/T4）未命中绑定 → 显式返回 `null`（禁止回落 T1 工作流）；
/// ③ 通用任务未命中 → 回落到 [fallback]（AiService 的默认供应商）；
/// ④ Provider 不可用 → 由上层降级链处理（P0：抛错给 UI 明示）。
library;

import 'ai_provider.dart';
import 'ai_task.dart';
import '../data/db/drift_database.dart';

class AiTaskRouter {
  AiTaskRouter({
    this.db,
    required this.providers,
    this.fallback,
  });

  /// 可空：纯冒烟 / 单元测试场景可传 null（直接走 ② fallback）。
  /// 真实 App 始终传入 [AppDatabase] 以启用 ① 任务级路由。
  final AppDatabase? db;

  /// 已实例化的 provider 注册表（id → 实例，对应 ai_providers.id）。
  final Map<String, AiProvider> providers;

  /// 默认供应商（③回落）。P0 通常是把唯一配置的 Dify 应用注册进来。
  final AiProvider? fallback;

  /// 必须绑定专属 provider 的任务（T3/T4）。
  ///
  /// 这些任务语义与 T1 完全不同，未命中专属绑定时**不得回落 T1**，应返回 `null`
  /// 由上层走本地兜底 / 显式报错，彻底消除「调错工作流」。
  static const Set<AiTask> _dedicated = {
    AiTask.t3Prerequisite,
    AiTask.t4GapAnalysis,
  };

  /// 解析任务 → 应使用的 Provider；无任何可用时返回 null。
  Future<AiProvider?> resolve(AiTask task) async {
    if (task.isLocalOnly) return null; // T4 纯本地，不走 Provider

    // ① 任务级绑定命中
    try {
      final database = db;
      if (database != null) {
        final row = await database.aiTaskRouteDao.findForTask(task);
        if (row != null) {
          final p = providers[row.providerId];
          if (p != null) return p;
        }
      }
    } on Object {
      // 路由表查询失败（如 DB 未初始化）不致命，走回落
    }

    // ② 专属任务（T3/T4）：未命中 / 命中但 provider 缺失 → 显式 null（禁止回落 T1）。
    if (_dedicated.contains(task)) return null;
    // ③ 通用任务：回落默认供应商。
    return fallback;
  }

  void register(AiProvider provider) => providers[provider.id] = provider;

  void dispose() {
    for (final p in providers.values) {
      p.dispose();
    }
    fallback?.dispose();
  }
}
