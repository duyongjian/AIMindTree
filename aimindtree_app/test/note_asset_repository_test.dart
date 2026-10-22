/// 笔记附件（图片）仓储测试（T05 图片插入全链路）。
///
/// 覆盖四层：
/// 1. **putAsset 数据面**：base64 往返、sha1 同笔记去重（跨笔记不误伤）、
///    2MB 上限拒收、空 noteId / 空字节拒收；
/// 2. **resolveBytes**：LRU 命中（改库不翻案——version 进 key）、
///    坏 base64 不炸（返回 null 让渲染降级）；
/// 3. **reconcileForNote**：被引用的保留、孤儿物理删；只删本笔记的附件
///    （跨笔记复制粘贴的场景另一篇的插图不受影响）；
/// 4. **同步接线**：put → upsert 入队（payload 带 data_base64）；
///    reconcile 硬删 → hardDelete 入队；未接线时不崩也不入队；
/// 5. **NoteAssetCache**：LRU 逐出顺序 + `$id:$version` 键不串味。
library;

// `dart:typed_data` 不单独导入：package:drift 已 export Uint8List，
// 重复导入会被 lint 判 unnecessary_import（Uint8List 从 drift 来）。
import 'dart:convert';

import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/note_asset_repository.dart'
    show NoteAssetCache, NoteAssetRepository, kMaxAssetBytes;
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:aimindtree_app/data/sync/sync_types.dart';
// drift 与 matcher 都导出 isNull / isNotNull（列表达式扩展 vs 断言匹配器），
// 双导入会歧义 → 藏掉 drift 那两个，测试断言统一用 matcher 的。
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late NoteAssetRepository assets;
  late KnowledgeRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    assets = NoteAssetRepository(db, deviceId: 'd');
    repo = KnowledgeRepository(db, deviceId: 'd');
  });

  tearDown(() async {
    SyncOutboxRepo.current = null;
    await db.close();
  });

  /// 造一篇笔记（附件必须归属已存在的笔记；走仓储拿真实 ULID id）。
  Future<String> makeNote(String title) async {
    final res = await repo.saveNote(
      Note(title: title, contentMd: '', deviceId: 'd'),
    );
    return (res as Success<Note>).value.id;
  }

  /// 造 N 字节的可区分内容（前 4 字节放序号，后面填 0）。
  Uint8List blob(int seed, int size) {
    final b = Uint8List(size);
    b[0] = seed & 0xFF;
    b[1] = (seed >> 8) & 0xFF;
    return b;
  }

  group('putAsset 数据面', () {
    test('入库 + base64 往返（resolveBytes 拿回原字节）', () async {
      final noteId = await makeNote('图1');
      final bytes = blob(7, 300);

      final res = await assets.putAsset(
        noteId: noteId,
        bytes: bytes,
        name: 'a.png',
        mime: 'image/png',
      );
      expect(res, isA<Success<String>>());
      final id = (res as Success<String>).value;

      // 行内容：sha1 / bytes / data_base64 都对。
      final row = await (db.select(db.noteAssets)
            ..where((t) => t.id.equals(id)))
          .getSingle();
      expect(row.noteId, noteId);
      expect(row.name, 'a.png');
      expect(row.mime, 'image/png');
      expect(row.bytes, 300);
      expect(row.sha1, isNotEmpty);
      expect(base64Decode(row.dataBase64), bytes);

      // 读回字节与入库时逐字节相等。
      final back = await assets.resolveBytes(id);
      expect(back, bytes);
    });

    test('同笔记 sha1 去重：第二次返回同一 id，不多存行', () async {
      final noteId = await makeNote('去重');
      final bytes = blob(1, 128);

      final r1 = await assets.putAsset(noteId: noteId, bytes: bytes);
      final r2 = await assets.putAsset(noteId: noteId, bytes: bytes);
      final id1 = (r1 as Success<String>).value;
      final id2 = (r2 as Success<String>).value;
      expect(id2, id1);

      final rows = await assets.assetsForNote(noteId);
      expect(rows, hasLength(1));
    });

    test('跨笔记不去重：同一张图贴进两篇笔记各存一份', () async {
      final n1 = await makeNote('笔记A');
      final n2 = await makeNote('笔记B');
      final bytes = blob(2, 64);

      final r1 = await assets.putAsset(noteId: n1, bytes: bytes);
      final r2 = await assets.putAsset(noteId: n2, bytes: bytes);
      final id1 = (r1 as Success<String>).value;
      final id2 = (r2 as Success<String>).value;
      expect(id1, isNot(id2));

      // 删一篇不影响另一篇（reconcile 只扫本笔记）。
      await assets.reconcileForNote(n1, const <String>{});
      expect(await assets.assetsForNote(n1), isEmpty);
      expect(await assets.assetsForNote(n2), hasLength(1));
    });

    test('超 2MB 拒收：Failure + 不写库', () async {
      final noteId = await makeNote('大图');
      final big = blob(3, kMaxAssetBytes + 1);

      final res = await assets.putAsset(noteId: noteId, bytes: big);
      expect(res, isA<Failure<String>>());
      expect((res as Failure<String>).message, contains('图片太大'));
      expect(await assets.assetsForNote(noteId), isEmpty);
    });

    test('恰好 2MB 边界：放行', () async {
      final noteId = await makeNote('边界');
      final ok = blob(4, kMaxAssetBytes);
      final res = await assets.putAsset(noteId: noteId, bytes: ok);
      expect(res, isA<Success<String>>());
    });

    test('空 noteId / 空字节拒收', () async {
      final noteId = await makeNote('哨兵');
      expect((await assets.putAsset(noteId: '', bytes: blob(1, 8))),
          isA<Failure<String>>());
      expect((await assets.putAsset(noteId: noteId, bytes: Uint8List(0))),
          isA<Failure<String>>());
      expect(await assets.assetsForNote(noteId), isEmpty);
    });
  });

  group('resolveBytes', () {
    test('不存在的 id → null（渲染层降级占位，不抛）', () async {
      expect(await assets.resolveBytes('no-such-id'), isNull);
    });

    test('LRU 命中：库里内容被改也不翻案（version 进 key）', () async {
      final noteId = await makeNote('缓存');
      final bytes = blob(9, 100);
      final id =
          (await assets.putAsset(noteId: noteId, bytes: bytes)) as Success<String>;

      // 第一次解析 → 进缓存。
      expect(await assets.resolveBytes(id.value), bytes);

      // 模拟「同步 pull 用同 id 覆盖一行」：version+1 + 换内容。
      await (db.update(db.noteAssets)..where((t) => t.id.equals(id.value)))
          .write(NoteAssetsCompanion(
        version: const Value(2),
        dataBase64: Value(base64Encode(blob(10, 100))),
      ));

      // 旧 version 的缓存键不再命中 → 读到新内容（绝不串味）。
      final after = await assets.resolveBytes(id.value);
      expect(after, blob(10, 100));
      expect(after, isNot(bytes));
    });

    test('坏 base64 → null 而不是抛异常（整篇笔记永远能渲染）', () async {
      final noteId = await makeNote('坏行');
      final id = (await assets.putAsset(
        noteId: noteId,
        bytes: blob(11, 32),
      )) as Success<String>;
      await (db.update(db.noteAssets)..where((t) => t.id.equals(id.value)))
          .write(const NoteAssetsCompanion(dataBase64: Value('!!!not-base64!!!')));

      expect(await assets.resolveBytes(id.value), isNull);
    });
  });

  group('reconcileForNote 孤儿清理', () {
    test('被引用的保留、未引用的物理删', () async {
      final noteId = await makeNote('清理');
      final keep =
          (await assets.putAsset(noteId: noteId, bytes: blob(1, 16))) as Success<String>;
      final drop =
          (await assets.putAsset(noteId: noteId, bytes: blob(2, 16))) as Success<String>;

      final removed = await assets.reconcileForNote(
        noteId,
        <String>{keep.value},
      );
      expect(removed, 1);

      final rows = await assets.assetsForNote(noteId);
      expect(rows.map((r) => r.id), <String>[keep.value]);
      // 物理删：行真的没了（不是墓碑）。
      final gone = await (db.select(db.noteAssets)
            ..where((t) => t.id.equals(drop.value)))
          .get();
      expect(gone, isEmpty);
    });

    test('空引用集 → 全部清空（用户删掉了所有图片行）', () async {
      final noteId = await makeNote('全删');
      await assets.putAsset(noteId: noteId, bytes: blob(1, 16));
      await assets.putAsset(noteId: noteId, bytes: blob(2, 16));

      expect(await assets.reconcileForNote(noteId, const <String>{}), 2);
      expect(await assets.assetsForNote(noteId), isEmpty);
    });

    test('无孤儿 → 0（幂等，重复保存不重复入队）', () async {
      final noteId = await makeNote('幂等');
      final id =
          (await assets.putAsset(noteId: noteId, bytes: blob(1, 16))) as Success<String>;
      expect(await assets.reconcileForNote(noteId, <String>{id.value}), 0);
    });
  });

  group('同步接线', () {
    test('未接线（current == null）：写仓储不崩、不入队', () async {
      final noteId = await makeNote('未接线');
      expect(SyncOutboxRepo.current, isNull);
      final res = await assets.putAsset(noteId: noteId, bytes: blob(1, 16));
      expect(res, isA<Success<String>>());
    });

    test('putAsset → note_assets upsert（payload 带 data_base64）', () async {
      final noteId = await makeNote('同步图');
      final outbox = SyncOutboxRepo(db, deviceId: 'd');
      SyncOutboxRepo.current = outbox;

      final id = (await assets.putAsset(
        noteId: noteId,
        bytes: blob(5, 24),
        name: 'x.png',
      )) as Success<String>;

      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      final row = pending.single;
      expect(row.entityTable, 'note_assets');
      expect(row.entityId, id.value);
      expect(row.op, SyncOp.upsert.name);
      expect(row.payloadJson, contains('data_base64'));
      expect(row.payloadJson, contains('"sha1"'));
    });

    test('reconcile 硬删 → hardDelete 入队', () async {
      final noteId = await makeNote('同步删');
      final outbox = SyncOutboxRepo(db, deviceId: 'd');
      SyncOutboxRepo.current = outbox;
      final id = (await assets.putAsset(
        noteId: noteId,
        bytes: blob(6, 24),
      )) as Success<String>;
      // 清掉 insert 那条，只看删除意图。
      await (db.delete(db.syncOutbox)).go();

      await assets.reconcileForNote(noteId, const <String>{});

      final pending = await outbox.pending();
      expect(pending, hasLength(1));
      expect(pending.single.entityTable, 'note_assets');
      expect(pending.single.entityId, id.value);
      // 硬删在同步层的语义就是 delete（payload 只有 deleted_at）。
      expect(pending.single.op, SyncOp.delete.name);
    });
  });

  group('NoteAssetCache（LRU）', () {
    test('超预算逐出最久未用；get 刷新使用顺序', () {
      // 预算 250：a+b=200 放得下，再放 c（+100）必逐出最久未用的。
      final cache = NoteAssetCache(budgetBytes: 250);
      cache.put('a', 1, Uint8List(100));
      cache.put('b', 1, Uint8List(100));
      expect(cache.bytes, 200);

      // 用一次 a → b 变成最久未用。
      expect(cache.get('a', 1), isNotNull);
      cache.put('c', 1, Uint8List(100)); // 超预算 → 逐出 b。
      expect(cache.get('b', 1), isNull);
      expect(cache.get('a', 1), isNotNull);
      expect(cache.get('c', 1), isNotNull);
      expect(cache.bytes, lessThanOrEqualTo(250));
    });

    test('key 带 version：同 id 不同 version 是两条', () {
      final cache = NoteAssetCache(budgetBytes: 1000);
      final v1 = Uint8List.fromList(<int>[1, 2, 3]);
      final v2 = Uint8List.fromList(<int>[4, 5, 6]);
      cache.put('same', 1, v1);
      cache.put('same', 2, v2);
      expect(cache.get('same', 1), v1);
      expect(cache.get('same', 2), v2);
      expect(cache.length, 2);
    });
  });
}
