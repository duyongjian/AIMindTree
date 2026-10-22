/// listTrees 墓碑过滤测试（问题①修复）。
///
/// 覆盖两条主线：
/// 1. **软删铁律**：canvases 行被直接写上 deletedAt（墓碑，模拟同步删除标记 /
///    别处软删）后，listTrees 不再返回它——物理行还在（墓碑不是硬删）。
/// 2. **deleteTree 行为不变**：仍然是硬删（物理行直接消失，不写墓碑），
///    listTrees 只剩未删的那棵。
library;

import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_tree.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late TreeRepository trees;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    trees = TreeRepository(db, deviceId: 'd');
  });

  tearDown(() async {
    await db.close();
  });

  /// 建一棵树，返回其 id。
  Future<String> makeTree(String name) async {
    final res = await trees.createTree(name);
    expect(res, isA<Success<KnowledgeTree>>());
    return (res as Success<KnowledgeTree>).value.id;
  }

  group('listTrees：tombstone 过滤', () {
    test('deleteTree 硬删：listTrees 只剩未删的那棵（行为不变）', () async {
      final keepId = await makeTree('保留的树');
      final dropId = await makeTree('要硬删的树');
      expect(await trees.listTrees(), hasLength(2));

      final res = await trees.deleteTree(dropId);
      expect(res, isA<Success<void>>());

      // listTrees 只剩未删的那棵。
      final list = await trees.listTrees();
      expect(list, hasLength(1));
      expect(list.single.id, keepId);
      // 物理行也没了：deleteTree 是硬删，不是墓碑（行为不变）。
      final rows = await db.select(db.canvases).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, keepId);
    });

    test('直接写 deletedAt 墓碑：listTrees 过滤该行', () async {
      final keepId = await makeTree('活树');
      final tombId = await makeTree('墓碑树');

      // 直接 update 写墓碑（模拟同步删除标记 / 别处软删）。
      await (db.update(db.canvases)..where((t) => t.id.equals(tombId)))
          .write(CanvasesCompanion(
        deletedAt: Value(DateTime.now().toUtc()),
      ));

      // listTrees 只剩未删的那棵（墓碑行不进列表）。
      final list = await trees.listTrees();
      expect(list, hasLength(1));
      expect(list.single.id, keepId);
      // 但物理行还在（墓碑不是硬删）。
      final rows = await db.select(db.canvases).get();
      expect(rows, hasLength(2));
    });
  });
}
