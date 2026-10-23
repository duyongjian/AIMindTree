/// 把一批知识点按「源树里的相对坐标」整体搬到目标树。
///
/// 与 [autoPlaceNewPointsInTree] 的区别：那个是**重新布局**（layoutForest 重算
/// 相对位置），本函数是**原样平移**——保持这批点在源树里的相互位置关系，
/// 只整体挪到目标树内容下方的空白区。
///
/// 连线无需搬运：画布渲染的边来自全局 `prerequisite_edges`（按两端都在当前树
/// 成员里过滤），两端点进了同一棵树，线会自动出现。
library;

import 'dart:math' as math;

import '../data/repositories/knowledge_repository.dart';
import '../data/repositories/tree_repository.dart';
import 'render/layout_engine.dart';

/// 把 [kpIds] 这批（已并入 [targetTreeId] 的）知识点按源树 [sourceTreeId] 里的
/// 相对坐标整块平移落位，避开目标树已有内容。
///
/// 规则：
/// 1. 目标树已有成员（排除本次这批）中「坐标非 (0,0)」的按节点尺寸占位；
/// 2. 源树里有坐标的点 → 以这批点的最小 x/y 为原点取相对坐标，块尺寸按包围盒算；
/// 3. 源树里没坐标（无行 / (0,0)）的点 → 按网格追加到块**下方**，绝不堆在块原点；
/// 4. 用 [findFreeBlockTopLeft] 给整块选一个不与占位相交的左上角（首选目标树内容
///    下方、与最左缘对齐），再逐点写回 `snapToGrid(块左上角 + 相对坐标)`。
///
/// 写回一律 `pinned: false`（新点浮动）——与 [autoPlaceNewPointsInTree] 一致，
/// 用户手动拖拽后才会被锁定。
Future<void> placeTransferredPointsInTree({
  required TreeRepository trees,
  required KnowledgeRepository repo,
  required String sourceTreeId,
  required String targetTreeId,
  required List<String> kpIds,
  LayoutConfig config = const LayoutConfig(),
}) async {
  if (kpIds.isEmpty) return;

  final sourceLayout = await repo.loadNodeLayout(sourceTreeId);
  final targetLayout = await repo.loadNodeLayout(targetTreeId);

  // 1) 目标树占位矩形：本次这批点以外的、已固化坐标的成员。
  //    口径同 layout_autoplace.dart：无行 / (0,0) 视为「尚未布局」，不占位。
  final transferSet = kpIds.toSet();
  final targetMemberIds = await trees.memberPointIds(targetTreeId);
  final occupied = <LayoutBox>[];
  for (final id in targetMemberIds) {
    if (transferSet.contains(id)) continue;
    final pos = targetLayout[id];
    if (pos == null) continue;
    if (pos.x == 0 && pos.y == 0) continue;
    occupied.add(LayoutBox(pos.x, pos.y, config.nodeWidth, config.nodeHeight));
  }

  // 2) 源树成员拆成「有坐标」/「无坐标」两组。
  final withPos = <String>[];
  final withoutPos = <String>[];
  for (final id in kpIds) {
    final pos = sourceLayout[id];
    if (pos == null || (pos.x == 0 && pos.y == 0)) {
      withoutPos.add(id);
    } else {
      withPos.add(id);
    }
  }

  // 3) 有坐标组的相对坐标 + 源块包围盒。
  final rel = <String, ({double dx, double dy})>{};
  var blockWidth = config.nodeWidth;
  var blockHeight = config.nodeHeight;
  if (withPos.isNotEmpty) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final id in withPos) {
      final pos = sourceLayout[id]!;
      if (pos.x < minX) minX = pos.x;
      if (pos.y < minY) minY = pos.y;
      if (pos.x > maxX) maxX = pos.x;
      if (pos.y > maxY) maxY = pos.y;
    }
    for (final id in withPos) {
      final pos = sourceLayout[id]!;
      rel[id] = (dx: pos.x - minX, dy: pos.y - minY);
    }
    blockWidth = (maxX - minX) + config.nodeWidth;
    blockHeight = (maxY - minY) + config.nodeHeight;
  }

  // 4) 无坐标组按网格追加到源块下方（不能全挤到块原点，否则互相重叠）。
  if (withoutPos.isNotEmpty) {
    final perRow =
        math.max(1, (blockWidth / (config.nodeWidth + config.hGap)).floor());
    for (var i = 0; i < withoutPos.length; i++) {
      rel[withoutPos[i]] = (
        dx: (i % perRow) * (config.nodeWidth + config.hGap),
        dy: blockHeight + (i ~/ perRow) * (config.nodeHeight + config.vGap),
      );
    }
    final rows = ((withoutPos.length - 1) ~/ perRow) + 1;
    blockHeight += rows * (config.nodeHeight + config.vGap);
  }

  // 5) 首选左上角：贴近目标树已有内容下方且与最左缘对齐；无旧节点则从原点开始。
  //    若该位置与旧节点相交，[findFreeBlockTopLeft] 会把整块推到占用集合下方。
  //    （与 layout_autoplace.dart 的选择逻辑保持一致。）
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

  // 6) 逐点写回（新点浮动，与既有行为一致）。
  for (final id in kpIds) {
    final r = rel[id];
    if (r == null) continue;
    await repo.saveNodePosition(
      targetTreeId,
      id,
      snapToGrid(free.left + r.dx, config.gridSize),
      snapToGrid(free.top + r.dy, config.gridSize),
      pinned: false,
    );
  }
}
