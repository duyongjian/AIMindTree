import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 'test-device');
  });

  tearDown(() async {
    await db.close();
  });

  group('锚点校验（PRD 硬规则1：无锚点视为幻觉，禁止入库）', () {
    test('原文中逐字匹配的 quote 正常入库，锚点区间可还原原文', () async {
      const content = '牛顿第一定律：任何物体都要保持匀速直线运动或静止状态。';
      await repo.saveNote(Note(id: 'n1', contentMd: content));

      final r = await repo.saveExtracted(
        noteId: 'n1',
        noteContent: content,
        rawPoints: const [
          RawKnowledgePoint(
            name: '牛顿第一定律',
            type: '定理',
            sourceQuote: '任何物体都要保持匀速直线运动',
            confidence: 0.95,
          ),
        ],
      );

      final res = (r as Success<ExtractionSaveResult>).value;
      expect(res.savedCount, 1);
      expect(res.rejectedCount, 0);

      final kp = res.saved.first;
      expect(kp.type, KnowledgePointType.theorem);
      // ★ 锚点区间必须能在原文中原样还原出 quote
      expect(
        content.substring(kp.sourceStart, kp.sourceEnd),
        '任何物体都要保持匀速直线运动',
      );
    });

    test('原文中不存在的 quote（幻觉）被剔除，且不入库', () async {
      const content = '牛顿第一定律：任何物体都要保持匀速直线运动。';
      await repo.saveNote(Note(id: 'n1', contentMd: content));

      final r = await repo.saveExtracted(
        noteId: 'n1',
        noteContent: content,
        rawPoints: const [
          RawKnowledgePoint(name: '真实知识点', sourceQuote: '牛顿第一定律'),
          RawKnowledgePoint(name: '幻觉知识点', sourceQuote: '这段原文里根本没有的话'),
          RawKnowledgePoint(name: '空引用知识点', sourceQuote: ''),
          RawKnowledgePoint(name: '', sourceQuote: '牛顿'), // 名称为空
        ],
      );

      final res = (r as Success<ExtractionSaveResult>).value;
      expect(res.savedCount, 1, reason: '只有 1 条能通过锚点校验');
      expect(res.rejectedCount, 3);
      expect(res.saved.single.name, '真实知识点');
      // 被剔除的都带原因，便于 UI 提示
      expect(res.rejected.every((e) => e.reason.isNotEmpty), isTrue);
    });
  });

  group('级联降级（PRD 硬规则4：标未掌握 → 后继逐级降级）', () {
    test('A 未掌握 → 后继 B 降为 learning', () async {
      const content = 'abc';
      await repo.saveNote(Note(id: 'n1', contentMd: content));
      final r = await repo.saveExtracted(
        noteId: 'n1',
        noteContent: content,
        rawPoints: const [
          RawKnowledgePoint(name: 'A', sourceQuote: 'a'),
          RawKnowledgePoint(name: 'B', sourceQuote: 'b'),
        ],
      );
      final kps = (r as Success<ExtractionSaveResult>).value.saved;
      final a = kps[0].id;
      final b = kps[1].id;

      await repo.addPrerequisiteEdges([PrerequisiteEdge(fromKpId: a, toKpId: b)]);

      await repo.setMastery(a, MasteryStatus.mastered);
      await repo.setMastery(b, MasteryStatus.mastered);
      expect(await repo.currentMastery(b), MasteryStatus.mastered);

      await repo.setMastery(a, MasteryStatus.notMastered);
      expect(await repo.currentMastery(a), MasteryStatus.notMastered);
      expect(await repo.currentMastery(b), MasteryStatus.learning,
          reason: 'mastered 降一档应为 learning');
    });

    test('链式 A→B→C：A 未掌握触发整链降级', () async {
      const content = 'abc';
      await repo.saveNote(Note(id: 'n1', contentMd: content));
      final r = await repo.saveExtracted(
        noteId: 'n1',
        noteContent: content,
        rawPoints: const [
          RawKnowledgePoint(name: 'A', sourceQuote: 'a'),
          RawKnowledgePoint(name: 'B', sourceQuote: 'b'),
          RawKnowledgePoint(name: 'C', sourceQuote: 'c'),
        ],
      );
      final kps = (r as Success<ExtractionSaveResult>).value.saved;
      final a = kps[0].id;
      final b = kps[1].id;
      final c = kps[2].id;

      await repo.addPrerequisiteEdges([
        PrerequisiteEdge(fromKpId: a, toKpId: b),
        PrerequisiteEdge(fromKpId: b, toKpId: c),
      ]);

      for (final id in [a, b, c]) {
        await repo.setMastery(id, MasteryStatus.mastered);
      }

      final changed = await repo.setMastery(a, MasteryStatus.notMastered);
      expect((changed as Success<int>).value, 3, reason: '自身 + B + C 共 3 处变更');

      expect(await repo.currentMastery(b), MasteryStatus.learning);
      expect(await repo.currentMastery(c), MasteryStatus.learning);
    });

    test('前置图成环不死循环', () async {
      const content = 'ab';
      await repo.saveNote(Note(id: 'n1', contentMd: content));
      final r = await repo.saveExtracted(
        noteId: 'n1',
        noteContent: content,
        rawPoints: const [
          RawKnowledgePoint(name: 'A', sourceQuote: 'a'),
          RawKnowledgePoint(name: 'B', sourceQuote: 'b'),
        ],
      );
      final kps = (r as Success<ExtractionSaveResult>).value.saved;
      final a = kps[0].id;
      final b = kps[1].id;

      // 人为制造环 A→B→A
      await repo.addPrerequisiteEdges([
        PrerequisiteEdge(fromKpId: a, toKpId: b),
        PrerequisiteEdge(fromKpId: b, toKpId: a),
      ]);

      final res = await repo.setMastery(a, MasteryStatus.notMastered);
      expect(res.isSuccess, isTrue, reason: '成环必须能正常退出，不能栈溢出/死循环');
    });
  });

  group('后继约束 + 分组平移（2026-10-10）', () {
    test('同一知识点已有后继时，再连出边被拒绝', () async {
      const content = 'ab';
      await repo.saveNote(Note(id: 'n1', contentMd: content));
      final r = await repo.saveExtracted(
        noteId: 'n1',
        noteContent: content,
        rawPoints: const [
          RawKnowledgePoint(name: 'A', sourceQuote: 'a'),
          RawKnowledgePoint(name: 'B', sourceQuote: 'b'),
        ],
      );
      final kps = (r as Success<ExtractionSaveResult>).value.saved;
      final a = kps[0].id;
      final b = kps[1].id;

      // 先建 A→B（第一个后继，允许）。
      final first = await repo.addManualPrerequisiteEdge(a, b);
      expect(first.isSuccess, isTrue);

      // 再想给 A 连第二个出边：被「最多一个后继」约束拒绝。
      final second = await repo.addManualPrerequisiteEdge(a, 'external-node');
      expect(second.isFailure, isTrue,
          reason: 'A 已有后继 B，再连出边必须被拒');
    });

    test('连线会形成环路时被拒绝', () async {
      const content = 'ab';
      await repo.saveNote(Note(id: 'n1', contentMd: content));
      final r = await repo.saveExtracted(
        noteId: 'n1',
        noteContent: content,
        rawPoints: const [
          RawKnowledgePoint(name: 'A', sourceQuote: 'a'),
          RawKnowledgePoint(name: 'B', sourceQuote: 'b'),
        ],
      );
      final kps = (r as Success<ExtractionSaveResult>).value.saved;
      final a = kps[0].id;
      final b = kps[1].id;

      await repo.addManualPrerequisiteEdge(a, b); // A→B 合法
      // B→A 会让 A→B→A 成环 → 拒绝。
      final back = await repo.addManualPrerequisiteEdge(b, a);
      expect(back.isFailure, isTrue, reason: 'B→A 会形成学习环路，必须被拒');
    });

    test('moveGroupMembers 把整组位置整体平移', () async {
      const content = 'abc';
      await repo.saveNote(Note(id: 'n1', contentMd: content));
      final r = await repo.saveExtracted(
        noteId: 'n1',
        noteContent: content,
        rawPoints: const [
          RawKnowledgePoint(name: 'A', sourceQuote: 'a'),
          RawKnowledgePoint(name: 'B', sourceQuote: 'b'),
          RawKnowledgePoint(name: 'C', sourceQuote: 'c'),
        ],
      );
      final kps = (r as Success<ExtractionSaveResult>).value.saved;
      final ids = kps.map((k) => k.id).toList();

      const treeId = 'tree-1';
      for (final id in ids) {
        await repo.saveNodePosition(treeId, id, 0, 0);
      }
      final move = await repo.moveGroupMembers(treeId, ids, 100, 50);
      expect(move.isSuccess, isTrue);

      final pos = await repo.loadNodePositions(treeId);
      for (final id in ids) {
        expect(pos[id]?.x, 100);
        expect(pos[id]?.y, 50);
      }
    });
  });
}
