/// 端到端回归：同篇笔记在两端之间「编辑」必须双向传播。
///
/// 复现用户现场：PC 与手机登录同一账号，一端改了、另一端拉取没变化，反向同理。
///
/// 关键设定 —— 本测试用的内存中继刻意模拟**用户实际部署的旧中继**：
///   - push 不递增 `base_version`（直接存客户端声明的版本），也不返回 `versions`
///     映射（旧中继契约，客户端 adoption 因此沦为 no-op）；
///   - manifest 不返回 `max_version` → 客户端回落 0（即用户看到的「服务器版本 0」）。
/// 在这种中继下，若 saveNote 不 bump 版本 + 刷新 updatedAt，接收方 LWW 会命中
/// `==` 平局分支（version 相等且 updatedAt 不更新）→ keep local → 编辑被静默丢弃。
///
/// 本测试任一用例变红 = 修复被回退。
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

/// 模拟用户实际部署的旧中继：存客户端声明版本、不递增、不返回 versions。
class _OldRelayApi implements SyncApi {
  _OldRelayApi();

  final Map<String, _Row> _store = {};
  int _clock = 0;

  String _key(SyncEnvelope e) => '${e.entityTable}:${e.entityId}';

  @override
  Future<SyncPushResult> pushBatch(List<SyncEnvelope> envelopes) async {
    _clock += 1;
    final serverTime = DateTime.utc(2026, 1, 1, 0, 0, _clock);
    for (final e in envelopes) {
      // 旧中继：直接落客户端声明的版本与 payload（不递增）。
      _store[_key(e)] = _Row(
        envelope: e.copyWith(baseVersion: e.baseVersion),
        serverTime: serverTime,
      );
    }
    // 旧中继不返回 versions 映射 → 客户端 adoption 为 no-op。
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
  Future<SyncManifestResult> fetchManifest() async =>
      // 旧中继缺 max_version → 客户端回落 0（用户看到的「服务器版本 0」）。
      SyncManifestResult.ok(SyncManifest(
        count: _store.length,
        maxVersion: 0,
      ));

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

/// Drift NoteRow → 领域 Note（模拟编辑器 _loadNote 的映射）。
Note _toNote(NoteRow r) => Note(
      id: r.id,
      notebookId: r.notebookId,
      title: r.title,
      contentMd: r.contentMd,
      contentHash: r.contentHash,
      updatedAt: r.updatedAt,
      version: r.version,
      deviceId: r.deviceId,
      deletedAt: r.deletedAt,
    );

void main() {
  late _OldRelayApi relay;

  setUp(() {
    relay = _OldRelayApi();
  });

  tearDown(() {
    SyncOutboxRepo.current = null;
  });

  test('A 建→B 拉→A 改→B 拉应看到；B 改→A 拉也应看到（双向）', () async {
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

    // 1) A 创建并上传。
    SyncOutboxRepo.current = outboxA;
    await repoA.saveNote(Note(id: 'n1', title: 'A 创建', contentMd: 'v1'));
    await engineA.push();

    // 2) B 拉取。
    SyncOutboxRepo.current = outboxB;
    await engineB.pull();
    expect(await _noteContent(dbB, 'n1'), 'v1',
        reason: 'B 应拉到 A 创建的内容');

    // 3) A 编辑（模拟编辑器：_loadNote 读回 → copyWith 只换内容）并上传。
    SyncOutboxRepo.current = outboxA;
    final aLoaded = _toNote(
        await (dbA.select(dbA.notes)..where((t) => t.id.equals('n1')))
            .getSingle());
    await repoA.saveNote(aLoaded.copyWith(title: 'A 改', contentMd: 'v2'));
    await engineA.push();

    // 4) B 拉取 —— 没有修复时这里会卡在旧内容（LWW 平局 keep local）。
    SyncOutboxRepo.current = outboxB;
    await engineB.pull();
    expect(await _noteContent(dbB, 'n1'), 'v2',
        reason: 'A 的编辑必须传播到 B（修复前会停在 v1）');

    // 5) 反向：B 编辑（同样走 _loadNote → copyWith）并上传。
    SyncOutboxRepo.current = outboxB;
    final bLoaded = _toNote(
        await (dbB.select(dbB.notes)..where((t) => t.id.equals('n1')))
            .getSingle());
    await repoB.saveNote(bLoaded.copyWith(contentMd: 'v3'));
    await engineB.push();

    // 6) A 拉取 —— 必须看到 B 的编辑。
    SyncOutboxRepo.current = outboxA;
    await engineA.pull();
    expect(await _noteContent(dbA, 'n1'), 'v3',
        reason: 'B 的编辑必须传播回 A（修复前会停在 v2）');

    await dbA.close();
    await dbB.close();
  });
}
