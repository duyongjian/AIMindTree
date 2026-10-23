/// 同步「上传/拉取恒为 0 条」回归测试。
///
/// 锁住用户实测暴露的三个 bug，任何一个复发都要让本文件变红：
///
/// 1. **计数字段不匹配**：CF Worker 返回 `{received, ...}`，App 只读
///    `accepted` → 永远回落 0（「提示上传成功，但是 0 条」）。
/// 2. **历史数据发不出去**：`push()` 只发 outbox（增量发件箱），
///    同步接线之前创建的存量数据一条都不在 outbox 里 → 首次上传空转。
/// 3. **拉取数字骗人**：自回声被记进 `skipped` 而非 `applied`，
///    UI 只显示 `applied` → 自己刚传上去的数据拉回来显示「应用 0 条」。
///    （本文件只覆盖 1、2 的引擎侧；3 是 UI 展示，见 setStored 断言。）
library;

import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/sync/sync_api.dart';
import 'package:aimindtree_app/data/sync/sync_engine.dart';
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:aimindtree_app/data/sync/sync_types.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

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
    // 全局接线点必须复位，否则会漏到别的测试文件里。
    SyncOutboxRepo.current = null;
    await db.close();
  });

  // ============ 造数据（**绕开仓储 / SyncOutboxWriter**）============
  //
  // 这正是 bug ② 的现场：行在表里，但 outbox 里一条都没有。

  Future<void> insertNote(String id, {DateTime? deletedAt}) async {
    await db.into(db.notes).insert(NotesCompanion(
          id: Value(id),
          title: Value('笔记-$id'),
          contentMd: Value('# $id'),
          updatedAt: Value(DateTime.utc(2026, 1, 1, 0, 0, 0)),
          version: const Value(1),
          deviceId: const Value('local-dev'),
          deletedAt: Value(deletedAt),
        ));
  }

  Future<void> insertKp(String id, {DateTime? deletedAt}) async {
    await db.into(db.knowledgePoints).insert(KnowledgePointsCompanion(
          id: Value(id),
          name: Value('知识点-$id'),
          type: const Value('concept'),
          sourceNoteId: const Value(''),
          sourceStart: const Value(0),
          sourceEnd: const Value(0),
          sourceQuote: const Value(''),
          updatedAt: Value(DateTime.utc(2026, 1, 1, 0, 0, 0)),
          version: const Value(1),
          deviceId: const Value('local-dev'),
          deletedAt: Value(deletedAt),
        ));
  }

  Future<void> insertTree(String id) async {
    await db.into(db.canvases).insert(CanvasesCompanion(
          id: Value(id),
          name: Value('树-$id'),
          notebookId: const Value('nb-1'),
          updatedAt: Value(DateTime.utc(2026, 1, 1, 0, 0, 0)),
          version: const Value(1),
          deviceId: const Value('local-dev'),
        ));
  }

  Future<void> insertNode(String id, String canvasId, String targetId) async {
    await db.into(db.canvasNodes).insert(CanvasNodesCompanion(
          id: Value(id),
          canvasId: Value(canvasId),
          targetType: const Value('kp'),
          targetId: Value(targetId),
          x: const Value(10),
          y: const Value(20),
          updatedAt: Value(DateTime.utc(2026, 1, 1, 0, 0, 0)),
          version: const Value(1),
          deviceId: const Value('local-dev'),
        ));
  }

  group('bug ①：计数字段兼容（received / accepted）', () {
    test('CF Worker 只返回 received 时，accepted 不再恒为 0', () async {
      // 起一个本地 HTTP 桩，模拟 CF Worker 当前的真实响应体
      //（只有 received，没有 accepted）。这是唯一能真正测到
      // `HttpSyncApi.pushBatch` 解析逻辑的方式。
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        await req.drain<void>();
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, dynamic>{
          'received': 7,
          'server_time': DateTime.utc(2026, 1, 2, 3, 4, 5).toIso8601String(),
        }));
        await req.response.close();
      });

      // 显式注入 HttpClient 并强制直连：绕开 findProxy 对测试环境的依赖。
      final client = HttpClient()
        ..findProxy = ((Uri uri) => 'DIRECT')
        ..connectionTimeout = const Duration(seconds: 5);
      final httpApi = HttpSyncApi(
        baseUrl: 'http://127.0.0.1:${server.port}',
        userToken: 'test-token',
        client: client,
      );
      addTearDown(httpApi.close);

      final result = await httpApi.pushBatch(<SyncEnvelope>[]);
      // 修复前：`m['accepted'] ?? 0` → 0（用户看到的「上传 0 条」）。
      expect(result.accepted, 7);
    });

    test('push() 把后端返回的 accepted 计入 PushReport.pushed', () async {
      await insertNote('n1');
      await insertNote('n2');
      await insertKp('kp1');
      await outbox.enqueue(
        entityTable: 'notes',
        entityId: 'n1',
        op: SyncOp.upsert,
        payload: {'id': 'n1', 'title': '笔记-n1', 'version': 1},
        baseVersion: 1,
      );
      await outbox.enqueue(
        entityTable: 'notes',
        entityId: 'n2',
        op: SyncOp.upsert,
        payload: {'id': 'n2', 'title': '笔记-n2', 'version': 1},
        baseVersion: 1,
      );
      await outbox.enqueue(
        entityTable: 'knowledge_points',
        entityId: 'kp1',
        op: SyncOp.upsert,
        payload: {'id': 'kp1', 'name': '知识点-kp1', 'version': 1},
        baseVersion: 1,
      );

      final report = await engine.push();
      expect(report.pushed, 3);
      expect(report.failed, 0);
      expect(await outbox.pendingCount(), 0);
    });
  });

  group('bug ②：pushAll 全量快照', () {
    test('存量数据（outbox 为空）只靠 push() 发不出去，pushAll() 能发出去',
        () async {
      // 现场复刻：同步接线之前就有数据 → 行在表里，outbox 空。
      await insertNote('n1');
      await insertNote('n2');
      await insertKp('kp1');

      expect(await outbox.pendingCount(), 0);

      final inc = await engine.push();
      expect(inc.pushed, 0,
          reason: '增量发件箱为空 → 一条都不发（这正是 bug 的现场）');
      expect(api.pushHistory, isEmpty);

      final snap = await engine.pushAll();
      expect(snap.pushed, greaterThan(0),
          reason: '全量快照必须把存量数据推上去');
      expect(snap.failed, 0);
    });

    test('数量与表分布正确：2 笔记 + 5 知识点 + 1 棵树 + 2 画布节点 = 10',
        () async {
      for (var i = 1; i <= 2; i++) {
        await insertNote('note-$i');
      }
      for (var i = 1; i <= 5; i++) {
        await insertKp('kp-$i');
      }
      await insertTree('tree-1');
      await insertNode('node-1', 'tree-1', 'kp-1');
      await insertNode('node-2', 'tree-1', 'kp-2');

      final report = await engine.pushAll();
      expect(report.pushed, 10);
      expect(report.failed, 0);

      final envelopes = api.pushHistory.expand((b) => b).toList();
      expect(envelopes.length, 10);

      final byTable = <String, int>{};
      for (final e in envelopes) {
        byTable[e.entityTable] = (byTable[e.entityTable] ?? 0) + 1;
        // 快照一律是 upsert（删除走 deleted_at 墓碑，不是 op=delete）。
        expect(e.op, SyncOp.upsert);
        expect(e.deviceId, 'local-dev');
      }
      expect(byTable, <String, int>{
        'notes': 2,
        'knowledge_points': 5,
        'canvases': 1,
        'canvas_nodes': 2,
      });
    });

    test('payload 键与下行 FromMap 对齐（抽样：知识点带 pinned / created_at）',
        () async {
      await insertKp('kp-1');
      await engine.pushAll();

      final env = api.pushHistory.single.single;
      final payload = env.payload!;
      expect(payload['id'], 'kp-1');
      expect(payload.containsKey('pinned'), isTrue);
      expect(payload.containsKey('created_at'), isTrue);
      expect(payload.containsKey('device_id'), isTrue);
      expect(payload.containsKey('deleted_at'), isTrue);
    });

    test('软删行走快照也带 deleted_at（否则对端会把已删行当活数据）',
        () async {
      final deletedAt = DateTime.utc(2026, 2, 3, 4, 5, 6);
      await insertKp('kp-alive');
      await insertKp('kp-deleted', deletedAt: deletedAt);

      final report = await engine.pushAll();
      expect(report.pushed, 2);

      final envelopes = api.pushHistory.expand((b) => b).toList();
      final deleted =
          envelopes.firstWhere((e) => e.entityId == 'kp-deleted');
      expect(deleted.deletedAt, isNotNull);
      expect(deleted.deletedAt!.isAtSameMomentAs(deletedAt), isTrue);
      // payload 里也要带（对端 LWW 落库时读的是 payload 的 deleted_at）。
      expect(deleted.payload!['deleted_at'], isNotNull);

      final alive = envelopes.firstWhere((e) => e.entityId == 'kp-alive');
      expect(alive.deletedAt, isNull);
    });

    test('pushAll 不写 outbox（全量是对齐，不是变更记账）', () async {
      await insertNote('n1');
      await engine.pushAll();
      expect(await outbox.pendingCount(), 0);
      expect(await outbox.failedCount(), 0);
    });

    test('分页读取：pageSize 小于总行数时依然一条不少', () async {
      for (var i = 1; i <= 7; i++) {
        await insertKp('kp-$i');
      }
      final report = await engine.pushAll(pageSize: 2);
      expect(report.pushed, 7);
      final ids = api.pushHistory
          .expand((b) => b)
          .map((e) => e.entityId)
          .toList();
      expect(ids.toSet(), <String>{for (var i = 1; i <= 7; i++) 'kp-$i'});
    });

    test('push() 与 pushAll() 可叠加：增量 + 快照都不重复丢', () async {
      await insertNote('n1');
      await outbox.enqueue(
        entityTable: 'notes',
        entityId: 'n1',
        op: SyncOp.upsert,
        payload: {'id': 'n1', 'title': '笔记-n1', 'version': 1},
        baseVersion: 1,
      );

      final inc = await engine.push();
      final snap = await engine.pushAll();
      expect(inc.pushed, 1);
      expect(snap.pushed, 1);
      // 两个报告分开计数，UI 才能让用户分清「增量」与「快照」。
      expect(inc.pushed + snap.pushed, 2);
    });
  });
}
