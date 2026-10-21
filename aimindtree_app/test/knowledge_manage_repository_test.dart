/// P1-1 知识点管理页：仓储层手动新建 / 编辑 / 边计数。
///
/// 锚点四件套豁免（PRD §4.2）：手动知识点 origin='user_manual'、sourceQuote=''、
/// sourceStart/End=-1，不要求锚点自证；空串哨兵（§4.3）作为「无来源笔记」。
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
  tearDown(() async => db.close());

  group('createManualKnowledgePoint（P1-1：手动新建，锚点豁免）', () {
    test('默认即「无来源笔记」且与 AI 提取点并列出现在列表', () async {
      final res = await repo.createManualKnowledgePoint(name: '牛顿第一定律');
      final kp = (res as Success<KnowledgePoint>).value;

      expect(kp.origin, 'user_manual');
      expect(kp.sourceNoteId, '');
      expect(kp.sourceQuote, '');
      expect(kp.sourceStart, -1);

      final all = await repo.allKnowledgePoints();
      expect(all, hasLength(1));
      expect(all.first.id, kp.id);
    });

    test('可关联一篇笔记作为来源', () async {
      final res = await repo.createManualKnowledgePoint(
        name: '关联点',
        sourceNoteId: 'note-1',
      );
      final kp = (res as Success<KnowledgePoint>).value;
      expect(kp.sourceNoteId, 'note-1');
    });

    test('名称为空被拒', () async {
      final res = await repo.createManualKnowledgePoint(name: '  ');
      expect(res, isA<Failure<KnowledgePoint>>());
    });
  });

  group('updateKpMeta（P1-1：编辑展示性字段）', () {
    test('改名 + 改类型 + 改定义后回读一致，version 递增', () async {
      final created =
          (await repo.createManualKnowledgePoint(name: '旧名')) as Success<KnowledgePoint>;
      final kp = created.value.copyWith(
        name: '新名',
        type: KnowledgePointType.theorem,
        definition: '定义内容',
      );
      final upd = await repo.updateKpMeta(kp);
      expect((upd as Success<KnowledgePoint>).isSuccess, isTrue);

      final back = await repo.pointsByIds([kp.id]);
      expect(back.single.name, '新名');
      expect(back.single.type, KnowledgePointType.theorem);
      expect(back.single.definition, '定义内容');
      expect(back.single.version, greaterThan(kp.version));
    });

    test('编辑不存在的知识点返回 Failure', () async {
      final fake = KnowledgePoint(
        id: 'ghost',
        name: '幽灵',
        sourceNoteId: '',
        sourceStart: -1,
        sourceEnd: -1,
        sourceQuote: '',
      );
      final res = await repo.updateKpMeta(fake);
      expect(res, isA<Failure<KnowledgePoint>>());
    });
  });

  group('countPrerequisiteEdges（删除影响面预览）', () {
    test('统计与某知识点相关的前置边数量', () async {
      final a = (await repo.createManualKnowledgePoint(name: 'A'))
          as Success<KnowledgePoint>;
      final b = (await repo.createManualKnowledgePoint(name: 'B'))
          as Success<KnowledgePoint>;
      final c = (await repo.createManualKnowledgePoint(name: 'C'))
          as Success<KnowledgePoint>;

      // 约束（PRD §关系）：每个知识点最多一个后继（出边 ≤ 1）。
      // 因此用 A→B、C→B 来构造：B 有两条入边（两个前驱），A、C 各一条出边。
      await repo.addManualPrerequisiteEdge(a.value.id, b.value.id);
      await repo.addManualPrerequisiteEdge(c.value.id, b.value.id);

      // B 是两条边的终点；A、C 各是 1 条边的起点。
      expect(await repo.countPrerequisiteEdges(a.value.id), 1);
      expect(await repo.countPrerequisiteEdges(b.value.id), 2);
      expect(await repo.countPrerequisiteEdges(c.value.id), 1);
    });
  });
}
