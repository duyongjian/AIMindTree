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

/// 给 [treeId] 里 [newIds] 这批新并入的知识点算布局坐标并写回，**并避让已有节点**。
///
/// 与旧版的关键差异：不再「用全树重排一次再取新点坐标」——那样新点会落到布局
/// 引擎为「全量重排」预留的格子上，而旧节点若被手动拖走过，新点就会叠在它们身上。
/// 现在改为：
/// 1. 取已有（非新）成员的**真实当前坐标**当作占位矩形 [LayoutBox]；
/// 2. 只对**新点集合内部**跑 [layoutForest]，得到一个以 (0,0) 为基准的子布局；
/// 3. 用 [findFreeBlockTopLeft] 给这个子布局整块选一个不与占位矩形相交的左上角；
/// 4. 逐点写回 `snapToGrid(块左上角 + 子布局坐标)`（pinned=false，浮动可再铺）。
Future<void> autoPlaceNewPointsInTree({
  required AppDatabase db,
  required TreeRepository trees,
  required KnowledgeRepository repo,
  required String treeId,
  required List<String> newIds,
}) async {
  if (newIds.isEmpty) return;
  final newIdSet = newIds.toSet();

  const config = LayoutConfig();

  // 1) 已有成员的真实坐标 → 占位矩形。只统计「已固化位置」的旧成员：
  //    没固化过的点交给布局引擎，不占位（否则会以为它在 (0,0) 挡住新点）。
  final memberIds = await trees.memberPointIds(treeId);
  final existingLayout = await repo.loadNodeLayout(treeId);
  final occupied = <LayoutBox>[];
  for (final id in memberIds) {
    if (newIdSet.contains(id)) continue; // 新点自身不算占位
    final pos = existingLayout[id];
    // 没有行、或坐标恰为 (0,0)：都视为「尚未布局」，不占位。
    // 口径与 TreeCanvas._syncSavedPositions 一致 —— TreeRepository.addPoints 写出的
    // 新成员 x/y 默认 0，若把 (0,0) 当成「放在原点」，就会凭空在原点造出一个幽灵
    // 节点，把整块新点无谓地往下推。只有真正固化过坐标（非 (0,0)）的旧成员才算占位。
    if (pos == null) continue;
    if (pos.x == 0 && pos.y == 0) continue;
    occupied.add(
        LayoutBox(pos.x, pos.y, config.nodeWidth, config.nodeHeight));
  }

  // 2) 只对「新点集合内部」跑布局：新点之间的前置边决定它们的相对层级/顺序。
  final newPts = await repo.pointsByIds(newIds);
  final allEdges = await (db.select(db.prerequisiteEdges)).get();
  final newInternalEdges = allEdges
      .where((e) =>
          newIdSet.contains(e.fromKpId) && newIdSet.contains(e.toKpId))
      .map((e) => PrerequisiteEdge(
            id: e.id,
            fromKpId: e.fromKpId,
            toKpId: e.toKpId,
            reason: e.reason,
            origin: e.origin,
            confidence: e.confidence,
          ))
      .toList();

  final layout = layoutForest(newPts, newInternalEdges, config: config);
  final posById = <String, LaidOutNode>{for (final n in layout.nodes) n.kpId: n};

  // 3) 子布局整体块的尺寸（以 (0,0) 为基准，每层一行）。
  var blockWidth = config.nodeWidth;
  var blockHeight = config.nodeHeight;
  for (final n in layout.nodes) {
    final w = n.x + config.nodeWidth;
    final h = n.y + config.nodeHeight;
    if (w > blockWidth) blockWidth = w;
    if (h > blockHeight) blockHeight = h;
  }

  // 首选左上角：贴近已有内容下方且与最左缘对齐；无旧节点则从原点开始。
  // 若该位置与旧节点相交，[findFreeBlockTopLeft] 会把整块推到占用集合下方。
  final preferredLeft = occupied.isEmpty
      ? 0.0
      : occupied.map((b) => b.left).reduce((a, b) => a < b ? a : b);
  final preferredTop = occupied.isEmpty
      ? 0.0
      : occupied.map((b) => b.bottom).reduce((a, b) => a > b ? a : b) +
          config.vGap;

  final free = findFreeBlockTopLeft(
    blockWidth: blockWidth,
    blockHeight: blockHeight,
    occupied: occupied,
    preferredLeft: preferredLeft,
    preferredTop: preferredTop,
    step: config.gridSize > 0 ? config.gridSize : 20,
  );

  // 4) 逐点写回。新并入的点默认「浮动」（pinned=false）：结构变化时仍可被布局引擎
  //    重新铺位，只有用户手动拖拽后才会被锁定（见 CanvasPage._onMoveNode）。
  for (final id in newIds) {
    final n = posById[id];
    if (n == null) continue;
    await repo.saveNodePosition(
      treeId,
      id,
      snapToGrid(free.left + n.x, config.gridSize),
      snapToGrid(free.top + n.y, config.gridSize),
      pinned: false,
    );
  }
}
