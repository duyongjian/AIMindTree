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
    NoteAssets,
    KnowledgePoints,
    PrerequisiteEdges,
    MasteryRecords,
    Cards,
    Canvases,
    CanvasNodes,
    CanvasEdges,
    CanvasCards,
    CanvasStrokes,
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
  int get schemaVersion => 8;

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
          // v4 → v5：知识点「置顶 + 创建时间」+ 笔记附件表（富文本图片）。
          if (from < 5) {
            await m.addColumn(knowledgePoints, knowledgePoints.pinned);
            await m.addColumn(knowledgePoints, knowledgePoints.createdAt);
            // 历史行没有创建时间：用「当时已知的更新时间」近似（比 epoch 1970 合理得多）。
            // ⚠️ 这是不可逆的近似值，真实创建时间无法还原。
            await m.database.customStatement(
              'UPDATE knowledge_points SET created_at = updated_at WHERE created_at IS NULL',
            );
            await m.createTable(noteAssets);
          }
          // v5 → v6（★2.0.0）：新增「画布自由文本卡片」与「画布手写笔迹」
          // 两张带 SyncMeta 的表，支撑无限画布放置更多组件。
          if (from < 6) {
            await m.createTable(canvasCards);
            await m.createTable(canvasStrokes);
          }
          // v6 → v7（Phase 1 地基）：homeworks 表补 4 列（知识点外键 / 批量键 /
          // 状态 / 截止时间），支撑作业与知识点关联 + 批量布置。
          // 均为可空或带默认，addColumn 自动回填历史行（status 默认 'assigned'）。
          if (from < 7) {
            await m.addColumn(homeworks, homeworks.kpId);
            await m.addColumn(homeworks, homeworks.batchId);
            await m.addColumn(homeworks, homeworks.status);
            await m.addColumn(homeworks, homeworks.dueAt);
          }
          // v7 → v8（笔记置顶 + 文件夹置顶）：notes 与 notebooks 各加一个
          // `pinned` 布尔列（默认 false）。非空布尔带默认值，addColumn 自动回填
          // 历史行；与 v4 节点置顶、v5 知识点置顶同范式。
          if (from < 8) {
            await m.addColumn(notes, notes.pinned);
            await m.addColumn(notebooks, notebooks.pinned);
          }
        },
      );

  /// 生产连接：应用文档目录下的 `aimindtree.sqlite`。
  static QueryExecutor _openConnection() => driftDatabase(name: 'aimindtree');
}
