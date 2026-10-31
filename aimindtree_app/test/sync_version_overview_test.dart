/// 设置页「数据版本」卡的数据侧验收测试。
///
/// 锁住两件事：
/// 1. **本机总览**（[SyncEngine.localOverview]）的口径：只统计
///    [kSyncTableAllowlist] 的 16 张表（`homeworks` 本轮已纳入同步，必须计入），
///    软删墓碑行照常计数，最大版本取 16 张表的全局最大。
/// 2. **服务器总览**（[HttpSyncApi.parseManifest] / [MockSyncApi.fetchManifest]）
///    的解析与降级：完整字段正常解析；旧中继只回 `count`（缺 `max_version`）
///    时必须回落 0 而不是抛异常——否则设置页整张卡会崩。
library;

import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/sync/sync_api.dart';
import 'package:aimindtree_app/data/sync/sync_engine.dart';
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SyncOutboxRepo outbox;
  late SyncEngine engine;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    outbox = SyncOutboxRepo(db, deviceId: 'local-dev');
    engine = SyncEngine(db: db, api: MockSyncApi(), outbox: outbox, deviceId: 'local-dev');
  });

  tearDown(() async {
    SyncOutboxRepo.current = null;
    await db.close();
  });

  final t0 = DateTime.utc(2026, 1, 1);

  Future<void> insertNote(String id, {int version = 1, DateTime? deletedAt}) async {
    await db.into(db.notes).insert(NotesCompanion(
          id: Value(id),
          title: Value('笔记-$id'),
          updatedAt: Value(t0),
          version: Value(version),
          deviceId: const Value('local-dev'),
          deletedAt: Value(deletedAt),
        ));
  }

  Future<void> insertNotebook(String id, {int version = 1}) async {
    await db.into(db.notebooks).insert(NotebooksCompanion(
          id: Value(id),
          name: Value('本-$id'),
          updatedAt: Value(t0),
          version: Value(version),
          deviceId: const Value('local-dev'),
        ));
  }

  group('本机数据总览（SyncEngine.localOverview）', () {
    test('空库 → 0 条 / 最大版本 0（顺带校验 16 张同步表都真实存在）', () async {
      final o = await engine.localOverview();
      expect(o.count, 0);
      expect(o.maxVersion, 0);
    });

    test('跨表累加：记录数是各表行数之和，最大版本取全局最大', () async {
      await insertNote('n1', version: 3);
      await insertNote('n2', version: 5);
      await insertNotebook('b1', version: 9);

      final o = await engine.localOverview();
      expect(o.count, 3, reason: 'notes 2 行 + notebooks 1 行');
      expect(o.maxVersion, 9, reason: '最大版本跨表取全局最大，不是最后一张表');
    });

    test('homeworks 已纳入同步白名单 → 计入总览', () async {
      await insertNote('n1', version: 2);
      await db.into(db.homeworks).insert(HomeworksCompanion(
            id: const Value('h1'),
            canvasId: const Value('c1'),
            updatedAt: Value(t0),
            version: const Value(99),
            deviceId: const Value('local-dev'),
          ));

      final o = await engine.localOverview();
      expect(
        o.count,
        2,
        reason: 'notes 1 行 + homeworks 1 行：homeworks 已在 kSyncTableAllowlist 内',
      );
      expect(
        o.maxVersion,
        99,
        reason: 'homeworks 纳入同步后，它的 version 也参与全局最大值',
      );
    });

    test('软删墓碑行（deleted_at 非空）仍计入记录数', () async {
      await insertNote('alive', version: 4);
      await insertNote('gone', version: 6, deletedAt: t0);

      final o = await engine.localOverview();
      // 口径与服务端一致：服务端也存墓碑，两边都算才可比。
      expect(o.count, 2);
      expect(o.maxVersion, 6);
    });
  });

  group('服务器总览解析（HttpSyncApi.parseManifest）', () {
    test('完整响应：count + max_version 都解析', () {
      final m = HttpSyncApi.parseManifest(<String, dynamic>{
        'count': 123,
        'max_version': 9,
      });
      expect(m.count, 123);
      expect(m.maxVersion, 9);
    });

    test('旧中继只回 count（缺 max_version）→ 回落 0，不抛异常', () {
      final m = HttpSyncApi.parseManifest(<String, dynamic>{'count': 12});
      expect(m.count, 12);
      expect(m.maxVersion, 0, reason: '旧中继没有该字段 → 显示「0」而不是崩');
    });

    test('空对象 / 非数字值 → 全部回落 0（UI 显示「—」而非报错）', () {
      final empty = HttpSyncApi.parseManifest(<String, dynamic>{});
      expect(empty.count, 0);
      expect(empty.maxVersion, 0);

      final junk = HttpSyncApi.parseManifest(<String, dynamic>{
        'count': 'oops',
        'max_version': [1, 2],
      });
      expect(junk.count, 0);
      expect(junk.maxVersion, 0);
    });
  });

  group('MockSyncApi.fetchManifest（测试桩）', () {
    test('默认返回 0/0 并记录调用次数', () async {
      final api = MockSyncApi();
      final r = await api.fetchManifest();
      expect(r.ok, isTrue);
      expect(r.manifest!.count, 0);
      expect(r.manifest!.maxVersion, 0);
      expect(api.manifestCalls, 1);
    });

    test('可注入返回值（供 UI 测试驱动）', () async {
      final api = MockSyncApi()
        ..manifestOverride = const SyncManifest(count: 42, maxVersion: 7);
      final r = await api.fetchManifest();
      expect(r.manifest!.count, 42);
      expect(r.manifest!.maxVersion, 7);
    });

    test('manifestError 非空 → 失败结果带原因，manifest 为 null', () async {
      final api = MockSyncApi()..manifestError = '未登录 Cloudflare 账号';
      final r = await api.fetchManifest();
      expect(r.ok, isFalse);
      expect(r.manifest, isNull);
      expect(r.error, '未登录 Cloudflare 账号');
    });
  });
}
