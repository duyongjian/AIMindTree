/// SyncEngine 集成测试（T03）。
///
/// 覆盖：
///   - push 成功/失败 -> outbox 状态正确切换；
///   - pull 自回声过滤（deviceId == 本地 -> 跳过）；
///   - LWW: version 大者赢；
///   - LWW: version 相等时 updatedAt 晚者赢；
///   - tombstone（remote.deletedAt != null）-> 本地硬删除；
///   - 完整 push -> 服务端 -> pull -> 本地 merge 闭环。
///
/// 用 NativeDatabase.memory() + MockSyncApi 模拟两端。
library;

import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/sync/sync_api.dart';
import 'dart:convert';
import 'package:aimindtree_app/data/sync/sync_engine.dart';
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:aimindtree_app/data/sync/sync_types.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

SyncEnvelope _mkEnv({
  required String deviceId,
  required String entityTable,
  required String entityId,
  required int baseVersion,
  required DateTime updatedAt,
  Map<String, dynamic>? payload,
  SyncOp op = SyncOp.upsert,
  DateTime? deletedAt,
}) {
  return SyncEnvelope(
    deviceId: deviceId,
    entityTable: entityTable,
    entityId: entityId,
    op: op,
    payload: payload ?? {'id': entityId, 'name': 'auto-test'},
    baseVersion: baseVersion,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
  );
}

void main() {
  late AppDatabase db;
  late SyncOutboxRepo outbox;
  late MockSyncApi api;
  late SyncEngine engine;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    outbox = SyncOutboxRepo(db, deviceId: 'local-dev');
    api = MockSyncApi(deviceIdOfCaller: 'remote-device-1');
    engine = SyncEngine(db: db, api: api, outbox: outbox, deviceId: 'local-dev');
  });

  tearDown(() async {
    await db.close();
  });

  group('Push', () {
    test('空 outbox → 0 push', () async {
      final r = await engine.push();
      expect(r.pushed, 0);
      expect(r.failed, 0);
      expect(api.pushHistory, isEmpty);
    });

    test('有 pending → 标记 done', () async {
      await outbox.enqueue(
        entityTable: 'notebooks',
        entityId: 'nb1',
        op: SyncOp.upsert,
        payload: {'id': 'nb1', 'name': '测试'},
        baseVersion: 1,
      );
      final r = await engine.push();
      expect(r.pushed, 1);
      expect(r.failed, 0);
      expect(api.pushHistory.length, 1);
      expect(api.pushHistory.first.first.entityId, 'nb1');
      // outbox 应被 markDone
      final pendingCount = await outbox.pendingCount();
      expect(pendingCount, 0);
    });

    test('push 失败 → 标记 failed + retryCount+1', () async {
      await outbox.enqueue(
        entityTable: 'notebooks',
        entityId: 'nb1',
        op: SyncOp.upsert,
        payload: {'id': 'nb1'},
        baseVersion: 1,
      );
      api.pushShouldFail = true;
      final r = await engine.push();
      expect(r.pushed, 0);
      expect(r.failed, 1);
      final failed = await outbox.failedCount();
      expect(failed, 1);
    });
  });

  group('Pull - 自回声过滤', () {
    test('deviceId == 本地 → 跳过', () async {
      api.enqueuePull([
        _mkEnv(
          deviceId: 'local-dev', // 自回声
          entityTable: 'notebooks',
          entityId: 'nb1',
          baseVersion: 1,
          updatedAt: DateTime.now().toUtc(),
        ),
      ]);
      final r = await engine.pull();
      expect(r.applied, 0);
      expect(r.skipped, 1);
      // 本地应无 nb1
      final rows = await db.select(db.notebooks).get();
      expect(rows, isEmpty);
    });

    test('deviceId != 本地 → apply', () async {
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'notebooks',
          entityId: 'nb1',
          baseVersion: 1,
          updatedAt: DateTime.now().toUtc(),
        ),
      ]);
      final r = await engine.pull();
      expect(r.applied, 1);
      final rows = await db.select(db.notebooks).get();
      expect(rows.length, 1);
      expect(rows.first.id, 'nb1');
    });
  });

  group('Pull - LWW', () {
    Future<void> seedLocal(String id, int version, DateTime at) async {
      await db.into(db.notebooks).insert(NotebooksCompanion(
            id: Value(id),
            name: Value('local-$id'),
            updatedAt: Value(at),
            version: Value(version),
            deviceId: const Value('local-dev'),
          ));
    }

    test('remote.version > local.version → apply remote', () async {
      final t = DateTime.now().toUtc();
      await seedLocal('nb1', 1, t);
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'notebooks',
          entityId: 'nb1',
          baseVersion: 2,
          updatedAt: t.add(const Duration(seconds: 1)),
          payload: {'id': 'nb1', 'name': 'remote-new'},
        ),
      ]);
      await engine.pull();
      final r = (await db.select(db.notebooks).get()).first;
      expect(r.name, 'remote-new');
      expect(r.version, 2);
    });

    test('remote.version < local.version → keep local', () async {
      final t = DateTime.now().toUtc();
      await seedLocal('nb1', 5, t);
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'notebooks',
          entityId: 'nb1',
          baseVersion: 3,
          updatedAt: t.add(const Duration(seconds: 1)),
          payload: {'id': 'nb1', 'name': 'remote-old'},
        ),
      ]);
      await engine.pull();
      final r = (await db.select(db.notebooks).get()).first;
      expect(r.name, 'local-nb1');
      expect(r.version, 5);
    });

    test('version 相等 → updatedAt 晚者赢', () async {
      final t = DateTime.now().toUtc();
      await seedLocal('nb1', 1, t);
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'notebooks',
          entityId: 'nb1',
          baseVersion: 1,
          updatedAt: t.add(const Duration(seconds: 1)), // 晚
          payload: {'id': 'nb1', 'name': 'remote-newer'},
        ),
      ]);
      await engine.pull();
      final r = (await db.select(db.notebooks).get()).first;
      expect(r.name, 'remote-newer');
    });

    test('version 相等 + updatedAt 早 → keep local', () async {
      final t = DateTime.now().toUtc();
      await seedLocal('nb1', 1, t.add(const Duration(seconds: 10)));
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'notebooks',
          entityId: 'nb1',
          baseVersion: 1,
          updatedAt: t, // 早
          payload: {'id': 'nb1', 'name': 'remote-older'},
        ),
      ]);
      await engine.pull();
      final r = (await db.select(db.notebooks).get()).first;
      expect(r.name, 'local-nb1');
    });

    test('remote.deletedAt 非空 → 本地硬删除', () async {
      final t = DateTime.now().toUtc();
      await seedLocal('nb1', 1, t);
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'notebooks',
          entityId: 'nb1',
          baseVersion: 2,
          updatedAt: t,
          deletedAt: t,
          op: SyncOp.delete,
        ),
      ]);
      final r = await engine.pull();
      final rows = await db.select(db.notebooks).get();
      expect(rows, isEmpty);
      // O2：tombstone 应计入 deleted，而不是被误算进 applied（避免「应用 N 条」虚高）。
      expect(r.deleted, 1);
      expect(r.applied, 0);
    });

    test('remote.version == 0（从未同步过） + 本地空 → insert', () async {
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'notebooks',
          entityId: 'nb1',
          baseVersion: 1,
          updatedAt: DateTime.now().toUtc(),
          payload: {'id': 'nb1', 'name': 'fresh'},
        ),
      ]);
      await engine.pull();
      final rows = await db.select(db.notebooks).get();
      expect(rows.length, 1);
      expect(rows.first.name, 'fresh');
    });
  });

  group('闭环', () {
    test('本地 push → 服务端留存 → 另一端 pull → 拉到自己这', () async {
      // 1) 本地写 → outbox
      await db.into(db.notebooks).insert(NotebooksCompanion(
            id: const Value('nb1'),
            name: const Value('本地写的'),
            updatedAt: Value(DateTime.now().toUtc()),
            version: const Value(1),
            deviceId: const Value('local-dev'),
          ));
      await outbox.enqueue(
        entityTable: 'notebooks',
        entityId: 'nb1',
        op: SyncOp.upsert,
        payload: {'id': 'nb1', 'name': '本地写的'},
        baseVersion: 1,
      );

      // 2) 模拟：push 后服务端收到 envelope，并把它"转发"给远端
      api.pushShouldFail = false;
      await engine.push();

      // 把刚 push 的内容复制到 pull 队列，模拟"远端拉服务端"
      // 注意：deviceId 必须是 remote-，否则被自回声过滤
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-2', // 远端
          entityTable: 'notebooks',
          entityId: 'nb1',
          baseVersion: 2,
          updatedAt: DateTime.now().toUtc(),
          payload: {'id': 'nb1', 'name': '远端覆盖'},
        ),
      ]);

      // 3) pull 进来覆盖本地
      final report = await engine.pull();
      expect(report.applied, 1);
      final r = (await db.select(db.notebooks).get()).first;
      expect(r.name, '远端覆盖');
      expect(r.version, 2);
    });
  });

  group('更多表覆盖 (cards / canvases / canvas_nodes / canvas_edges / ai_sessions / ai_messages)', () {
    Future<void> seed(String table, Map<String, dynamic> row) async {
      // 走 enqueue 让 payload 序列化路径也走一遍
      await outbox.enqueue(
        entityTable: table,
        entityId: row['id'] as String,
        op: SyncOp.upsert,
        payload: row,
        baseVersion: (row['version'] as num?)?.toInt() ?? 1,
      );
      // 模拟 push（envelope 已构造）
      final r = await engine.push();
      expect(r.pushed, greaterThanOrEqualTo(1));
    }

    test('cards: upsert + pull 应用 + LWW', () async {
      // 本地先写
      await db.into(db.cards).insert(CardsCompanion.insert(
            id: 'card1',
            type: 'qna',
            contentMd: const Value('本地卡片'),
            updatedAt: DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
            version: const Value(1),
            deviceId: 'local-dev',
          ));
      // pull 一条远端的更新
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'cards',
          entityId: 'card1',
          baseVersion: 3,
          updatedAt: DateTime.now().toUtc(),
          payload: {'id': 'card1', 'type': 'qna', 'content_md': '远端覆盖'},
        ),
      ]);
      final r = await engine.pull();
      expect(r.applied, 1);
      final card = (await db.select(db.cards).get()).first;
      expect(card.contentMd, '远端覆盖');
      expect(card.version, 3);
    });

    test('canvases: pull fresh insert', () async {
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'canvases',
          entityId: 'cv1',
          baseVersion: 1,
          updatedAt: DateTime.now().toUtc(),
          payload: {'id': 'cv1', 'name': '思维导图', 'viewport': '{"x":0,"y":0,"zoom":1.2}'},
        ),
      ]);
      await engine.pull();
      final cv = (await db.select(db.canvases).get()).first;
      expect(cv.name, '思维导图');
      expect(cv.viewport, '{"x":0,"y":0,"zoom":1.2}');
    });

    test('canvas_nodes: position + collapsed 默认值兜住', () async {
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'canvas_nodes',
          entityId: 'cn1',
          baseVersion: 1,
          updatedAt: DateTime.now().toUtc(),
          // payload 故意省略 x/y/w/h/z/collapsed，看默认值
          payload: {'id': 'cn1', 'canvas_id': 'cv1', 'target_type': 'kp', 'target_id': 'kp1'},
        ),
      ]);
      await engine.pull();
      final cn = (await db.select(db.canvasNodes).get()).first;
      expect(cn.x, 0.0);
      expect(cn.y, 0.0);
      expect(cn.w, 200.0);
      expect(cn.h, 120.0);
      expect(cn.z, 0);
      expect(cn.collapsed, false);
    });

    test('canvas_edges: edge_type 默认 manual + prereqEdgeId 可空', () async {
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'canvas_edges',
          entityId: 'ce1',
          baseVersion: 1,
          updatedAt: DateTime.now().toUtc(),
          payload: {'id': 'ce1', 'canvas_id': 'cv1', 'from_node_id': 'cn1', 'to_node_id': 'cn2'},
        ),
      ]);
      await engine.pull();
      final ce = (await db.select(db.canvasEdges).get()).first;
      expect(ce.edgeType, 'manual');
      expect(ce.prereqEdgeId, isNull);
    });

    test('ai_sessions: kpId 可空 + 默认 type=chat', () async {
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'ai_sessions',
          entityId: 's1',
          baseVersion: 1,
          updatedAt: DateTime.now().toUtc(),
          payload: {'id': 's1', 'title': '老师模式'},
        ),
      ]);
      await engine.pull();
      final s = (await db.select(db.aiSessions).get()).first;
      expect(s.title, '老师模式');
      expect(s.type, 'chat');
      expect(s.kpId, isNull);
    });

    test('ai_messages: tokens/latencyMs/modelId 可空', () async {
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'ai_messages',
          entityId: 'm1',
          baseVersion: 1,
          updatedAt: DateTime.now().toUtc(),
          payload: {'id': 'm1', 'session_id': 's1', 'role': 'assistant', 'content_md': '回答'},
        ),
      ]);
      await engine.pull();
      final m = (await db.select(db.aiMessages).get()).first;
      expect(m.role, 'assistant');
      expect(m.contentMd, '回答');
      expect(m.tokens, isNull);
      expect(m.latencyMs, isNull);
      expect(m.modelId, isNull);
    });

    test('push 多张表混合 → 全 done', () async {
      // cards + canvases + canvas_nodes + ai_messages 一起入队 + push
      await outbox.enqueue(
        entityTable: 'cards',
        entityId: 'cardA',
        op: SyncOp.upsert,
        payload: {'id': 'cardA', 'type': 'qna', 'content_md': 'cardA'},
        baseVersion: 1,
      );
      await outbox.enqueue(
        entityTable: 'canvases',
        entityId: 'cvA',
        op: SyncOp.upsert,
        payload: {'id': 'cvA', 'name': 'cvA'},
        baseVersion: 1,
      );
      await outbox.enqueue(
        entityTable: 'canvas_nodes',
        entityId: 'cnA',
        op: SyncOp.upsert,
        payload: {'id': 'cnA', 'canvas_id': 'cvA', 'target_type': 'kp', 'target_id': 'kpA'},
        baseVersion: 1,
      );
      await outbox.enqueue(
        entityTable: 'ai_messages',
        entityId: 'mA',
        op: SyncOp.upsert,
        payload: {'id': 'mA', 'session_id': 'sA', 'role': 'user', 'content_md': 'hi'},
        baseVersion: 1,
      );

      final r = await engine.push();
      expect(r.pushed, 4);
      // outbox 全 done
      expect(await outbox.pendingCount(), 0);
      // 远端 pushHistory 也全收齐
      final allEnvelopes = api.pushHistory.expand((e) => e).toList();
      final tables = allEnvelopes.map((e) => e.entityTable).toSet();
      expect(tables, containsAll({'cards', 'canvases', 'canvas_nodes', 'ai_messages'}));
    });

    test('seed 辅助函数本身能跑（与 cards 协同）', () async {
      // 验证 seed 流程：enqueue + push 走通，但表已存在时应用的就是 update
      // 这里只验证 cards enqueue/push 没崩
      await seed('cards', {
        'id': 'card_seed',
        'type': 'qna',
        'content_md': 'seeded',
      });
      // 再 pull 同 id 的更新（更高 version）
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'cards',
          entityId: 'card_seed',
          baseVersion: 5,
          updatedAt: DateTime.now().toUtc(),
          payload: {'id': 'card_seed', 'type': 'qna', 'content_md': 'pulled'},
        ),
      ]);
      await engine.pull();
      final card = await (db.select(db.cards)
            ..where((t) => t.id.equals('card_seed')))
          .getSingle();
      expect(card.contentMd, 'pulled');
      expect(card.version, 5);
    });
  });

  group('Pull - 笔记冲突本地胜出 → 合并结果回推发件箱', () {
    test('本地胜出（version 更高）且内容冲突：合并进胜方并登记 outbox 回推', () async {
      // 本地先有一篇笔记，版本 5。
      await db.into(db.notes).insert(NotesCompanion(
        id: const Value('n1'),
        notebookId: const Value(null),
        title: const Value('t'),
        contentMd: const Value('LOCAL'),
        contentHash: const Value(''),
        pinned: const Value(false),
        updatedAt: Value(DateTime.parse('2026-01-01T00:00:00Z')),
        version: const Value(5),
        deviceId: const Value('local-dev'),
        deletedAt: const Value(null),
      ));
      // 对端（另一设备）推来同 id、版本更低、内容不同的笔记 → 本地胜出。
      api.enqueuePull([
        _mkEnv(
          deviceId: 'remote-device-1',
          entityTable: 'notes',
          entityId: 'n1',
          baseVersion: 2,
          updatedAt: DateTime.now().toUtc(),
          payload: <String, dynamic>{
            'id': 'n1',
            'notebook_id': null,
            'title': 't',
            'content_md': 'REMOTE',
            'content_hash': '',
            'pinned': false,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
            'version': 2,
            'device_id': 'remote-device-1',
            'deleted_at': null,
          },
        ),
      ]);
      final r = await engine.pull();
      expect(r.conflictsMerged, 1,
          reason: '本地胜出的内容冲突应计为一次内联合并');

      // 本地笔记应保留本地内容，并把对端内容追加进「同步冲突」区块。
      final local =
          await (db.select(db.notes)..where((t) => t.id.equals('n1'))).getSingle();
      expect(local.contentMd, contains('LOCAL'));
      expect(local.contentMd, contains('REMOTE'));
      expect(local.contentMd, contains('同步冲突'));

      // 合并结果必须回推：outbox 里应有一条 notes upsert，内容同样含冲突区块。
      final pending = await outbox.pending();
      final noteRow = pending
          .where((e) => e.entityTable == 'notes' && e.entityId == 'n1')
          .toList();
      expect(noteRow, isNotEmpty,
          reason: 'H2：本地胜出合并后必须把结果登记进发件箱回推，'
              '否则对端仍是旧版本（分叉）');
      final pushed =
          jsonDecode(noteRow.single.payloadJson) as Map<String, dynamic>;
      expect(pushed['content_md'], contains('同步冲突'));
      // 回推版本必须严格高于对端（本机 5 vs 对端 2 → 6），保证 LWW 不被旧版本覆盖。
      expect(pushed['version'], 6);
    });
  });
}