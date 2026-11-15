/// 回归：服务端「防陈旧覆盖」守卫回 skipped 时，App 侧不得把未落库的行
/// 当成推送成功；必须刷新 payload/version 后自动重推，且最多 2 轮。
///
/// 复现链：中继跳过写入却回 200 全成功 → 旧代码 `markPushed(ids)` 清掉
/// outbox → 内容永久丢失。本文件任一用例变红 = 修复被回退。
library;

import 'dart:convert';

import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
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
  late KnowledgeRepository repo;
  late MockSyncApi api;
  late SyncEngine engine;

  final t0 = DateTime.utc(2026, 1, 1);

  /// 造一条 notes 的 upsert outbox 行（不经过仓储，便于精确控制 baseVersion
  /// 与 payload 里的 updated_at）。
  Future<void> enqueueNote({
    required int version,
    DateTime? updatedAt,
    String contentMd = '正文',
  }) {
    return outbox.enqueue(
      entityTable: 'notes',
      entityId: 'n1',
      op: SyncOp.upsert,
      payload: <String, dynamic>{
        'id': 'n1',
        'notebook_id': null,
        'title': 't',
        'content_md': contentMd,
        'content_hash': '',
        'pinned': false,
        'updated_at': updatedAt ?? t0,
        'version': version,
        'device_id': 'dev-A',
        'deleted_at': null,
      },
      baseVersion: version,
    );
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    outbox = SyncOutboxRepo(db, deviceId: 'dev-A');
    repo = KnowledgeRepository(db, deviceId: 'dev-A');
    api = MockSyncApi();
    engine = SyncEngine(db: db, api: api, outbox: outbox, deviceId: 'dev-A');
    SyncOutboxRepo.current = outbox;
  });

  tearDown(() async {
    SyncOutboxRepo.current = null;
    await db.close();
  });

  group('saveNote 版本与 payload', () {
    test('连续两次编辑：version 严格递增，outbox 记新正文与新 version', () async {
      final n1 = (await repo.saveNote(Note(
              id: 'n1',
              title: 't',
              contentMd: 'v1',
              deviceId: 'dev-A')) as Success<Note>)
          .value;
      final n2 =
          (await repo.saveNote(n1.copyWith(contentMd: 'v2')) as Success<Note>)
              .value;

      expect(n2.version, n1.version + 1,
          reason: '连续两次编辑 version 必须严格递增');

      final rows = await outbox.pending();
      final latest =
          rows.reduce((a, b) => a.baseVersion >= b.baseVersion ? a : b);
      expect(latest.baseVersion, n2.version,
          reason: 'outbox.baseVersion 必须是写完之后该行的新 version');
      final payload = jsonDecode(latest.payloadJson) as Map<String, dynamic>;
      expect(payload['content_md'], 'v2',
          reason: 'outbox payload 必须是本次编辑的新正文');
      expect(payload['version'], n2.version);
    });
  });

  group('服务端 skipped → 刷新并重推', () {
    test('skipped + versions 回写 authStart：保留 pending → 自动重推 → '
        '第二轮 baseVersion >= authStart → 正文最终落库', () async {
      await repo.saveNote(Note(
          id: 'n1',
          title: 't',
          contentMd: '新正文',
          deviceId: 'dev-A'));
      const authStart = 7;
      api.pushResponseQueue.addAll(<SyncPushResult>[
        SyncPushResult(
          accepted: 0,
          skipped: const <String>['notes:n1'],
          versions: const <String, int>{'notes:n1': authStart},
          serverTime: t0,
        ),
        SyncPushResult(
          accepted: 1,
          skipped: const <String>[],
          versions: const <String, int>{'notes:n1': authStart + 1},
          serverTime: t0.add(const Duration(seconds: 1)),
        ),
      ]);

      final report = await engine.push();

      expect(api.pushHistory, hasLength(2), reason: '必须自动重推一轮');
      expect(report.pushed, 1, reason: '真正落库 1 条');
      expect(report.skipped, 0, reason: '第二轮成功，最终无残留 skipped');

      final retryBatch = api.pushHistory[1];
      expect(retryBatch, hasLength(1));
      // ★反向验红点：把下面这条断言用 if(false) 短路，本用例必须变红。
      expect(retryBatch.single.baseVersion, greaterThanOrEqualTo(authStart),
          reason: 'adoption 后必须用新 version 重推，'
              '不能沿用登记时的旧值（否则二次 stale 死循环）');
      expect(retryBatch.single.payload!['content_md'], '新正文',
          reason: '重推的 payload 必须是当前库里的新正文');

      final row = await (db.select(db.notes)
            ..where((t) => t.id.equals('n1')))
          .getSingle();
      expect(row.version, authStart + 1,
          reason: '服务端权威版本必须 adoption 回本地');
      expect(row.contentMd, '新正文');
      expect(await outbox.pendingCount(), 0,
          reason: '第二轮成功后 outbox 不应有残留 pending');
    });

    test('两轮都 skipped：不死循环，行保留 pending，绝不标 failed', () async {
      await enqueueNote(version: 1);
      for (var i = 0; i < 4; i++) {
        api.pushResponseQueue.add(SyncPushResult(
          accepted: 0,
          skipped: const <String>['notes:n1'],
          versions: const <String, int>{'notes:n1': 7},
          serverTime: t0,
        ));
      }

      final report = await engine.push();

      expect(api.pushHistory, hasLength(2), reason: '最多 2 轮，绝不无限重推');
      expect(report.skipped, greaterThan(0));
      final rows = await outbox.pending();
      expect(rows, hasLength(1), reason: 'skipped 行必须留在 outbox');
      expect(rows.single.status, OutboxStatus.pending.name,
          reason: '绝不能标 failed：failed 行会被追加在新 pending 行之后，'
              '形成 [新版, 旧版] 批内乱序倒灌');
    });
  });

  group('push envelope 口径', () {
    test('updatedAt 取 payload.updated_at，而不是 outbox.createdAt', () async {
      final editedAt = DateTime.utc(2026, 6, 1, 12);
      // enqueue 内部 createdAt = DateTime.now()，与 editedAt 明显不同。
      await enqueueNote(version: 3, updatedAt: editedAt);

      await engine.push();

      final env = api.pushHistory.single.single;
      expect(env.updatedAt, editedAt,
          reason: '必须与 pushAll 口径一致（行真正 updated_at），'
              '不能用发件箱创建时间污染 _compare 平局判定');
    });

    test('同一 key 的多条 outbox 行按 baseVersion 升序推，相等时保持原顺序',
        () async {
      // 两个 baseVersion=3 用来验证排序是稳定的（Dart List.sort 不稳定）。
      await enqueueNote(version: 9, contentMd: 'A');
      await enqueueNote(version: 3, contentMd: 'B');
      await enqueueNote(version: 6, contentMd: 'C');
      await enqueueNote(version: 3, contentMd: 'D');

      await engine.push();

      final envs = api.pushHistory.single;
      expect(<int>[for (final e in envs) e.baseVersion], <int>[3, 3, 6, 9],
          reason: '旧行在前、新行在后，中继批内「最后一条胜出」才落新行');
      expect(<String>[for (final e in envs) e.payload!['content_md'] as String],
          <String>['B', 'D', 'C', 'A'],
          reason: '相等 baseVersion 的两行必须保持插入顺序（稳定排序）');
    });
  });

  group('pull 计数', () {
    test('LWW keep local：输方正文内联合并进胜方笔记（P0，不另开副本）', () async {
      final localAt = DateTime.utc(2026, 6, 1, 12);
      await db.into(db.notes).insert(NotesCompanion(
            id: const Value('n1'),
            title: const Value('t'),
            contentMd: const Value('本地更新'),
            updatedAt: Value(localAt),
            version: const Value(5),
            deviceId: const Value('dev-B'),
          ));
      final remoteAt = localAt.subtract(const Duration(days: 1));
      api.enqueuePull(<SyncEnvelope>[
        SyncEnvelope(
          deviceId: 'remote-dev',
          entityTable: 'notes',
          entityId: 'n1',
          op: SyncOp.upsert,
          payload: <String, dynamic>{
            'id': 'n1',
            'notebook_id': null,
            'title': 't',
            'content_md': '远端旧值',
            'content_hash': '',
            'pinned': false,
            'updated_at': remoteAt.toIso8601String(),
            'version': 5,
            'device_id': 'remote-dev',
            'deleted_at': null,
          },
          baseVersion: 5,
          updatedAt: remoteAt,
          deletedAt: null,
        ),
      ]);

      final report = await engine.pull();

      // 胜方（本地）保留，输方（远端旧值）内联合并进同一篇笔记 —— 不另开副本。
      final row = await (db.select(db.notes)
            ..where((t) => t.id.equals('n1')))
          .getSingle();
      expect(row.contentMd, contains('本地更新'), reason: '胜方内容必须保留');
      expect(row.contentMd, contains('远端旧值'),
          reason: '输方内容必须内联合并，不能静默丢失');
      expect(row.contentMd, contains('同步冲突'),
          reason: '应带「同步冲突」标记区块');

      // 没有额外副本笔记，只有 n1 这一篇。
      final allNotes = await (db.select(db.notes)).get();
      expect(allNotes, hasLength(1),
          reason: '内联合并不应生成额外副本笔记');

      expect(report.conflictsMerged, 1, reason: '应计为一次内联合并');
      expect(report.applied, 0, reason: '胜方未被远端覆盖，不算应用');
      expect(report.keptLocal, 0);
    });
  });

  group('路径 B：手动全量拉取不能写回旧正文', () {
    test('云端被重推更新后，全量拉取落库的是新正文而非旧正文', () async {
      await repo.saveNote(Note(
          id: 'n1',
          title: 't',
          contentMd: '新正文',
          deviceId: 'dev-A'));
      const authStart = 7;
      api.pushResponseQueue.addAll(<SyncPushResult>[
        SyncPushResult(
          accepted: 0,
          skipped: const <String>['notes:n1'],
          versions: const <String, int>{'notes:n1': authStart},
          serverTime: t0,
        ),
        SyncPushResult(
          accepted: 1,
          skipped: const <String>[],
          versions: const <String, int>{'notes:n1': authStart + 1},
          serverTime: t0.add(const Duration(seconds: 1)),
        ),
      ]);

      final pushReport = await engine.push();
      // ★反向验红点：短路「自动重推」后这条必须变红（云端确实被改对的证据）。
      expect(api.pushHistory, hasLength(2),
          reason: '上传侧必须自动重推一轮，云端 payload 才会是新正文');
      expect(pushReport.skipped, 0);

      // 云端已被重推更新：取第二轮 envelope 的 payload 作为云端内容。
      final cloudPayload =
          Map<String, dynamic>.from(api.pushHistory[1].single.payload!);
      expect(cloudPayload['content_md'], '新正文',
          reason: '重推后云端存的必须是新正文');

      // 模拟「手动全量拉取」：设置页拉取前把 since 重置成 epoch
      // （sync_settings_section.dart:462-464），云端行会带合法高版本回来。
      // deviceId 必须不是本机，否则被自回声过滤跳过。
      api.enqueuePull(<SyncEnvelope>[
        SyncEnvelope(
          deviceId: 'cloud-relay',
          entityTable: 'notes',
          entityId: 'n1',
          op: SyncOp.upsert,
          payload: cloudPayload,
          baseVersion: authStart + 1,
          updatedAt: DateTime.now().toUtc().add(const Duration(days: 1)),
          deletedAt: null,
        ),
      ]);
      engine.updateLastPulledAt(DateTime.fromMillisecondsSinceEpoch(0));
      final pullReport = await engine.pull();

      expect(pullReport.applied, 1);
      expect(pullReport.keptLocal, 0);
      final row = await (db.select(db.notes)
            ..where((t) => t.id.equals('n1')))
          .getSingle();
      // 核心断言：全量拉取落库的必须仍是新正文，不能写回旧正文。
      expect(row.contentMd, '新正文',
          reason: '修复前手动全量拉取会把云端旧 payload 主动写回，正文变回旧值');
    });
  });
}
