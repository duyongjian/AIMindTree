/// 老师模式页面：widget 层端到端测试。
///
/// 覆盖测试方案：
/// - T2 二次进入渲染历史讲解（不经内存变量）+ 负对照（软删后不复现）+ 不重复讲解
/// - T3 全删后重新进入 → 自动新建会话并自动讲解
/// - T5 进入后消息流同时呈现「讲解」与「追问」，会话列表只剩 1 条
/// - T6 ★ 最高优先级：多轮记忆——第 3 轮能引用第 1 轮（含反向证据用例）
/// - T8 「再讲一次」= 追加，历史讲解不被覆盖
///
/// 假 Provider 只在**第 1 轮的回答**里种下「记忆锚点」，因此「第 3 轮气泡
/// 复述锚点」严格等价于「第 1 轮内容被注入进第 3 轮的 query」——因果链闭合。
library;

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/ai_session_repository.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/features/teacher/teacher_page.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ulid/ulid.dart';

/// 假 AI Provider：记录每次收到的 query，并按「记忆锚点」回显。
///
/// **锚点只能由本 Provider 在第 1 轮的回答里产出** —— 因此「第 3 轮气泡里
/// 出现『我记得你说过 <锚点>』」严格等价于「第 1 轮内容被注入进第 3 轮的 query」。
///
/// [forgetful] = true → 恒定返回「（本轮未携带历史）」，用于反向证据用例
/// （证明 T6 的主断言不是恒真的）。
class _FakeProvider implements AiProvider {
  _FakeProvider({this.explainText = '讲解正文XYZ', this.forgetful = false});

  final List<String> queries = [];
  int t6Calls = 0;
  int t5Calls = 0;
  final String explainText;
  final bool forgetful;

  /// 「记忆锚点」：只会由本 Provider 在第 1 轮的回答里产出。
  static const String anchor = 'ALPHA-7.5';
  static const String rememberReply = '我记得你说过 ALPHA-7.5';
  static const String noHistoryReply = '（本轮未携带历史）';

  @override
  String get id => 'fake';

  @override
  String get protocol => 'fake';

  @override
  Stream<AiChunk> streamChat(
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 120),
    AiTask? task,
    String? variant,
  }) async* {
    queries.add(query);
    if (task == AiTask.t6Explain) {
      t6Calls++;
      yield AiChunk(delta: explainText, done: true);
      return;
    }
    t5Calls++;
    if (forgetful) {
      yield AiChunk(delta: noHistoryReply, done: true);
      return;
    }
    // 只有当本轮 query 里真的带着锚点时，才「记得」——否则顺手把锚点种进历史。
    final hit = query.contains(anchor);
    yield AiChunk(
      delta: hit ? rememberReply : '（回答）这里的关键数是 $anchor',
      done: true,
    );
  }

  @override
  Future<AiTaskResult> runTask(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 120),
    String? variant,
  }) async =>
      const AiTaskResult(content: '{}');

  @override
  void dispose() {}
}

void main() {
  late AppDatabase db;
  late AiSessionRepository sessions;
  late KnowledgeRepository kpRepo;
  late AiJobService jobs;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    sessions = AiSessionRepository(db, deviceId: 'test-device');
    kpRepo = KnowledgeRepository(db, deviceId: 'test-device');
    jobs = AiJobService(baseUrl: 'http://127.0.0.1:1');
  });

  tearDown(() async {
    await db.close();
  });

  KnowledgePoint kp(String id) => KnowledgePoint(
        id: id,
        name: '链式法则',
        type: KnowledgePointType.theorem,
        definition: '复合函数求导法则',
        sourceNoteId: '',
        sourceStart: -1,
        sourceEnd: -1,
        sourceQuote: '原文锚点',
      );

  Future<void> pumpPage(
    WidgetTester tester,
    _FakeProvider fake, {
    required String kpId,
  }) async {
    // ⚠️ 必须先挂一棵空树强制卸载上一个 TeacherPage：同类型 + 无 key 时
    // Flutter 会**复用同一个 State**，读到的其实是内存里残留下来的
    // `_messages`，T2 的「二次进入从库里读」断言会退化成假阳性。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pumpWidget(MaterialApp(
      home: TeacherPage(
        kp: kp(kpId),
        sessions: sessions,
        ai: AiService(router: AiTaskRouter(providers: const {}, fallback: fake)),
        repo: kpRepo,
        jobs: jobs,
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 手工插一条会话行（可指定 type / 软删）。
  Future<void> insertSession({
    required String id,
    required String kpId,
    required String type,
    DateTime? deletedAt,
  }) async {
    await db.into(db.aiSessions).insert(AiSessionsCompanion(
          id: Value(id),
          type: Value(type),
          targetRef: Value(kpId),
          title: const Value(''),
          kpId: Value(kpId),
          modelId: const Value('dify-t1-local'),
          tutorState: const Value('{}'),
          updatedAt: Value(DateTime.now().toUtc()),
          version: const Value(1),
          deviceId: const Value('test-device'),
          deletedAt: Value(deletedAt),
        ));
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
  }

  // ==================== T2 ====================

  testWidgets('T2 二次进入渲染历史讲解（从库里读，不是内存残留）',
      (tester) async {
    final fake = _FakeProvider(explainText: '讲解正文XYZ');

    // 第一个实例：补建主会话 + 自动讲解一次
    await pumpPage(tester, fake, kpId: 'kp-w2');
    expect(find.text('讲解正文XYZ'), findsOneWidget); // ①
    expect(fake.t6Calls, 1);

    // 第二个实例（全新 State，同一 db / 同一 kp / 同一 fake）
    await pumpPage(tester, fake, kpId: 'kp-w2');
    expect(find.text('讲解正文XYZ'), findsOneWidget); // ② 仍渲染
    expect(find.textContaining('暂无讲解'), findsNothing); // ③
    expect(fake.t6Calls, 1, reason: '主会话已有 assistant 消息，不重复自动讲解'); // ④

    // ⑤ 负对照：把该会话消息全部软删 → 第三次进入讲解不复现
    final list = await sessions.listSessionsForKp('kp-w2');
    await sessions.clearMessages(list.single.id);
    await pumpPage(tester, fake, kpId: 'kp-w2');
    expect(find.text('讲解正文XYZ'), findsNothing);
  });

  // ==================== T3 ====================

  testWidgets('T3 会话被软删后重新进入 → 自动新建会话并自动讲解', (tester) async {
    final old = await sessions.createSessionForKp('kp-w3');
    await sessions.deleteSession(old.id); // 唯一会话被软删

    final fake = _FakeProvider(explainText: '自动补讲解');
    await pumpPage(tester, fake, kpId: 'kp-w3');

    final list = await sessions.listSessionsForKp('kp-w3');
    expect(list, hasLength(1));
    expect(list.single.id, isNot(old.id)); // 新建的不是墓碑行
    final msgs = await sessions.listMessages(list.single.id);
    expect(msgs, hasLength(1));
    expect(msgs.single.modelId, 'dify-t6'); // 自动生成一条讲解
    expect(msgs.single.content, '自动补讲解');
    expect(find.text('自动补讲解'), findsOneWidget);
  });

  // ==================== T5 ====================

  testWidgets('T5 进入后消息流同时呈现讲解与追问，会话列表只剩 1 条',
      (tester) async {
    final e = Ulid(millis: 1000).toString(); // explain 更早
    final c = Ulid(millis: 2000).toString(); // chat 更晚
    await insertSession(id: e, kpId: 'kp-w5', type: 'explain');
    await insertSession(id: c, kpId: 'kp-w5', type: 'chat');
    await sessions.addMessage(
        sessionId: e, role: 'assistant', content: '讲解正文PRESET',
        modelId: 'dify-t6');
    await sessions.addMessage(
        sessionId: c, role: 'user', content: '追问原文');

    final fake = _FakeProvider();
    await pumpPage(tester, fake, kpId: 'kp-w5');

    // 合并后两条都在同一个会话里
    expect(find.text('讲解正文PRESET'), findsOneWidget);
    expect(find.text('追问原文'), findsOneWidget);
    // 主会话是 C，且合并后只剩 1 条会话
    final list = await sessions.listSessionsForKp('kp-w5');
    expect(list, hasLength(1));
    expect(list.single.id, c); // explain 没抢走主会话
    // 已有 assistant 消息 → 不重复自动讲解
    expect(fake.t6Calls, 0);
  });

  // ==================== T6（最高优先级） ====================

  testWidgets('T6 第 3 轮能引用第 1 轮（多轮记忆生效）', (tester) async {
    final fake = _FakeProvider(explainText: '讲解正文XYZ');
    await pumpPage(tester, fake, kpId: 'kp-w6');

    // —— 第 1 轮 ——（回答里种下锚点）
    await send(tester, '给我一个反向传播的例子');
    // —— 第 2 轮 ——
    await send(tester, '那它的梯度怎么回传');
    // —— 第 3 轮：问「刚才那个数是多少」（本身不含锚点）——
    await send(tester, '刚才那个数是多少');

    // ★ 断言 A：第 3 轮的 query 逐字带着第 1 轮的内容
    final q3 = fake.queries.last;
    expect(q3, contains(_FakeProvider.anchor));
    expect(q3, contains('【本会话前文】')); // 前文块确实注入了
    expect(q3, contains('刚才那个数是多少')); // 本轮问题也在

    // ★ 断言 B：第 2/3 轮的 assistant 气泡真的复述了锚点（端到端语义）
    expect(find.textContaining(_FakeProvider.rememberReply),
        findsNWidgets(2));

    // ★ 断言 C：不是「没带历史」的兜底回答
    expect(find.textContaining(_FakeProvider.noHistoryReply), findsNothing);
  });

  testWidgets('T6 反向证据：丢弃历史的 Provider 在第 3 轮必定「未携带历史」',
      (tester) async {
    // forgetful：恒定返回「（本轮未携带历史）」，不依赖历史
    final fake = _FakeProvider(forgetful: true);
    await pumpPage(tester, fake, kpId: 'kp-w6b');

    await send(tester, '第一轮问题');
    await send(tester, '第二轮问题');
    await send(tester, '第三轮问题');

    // 三轮都不会出现「我记得…」→ 证明上一条断言不是恒真的
    expect(find.textContaining(_FakeProvider.rememberReply), findsNothing);
    expect(find.textContaining(_FakeProvider.noHistoryReply), findsNWidgets(3));
  });

  // ==================== T8 ====================

  testWidgets('T8 「再讲一次」= 追加，历史讲解不被覆盖', (tester) async {
    final s = await sessions.createSessionForKp('kp-w8', title: '链式法则 讲解');
    await sessions.addMessage(
        sessionId: s.id, role: 'assistant', content: '旧讲解', modelId: 'dify-t6');

    final fake = _FakeProvider(explainText: '新讲解');
    await pumpPage(tester, fake, kpId: 'kp-w8');
    expect(find.text('旧讲解'), findsOneWidget);

    await tester.tap(find.text('再讲一次'));
    await tester.pumpAndSettle();

    final msgs = await sessions.listMessages(s.id);
    expect(msgs, hasLength(2), reason: '是追加，不是覆盖'); // ①
    expect(msgs.map((m) => m.content), ['旧讲解', '新讲解']); // ② 旧内容仍在
    expect(msgs.last.modelId, 'dify-t6'); // ③ 新消息是讲解
    expect(find.text('旧讲解'), findsOneWidget); // ② UI 上仍可见
    expect(find.text('新讲解'), findsOneWidget);
    expect(find.text('重新生成'), findsNothing); // ⑥ 文案是「再讲一次」
  });

  testWidgets('T8 断言④ 用户自建会话点「再讲一次」→ 讲解写入该会话（不是主会话）',
      (tester) async {
    // 主会话先有一条历史讲解
    final primary =
        await sessions.createSessionForKp('kp-w8b', title: '链式法则 讲解');
    await sessions.addMessage(
        sessionId: primary.id, role: 'assistant', content: '主会话旧讲解',
        modelId: 'dify-t6');

    final fake = _FakeProvider(explainText: '新讲解B');
    await pumpPage(tester, fake, kpId: 'kp-w8b');

    // AppBar「新建会话」→ 切到用户自建会话
    await tester.tap(find.byTooltip('新建会话'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('再讲一次'));
    await tester.pumpAndSettle();

    final list = await sessions.listSessionsForKp('kp-w8b');
    final created = list.firstWhere((s) => s.id != primary.id);
    final msgs = await sessions.listMessages(created.id);
    expect(msgs, hasLength(1));
    expect(msgs.single.content, '新讲解B'); // 写进**当前**会话
    expect(msgs.single.modelId, 'dify-t6');
    // 主会话不受影响（没有被覆盖、也没有被串写）
    final primaryMsgs = await sessions.listMessages(primary.id);
    expect(primaryMsgs, hasLength(1));
    expect(primaryMsgs.single.content, '主会话旧讲解');
  });

  // ==================== 会话面板（回归：重复 pop / 新建无效） ====================

  /// 打开会话面板（AppBar 的「会话列表」按钮）。
  Future<void> openSessionPanel(WidgetTester tester) async {
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();
  }

  testWidgets('R1 点会话项只是切换会话，不会退出老师模式页', (tester) async {
    // 两条**已命名**的会话，各带一条可区分的消息，便于断言切到了哪一条。
    final a = await sessions.createSessionForKp('kp-r1', title: '会话甲');
    final b = await sessions.createSessionForKp('kp-r1', title: '会话乙');
    await sessions.addMessage(
        sessionId: a.id, role: 'assistant', content: '甲的消息',
        modelId: 'dify-t6');
    await sessions.addMessage(
        sessionId: b.id, role: 'assistant', content: '乙的消息',
        modelId: 'dify-t6');

    final fake = _FakeProvider();
    await pumpPage(tester, fake, kpId: 'kp-r1');
    expect(find.text('老师模式 · 链式法则'), findsOneWidget);

    // 看看当前停在哪一条（主会话的选法不在本用例的断言范围内）。
    final startOnA = find.text('甲的消息').evaluate().isNotEmpty;
    final otherTitle = startOnA ? '会话乙' : '会话甲';
    final otherMsg = startOnA ? '乙的消息' : '甲的消息';

    await openSessionPanel(tester);
    await tester.tap(find.text(otherTitle));
    await tester.pumpAndSettle();

    // ★ 回归断言：页面还在（旧实现父页多 pop 了一次，会把 TeacherPage 自己弹掉）
    expect(find.text('老师模式 · 链式法则'), findsOneWidget);
    // 并且真的切到了被点中的那条会话
    expect(find.text(otherMsg), findsOneWidget);
  });

  testWidgets('R2 面板里点「新建对话」真的新建一条并切过去', (tester) async {
    // 先有一条带消息的主会话：这样进入时不会触发自动讲解，计数干净。
    final primary =
        await sessions.createSessionForKp('kp-r2', title: '链式法则 讲解');
    await sessions.addMessage(
        sessionId: primary.id, role: 'assistant', content: '已有讲解',
        modelId: 'dify-t6');

    final before = await sessions.listSessionsForKp('kp-r2');
    expect(before, hasLength(1));

    final fake = _FakeProvider();
    await pumpPage(tester, fake, kpId: 'kp-r2');
    expect(find.text('已有讲解'), findsOneWidget);

    await openSessionPanel(tester);
    await tester.tap(find.text('新建对话'));
    await tester.pumpAndSettle();

    // ★ 会话数 +1（旧实现接的是 _bootstrap()，主会话已存在 → 什么都不建）
    final after = await sessions.listSessionsForKp('kp-r2');
    expect(after.length, before.length + 1,
        reason: '「新建对话」必须真的建一条会话');
    final created = after.firstWhere((s) => s.id != primary.id);
    expect(created.deletedAt, isNull);

    // 页面仍在，且当前会话已切到新建的那条（空的非主会话 → 显示这条提示）
    expect(find.text('老师模式 · 链式法则'), findsOneWidget);
    expect(find.text('这个会话还没有内容，问点什么吧'), findsOneWidget);
    expect(find.text('已有讲解'), findsNothing, reason: '已切走，不再渲染主会话的消息');
  });

  testWidgets('N4 只有 model_id=dify-t6 的消息才渲染「讲解」标签', (tester) async {
    final e = Ulid(millis: 1000).toString();
    final c = Ulid(millis: 2000).toString();
    await insertSession(id: e, kpId: 'kp-n4', type: 'explain');
    await insertSession(id: c, kpId: 'kp-n4', type: 'chat');
    // 讲解（dify-t6）/ 追问回答（dify-t5）/ 老数据（modelId=null）/ 用户提问
    await sessions.addMessage(
        sessionId: e, role: 'assistant', content: '讲解正文', modelId: 'dify-t6');
    await sessions.addMessage(
        sessionId: e, role: 'assistant', content: '追问回答', modelId: 'dify-t5');
    await sessions.addMessage(
        sessionId: e, role: 'assistant', content: '老数据回答'); // modelId 为 null
    await sessions.addMessage(
        sessionId: c, role: 'user', content: '用户提问');

    final fake = _FakeProvider();
    await pumpPage(tester, fake, kpId: 'kp-n4');

    // 四条消息都渲染出来了
    expect(find.text('讲解正文'), findsOneWidget);
    expect(find.text('追问回答'), findsOneWidget);
    expect(find.text('老数据回答'), findsOneWidget);
    expect(find.text('用户提问'), findsOneWidget);
    // 但「讲解」标签只有 1 个（仅 dify-t6 那条）——modelId 为 null/异常值都不渲染
    expect(find.text('讲解'), findsOneWidget);
  });
}
