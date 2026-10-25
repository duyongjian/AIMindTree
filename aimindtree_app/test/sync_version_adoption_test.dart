/// 同步「服务端权威版本回写本地」验收测试。
///
/// 锁住用户决策：上传时服务端对每一项比对服务器版本后递增版本（不靠本地 +1），
/// App 把服务端返回的 `versions{ "<table>:<id>": newVer }` 回写本地 `version`
/// 列，使本地 version 与服务器对齐；拉取侧不调整版本。
///
/// 任何一个回归都要让本文件变红：
/// 1. pushAll（全量快照）成功后，本地行 version 被抬到服务端返回的新版本。
/// 2. push（增量 outbox）成功后，本地行 version 同样被 adoption 覆盖。
/// 3. 服务端不返回 versions（旧后端 / 坏数据）时，本地 version 保持不变，不崩。
library;

import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/sync/sync_api.dart';
import 'package:aimindtree_app/data/sync/sync_config.dart';
import 'package:aimindtree_app/data/sync/sync_engine.dart';
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:aimindtree_app/data/sync/sync_types.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 自定义后端：pushBatch 返回预设的 `versions` 映射，pull 一律空。
class _FakeSyncApi implements SyncApi {
  _FakeSyncApi({this.versions = const {}});
  final Map<String, int> versions;
  final List<List<SyncEnvelope>> pushCalls = [];

  @override
  Future<SyncPushResult> pushBatch(List<SyncEnvelope> envelopes) async {
    pushCalls.add(envelopes);
    return SyncPushResult(
      accepted: envelopes.length,
      serverTime: DateTime.now().toUtc(),
      versions: versions,
    );
  }

  @override
  Future<SyncPullResult> pullSince(DateTime? since) async =>
      SyncPullResult(envelopes: const [], serverTime: DateTime.now().toUtc());

  @override
  Future<String?> testConnection() async => null;

  @override
  void close() {}

  @override
  int get pushBatchBudgetBytes => SyncConfig.kSyncPushBatchBudgetBytes;

  @override
  int get maxEnvelopeBytes => SyncConfig.kSyncMaxEnvelopeBytes;
}

void main() {
  late AppDatabase db;
  late SyncOutboxRepo outbox;
  late SyncEngine engine;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    outbox = SyncOutboxRepo(db, deviceId: 'local-dev');
  });

  tearDown(() async {
    SyncOutboxRepo.current = null;
    await db.close();
  });

  Future<int> readNoteVersion(String id) async {
    final r = await (db.select(db.notes)..where((t) => t.id.equals(id)))
        .getSingle();
    return r.version;
  }

  Future<void> insertNote(String id, {int version = 1}) async {
    await db.into(db.notes).insert(NotesCompanion(
          id: Value(id),
          title: Value('笔记-$id'),
          contentMd: Value('# $id'),
          updatedAt: Value(DateTime.utc(2026, 1, 1, 0, 0, 0)),
          version: Value(version),
          deviceId: const Value('local-dev'),
        ));
  }

  group('服务端权威版本回写本地', () {
    test('pushAll 全量快照：本地 version 被抬到服务端返回的新版本', () async {
      await insertNote('n1', version: 1);
      final api = _FakeSyncApi(versions: const {'notes:n1': 5});
      engine = SyncEngine(db: db, api: api, outbox: outbox, deviceId: 'local-dev');

      await engine.pushAll();

      expect(await readNoteVersion('n1'), 5,
          reason: 'pushAll 后应把本地 version 从 1 抬到服务端返回的 5');
    });

    test('push 增量：outbox 行推送成功后本地 version 同样被 adoption 覆盖', () async {
      await insertNote('n2', version: 1);
      await outbox.enqueue(
        entityTable: 'notes',
        entityId: 'n2',
        op: SyncOp.upsert,
        payload: <String, dynamic>{'id': 'n2', 'version': 1},
        baseVersion: 1,
      );
      final api = _FakeSyncApi(versions: const {'notes:n2': 3});
      engine = SyncEngine(db: db, api: api, outbox: outbox, deviceId: 'local-dev');

      final report = await engine.push();

      expect(report.pushed, 1);
      expect(await readNoteVersion('n2'), 3,
          reason: 'push 成功后本地 version 应从 1 抬到服务端返回的 3');
    });

    test('多实体：versions 含不同表的多个键，各自回写正确', () async {
      await insertNote('nA', version: 1);
      await insertNote('nB', version: 1);
      final api = _FakeSyncApi(versions: const {
        'notes:nA': 7,
        'notes:nB': 9,
      });
      engine = SyncEngine(db: db, api: api, outbox: outbox, deviceId: 'local-dev');

      await engine.pushAll();

      expect(await readNoteVersion('nA'), 7);
      expect(await readNoteVersion('nB'), 9);
    });

    test('服务端不返回 versions（旧后端）时本地 version 保持不变', () async {
      await insertNote('n3', version: 1);
      // 旧后端/坏数据：versions 为空。
      final api = _FakeSyncApi(versions: const {});
      engine = SyncEngine(db: db, api: api, outbox: outbox, deviceId: 'local-dev');

      await engine.pushAll();

      expect(await readNoteVersion('n3'), 1,
          reason: '无 versions 时 adoption 应为 no-op，本地 version 保持 1');
    });

    test('tombstone（本地已硬删）场景下 adoption 静默 no-op，不抛错', () async {
      // 本地已无该笔记（被删），但服务端仍返回了它的版本。
      final api = _FakeSyncApi(versions: const {'notes:gone': 4});
      engine = SyncEngine(db: db, api: api, outbox: outbox, deviceId: 'local-dev');

      // 不应抛异常（where id 命中 0 行）。
      await engine.pushAll();
      final r = await (db.select(db.notes)..where((t) => t.id.equals('gone')))
          .get();
      expect(r, isEmpty);
    });
  });
}
