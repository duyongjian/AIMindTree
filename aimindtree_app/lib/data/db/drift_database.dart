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
  int get schemaVersion => 1;

  /// 生产连接：应用文档目录下的 `aimindtree.sqlite`。
  static QueryExecutor _openConnection() => driftDatabase(name: 'aimindtree');
}
