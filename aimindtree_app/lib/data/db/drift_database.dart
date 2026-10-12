/// Drift 数据库（T01 基础设施 + T02 数据层入口）。
///
/// - 连接由 `drift_flutter` 统一处理（Native 走 sqlite3，Web 走 drift/wasm），跨端一致。
/// - 允许注入 [QueryExecutor]，测试中用内存库（NativeDatabase.memory()）替换，无需改业务代码。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../daos/ai_task_route_dao.dart';
import 'tables.dart';

part 'drift_database.g.dart';

@DriftDatabase(
  tables: [
    Notebooks,
    Notes,
    KnowledgePoints,
    PrerequisiteEdges,
    MasteryRecords,
    Cards,
    Canvases,
    CanvasNodes,
    CanvasEdges,
    KpGroups,
    Homeworks,
    AiSessions,
    AiMessages,
    AiProviders,
    AiTaskRoutes,
    SyncOutbox,
  ],
  daos: [AiTaskRouteDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          // v1 → v2：新增「知识点分组」表（KpGroups）。
          if (from < 2) {
            await m.createTable(kpGroups);
          }
          // v2 → v3：新增「作业」表（Homeworks）。
          // ⚠️ 已升到 3 之后别再改这条分支，后续迁移用 `from < 4` 新开一段。
          if (from < 3) {
            await m.createTable(homeworks);
          }
          // v3 → v4：给画布节点表（CanvasNodes）加 `pinned` 列（自动布局锁定开关）。
          // 非空布尔带默认值，drift 的 addColumn 会自动回填历史行。
          if (from < 4) {
            await m.addColumn(canvasNodes, canvasNodes.pinned);
          }
        },
      );

  /// 生产连接：应用文档目录下的 `aimindtree.sqlite`。
  static QueryExecutor _openConnection() => driftDatabase(name: 'aimindtree');
}
