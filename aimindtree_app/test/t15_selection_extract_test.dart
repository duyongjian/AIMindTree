/// T15 划词提取 + 提取模式（prompt variant）测试。
///
/// 覆盖：
/// - **T15 单对象解析**：`{"knowledge_point": {...}}` 契约形态，以及容错形态
///   （T1 数组契约误用 / 裸对象 / 裸数组）；
/// - **source_quote 客户端权威覆盖**：LLM 把 quote 改字 / 扩写都没用，
///   落库的一定是选中的原文（锚点天然通过，幻觉漂移被堵死）；
/// - 选中文字不在原文 → 锚点剔除 → Failure 带原因；
/// - LLM 输出不可解析 → Failure；
/// - **提取模式走 variant**：`extract(..., variant:)` 三态映射
///   （'' → 不传；'keypoints' / 'both' 原样穿透），任务码始终是 T1；
/// - AiTask 枚举：T15 在、T1.keypoints / T1.both **不在**（它们是 variant）。
library;

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/extraction_service.dart';
import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/group_repository.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/note_asset_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 Provider：按脚本返回 T15/T1 的结构化输出，并记录收到的任务、variant 与入参。
class _StubProvider extends AiProvider {
  _StubProvider(this.result);

  final AiTaskResult result;
  final List<AiTask> tasks = <AiTask>[];
  final List<String?> variants = <String?>[];
  final List<Map<String, dynamic>> inputs = <Map<String, dynamic>>[];

  @override
  String get id => 'stub';

  @override
  String get protocol => 'stub';

  @override
  Future<AiTaskResult> runTask(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 120),
    String? variant,
  }) async {
    tasks.add(task);
    variants.add(variant);
    this.inputs.add(inputs);
    return result;
  }

  @override
  Stream<AiChunk> streamChat(
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 120),
    AiTask? task,
    String? variant,
  }) =>
      const Stream<AiChunk>.empty();

  @override
  void dispose() {}
}

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;
  late _StubProvider stub;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 'd');
    stub = _StubProvider(const AiTaskResult(
      content: '{"knowledge_point": {"name": "导数"}}',
      parsed: <String, dynamic>{
        'knowledge_point': <String, dynamic>{
          'name': '导数',
          'type': 'concept',
          'definition': '描述函数变化率的概念',
          'source_quote': '函数的变化率',
          'prerequisites': <dynamic>['极限'],
          'confidence': 0.9,
        },
      },
    ));
  });

  tearDown(() async {
    await db.close();
  });

  ExtractionService makeService() => ExtractionService(
        repo: repo,
        trees: TreeRepository(db, deviceId: 'd'),
        groups: GroupRepository(db, deviceId: 'd'),
        jobs: AiJobService(baseUrl: 'http://127.0.0.1:1'),
        ai: AiService(router: AiTaskRouter(providers: const {}, fallback: stub)),
        assets: NoteAssetRepository(db, deviceId: 'd'),
      );

  // ============================ AiTask 枚举 ============================

  group('AiTask：T15 存在，T1 变体不是新任务码', () {
    test('T15 在枚举里且为结构化任务', () {
      expect(AiTask.t15KpFromSelection.code, 'T15');
      expect(AiTask.t15KpFromSelection.label, '划词提取知识点');
      expect(AiTask.t15KpFromSelection.structured, isTrue);
      expect(AiTask.t15KpFromSelection.isLocalOnly, isFalse);
      expect(AiTask.values.where((t) => t.isLocalOnly), isEmpty);
      expect(AiTask.values.length, 15);
    });

    test('T1.keypoints / T1.both 不是枚举值（它们是 T1 的 variant）', () {
      expect(
        AiTask.values.map((t) => t.code),
        isNot(contains('T1.keypoints')),
      );
      expect(
        AiTask.values.map((t) => t.code),
        isNot(contains('T1.both')),
      );
    });

    test('parse 支持按 code / name 反查（含 T15）', () {
      expect(AiTask.parse('T15'), AiTask.t15KpFromSelection);
      expect(AiTask.parse('t15KpFromSelection'), AiTask.t15KpFromSelection);
      // 未知值回落 T1（旧行为）。
      expect(AiTask.parse('不存在'), AiTask.t1Extract);
    });
  });

  // ============================ T15 划词提取 ============================

  group('extractFromSelection：单对象解析 + quote 客户端权威覆盖', () {
    const content = '第一段：导数是描述函数变化率的核心工具。\n第二段。';

    test('happy path：落库一条知识点，归属当前笔记', () async {
      final res = await repo.saveNote(Note(id: 'n1', contentMd: content));
      expect(res, isA<Success<Note>>());
      final note = (res as Success<Note>).value;

      final r = await makeService().extractFromSelection(
        note: note,
        selection: '导数是描述函数变化率的核心工具',
      );

      expect(r, isA<Success<KnowledgePoint>>());
      final kp = (r as Success<KnowledgePoint>).value;
      expect(kp.name, '导数');
      expect(kp.type, KnowledgePointType.parse('concept'));
      expect(kp.definition, '描述函数变化率的概念');
      expect(kp.sourceNoteId, 'n1');
      expect(kp.origin, 'ai_extract');
      expect(kp.confidence, 0.9);

      // 只调了一次 T15，入参带上 selection + 整篇笔记。
      expect(stub.tasks, <AiTask>[AiTask.t15KpFromSelection]);
      expect(stub.inputs.single['selection'], '导数是描述函数变化率的核心工具');
      expect(stub.inputs.single['note_text'], content);

      // 真的入库了，且能按笔记读回。
      final points = await repo.pointsForNote('n1');
      expect(points, hasLength(1));
      expect(points.single.name, '导数');
    });

    test('source_quote 无条件覆盖为选中文字（LLM 改字也无效）', () async {
      // LLM 把 quote 改成了「函数的变化率」（不在原文中逐字出现）。
      final res = await repo.saveNote(Note(id: 'n1', contentMd: content));
      final note = (res as Success<Note>).value;

      final r = await makeService().extractFromSelection(
        note: note,
        selection: '导数是描述函数变化率的核心工具',
      );

      final kp = (r as Success<KnowledgePoint>).value;
      expect(kp.sourceQuote, '导数是描述函数变化率的核心工具');
      // 锚点落在原文真实位置（不是 LLM 那段）。
      expect(content.substring(kp.sourceStart, kp.sourceEnd), kp.sourceQuote);
    });

    test('选中文字带首尾空白 / 换行：trim 后仍能锚定', () async {
      final res = await repo.saveNote(Note(id: 'n1', contentMd: content));
      final note = (res as Success<Note>).value;

      final r = await makeService().extractFromSelection(
        note: note,
        selection: '\n  导数是描述函数变化率的核心工具  \n',
      );

      final kp = (r as Success<KnowledgePoint>).value;
      expect(kp.sourceQuote, '导数是描述函数变化率的核心工具');
      expect(stub.inputs.single['selection'], '导数是描述函数变化率的核心工具');
    });

    test('选中文字不在原文 → 锚点剔除，Failure 带原因', () async {
      final res = await repo.saveNote(Note(id: 'n1', contentMd: content));
      final note = (res as Success<Note>).value;

      final r = await makeService().extractFromSelection(
        note: note,
        selection: '这段话原文里根本没有',
      );

      expect(r, isA<Failure<KnowledgePoint>>());
      expect((r as Failure<KnowledgePoint>).message, contains('锚点校验失败'));
      expect(await repo.pointsForNote('n1'), isEmpty);
    });

    test('空选区 → ArgumentError', () async {
      final res = await repo.saveNote(Note(id: 'n1', contentMd: content));
      final note = (res as Success<Note>).value;

      final r = await makeService().extractFromSelection(
        note: note,
        selection: '   \n  ',
      );

      expect(r, isA<Failure<KnowledgePoint>>());
      expect((r as Failure<KnowledgePoint>).message, contains('为空'));
    });

    test('LLM 输出不可解析 → Failure（带原文预览）', () async {
      stub = _StubProvider(const AiTaskResult(content: '我拒绝回答', parsed: null));
      final res = await repo.saveNote(Note(id: 'n1', contentMd: content));
      final note = (res as Success<Note>).value;

      final r = await makeService().extractFromSelection(
        note: note,
        selection: '导数是描述函数变化率的核心工具',
      );

      expect(r, isA<Failure<KnowledgePoint>>());
      expect((r as Failure<KnowledgePoint>).message, contains('无法解析'));
      expect(await repo.pointsForNote('n1'), isEmpty);
    });

    test('容错：LLM 误用 T1 的数组契约也能取第一条', () async {
      stub = _StubProvider(const AiTaskResult(
        content: '{}',
        parsed: <String, dynamic>{
          'knowledge_points': <dynamic>[
            <String, dynamic>{'name': '第一个', 'definition': 'd1'},
            <String, dynamic>{'name': '第二个', 'definition': 'd2'},
          ],
        },
      ));
      final res = await repo.saveNote(Note(id: 'n1', contentMd: content));
      final note = (res as Success<Note>).value;

      final r = await makeService().extractFromSelection(
        note: note,
        selection: '导数是描述函数变化率的核心工具',
      );

      final kp = (r as Success<KnowledgePoint>).value;
      expect(kp.name, '第一个');
      expect(kp.sourceQuote, '导数是描述函数变化率的核心工具');
    });

    test('容错：裸对象 / 裸数组都能解析', () async {
      stub = _StubProvider(const AiTaskResult(
        content: '{}',
        parsed: <String, dynamic>{'name': '裸对象', 'definition': 'd'},
      ));
      final res = await repo.saveNote(Note(id: 'n1', contentMd: content));
      final note = (res as Success<Note>).value;

      final r = await makeService().extractFromSelection(
        note: note,
        selection: '导数是描述函数变化率的核心工具',
      );
      expect((r as Success<KnowledgePoint>).value.name, '裸对象');

      stub = _StubProvider(const AiTaskResult(
        content: '[]',
        parsed: <dynamic>[
          <String, dynamic>{'name': '数组首条', 'definition': 'd'},
        ],
      ));
      final r2 = await makeService().extractFromSelection(
        note: note,
        selection: '导数是描述函数变化率的核心工具',
      );
      expect((r2 as Success<KnowledgePoint>).value.name, '数组首条');
    });
  });

  // ======================== 提取模式（D） ========================

  group('extract：提取模式走 prompt variant（默认不传 = 仅知识点）', () {
    const content = '导数是核心工具。极限是基础。';

    setUp(() {
      stub = _StubProvider(const AiTaskResult(
        content: '{}',
        parsed: <String, dynamic>{
          'knowledge_points': <dynamic>[
            <String, dynamic>{
              'name': '导数',
              'type': 'concept',
              'definition': '描述变化率',
              'source_quote': '导数是核心工具',
              'prerequisites': <dynamic>['极限'],
              'confidence': 0.8,
            },
          ],
        },
      ));
    });

    test('不传 variant → 走 T1 且 variant 为 null（旧行为不变）', () async {
      final res = await repo.saveNote(Note(id: 'n1', contentMd: content));
      final note = (res as Success<Note>).value;

      final r = await makeService().extract(content, existingNote: note);

      expect(r, isA<Success<ExtractionSaveResult>>());
      expect(stub.tasks, <AiTask>[AiTask.t1Extract]);
      expect(stub.variants.single, isNull);
      final out = (r as Success<ExtractionSaveResult>).value;
      expect(out.savedCount, 1);
      expect(out.saved.single.name, '导数');
    });

    test('三态映射："" → null；keypoints / both 原样穿透', () async {
      final res = await repo.saveNote(Note(id: 'n1', contentMd: content));
      final note = (res as Success<Note>).value;

      // 显式传空串 = 「仅知识点」，与不传等价（都不带 variant）。
      final r0 = await makeService()
          .extract(content, existingNote: note, variant: '');
      expect(r0, isA<Success<ExtractionSaveResult>>());
      expect(stub.tasks.last, AiTask.t1Extract);
      expect(stub.variants.last, isNull);

      for (final v in <String>['keypoints', 'both']) {
        stub.tasks.clear();
        stub.variants.clear();
        stub.inputs.clear();
        final r = await makeService()
            .extract(content, existingNote: note, variant: v);
        expect(r, isA<Success<ExtractionSaveResult>>(), reason: v);
        // 任务码始终是 T1（variant 不是新任务码，服务端按 (T1, variant) 检索）。
        expect(stub.tasks, <AiTask>[AiTask.t1Extract]);
        expect(stub.variants, <String>[v]);
        // 入参仍是 note_text（variant 走 body 顶层，不塞 inputs）。
        expect(stub.inputs.single, <String, dynamic>{'note_text': content});
      }
    });
  });
}
