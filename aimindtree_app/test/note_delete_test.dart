import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;
  late TreeRepository trees;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 'test-device');
    trees = TreeRepository(db, deviceId: 'test-device');
  });

  tearDown(() async {
    await db.close();
  });

  /// 造一篇笔记 + 3 个知识点，并返回知识点 id 列表。
  Future<List<String>> seedNote(String noteId) async {
    const content = 'aaaa bbbb cccc dddd eeee ffff';
    await repo.saveNote(Note(id: noteId, contentMd: content));
    final r = await repo.saveExtracted(
      noteId: noteId,
      noteContent: content,
      rawPoints: const [
        RawKnowledgePoint(name: 'p1', sourceQuote: 'aaaa'),
        RawKnowledgePoint(name: 'p2', sourceQuote: 'bbbb'),
        RawKnowledgePoint(name: 'p3', sourceQuote: 'cccc'),
      ],
    );
    expect((r as Success).isSuccess, isTrue);
    return (await repo.pointIdsOfNote(noteId));
  }

  group('TreeRepository.treesContaining（删除笔记的影响面）', () {
    test('知识点分布在多棵树时，按树聚合数量', () async {
      final kpIds = await seedNote('n1');

      await trees.createTree('自建树A', fixedId: 'treeA');
      await trees.createTree('自建树B', fixedId: 'treeB');
      await trees.addPoints('treeA', kpIds);
      await trees.addPoints('treeB', <String>[kpIds.first]);

      final impacts = await trees.treesContaining(kpIds);
      final byId = {for (final i in impacts) i.treeId: i.pointCount};

      expect(byId['treeA'], 3);
      expect(byId['treeB'], 1);
      expect(impacts.first.treeId, 'treeA'); // 多的排前面
    });

    test('树已被删除时，残留的成员记录不计入影响面', () async {
      final kpIds = await seedNote('n1');
      await trees.createTree('临时树', fixedId: 'tmp');
      await trees.addPoints('tmp', kpIds);
      await trees.deleteTree('tmp');

      // 成员关系随树一起清掉了 → 影响面为空
      expect(await trees.treesContaining(kpIds), isEmpty);
    });
  });

  group('删除笔记', () {
    test('不勾选任何树：笔记软删除，知识点保留在原树中', () async {
      final kpIds = await seedNote('n1');
      await trees.createTree('自建树', fixedId: 'treeA');
      await trees.addPoints('treeA', kpIds);

      final res = await repo.deleteNote(
        noteId: 'n1',
        deletePoints: false,
        removeFromTrees: <String>{},
      );

      final s = (res as Success<NoteDeleteSummary>).value;
      expect(s.pointsDeleted, 0);
      expect(s.treesAffected, 0);

      // 笔记软删除：row 还在，但 deletedAt 有值
      final row =
          await (db.select(db.notes)..where((t) => t.id.equals('n1')))
              .getSingle();
      expect(row.deletedAt, isNotNull);

      // 知识点和树成员关系都还在
      expect(await repo.pointsByIds(kpIds), hasLength(3));
      expect(await trees.memberPointIds('treeA'), hasLength(3));
    });

    test('勾选部分树：只解除这些树的成员关系，知识点保留', () async {
      final kpIds = await seedNote('n1');
      await trees.createTree('A', fixedId: 'treeA');
      await trees.createTree('B', fixedId: 'treeB');
      await trees.addPoints('treeA', kpIds);
      await trees.addPoints('treeB', kpIds);

      final res = await repo.deleteNote(
        noteId: 'n1',
        deletePoints: false,
        removeFromTrees: <String>{'treeA'},
      );

      final s = (res as Success<NoteDeleteSummary>).value;
      expect(s.pointsDeleted, 0);
      expect(s.treesAffected, 1);
      expect(await trees.memberPointIds('treeA'), isEmpty);
      expect(await trees.memberPointIds('treeB'), hasLength(3));
      expect(await repo.pointsByIds(kpIds), hasLength(3));
    });

    test('彻底删除：知识点、前置边、掌握记录、所有树成员关系一起清掉', () async {
      final kpIds = await seedNote('n1');
      await trees.createTree('A', fixedId: 'treeA');
      await trees.addPoints('treeA', kpIds);

      // 造一条前置边 + 一条掌握记录
      await repo.addManualPrerequisiteEdge(kpIds[0], kpIds[1]);
      await repo.setMastery(kpIds[0], MasteryStatus.mastered);

      final res = await repo.deleteNote(
        noteId: 'n1',
        deletePoints: true,
        removeFromTrees: <String>{},
      );

      final s = (res as Success<NoteDeleteSummary>).value;
      expect(s.pointsDeleted, 3);

      expect(await repo.pointsByIds(kpIds), isEmpty);
      expect(await trees.memberPointIds('treeA'), isEmpty);
      expect(await db.select(db.prerequisiteEdges).get(), isEmpty);
      expect(await db.select(db.masteryRecords).get(), isEmpty);
    });

    test('删除笔记时会清掉它的「笔记树」，避免留下空的僵尸树', () async {
      await seedNote('n1');
      await trees.ensureNoteTree(noteId: 'n1', noteTitle: '某篇笔记');
      expect(await trees.getTree('n1'), isNotNull);

      await repo.deleteNote(
        noteId: 'n1',
        deletePoints: true,
        removeFromTrees: <String>{},
      );

      expect(await trees.getTree('n1'), isNull);
    });

    test('删除一篇笔记不会影响其它笔记的知识点', () async {
      final mine = await seedNote('n1');
      final others = await seedNote('n2');

      await repo.deleteNote(
        noteId: 'n1',
        deletePoints: true,
        removeFromTrees: <String>{},
      );

      expect(await repo.pointsByIds(mine), isEmpty);
      expect(await repo.pointsByIds(others), hasLength(3));
    });
  });

  group('软删知识点（P0-3：删了本地库不再看得到）', () {
    test('软删后 allKnowledgePoints / pointsByIds / pointsForNote 不再返回',
        () async {
      final kpIds = await seedNote('n1');
      expect(await repo.allKnowledgePoints(), hasLength(3));
      expect(await repo.pointsByIds(kpIds), hasLength(3));

      final res = await repo.softDeleteKnowledgePoint(kpIds.first);
      expect((res as Success<int>).value, 1);

      // 已软删的不再出现在任何读路径（修复「删了本地库还看得到」）
      expect(await repo.pointsByIds(kpIds), hasLength(2));
      expect(await repo.pointsForNote('n1'), hasLength(2));
      expect(await repo.allKnowledgePoints(), hasLength(2));
    });

    test('软删级联清掉前置边 / 掌握记录 / 树成员关系', () async {
      final kpIds = await seedNote('n1');
      await trees.createTree('A', fixedId: 'treeA');
      await trees.addPoints('treeA', kpIds);
      await repo.addManualPrerequisiteEdge(kpIds[0], kpIds[1]);
      await repo.setMastery(kpIds[0], MasteryStatus.mastered);

      await repo.softDeleteKnowledgePoint(kpIds[0]);

      expect(await db.select(db.prerequisiteEdges).get(), isEmpty);
      expect(await db.select(db.masteryRecords).get(), isEmpty);
      expect(await trees.memberPointIds('treeA'), hasLength(2));
    });

    test('软删不存在的 id 返回 0', () async {
      final res = await repo.softDeleteKnowledgePoint('nope');
      expect((res as Success<int>).value, 0);
    });
  });
}
