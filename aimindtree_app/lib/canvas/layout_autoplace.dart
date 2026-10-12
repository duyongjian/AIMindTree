/// 把「刚并入知识树、还没摆位置」的知识点用布局引擎算不重叠坐标并写回 DB。
///
/// 抽成模块级函数，供两处共用，避免逻辑漂移：
/// - [CanvasPage._autoPlaceNewPoints]：批量补前置后铺开新点；
/// - [AgentPage]：对话中把检测到的知识点加入知识树后铺开新点。
///
/// 根因：TreeRepository.addPoints 写出的 canvas_nodes 行 x/y 默认 0，布局引擎
/// 会把「库里有位置 (0,0)」当成「已放在原点」，导致新点全挤在 (0,0)、也拖不动。
library;

import '../data/db/drift_database.dart';
import '../data/models/knowledge_point.dart';
import '../data/repositories/knowledge_repository.dart';
import '../data/repositories/tree_repository.dart';
import 'render/layout_engine.dart';

/// 给 [treeId] 里 [newIds] 这批新并入的知识点算布局坐标并写回。
///
/// 只对 [newIds] 落坐标（已手动摆过的旧节点不动），用全树成员 + 全树内部边
/// 跑一次 [layoutForest] 得到稳定坐标。
Future<void> autoPlaceNewPointsInTree({
  required AppDatabase db,
  required TreeRepository trees,
  required KnowledgeRepository repo,
  required String treeId,
  required List<String> newIds,
}) async {
  if (newIds.isEmpty) return;
  final memberIds = await trees.memberPointIds(treeId);
  final pts = await repo.pointsByIds(memberIds);
  final allEdges = await (db.select(db.prerequisiteEdges)).get();
  final treeEdges = allEdges
      .where((e) =>
          memberIds.contains(e.fromKpId) && memberIds.contains(e.toKpId))
      .map((e) => PrerequisiteEdge(
            id: e.id,
            fromKpId: e.fromKpId,
            toKpId: e.toKpId,
            reason: e.reason,
            origin: e.origin,
            confidence: e.confidence,
          ))
      .toList();
  final layout = layoutForest(pts, treeEdges, config: const LayoutConfig());
  final posById = <String, LaidOutNode>{for (final n in layout.nodes) n.kpId: n};
  for (final id in newIds) {
    final n = posById[id];
    // 新并入的点默认「浮动」（pinned=false）：结构变化时仍可被布局引擎重新铺位，
    // 只有用户手动拖拽后才会被锁定（见 CanvasPage._onMoveNode）。
    if (n != null) {
      await repo.saveNodePosition(treeId, id, n.x, n.y, pinned: false);
    }
  }
}
