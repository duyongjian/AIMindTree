/// 老师模式会话：仓储层测试（老数据合并矩阵 + 主会话判定 + 隔离 + outbox）。
///
/// 覆盖测试方案：
/// - §5 合并矩阵 M1–M9（explain→chat 方向 / 幂等 / 失败回退 / type 归一 / 排序键）
/// - M10 崩溃重试幂等、M11 newDerivedUlid 派生 id 规格（整体逐字节 +1）
/// - T1 软删后建新会话、T3 主会话顺延、T5 先合并后取主会话、T7 会话隔离
/// - T9 会话写操作登记 outbox、T11 迁移字段原样保留（含 model_id 为 null）
/// - T12 listAgentSessions 过滤语义零变化
///
/// 全部用内存库 `NativeDatabase.memory()`，不依赖任何 Provider / 真实 LLM。
library;

import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/core/id.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/ai_session_repository.dart'
    show AiSessionRepository, LegacyMergeOutcome;
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:aimindtree_app/data/sync/sync_types.dart';
import 'package:aimindtree_app/features/shared/session_ui.dart';
import 'package:aimindtree_app/features/teacher/teacher_session_controller.dart';
// 只取 Value：drift 也导出 isNull/isNotNull，与 matcher 同名会冲突。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ulid/ulid.dart';

/// 造一个**字节可控**的 ULID（seed 递增 → id 字典序严格递增）。
///
/// ⚠️ 刻意让全部 16 个字节都 < 0x80：`newDerivedUlid` 是「逐字节 +1、无进位」
/// （`(b + 1) & 0xFF`），一旦某字节为 0xFF，+1 会回绕成 0x00，从而**破坏保序**。
/// 夹具不含 0xFF 字节，保序断言才是确定性的（否则会变成概率性通过的假阳性）。
String _ulid(int seed) {
  final bytes = <int>[
    0x01, 0x02, 0x03, 0x04, 0x05, 0x10 + seed, // 时间字节（小值）
    for (var i = 0; i < 10; i++) (0x20 + seed + i) & 0x7F, // 随机字节（< 0x80）
  ];
  return Ulid.fromBytes(bytes).toString();
}

/// 含 0xFF 字节的 ULID（M11 ⑤ 取模验证用）。
String _ulidWithFF() => Ulid.fromBytes(<int>[
      0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
      0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C,
      0x0D, 0x0E, 0x0F, 0xFF, // 末字节 0xFF
    ]).toString();

/// 注入合并失败的仓储（覆写测试接缝 `insertMessageRow`）。
class _FailingRepo extends AiSessionRepository {
  _FailingRepo(super.db);

  @override
  Future<void> insertMessageRow(AiMessagesCompanion row) async {
    throw StateError('injected');
  }
}

void main() {
  late AppDatabase db;
  late AiSessionRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AiSessionRepository(db, deviceId: 'test-device');
  });

  tearDown(() async {
    SyncOutboxRepo.current = null;
    await db.close();
  });

  // ---------------- 造数助手 ----------------

  Future<void> insertSession({
    required String id,
    required String kpId,
    required String type,
    String title = '',
    DateTime? updatedAt,
    DateTime? deletedAt,
    int version = 1,
  }) async {
    await db.into(db.aiSessions).insert(AiSessionsCompanion(
          id: Value(id),
          type: Value(type),
          targetRef: Value(kpId),
          title: Value(title),
          kpId: Value(kpId),
          modelId: const Value('dify-t1-local'),
          tutorState: const Value('{}'),
          updatedAt: Value(updatedAt ?? DateTime.now().toUtc()),
          version: Value(version),
          deviceId: const Value('test-device'),
          deletedAt: Value(deletedAt),
        ));
  }

  Future<void> insertMessage({
    required String id,
    required String sessionId,
    required String role,
    required String content,
    String? modelId,
    DateTime? updatedAt,
  }) async {
    await repo.insertMessageRow(AiMessagesCompanion(
      id: Value(id),
      sessionId: Value(sessionId),
      role: Value(role),
      contentMd: Value(content),
      modelId: Value(modelId),
      updatedAt: Value(updatedAt ?? DateTime.now().toUtc()),
      version: const Value(1),
      deviceId: const Value('test-device'),
    ));
  }

  Future<AiSessionRow?> sessionRow(String id) =>
      (db.select(db.aiSessions)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<AiMessageRow?> messageRow(String id) =>
      (db.select(db.aiMessages)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<AiSessionRow>> allSessionsForKp(String kpId) =>
      (db.select(db.aiSessions)..where((t) => t.kpId.equals(kpId))).get();

  // ==================== T1 ====================

  test('T1 软删会话后 getOrCreateForKp 返回新会话（非墓碑行）', () async {
    final a = await repo.getOrCreateForKp(
        kpId: 'kp-t1', task: AiTask.t5Ask);
    await repo.addMessage(
        sessionId: a.id, role: 'user', content: '旧消息');
    await repo.deleteSession(a.id);

    final b = await repo.getOrCreateForKp(
        kpId: 'kp-t1', task: AiTask.t5Ask);

    expect(b.deletedAt, isNull); // ① 返回行未删
    expect(b.id, isNot(a.id)); // ② 是新会话，不是墓碑
    expect(b.type, 'chat'); // ③
    final rows = await allSessionsForKp('kp-t1');
    expect(rows.length, 2); // ④ 共 2 行
    expect(rows.where((r) => r.deletedAt == null).length, 1); // ④ 恰好 1 行未删
    expect(await repo.listMessages(b.id), isEmpty); // ⑤ 不复用旧消息
    expect((await repo.listSessionsForKp('kp-t1')).map((s) => s.id),
        [b.id]); // ⑥
  });

  // ==================== T3 ====================

  test('T3 主会话 = id 最小者；删后顺延；全删为 null', () async {
    final a = _ulid(1);
    final b = _ulid(2);
    final c = _ulid(3);
    for (final id in [a, b, c]) {
      await insertSession(id: id, kpId: 'kp-t3', type: 'chat');
    }

    expect((await repo.primarySessionForKp('kp-t3'))?.id, a); // ①
    await repo.deleteSession(a);
    expect((await repo.primarySessionForKp('kp-t3'))?.id, b); // ② 顺延
    await repo.deleteSession(b);
    expect((await repo.primarySessionForKp('kp-t3'))?.id, c); // ③
    await repo.deleteSession(c);
    expect(await repo.primarySessionForKp('kp-t3'), isNull); // ④ 全删

    // ⑥ 反向断言：primarySessionForKp（判定）与 getOrCreateForKp（补建）
    // 是两个不同语义——全删后前者返回 null，后者会补一条新行。
    final created = await repo.getOrCreateForKp(
        kpId: 'kp-t3', task: AiTask.t5Ask);
    expect(created.deletedAt, isNull);
    expect((await repo.primarySessionForKp('kp-t3'))?.id, created.id);
  });

  // ==================== 合并矩阵 M1–M9 ====================

  test('M1 explain-only → 原地归一为 chat，不迁移消息', () async {
    final e = _ulid(1);
    await insertSession(id: e, kpId: 'kp-m1', type: 'explain');
    final msgId = _ulid(11);
    await insertMessage(
        id: msgId, sessionId: e, role: 'assistant',
        content: '讲解正文', modelId: 'dify-t6');

    final r = await repo.mergeLegacyExplain('kp-m1');
    expect(r.outcome, LegacyMergeOutcome.merged); // ①
    expect(r.normalizedOnly, 1); // ①
    expect(r.movedMessages, 0);

    final row = await sessionRow(e);
    expect(row!.type, 'chat'); // ② 归一
    expect(row.version, greaterThanOrEqualTo(2)); // ② version +1
    expect(row.deletedAt, isNull);

    expect(await repo.listMessages(e), hasLength(1)); // ③ 未迁移
    expect((await repo.primarySessionForKp('kp-m1'))?.id, e); // ④
    expect(await repo.listSessionsForKp('kp-m1'), hasLength(1)); // ⑤
    expect((await messageRow(msgId))!.modelId, 'dify-t6'); // ⑥
  });

  test('M2 chat-only → skippedNoLegacy（零写入）', () async {
    final c = _ulid(1);
    await insertSession(id: c, kpId: 'kp-m2', type: 'chat');
    await insertMessage(id: _ulid(11), sessionId: c, role: 'user', content: 'a');
    await insertMessage(
        id: _ulid(12), sessionId: c, role: 'assistant', content: 'b');

    final r = await repo.mergeLegacyExplain('kp-m2');
    expect(r.outcome, LegacyMergeOutcome.skippedNoLegacy); // ①
    expect(await repo.listMessages(c), hasLength(2)); // ③
    expect((await repo.primarySessionForKp('kp-m2'))?.id, c); // ④
    expect(await repo.listSessionsForKp('kp-m2'), hasLength(1)); // ⑤
  });

  test('M3 两者都有且 explain id 更小 → 主会话是 chat（不是 explain）', () async {
    final e = _ulid(1); // explain 更早
    final c = _ulid(2); // chat 更晚
    await insertSession(id: e, kpId: 'kp-m3', type: 'explain');
    await insertSession(id: c, kpId: 'kp-m3', type: 'chat');
    final eMsg = _ulid(11);
    final cMsg = _ulid(21);
    await insertMessage(
        id: eMsg, sessionId: e, role: 'assistant',
        content: 'EXPLAIN-BODY', modelId: 'dify-t6');
    await insertMessage(
        id: cMsg, sessionId: c, role: 'user',
        content: 'ASK-BODY', modelId: null);

    final r = await repo.mergeLegacyExplain('kp-m3');
    expect(r.outcome, LegacyMergeOutcome.merged);
    expect(r.movedMessages, 1);
    expect(r.chatSessionId, c);
    expect(r.explainSessionId, e);

    // ① 复制迁入（新 id），② 原行软删但仍在库
    final derived = newDerivedUlid(eMsg);
    expect(await messageRow(derived), isNotNull);
    final old = await messageRow(eMsg);
    expect(old!.deletedAt, isNotNull); // ②
    expect((await messageRow(derived))!.sessionId, c); // ⑤

    expect((await sessionRow(e))!.deletedAt, isNotNull); // ③
    expect((await repo.primarySessionForKp('kp-m3'))?.id, c); // ④ 反证
    expect(await repo.listSessionsForKp('kp-m3'), hasLength(1)); // ⑤

    // ⑥ 消息流按 id ASC：讲解（较早）在前、追问在后
    final msgs = await repo.listMessages(c);
    expect(msgs.map((m) => m.content), ['EXPLAIN-BODY', 'ASK-BODY']);
  });

  test('M4 两者都有且 chat id 更小 → 结果与 M3 一致（方向只看 type）', () async {
    final c = _ulid(1); // chat 更早
    final e = _ulid(2); // explain 更晚
    await insertSession(id: c, kpId: 'kp-m4', type: 'chat');
    await insertSession(id: e, kpId: 'kp-m4', type: 'explain');
    final cMsg = _ulid(11);
    final eMsg = _ulid(21);
    await insertMessage(
        id: cMsg, sessionId: c, role: 'user', content: 'ASK');
    await insertMessage(
        id: eMsg, sessionId: e, role: 'assistant',
        content: 'EXPLAIN', modelId: 'dify-t6');

    final r = await repo.mergeLegacyExplain('kp-m4');
    expect(r.outcome, LegacyMergeOutcome.merged);
    expect(r.chatSessionId, c); // 保留方仍是 chat
    expect((await repo.primarySessionForKp('kp-m4'))?.id, c);
    expect((await sessionRow(e))!.deletedAt, isNotNull);
    final msgs = await repo.listMessages(c);
    expect(msgs.map((m) => m.content), ['ASK', 'EXPLAIN']);
  });

  test('M5/M10 幂等：已合并过再调用 → skippedNoLegacy 且不产生新行', () async {
    final e = _ulid(1);
    final c = _ulid(2);
    await insertSession(id: e, kpId: 'kp-m5', type: 'explain');
    await insertSession(id: c, kpId: 'kp-m5', type: 'chat');
    final eMsg = _ulid(11);
    await insertMessage(
        id: eMsg, sessionId: e, role: 'assistant',
        content: 'EXPLAIN', modelId: 'dify-t6');

    await repo.mergeLegacyExplain('kp-m5');
    final idsBefore = (await repo.listMessages(c)).map((m) => m.id).toList();
    final countBefore = (await db.select(db.aiMessages).get()).length;

    final again = await repo.mergeLegacyExplain('kp-m5'); // 崩溃重试
    expect(again.outcome, LegacyMergeOutcome.skippedNoLegacy);
    final idsAfter = (await repo.listMessages(c)).map((m) => m.id).toList();
    expect(idsAfter, idsBefore); // id 集合完全相同
    expect((await db.select(db.aiMessages).get()).length, countBefore); // 无重复行
    expect((await repo.primarySessionForKp('kp-m5'))?.id, c);
  });

  test('M6 迁移失败（注入接缝）→ failed 且源数据一条不删', () async {
    final e = _ulid(1);
    final c = _ulid(2);
    await insertSession(id: e, kpId: 'kp-m6', type: 'explain');
    await insertSession(id: c, kpId: 'kp-m6', type: 'chat');
    final eMsg = _ulid(11);
    await insertMessage(
        id: eMsg, sessionId: e, role: 'assistant',
        content: 'EXPLAIN-KEEP', modelId: 'dify-t6');

    final failing = _FailingRepo(db);
    final r = await failing.mergeLegacyExplain('kp-m6');

    expect(r.outcome, LegacyMergeOutcome.failed); // ① 不抛异常给调用方
    expect(r.error, isNotNull);
    final eRow = await sessionRow(e);
    expect(eRow, isNotNull); // ② explain 行仍在库
    expect(eRow!.deletedAt, isNull); // ② 未被软删
    final src = await messageRow(eMsg);
    expect(src!.deletedAt, isNull); // ③ 消息一条没少
    expect(src.contentMd, 'EXPLAIN-KEEP');
    expect((await repo.primarySessionForKp('kp-m6'))?.id, c); // ④ 不阻断
    expect(await repo.listSessionsForKp('kp-m6'), hasLength(2)); // ⑤ 残留可见
  });

  test('M8 迁移后消息顺序稳定（id ASC）+ updated_at 原样保留', () async {
    final e = _ulid(1);
    final c = _ulid(2);
    await insertSession(id: e, kpId: 'kp-m8', type: 'explain');
    await insertSession(id: c, kpId: 'kp-m8', type: 'chat');
    final base = DateTime.utc(2026, 1, 1);
    final srcIds = [_ulid(11), _ulid(12), _ulid(13)];
    for (var i = 0; i < 3; i++) {
      await insertMessage(
        id: srcIds[i],
        sessionId: e,
        role: i.isEven ? 'user' : 'assistant',
        content: 'msg$i',
        updatedAt: base.add(Duration(seconds: i)), // 与 id 同序
      );
    }

    await repo.mergeLegacyExplain('kp-m8');
    final msgs = await repo.listMessages(c);

    // 保序：派生 id 与源 id 同序（夹具无 0xFF 字节 → 逐字节 +1 不回绕）
    expect(msgs.map((m) => m.content), ['msg0', 'msg1', 'msg2']);
    expect(msgs.map((m) => m.id),
        [for (final s in srcIds) newDerivedUlid(s)]); // 新派生的 id 严格递增
    // updated_at 原样保留（不是迁移时刻）。
    // ⚠️ drift 读回的是本地时区表示，比较前统一转 UTC。
    expect(msgs[0].createdAt.toUtc(), base.toUtc());
    expect(msgs[2].createdAt.toUtc(), base.add(const Duration(seconds: 2)).toUtc());
  });

  test('M9 explain 行已是墓碑 → skippedNoLegacy，不触发迁移', () async {
    final e = _ulid(1);
    final c = _ulid(2);
    await insertSession(id: e, kpId: 'kp-m9', type: 'explain',
        deletedAt: DateTime.now().toUtc());
    await insertSession(id: c, kpId: 'kp-m9', type: 'chat');
    await insertMessage(
        id: _ulid(11), sessionId: e, role: 'assistant', content: 'x');

    final r = await repo.mergeLegacyExplain('kp-m9');
    expect(r.outcome, LegacyMergeOutcome.skippedNoLegacy);
    expect(await repo.listMessages(c), isEmpty); // 不产生新行
    expect((await repo.primarySessionForKp('kp-m9'))?.id, c);
    expect(await repo.listSessionsForKp('kp-m9'), hasLength(1));
  });

  // ==================== M11 派生 id 规格 ====================

  group('M11 newDerivedUlid 规格', () {
    test('① 派生 id ≠ 源 id', () {
      final s = _ulid(1);
      expect(newDerivedUlid(s), isNot(s));
    });
    test('② 两个不同源 id 派生后不撞（单射）', () {
      final a = _ulid(1);
      final b = _ulid(2);
      expect(newDerivedUlid(a), isNot(newDerivedUlid(b)));
    });
    test('③ 保序：源 id 递增 → 派生 id 递增', () {
      final ids = [_ulid(1), _ulid(2), _ulid(3)];
      final d = ids.map(newDerivedUlid).toList();
      expect(d[0].compareTo(d[1]), lessThan(0));
      expect(d[1].compareTo(d[2]), lessThan(0));
    });
    test('④ 幂等：同源于两次派生完全相同', () {
      final s = _ulid(5);
      expect(newDerivedUlid(s), newDerivedUlid(s));
    });
    test('⑤ 逐字节取模：源字节 0xFF → 派生为 0x00', () {
      final ff = _ulidWithFF();
      final srcBytes = Ulid.parse(ff).toBytes();
      expect(srcBytes[15], 0xFF);
      final outBytes = Ulid.parse(newDerivedUlid(ff)).toBytes();
      expect(outBytes[15], 0x00); // 必须取模，否则溢出破坏单射
    });
    test('⑥ 派生 id 仍是合法 26 字符 Crockford ULID', () {
      final d = newDerivedUlid(_ulid(7));
      expect(d.length, 26);
      // ulid 包用小写 Crockford Base32 编码
      expect(RegExp(r'^[0-9a-hjkmnp-tv-z]{26}$').hasMatch(d), isTrue);
    });
  });

  // ==================== T5 加载顺序 ====================

  test('T5 先合并后取主会话：explain 的 id 更小也不抢主会话', () async {
    final e = _ulid(1); // explain 更早
    final c = _ulid(2);
    await insertSession(id: e, kpId: 'kp-t5', type: 'explain');
    await insertSession(id: c, kpId: 'kp-t5', type: 'chat');
    final eMsg = _ulid(11);
    final cMsg = _ulid(21);
    await insertMessage(
        id: eMsg, sessionId: e, role: 'assistant',
        content: '讲解', modelId: 'dify-t6');
    await insertMessage(
        id: cMsg, sessionId: c, role: 'user', content: '追问');

    // 先合并
    await repo.mergeLegacyExplain('kp-t5');
    // 后取主会话
    final primary = await repo.primarySessionForKp('kp-t5');
    expect(primary!.id, c); // ① 主会话 = C（不是 E）
    expect((await repo.listMessages(c)).map((m) => m.content),
        ['讲解', '追问']); // ④ 合并后消息流
  });

  // ==================== T7 / T12 会话隔离 ====================

  test('T7 老师模式列表不含 Agent 会话，反之亦然（含 explain 残留）', () async {
    // 2 条 Agent 会话（kpId=null）+ 1 条软删的 Agent 会话
    final ag1 = _ulid(1);
    final ag2 = _ulid(2);
    final agDeleted = _ulid(3);
    for (final id in [ag1, ag2]) {
      await db.into(db.aiSessions).insert(AiSessionsCompanion(
            id: Value(id),
            type: const Value('chat'),
            targetRef: const Value(''),
            title: const Value(''),
            kpId: const Value(null),
            modelId: const Value('dify-t1-local'),
            tutorState: const Value('{}'),
            updatedAt: Value(DateTime.now().toUtc()),
            version: const Value(1),
            deviceId: const Value('test-device'),
          ));
    }
    await db.into(db.aiSessions).insert(AiSessionsCompanion(
          id: Value(agDeleted),
          type: const Value('chat'),
          targetRef: const Value(''),
          title: const Value(''),
          kpId: const Value(null),
          modelId: const Value('dify-t1-local'),
          tutorState: const Value('{}'),
          updatedAt: Value(DateTime.now().toUtc()),
          version: const Value(1),
          deviceId: const Value('test-device'),
          deletedAt: Value(DateTime.now().toUtc()),
        ));

    // 2 条老师 chat + 1 条 explain 残留
    final t1 = _ulid(11);
    final t2 = _ulid(12);
    final tExplain = _ulid(13);
    await insertSession(id: t1, kpId: 'kp-7', type: 'chat');
    await insertSession(id: t2, kpId: 'kp-7', type: 'chat');
    await insertSession(id: tExplain, kpId: 'kp-7', type: 'explain');

    final agent = await repo.listAgentSessions();
    expect(agent, hasLength(2)); // ① ⑥ 软删的不在
    expect(agent.every((s) => s.kpId == null && s.type == 'chat' &&
        s.deletedAt == null), isTrue);

    final teacher = await repo.listSessionsForKp('kp-7');
    expect(teacher, hasLength(3)); // ② 含 explain 残留（不按 type 过滤）
    expect(teacher.every((s) => s.kpId == 'kp-7' && s.deletedAt == null),
        isTrue);
    expect(teacher.map((s) => s.id), isNot(contains(ag1))); // ③
    // ④ 交集为空
    expect(teacher.map((s) => s.id).toSet()
        .intersection(agent.map((s) => s.id).toSet()), isEmpty);
  });

  test('T12 listAgentSessions 过滤语义零变化', () async {
    for (final seed in [1, 2]) {
      await db.into(db.aiSessions).insert(AiSessionsCompanion(
            id: Value(_ulid(seed)),
            type: const Value('chat'),
            targetRef: const Value(''),
            title: const Value(''),
            kpId: const Value(null),
            modelId: const Value('dify-t1-local'),
            tutorState: const Value('{}'),
            updatedAt: Value(DateTime.now().toUtc()),
            version: const Value(1),
            deviceId: const Value('test-device'),
          ));
    }
    final kpChat = _ulid(11);
    final kpExplain = _ulid(12);
    await insertSession(id: kpChat, kpId: 'kp-12', type: 'chat');
    await insertSession(id: kpExplain, kpId: 'kp-12', type: 'explain');

    final agent = await repo.listAgentSessions();
    expect(agent, hasLength(2)); // ①
    expect(agent.every((s) => s.type == 'chat' && s.kpId == null), isTrue);
    expect(agent.map((s) => s.id), isNot(contains(kpExplain))); // ②

    final teacher = await repo.listSessionsForKp('kp-12');
    expect(teacher, hasLength(2)); // ③ chat + explain 残留
    expect(teacher.every((s) => s.deletedAt == null), isTrue); // ④ 不含软删
  });

  // ==================== T9 outbox ====================

  group('T9 会话写操作登记 outbox', () {
    setUp(() {
      // 必须与仓储共用同一个 db 实例，否则 writer 静默跳过。
      SyncOutboxRepo.current = SyncOutboxRepo(db, deviceId: 'test-device');
    });

    tearDown(() {
      SyncOutboxRepo.current = null;
    });

    Future<List<SyncOutboxRow>> outboxRows() => db.select(db.syncOutbox).get();

    test('① 重命名 → 1 条 ai_sessions upsert，payload 含 title', () async {
      final s = _ulid(1);
      await insertSession(id: s, kpId: 'kp-t9', type: 'chat');
      (await outboxRows()).length; // 造数本身不产生 outbox（直接写表）
      await repo.renameSession(s, '新名字');
      final rows = (await outboxRows())
          .where((r) => r.entityTable == 'ai_sessions')
          .toList();
      expect(rows, hasLength(1));
      expect(rows.single.op, SyncOp.upsert.name);
      expect(rows.single.payloadJson, contains('新名字'));
    });

    test('② 清空 2 条消息 → 逐条 2 条 ai_messages upsert', () async {
      final s = _ulid(1);
      await insertSession(id: s, kpId: 'kp-t9', type: 'chat');
      await insertMessage(id: _ulid(11), sessionId: s, role: 'user', content: 'a');
      await insertMessage(
          id: _ulid(12), sessionId: s, role: 'assistant', content: 'b');
      await repo.clearMessages(s);
      final rows = (await outboxRows())
          .where((r) => r.entityTable == 'ai_messages')
          .toList();
      expect(rows, hasLength(2)); // 逐条，不是 1 条
      expect(rows.every((r) => r.op == SyncOp.upsert.name), isTrue);
    });

    test('③ 删除会话 → ai_sessions upsert（payload 含 deleted_at）+ 消息 upsert',
        () async {
      final s = _ulid(1);
      await insertSession(id: s, kpId: 'kp-t9', type: 'chat');
      await insertMessage(id: _ulid(11), sessionId: s, role: 'user', content: 'a');
      await repo.deleteSession(s);
      final rows = await outboxRows();
      final sess = rows.where((r) => r.entityTable == 'ai_sessions').toList();
      expect(sess, hasLength(1));
      expect(sess.single.op, SyncOp.upsert.name); // 软删靠 payload 传播
      expect(sess.single.payloadJson, contains('deleted_at'));
      expect(rows.where((r) => r.entityTable == 'ai_messages'), hasLength(1));
    });

    test('④ 合并迁移 N 条 → N 条 ai_messages upsert + explain 行 upsert',
        () async {
      final e = _ulid(1);
      final c = _ulid(2);
      await insertSession(id: e, kpId: 'kp-t9b', type: 'explain');
      await insertSession(id: c, kpId: 'kp-t9b', type: 'chat');
      await insertMessage(
          id: _ulid(11), sessionId: e, role: 'assistant', content: 'x',
          modelId: 'dify-t6');
      await repo.mergeLegacyExplain('kp-t9b');
      final rows = await outboxRows();
      // 迁移 1 条消息 → 2 条 ai_messages upsert：
      // ① 派生的新行（copy）② 原行软删的墓碑（payload 带 deleted_at）
      expect(rows.where((r) => r.entityTable == 'ai_messages'), hasLength(2));
      // type 归一必须走 upsertAiSession（G19），否则对端永远停在 explain
      expect(
          rows.where((r) =>
              r.entityTable == 'ai_sessions' && r.entityId == e),
          hasLength(1));
    });
  });

  // ==================== T11 迁移字段原样保留 ====================

  test('T11 迁移保留 role/content/updated_at/model_id（含 null）', () async {
    final e = _ulid(1);
    final c = _ulid(2);
    await insertSession(id: e, kpId: 'kp-t11', type: 'explain');
    await insertSession(id: c, kpId: 'kp-t11', type: 'chat');

    final base = DateTime.utc(2026, 2, 2, 3, 4, 5);
    final specs = <(String, String, String?, DateTime)>[
      (_ulid(11), 'user', null, base),
      (_ulid(12), 'assistant', 'dify-t6', base.add(const Duration(seconds: 1))),
      (_ulid(13), 'assistant', 'dify-t5', base.add(const Duration(seconds: 2))),
      (_ulid(14), 'assistant', null, base.add(const Duration(seconds: 3))),
    ];
    for (final (id, role, modelId, at) in specs) {
      await insertMessage(
          id: id, sessionId: e, role: role, content: 'body-$role-$modelId',
          modelId: modelId, updatedAt: at);
    }

    await repo.mergeLegacyExplain('kp-t11');
    final msgs = await repo.listMessages(c);
    expect(msgs, hasLength(4)); // ① 4 条新消息

    for (var i = 0; i < specs.length; i++) {
      final (srcId, role, modelId, at) = specs[i];
      final newId = newDerivedUlid(srcId);
      final newRow = await messageRow(newId);
      expect(newRow, isNotNull, reason: '派生行应存在');
      expect(newRow!.role, role); // ② 逐字段相等
      expect(newRow.contentMd, 'body-$role-$modelId');
      // ② updated_at 原样保留（drift 读回为本地时区，统一转 UTC 再比较）
      expect(newRow.updatedAt.toUtc(), at.toUtc());
      expect(newRow.modelId, modelId); // ③④ 可容忍 null
      expect(newRow.sessionId, c); // ⑤
      expect(newRow.id, isNot(srcId)); // ⑤ 是复制（不是改 session_id）
      final oldRow = await messageRow(srcId);
      expect(oldRow!.deletedAt, isNotNull); // ⑥ 原行软删
    }
    // ⑥ 行数不变（墓碑行仍在库）
    final all = await db.select(db.aiMessages).get();
    expect(all, hasLength(8)); // 4 原行 + 4 新行
    // ⑧ model_id 为 null 的消息不是「讲解」
    final msgs2 = await repo.listMessages(c);
    final nullOne = msgs2.firstWhere((m) => m.modelId == null);
    expect(isExplainMessage(nullOne), isFalse);
    expect(() => isExplainMessage(nullOne), returnsNormally);
  });

  // ==================== 控制器补建主会话（T3 widget 层的仓储侧证据） ====================

  test('控制器 ensurePrimarySession 只补建空会话，绝不发起讲解（问题9）', () async {
    final controller = TeacherSessionController(repo: repo, kp: _kp('kp-ctrl'));
    // 无主会话 → 补建一条空会话。以前这里要 BuildContext，且顺手讲解一次。
    final s = await controller.ensurePrimarySession();
    expect(s.kpId, 'kp-ctrl');
    expect(s.title, isNotEmpty);
    expect(await repo.listMessages(s.id), isEmpty); // 打开知识点不再自动讲解
    // 已有主会话 → 原样返回，不重复建
    expect((await controller.ensurePrimarySession()).id, s.id);
    expect(await repo.listSessionsForKp('kp-ctrl'), hasLength(1));
  });

  test('deleteSession 删掉最后一条会话 → 补建空会话（不自动讲解）', () async {
    final a = _ulid(1);
    await insertSession(id: a, kpId: 'kp-del2', type: 'chat');
    await insertMessage(
        id: _ulid(11), sessionId: a, role: 'assistant', content: '旧讲解',
        modelId: 'dify-t6');
    final controller = TeacherSessionController(repo: repo, kp: _kp('kp-del2'));

    final r = await controller.deleteSession(sessionId: a);
    expect(r.$1, isNotNull);
    expect(r.$1, isNot(a)); // 是新建的一条，不是复活旧会话
    expect(r.$3, '已新建空会话');
    expect(await repo.listMessages(r.$1!), isEmpty); // 空会话：等用户点按钮
  });

  test('控制器 createUserSession 不自动讲解（纯本地建会话）', () async {
    final kp = _kp('kp-ctrl2');
    final controller = TeacherSessionController(repo: repo, kp: kp);
    final s = await controller.createUserSession();
    expect(s.kpId, 'kp-ctrl2');
    expect(s.type, 'chat');
    expect(await repo.listMessages(s.id), isEmpty); // 不自动讲解
  });

  test('deleteSession 有其它会话时顺延到下一个（主会话顺延）', () async {
    final a = _ulid(1);
    final b = _ulid(2);
    await insertSession(id: a, kpId: 'kp-del', type: 'chat');
    await insertSession(id: b, kpId: 'kp-del', type: 'chat');
    await insertMessage(id: _ulid(11), sessionId: b, role: 'user',
        content: '第二会话首问');
    final kp = _kp('kp-del');
    final controller = TeacherSessionController(repo: repo, kp: kp);

    final r = await controller.deleteSession(sessionId: a);
    expect(r.$1, b); // 顺延到下一个未删会话
    final title = deriveSessionTitle(
      storedTitle: '',
      messages: await repo.listMessages(b),
      fallbackTitle: '${kp.name} 讲解',
    );
    expect(title, '第二会话首问'); // 标题由首条 user 消息派生
    expect(r.$2, title);
    expect(r.$3, contains('已切换到会话'));
  });
}

// -------- 辅助：构造 KnowledgePoint --------

KnowledgePoint _kp(String id) => KnowledgePoint(
      id: id,
      name: '链式法则',
      type: KnowledgePointType.theorem,
      definition: '复合函数求导法则',
      sourceNoteId: '',
      sourceStart: -1,
      sourceEnd: -1,
      sourceQuote: '原文锚点',
    );
