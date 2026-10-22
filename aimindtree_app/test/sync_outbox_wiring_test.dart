/// 上行同步接线测试（T03 补齐：`SyncOutboxRepo.enqueue` 全仓零调用 → 发件箱永远空）。
///
/// 覆盖两件事：
/// 1. **接线生效**：仓储层写完本地库后，outbox 里真的出现了对应行
///    （entityTable / op / baseVersion / payload 键都对）；
///    未接线（`SyncOutboxRepo.current == null`）时静默跳过、不崩。
/// 2. **DateTime 序列化加固**：payload 经 JSON 往返后 `deleted_at` 是 ISO
///    字符串，旧代码 `as DateTime?` 会抛 TypeError；修复后 push / pull 全链路
///    都能正确解析与落库。
library;

import 'dart:convert';

import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/models/knowledge_tree.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:aimindtree_app/data/sync/sync_api.dart';
import 'package:aimindtree_app/data/sync/sync_engine.dart';
import 'package:aimindtree_app/data/sync/sync_json.dart';
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:aimindtree_app/data/sync/sync_types.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SyncOutboxRepo outbox;
  late KnowledgeRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    outbox = SyncOutboxRepo(db, deviceId: 'local-dev');
    repo = KnowledgeRepository(db, deviceId: 'local-dev');
  });

  tearDown(() async {
    // 全局接线点必须复位，否则会漏到别的测试文件里。
    SyncOutboxRepo.current = null;
    await db.close();
  });

  group('接线：仓储写完 → outbox 有行', () {
    test('未接线时（current == null）写仓储不崩、也不入队', () async {
      expect(SyncOutboxRepo.current, isNull);

      final res = await repo.createManualKnowledgePoint(name: '未接线点');
      expect(res, isA<Success<KnowledgePoint>>());

      expect(await outbox.pendingCount(), 0);
    });

    test('createManualKnowledgePoint → knowledge_points upsert', () async {
      SyncOutboxRepo.current = outbox;

      final res = await repo.createManualKnowledgePoint(name: '牛顿第一定律');
      final kp = (res as Success<KnowledgePoint>).value;

      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      final row = pending.single;
      expect(row.entityTable, 'knowledge_points');
      expect(row.entityId, kp.id);
      expect(row.op, SyncOp.upsert.name);
      // baseVersion = 写完后该行的 version（新插入 = 1）。
      expect(row.baseVersion, kp.version);

      // payload 的键必须是表的 snake_case 列名（与 engine 的 fromMap 对齐）。
      final payload = jsonDecode(row.payloadJson) as Map<String, dynamic>;
      expect(payload['id'], kp.id);
      expect(payload['name'], '牛顿第一定律');
      expect(payload['source_note_id'], '');
      expect(payload['origin'], 'user_manual');
      expect(payload['version'], kp.version);
      expect(payload['device_id'], 'local-dev');
    });

    test('saveNote → notes upsert', () async {
      SyncOutboxRepo.current = outbox;

      final note = Note(
        title: '测试笔记',
        contentMd: '# 正文',
        deviceId: 'local-dev',
      );
      final res = await repo.saveNote(note);
      expect(res, isA<Success<Note>>());

      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      expect(pending.single.entityTable, 'notes');
      expect(pending.single.entityId, note.id);
      expect(pending.single.op, SyncOp.upsert.name);

      final payload =
          jsonDecode(pending.single.payloadJson) as Map<String, dynamic>;
      expect(payload['title'], '测试笔记');
      expect(payload['content_md'], '# 正文');
    });

    test('softDeleteKnowledgePoint → knowledge_points delete（墓碑）', () async {
      SyncOutboxRepo.current = outbox;

      final res = await repo.createManualKnowledgePoint(name: '待删点');
      final kp = (res as Success<KnowledgePoint>).value;
      // 清掉前面的 upsert，只看删除这一条。
      await outbox.markPushed(<int>[(await outbox.pending()).single.id]);

      final del = await repo.softDeleteKnowledgePoint(kp.id);
      expect((del as Success<int>).value, 1);

      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      final row = pending.single;
      expect(row.entityTable, 'knowledge_points');
      expect(row.entityId, kp.id);
      expect(row.op, SyncOp.delete.name);
      // 墓碑时间必须在 payload 里（enqueue 的 deletedAt 形参不生效，
      // engine 的 _extractDeletedAt 从 payload['deleted_at'] 取）。
      final payload = jsonDecode(row.payloadJson) as Map<String, dynamic>;
      expect(payload.containsKey('deleted_at'), isTrue);
      expect(DateTime.tryParse(payload['deleted_at'] as String), isNotNull);
    });

    test('updateKpMeta → knowledge_points upsert（version 递增）', () async {
      SyncOutboxRepo.current = outbox;

      final res = await repo.createManualKnowledgePoint(name: '旧名');
      final kp = (res as Success<KnowledgePoint>).value;
      await outbox.markPushed(<int>[(await outbox.pending()).single.id]);

      final edited = kp.copyWith(name: '新名');
      final upd = await repo.updateKpMeta(edited);
      expect(upd, isA<Success<KnowledgePoint>>());

      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      expect(pending.single.op, SyncOp.upsert.name);
      expect(pending.single.baseVersion, kp.version + 1);
      final payload =
          jsonDecode(pending.single.payloadJson) as Map<String, dynamic>;
      expect(payload['name'], '新名');
      expect(payload['version'], kp.version + 1);
    });

    test('addPoints / saveNodePosition → canvas_nodes upsert', () async {
      SyncOutboxRepo.current = outbox;

      final trees = TreeRepository(db, deviceId: 'local-dev');
      final treeRes = await trees.createTree('我的树');
      final tree = (treeRes as Success<KnowledgeTree>).value;
      final treeId = tree.id;
      await outbox.markPushed(<int>[(await outbox.pending()).single.id]);

      final kpRes = await repo.createManualKnowledgePoint(name: '树成员');
      final kp = (kpRes as Success<KnowledgePoint>).value;
      await outbox.markPushed(<int>[(await outbox.pending()).single.id]);

      await trees.addPoints(treeId, <String>[kp.id]);
      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      expect(pending.single.entityTable, 'canvas_nodes');
      expect(pending.single.entityId, '$treeId:${kp.id}');
      expect(pending.single.op, SyncOp.upsert.name);
    });
  });

  group('DateTime 序列化加固', () {
    test('JSON 往返后 deleted_at 是 ISO 字符串（不是 DateTime）', () async {
      SyncOutboxRepo.current = outbox;

      final res = await repo.createManualKnowledgePoint(name: '墓碑点');
      final kp = (res as Success<KnowledgePoint>).value;
      await outbox.markPushed(<int>[(await outbox.pending()).single.id]);
      await repo.softDeleteKnowledgePoint(kp.id);

      final row = (await outbox.pending()).single;
      final decoded = jsonDecode(row.payloadJson) as Map<String, dynamic>;
      // JSON 往返后必然是字符串 —— 这正是旧代码 `as DateTime?` 会炸的原因。
      expect(decoded['deleted_at'], isA<String>());
      expect(DateTime.tryParse(decoded['deleted_at'] as String), isNotNull);
    });

    test('push 构造 envelope 时 deleted_at 能解析出 DateTime（不抛 TypeError）', () async {
      SyncOutboxRepo.current = outbox;

      final res = await repo.createManualKnowledgePoint(name: '墓碑点');
      final kp = (res as Success<KnowledgePoint>).value;
      await outbox.markPushed(<int>[(await outbox.pending()).single.id]);
      await repo.softDeleteKnowledgePoint(kp.id);

      final api = MockSyncApi(deviceIdOfCaller: 'remote-device-1');
      final engine =
          SyncEngine(db: db, api: api, outbox: outbox, deviceId: 'local-dev');

      // 旧实现：_extractDeletedAt 里 `p?['deleted_at'] as DateTime?`
      // 在 JSON 往返后抛 TypeError → push 直接失败。
      final report = await engine.push();
      expect(report.pushed, 1);
      expect(report.failed, 0);

      final envelope = api.pushHistory.single.single;
      expect(envelope.op, SyncOp.delete);
      expect(envelope.deletedAt, isA<DateTime>());
      expect(envelope.deletedAt, isNotNull);
    });

    test('payload 经 JSON 往返后 pull 能正确落库（不抛 cast 错）', () async {
      // 模拟「服务端存的是 JSON 往返后的 payload」→ pull 到本地库。
      final api = MockSyncApi(deviceIdOfCaller: 'remote-device-1');
      final engine =
          SyncEngine(db: db, api: api, outbox: outbox, deviceId: 'local-dev');

      final updatedAt = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final deletedAt = DateTime.utc(2026, 1, 2, 3, 4, 6);
      // payload 里放 DateTime，再过一遍 JSON 往返 —— 之后就是字符串。
      // （注意：Dart 的 jsonEncode 默认**不支持** DateTime，会抛
      // JsonUnsupportedObjectError；同步层用 sync_json.dart 的安全编码器。）
      final rawPayload = <String, dynamic>{
        'id': 'kp-remote',
        'notebook_id': null,
        'name': '远端知识点',
        'type': 'concept',
        'definition': '定义',
        'source_note_id': 'n1',
        'source_start': 0,
        'source_end': 4,
        'source_quote': '引用',
        'origin': 'ai_extract',
        'confidence': 0.9,
        'updated_at': updatedAt,
        'version': 7,
        'device_id': 'remote-device-1',
        'deleted_at': deletedAt,
      };
      final roundTripped =
          jsonDecode(encodeSyncJson(rawPayload)) as Map<String, dynamic>;
      expect(roundTripped['updated_at'], isA<String>());
      expect(roundTripped['deleted_at'], isA<String>());

      api.enqueuePull(<SyncEnvelope>[
        SyncEnvelope(
          deviceId: 'remote-device-1',
          entityTable: 'knowledge_points',
          entityId: 'kp-remote',
          op: SyncOp.upsert,
          payload: roundTripped,
          baseVersion: 7,
          updatedAt: updatedAt,
        ),
      ]);

      final report = await engine.pull();
      expect(report.applied, 1);
      expect(report.skipped, 0);

      // 落库成功，且 DateTime 列被正确解析（不是字符串、不是抛错）。
      final rows = await db.select(db.knowledgePoints).get();
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.id, 'kp-remote');
      expect(row.name, '远端知识点');
      expect(row.version, 7);
      expect(row.updatedAt, isA<DateTime>());
      expect(row.deletedAt, isA<DateTime>());
      // Drift 按本地时区返回 DateTime → 比较「时刻」而非「字面相等」。
      expect(row.deletedAt!.isAtSameMomentAs(deletedAt), isTrue);
      expect(row.updatedAt.isAtSameMomentAs(updatedAt), isTrue);
    });

    test('transport 层 toJson 遇 DateTime payload 不炸（jsonEncode 可用）', () async {
      final envelope = SyncEnvelope(
        deviceId: 'local-dev',
        entityTable: 'knowledge_points',
        entityId: 'kp1',
        op: SyncOp.upsert,
        payload: <String, dynamic>{
          'id': 'kp1',
          'updated_at': DateTime.utc(2026, 5, 6),
          'deleted_at': null,
        },
        baseVersion: 3,
        updatedAt: DateTime.utc(2026, 5, 6),
      );
      // 旧实现：payload 里带 DateTime → jsonEncode 抛
      // JsonUnsupportedObjectError。
      final json = jsonEncode(envelope.toJson());
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final payload = decoded['payload'] as Map<String, dynamic>;
      expect(payload['updated_at'], isA<String>());
      expect(DateTime.tryParse(payload['updated_at'] as String), isNotNull);
    });
  });
}
