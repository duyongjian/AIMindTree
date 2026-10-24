/// 笔记附件（图片）仓储（T05 图片插入全链路）。
///
/// 图片的**唯一权威存储是 `note_assets.data_base64`**（SQLite 行内）：
/// - 磁盘不做图片缓存目录——「本地 SQLite 唯一业务源」铁律下，任何缓存
///   都是可重建的派生数据；解码后的字节只在内存里做 LRU（见 [_cache]）。
/// - 与笔记分开同步：笔记正文只放 `aimindtree-asset://<id>` 短引用，
///   附件单独走 outbox（`upsertNoteAsset` / `tombstoneNoteAsset` /
///   `hardDeleteNoteAssets`），避免把几 MB 的 base64 拖进笔记 envelope。
///
/// 三条硬规则：
/// 1. **大小上限** [kMaxAssetBytes]（2MB）：超出直接拒收，不写库。
///    手机拍的图经常 3-8MB，超限时提示用户换图（后续可加压缩，本期不做）。
/// 2. **同笔记 sha1 去重**：同一笔记里插入同一张图两次只存一行，
///    第二次返回已有 id（正文里就会出现两个指向同一 id 的引用）。
/// 3. **reconcile 孤儿清理**：正文里不再引用的附件 = 用户已删除的图片，
///    物理删 + `hardDeleteNoteAssets` 入队（墓碑留痕交给同步层）。
library;

// `dart:typed_data` 不单独导入：package:drift 已 `export 'dart:typed_data'
// show Uint8List`，重复导入会被 lint 判 unnecessary_import。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/id.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../db/drift_database.dart';
import '../models/note_asset.dart';
import '../sync/sync_outbox_writer.dart';

/// 单张图片的字节上限（2MB）：超出拒收。
///
/// 取 2MB 的理由：outbox push 批次预算默认 4MB（[SyncConfig.kSyncPushBatchBudgetBytes]，
/// edgeone 收紧到 850KB），一张图最坏情况也要能给 envelope 留出余量；
/// base64 还会再涨 33%。注：EdgeOne 链路单条上限仅 850KB，大图会被标记
/// failed，建议这类数据走 CF / CloudBase。
const int kMaxAssetBytes = 2 * 1024 * 1024;

/// 内存 LRU 的字节预算（32MB）：解码后的图片字节全部缓存在这里，
/// 超预算按最近最少使用逐出（key 见 [NoteAssetCache]）。
const int kAssetCacheBudgetBytes = 32 * 1024 * 1024;

/// 解码后的图片字节 LRU（`'$id:$version'` 为 key）。
///
/// 为什么带 version：同步 pull 可能用**同一个 id** 覆盖一行（LWW 收敛），
/// 只按 id 缓存会拿到旧字节 —— 渲染出「图片没变」的假象。version 是
/// 行级单调递增的同步凭证，进 key 才能保证「同 id 不同内容」不串味。
class NoteAssetCache {
  NoteAssetCache({this.budgetBytes = kAssetCacheBudgetBytes});

  /// 总字节预算。
  final int budgetBytes;

  final Map<String, Uint8List> _map = <String, Uint8List>{};
  int _bytes = 0;

  static String key(String id, int version) => '$id:$version';

  /// 取缓存（命中会刷新「最近使用」顺序）。
  Uint8List? get(String id, int version) {
    final k = key(id, version);
    final data = _map.remove(k);
    if (data == null) return null;
    _map[k] = data; // 重新插入到尾部 = 最近使用。
    return data;
  }

  /// 写缓存；超预算时从头部（最久未用）逐出，直到放得下。
  void put(String id, int version, Uint8List data) {
    final k = key(id, version);
    final existing = _map.remove(k);
    if (existing != null) _bytes -= existing.length;
    _map[k] = data;
    _bytes += data.length;
    while (_bytes > budgetBytes && _map.isNotEmpty) {
      final oldestKey = _map.keys.first;
      _bytes -= _map.remove(oldestKey)!.length;
    }
  }

  /// 当前占用字节（测试 / 诊断用）。
  int get bytes => _bytes;

  /// 当前条目数（测试 / 诊断用）。
  int get length => _map.length;
}

class NoteAssetRepository {
  NoteAssetRepository(this._db, {this.deviceId = ''});

  final AppDatabase _db;
  final String deviceId;

  /// 上行同步接线（`SyncOutboxRepo.current == null` 时全部静默跳过）。
  late final SyncOutboxWriter _sync = SyncOutboxWriter(_db);

  /// 解码字节的内存 LRU（跟着仓储对象同生命周期，bootstrap 里只建一次）。
  final NoteAssetCache _cache = NoteAssetCache();

  static final AppLog _log = AppLog('note_asset_repo');

  // ============ 读 ============

  /// 某篇笔记的全部附件（按写入顺序；展示序由正文引用顺序决定，
  /// 这里只保证稳定）。
  Future<List<NoteAsset>> assetsForNote(String noteId) async {
    final rows = await (_db.select(_db.noteAssets)
          ..where((t) => t.noteId.equals(noteId))
          ..orderBy([(t) => OrderingTerm.asc(t.updatedAt)]))
        .get();
    return rows.map(_fromRow).toList();
  }

  /// 解析附件的解码字节（优先 LRU → 库 → base64 解码 → 回填缓存）。
  ///
  /// 渲染层每次重建都会调它；命中缓存时零解码。返回 null = 不存在
  /// （同步未到 / 已删），调用方降级为「图片未同步」占位块。
  Future<Uint8List?> resolveBytes(String assetId) async {
    final row = await (_db.select(_db.noteAssets)
          ..where((t) => t.id.equals(assetId)))
        .getSingleOrNull();
    if (row == null) return null;
    final cached = _cache.get(row.id, row.version);
    if (cached != null) return cached;
    try {
      final data = base64Decode(row.dataBase64);
      _cache.put(row.id, row.version, data);
      return data;
    } on Object catch (e, s) {
      // base64 坏行（理论不出现：写入口径唯一）不能让整篇笔记渲染失败。
      _log.e('附件 base64 解码失败 $assetId', error: e, stackTrace: s);
      return null;
    }
  }

  // ============ 写 ============

  /// 插入一张图片，返回附件 id（供正文拼 `aimindtree-asset://<id>`）。
  ///
  /// - 超 [kMaxAssetBytes] → [Failure]，不写库；
  /// - 同笔记内 sha1 已存在 → 直接返回已有 id（去重，不写库、不入队）；
  /// - 否则插入新行 + `upsertNoteAsset` 入队。
  Future<Result<String>> putAsset({
    required String noteId,
    required Uint8List bytes,
    String name = '',
    String mime = 'image/png',
  }) async {
    try {
      if (noteId.isEmpty) {
        return Failure(ArgumentError('附件必须归属一篇已保存的笔记'));
      }
      if (bytes.isEmpty) {
        return Failure(ArgumentError('图片内容为空'));
      }
      if (bytes.length > kMaxAssetBytes) {
        return Failure(ArgumentError(
          '图片太大（${(bytes.length / 1024 / 1024).toStringAsFixed(1)}MB），'
          '上限 ${kMaxAssetBytes ~/ 1024 ~/ 1024}MB',
        ));
      }
      final sha1 = _sha1(bytes);
      // 同笔记去重：同样内容只存一份（跨笔记允许各存一份——
      // 附件归属单篇笔记，删一篇不应连带另一篇的插图）。
      final dup = await (_db.select(_db.noteAssets)
            ..where((t) =>
                t.noteId.equals(noteId) &
                t.sha1.equals(sha1) &
                t.deletedAt.isNull())
            ..limit(1))
          .getSingleOrNull();
      if (dup != null) {
        _log.i('附件去重命中 ${dup.id}（sha1=$sha1）');
        return Success(dup.id);
      }
      final id = newUlid();
      await _db.into(_db.noteAssets).insert(NoteAssetsCompanion(
            id: Value(id),
            noteId: Value(noteId),
            name: Value(name),
            mime: Value(mime),
            sha1: Value(sha1),
            bytes: Value(bytes.length),
            dataBase64: Value(base64Encode(bytes)),
            updatedAt: Value(DateTime.now().toUtc()),
            version: const Value(1),
            deviceId: Value(deviceId),
          ));
      await _sync.upsertNoteAsset(id);
      _log.i('插入附件 $id（${bytes.length}B, note=$noteId）');
      return Success(id);
    } on Object catch (e, s) {
      _log.e('插入附件失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 孤儿清理：物理删除 [noteId] 下**不被 [referencedIds] 引用**的附件。
  ///
  /// 调用时机 = 编辑器保存（正文是图片引用的唯一权威来源）。
  /// 返回删除的行数。只删**本笔记**的附件——别的笔记引用了同一张图
  /// （跨笔记复制粘贴的场景）不受影响。
  ///
  /// 为什么是物理删 + `hardDeleteNoteAssets` 而不是软删：附件是纯派生
  /// 数据（正文引用才是用户意图），留着墓碑只会让 `assetsForNote`
  /// 越来越脏；同步层的 hardDelete 会把删除意图告诉对端。
  Future<int> reconcileForNote(String noteId, Set<String> referencedIds) async {
    try {
      final rows = await (_db.select(_db.noteAssets)
            ..where((t) => t.noteId.equals(noteId)))
          .get();
      final orphans =
          rows.where((r) => !referencedIds.contains(r.id)).toList();
      if (orphans.isEmpty) return 0;
      for (final r in orphans) {
        await (_db.delete(_db.noteAssets)..where((t) => t.id.equals(r.id)))
            .go();
      }
      await _sync.hardDeleteNoteAssets(orphans);
      _log.i('清理孤儿附件 ${orphans.length} 个（note=$noteId）');
      return orphans.length;
    } on Object catch (e, s) {
      // 清理失败不影响保存（下次保存会再试）；只记账。
      _log.e('清理孤儿附件失败', error: e, stackTrace: s);
      return 0;
    }
  }

  // ============ 内部实现 ==============

  String _sha1(Uint8List bytes) => sha1.convert(bytes).toString();

  NoteAsset _fromRow(NoteAssetRow r) => NoteAsset(
        id: r.id,
        noteId: r.noteId,
        name: r.name,
        mime: r.mime,
        sha1: r.sha1,
        bytes: r.bytes,
        dataBase64: r.dataBase64,
        updatedAt: r.updatedAt,
        version: r.version,
        deviceId: r.deviceId,
      );
}
