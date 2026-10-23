/// 跨知识树复制知识点的落位测试（[placeTransferredPointsInTree]）。
///
/// 守住四条：
/// 1. **相对位置保持**：这批点在源树里的两两坐标差原样带到目标树，且整块落在
///    目标树已有内容下方；
/// 2. **无坐标点不重叠**：源树里没摆过位（无行 / (0,0)）的点按网格追加到块下方，
///    不与任何点重叠；
/// 3. **重复加入幂等**：`TreeRepository.addPoints` 按树去重，不产生重复成员行；
/// 4. **空目标树**：无占位时整体从 (0,0) 起落位。
library;

import 'package:aimindtree_app/canvas/layout_transfer.dart';
import 'package:aimindtree_app/canvas/render/layout_engine.dart';
import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/models/knowledge_tree.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;
  late TreeRepository trees;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 'd');
    trees = TreeRepository(db, deviceId: 'd');
  });

  tearDown(() async {
    await db.close();
  });

  Future<KnowledgeTree> newTree(String name) async {
    final res = await trees.createTree(name);
    expect(res, isA<Success<KnowledgeTree>>());
    return (res as Success<KnowledgeTree>).value;
  }

  Future<KnowledgePoint> newKp(String name) async {
    final res = await repo.createManualKnowledgePoint(name: name);
    expect(res, isA<Success<KnowledgePoint>>());
    return (res as Success<KnowledgePoint>).value;
  }

  Future<void> put(String treeId, KnowledgePoint kp, double x, double y) async {
    final res = await repo.saveNodePosition(treeId, kp.id, x, y);
    expect(res, isA<Success<void>>());
  }

  Future<void> addToTree(String treeId, List<KnowledgePoint> kps) async {
    final res = await trees.addPoints(treeId, kps.map((k) => k.id).toList());
    expect(res, isA<Success<int>>());
  }

  /// 读某棵树各成员的当前坐标。
  Future<Map<String, ({double x, double y})>> positions(String treeId) async {
    final layout = await repo.loadNodeLayout(treeId);
    return <String, ({double x, double y})>{
      for (final e in layout.entries) e.key: (x: e.value.x, y: e.value.y),
    };
  }

  test('相对位置保持：两两坐标差与源树一致，且整块落在目标树已有内容下方', () async {
    final source = await newTree('源树');
    final target = await newTree('目标树');

    // 源树 3 点：(100,100) (300,100) (100,260)。
    final a = await newKp('A');
    final b = await newKp('B');
    final c = await newKp('C');
    await addToTree(source.id, [a, b, c]);
    await put(source.id, a, 100, 100);
    await put(source.id, b, 300, 100);
    await put(source.id, c, 100, 260);

    // 目标树已有 2 点占住上方：(100,100) (340,100)。
    final x = await newKp('X');
    final y = await newKp('Y');
    await addToTree(target.id, [x, y]);
    await put(target.id, x, 100, 100);
    await put(target.id, y, 340, 100);

    // 把 3 个点加入目标树并按源树坐标落位。
    await addToTree(target.id, [a, b, c]);
    await placeTransferredPointsInTree(
      trees: trees,
      repo: repo,
      sourceTreeId: source.id,
      targetTreeId: target.id,
      kpIds: [a.id, b.id, c.id],
    );

    final src = await positions(source.id);
    final dst = await positions(target.id);

    // 两两坐标差与源树完全相等。
    const pairs = [
      ['A', 'B'],
      ['A', 'C'],
      ['B', 'C'],
    ];
    final idByName = {a.name: a.id, b.name: b.id, c.name: c.id};
    for (final p in pairs) {
      final id1 = idByName[p[0]]!;
      final id2 = idByName[p[1]]!;
      final s1 = src[id1]!;
      final s2 = src[id2]!;
      final d1 = dst[id1]!;
      final d2 = dst[id2]!;
      expect(d1.x - d2.x, s1.x - s2.x, reason: '${p[0]}-${p[1]} dx 应保持');
      expect(d1.y - d2.y, s1.y - s2.y, reason: '${p[0]}-${p[1]} dy 应保持');
    }

    // 整块在目标树已有内容（100,100)+(340,100) 的下方：maxBottom = 100+136。
    const config = LayoutConfig();
    final existingBottom = 100 + config.nodeHeight;
    final minY = [a.id, b.id, c.id]
        .map((id) => dst[id]!.y)
        .reduce((p, q) => p < q ? p : q);
    expect(minY, greaterThan(existingBottom));
  });

  test('无坐标点不重叠：源树没摆过位的点按网格追加到块下方', () async {
    final source = await newTree('源树');
    final target = await newTree('空目标树');

    final a = await newKp('A');
    final b = await newKp('B');
    final c = await newKp('C'); // 无坐标（addPoints 写入 x/y=0）
    final d = await newKp('D'); // 无坐标
    await addToTree(source.id, [a, b, c, d]);
    await put(source.id, a, 100, 100);
    await put(source.id, b, 360, 100);

    await addToTree(target.id, [a, b, c, d]);
    await placeTransferredPointsInTree(
      trees: trees,
      repo: repo,
      sourceTreeId: source.id,
      targetTreeId: target.id,
      kpIds: [a.id, b.id, c.id, d.id],
    );

    final dst = await positions(target.id);
    const config = LayoutConfig();
    final boxes = <String, LayoutBox>{
      for (final id in dst.keys)
        id: LayoutBox(dst[id]!.x, dst[id]!.y, config.nodeWidth,
            config.nodeHeight),
    };
    final ids = boxes.keys.toList();
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        expect(
          boxes[ids[i]]!.overlaps(boxes[ids[j]]!),
          isFalse,
          reason: '${ids[i]} 与 ${ids[j]} 不应重叠：'
              '${boxes[ids[i]]!.left},${boxes[ids[i]]!.top} / '
              '${boxes[ids[j]]!.left},${boxes[ids[j]]!.top}',
        );
      }
    }
    // 无坐标的两个点不应落在块原点 (0,0) 上（会压住 A 的位置）。
    expect(dst[c.id], isNot((x: 0.0, y: 0.0)));
    expect(dst[d.id], isNot((x: 0.0, y: 0.0)));
  });

  test('重复加入幂等：addPoints 返回 0，成员行不重复', () async {
    final tree = await newTree('目标树');
    final kp = await newKp('已有点');
    final first = await trees.addPoints(tree.id, [kp.id]);
    expect((first as Success<int>).value, 1);

    final second = await trees.addPoints(tree.id, [kp.id]);
    expect(second, isA<Success<int>>());
    expect((second as Success<int>).value, 0);

    final rows = await (db.select(db.canvasNodes)
          ..where((t) =>
              t.canvasId.equals(tree.id) & t.targetId.equals(kp.id)))
        .get();
    expect(rows, hasLength(1));
  });

  test('空目标树：无占位时整体从 (0,0) 起落位', () async {
    final source = await newTree('源树');
    final target = await newTree('空目标树');

    final a = await newKp('A');
    final b = await newKp('B');
    final c = await newKp('C');
    await addToTree(source.id, [a, b, c]);
    await put(source.id, a, 100, 100);
    await put(source.id, b, 300, 100);
    await put(source.id, c, 100, 260);

    await addToTree(target.id, [a, b, c]);
    await placeTransferredPointsInTree(
      trees: trees,
      repo: repo,
      sourceTreeId: source.id,
      targetTreeId: target.id,
      kpIds: [a.id, b.id, c.id],
    );

    final dst = await positions(target.id);
    final xs = dst.values.map((p) => p.x);
    final ys = dst.values.map((p) => p.y);
    expect(xs.reduce((p, q) => p < q ? p : q), 0);
    expect(ys.reduce((p, q) => p < q ? p : q), 0);
  });
}
