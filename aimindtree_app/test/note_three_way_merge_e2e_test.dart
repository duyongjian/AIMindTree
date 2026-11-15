/// 端到端回归：基线收敛后，两端各改不同段落 → pull 时走段级三方合并，
/// 两边改动都保留、且不进入「同步冲突」内联合并区块（P2 路径 C 集成验证）。
///
/// 复现场景：手机改了第一段、PC 改了第二段，两边都基于同一份旧版（基线）分叉，
/// 拉取时应把两段改动合并成一篇，而不是把一方追加成冲突段落。
library;

import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/sync/sync_api.dart';
import 'package:aimindtree_app/data/sync/sync_config.dart';
import 'package:aimindtree_app/data/sync/sync_engine.dart';
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:aimindtree_app/data/sync/sync_types.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存中继：按 (table:id) 覆盖存储最新一份，不递增版本、不返回 versions
/// （刻意贴近用户旧中继，逼出「baseline 必须本地建立」这条链路）。
class _MemRelayApi implements SyncApi {
  _MemRelayApi();

  final Map<String, _Row> _store = {};
  int _clock = 0;

  String _key(SyncEnvelope e) => '${e.entityTable}:${e.entityId}';

  @override
  Future<SyncPushResult> pushBatch(List<SyncEnvelope> envelopes) async {
    _clock += 1;
    final serverTime = DateTime.utc(2026, 1, 1, 0, 0, _clock);
    for (final e in envelopes) {
      _store[_key(e)] = _Row(envelope: e, serverTime: serverTime);
    }
    return SyncPushResult(
      accepted: envelopes.length,
      serverTime: serverTime,
      versions: const {},
    );
  }

  @override
  Future<SyncPullResult> pullSince(DateTime? since) async {
    final list = _store.values
        .where((r) => since == null || r.serverTime.isAfter(since))
        .map((r) => r.envelope)
        .toList();
    return SyncPullResult(
      envelopes: list,
      serverTime: DateTime.utc(2026, 1, 1, 0, 0, _clock),
    );
  }

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<SyncManifestResult> fetchManifest() async => SyncManifestResult.ok(
        SyncManifest(count: _store.length, maxVersion: 0),
      );

  @override
  void close() {}

  @override
  int get pushBatchBudgetBytes => SyncConfig.kSyncPushBatchBudgetBytes;

  @override
  int get maxEnvelopeBytes => SyncConfig.kSyncMaxEnvelopeBytes;
}

class _Row {
  _Row({required this.envelope, required this.serverTime});
  final SyncEnvelope envelope;
  final DateTime serverTime;
}

Future<String> _noteContent(AppDatabase db, String id) async {
  final row =
      await (db.select(db.notes)..where((t) => t.id.equals(id))).getSingle();
  return row.contentMd;
}

void main() {
  late _MemRelayApi relay;

  setUp(() {
    relay = _MemRelayApi();
  });

  tearDown(() {
    SyncOutboxRepo.current = null;
  });

  test('基线收敛后两端各改不同段落 → pull 三方合并保留两边、不进冲突区块',
      () async {
    const noteId = 'n1';
    const base = 'P1\n\nP2'; // 共同祖先：两段

    final dbA = AppDatabase(NativeDatabase.memory());
    final outboxA = SyncOutboxRepo(dbA, deviceId: 'dev-A');
    final repoA = KnowledgeRepository(dbA, deviceId: 'dev-A');
    final engineA =
        SyncEngine(db: dbA, api: relay, outbox: outboxA, deviceId: 'dev-A');

    final dbB = AppDatabase(NativeDatabase.memory());
    final outboxB = SyncOutboxRepo(dbB, deviceId: 'dev-B');
    final repoB = KnowledgeRepository(dbB, deviceId: 'dev-B');
    final engineB =
        SyncEngine(db: dbB, api: relay, outbox: outboxB, deviceId: 'dev-B');

    // 1) A 创建基线并上传。
    SyncOutboxRepo.current = outboxA;
    await repoA.saveNote(Note(id: noteId, title: 't', contentMd: base));
    await engineA.push();

    // 2) B 拉取 → 建立 B 端的收敛基线（== base）。
    SyncOutboxRepo.current = outboxB;
    await engineB.pull();
    expect(await _noteContent(dbB, noteId), base,
        reason: 'B 应拉到共同祖先');

    // 3) A 改第一段、B 改第二段（各自基于 base 分叉）。
    SyncOutboxRepo.current = outboxA;
    await repoA.saveNote(Note(id: noteId, title: 't', contentMd: 'P1-A\n\nP2'));
    await engineA.push(); // 中继现在只存 A 的 v2

    SyncOutboxRepo.current = outboxB;
    await repoB.saveNote(Note(id: noteId, title: 't', contentMd: 'P1\n\nP2-B'));

    // 4) B 拉 A 的改动 → 应段级三方合并：P1 取 A、P2 取 B。
    final report = await engineB.pull();
    final merged = await _noteContent(dbB, noteId);

    expect(merged, 'P1-A\n\nP2-B',
        reason: '两段改动都应保留（各取一端）');
    expect(merged.contains('同步冲突'), isFalse,
        reason: '正常三方合并不应产生冲突区块');
    expect(report.conflictsMerged, 0,
        reason: '没有冲突回落，不应计为内联合并');
    expect(report.applied, greaterThanOrEqualTo(1),
        reason: '三方合并结果应作为一次应用落库');

    await dbA.close();
    await dbB.close();
  });
}
