/// T01 数据层地基（schema v4 → v5）的验收测试。
///
/// 覆盖三件事：
/// 1. 新建库里知识点的 `pinned` 默认 false、`createdAt` 被写入（新列真的生效）；
/// 2. `note_assets` 表存在且可写；
/// 3. **真实的** `onUpgrade` 迁移：把文件库手工降回 v4 形态再让 drift 打开，
///    验证历史行的 `created_at` 被回填成 `updated_at`、`pinned` 落 false、
///    `note_assets` 被建出来。
///
/// ⚠️ 为什么不用内存库测迁移：`NativeDatabase.memory()` 永远是全新库，
/// 走的是 `onCreate` 而不是 `onUpgrade`，测不到迁移代码。这里用**文件库 +
/// `PRAGMA user_version` 手工回退**的方式真正触发 `from < 5` 分支。
library;

import 'dart:io';

import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/models/note_asset.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
// 只为了拿 `Value`；drift 也导出了一套 SQL 版 isNull/isNotNull，与 matcher 撞名故隐藏。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一条「旧时代」的知识点更新时间（远早于 createdAt，用来证明回填取自它）。
final DateTime kLegacyUpdatedAt = DateTime.utc(2024, 1, 2, 3, 4, 5);

/// 与之无关的另一个时间点（若回填逻辑写错成了「保留原 createdAt」，会命中它）。
final DateTime kLegacyCreatedAt = DateTime.utc(2023, 5, 5, 6, 7, 8);

/// 取时刻（毫秒）。
///
/// sqlite 里 DateTime 存的是 INTEGER 秒、回读成本地时区的 DateTime，而 Dart 的
/// `DateTime ==` 还会比对 `isUtc`，直接拿两个对象比会假失败，所以统一比时刻。
int _instant(DateTime t) => t.millisecondsSinceEpoch;

void main() {
  group('v5 新列：正常读写路径', () {
    late AppDatabase db;
    late KnowledgeRepository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = KnowledgeRepository(db, deviceId: 'v5-test');
    });

    tearDown(() async {
      await db.close();
    });

    test('新建知识点默认不置顶（pinned == false）', () async {
      final res = await repo.createManualKnowledgePoint(name: '牛顿第一定律');
      final kp = (res as Success<KnowledgePoint>).value;

      // 领域对象侧
      expect(kp.pinned, isFalse, reason: '新建知识点默认不置顶');

      // 落库回读侧（证明列真的存在、默认值真的生效）
      final row = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(kp.id)))
          .getSingle();
      expect(row.pinned, isFalse);

      final readBack = (await repo.allKnowledgePoints()).single;
      expect(readBack.pinned, isFalse);
      expect(readBack.id, kp.id);
    });

    test('正常插入路径会写入非 null 的 createdAt', () async {
      final manual = await repo.createManualKnowledgePoint(name: '手动点');
      final manualKp = (manual as Success<KnowledgePoint>).value;

      final row = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(manualKp.id)))
          .getSingle();
      expect(row.createdAt, isNotNull,
          reason: 'created_at 列可空，但新建行必须由仓储写入，不能为 null');

      // AI 提取入库（另一条写路径）同样不能漏。
      await repo.saveNote(Note(id: 'n1', contentMd: '任何物体都要保持惯性。'));
      final extracted = await repo.saveExtracted(
        noteId: 'n1',
        noteContent: '任何物体都要保持惯性。',
        rawPoints: const [RawKnowledgePoint(name: '提取点', sourceQuote: '惯性')],
      );
      final extractedKp = (extracted as Success<ExtractionSaveResult>)
          .value
          .saved
          .single;
      final row2 = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(extractedKp.id)))
          .getSingle();
      expect(row2.createdAt, isNotNull,
          reason: 'saveExtracted 这条写路径也必须补 createdAt');

      // 回读进领域对象一样不能丢，且 effectiveCreatedAt 兜底可用。
      final all = await repo.allKnowledgePoints();
      for (final kp in all) {
        expect(kp.createdAt, isNotNull);
        expect(kp.effectiveCreatedAt, kp.createdAt);
      }
    });

    test('note_assets 表存在且能插入一条', () async {
      await db.into(db.noteAssets).insert(
            NoteAssetsCompanion.insert(
              id: 'asset-1',
              noteId: 'n1',
              name: const Value('惯性.png'),
              dataBase64: 'iVBORw0KGgo=',
              updatedAt: DateTime.now().toUtc(),
              deviceId: 'v5-test',
            ),
          );

      final rows = await db.select(db.noteAssets).get();
      expect(rows, hasLength(1));
      expect(rows.single.noteId, 'n1');
      expect(rows.single.mime, 'image/png', reason: 'mime 默认值');
      expect(rows.single.bytes, 0, reason: 'bytes 默认值');
      expect(rows.single.sha1, '', reason: 'sha1 默认值');
      expect(rows.single.deletedAt, isNull);
    });
  });

  group('v4 → v5 迁移（真跑 onUpgrade）', () {
    Directory? tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('aimindtree_v5_migration');
    });

    tearDown(() {
      tmp?.deleteSync(recursive: true);
    });

    test('历史行 created_at 回填为 updated_at、pinned 落 false、新建 note_assets',
        () async {
      final file = File('${tmp!.path}${Platform.pathSeparator}legacy.sqlite');

      // ① 先用当前（v5）代码建一个库并落一条历史数据：updated_at 故意是
      //    2024-01-02，created_at 故意是 2023-05-05（二者不同，便于判定回填来源）。
      final v5 = AppDatabase(NativeDatabase(file));
      await v5.into(v5.knowledgePoints).insert(
            KnowledgePointsCompanion.insert(
              id: 'kp-legacy',
              name: '历史知识点',
              type: 'concept',
              sourceNoteId: 'note-legacy',
              sourceStart: 0,
              sourceEnd: 2,
              sourceQuote: '历史',
              deviceId: 'legacy-device',
              version: const Value(7),
              updatedAt: kLegacyUpdatedAt,
              createdAt: Value(kLegacyCreatedAt),
            ),
          );
      await v5.close();

      // ② 把它手工降回 **v4 形态**：抽掉 pinned / created_at 两列、删掉
      //    note_assets 表、PRAGMA user_version 退回 4。
      //    （SQLite 老版本不支持 DROP COLUMN，用「建新表 → 拷数据 → 改名」这一套，
      //     任何 3.25+ 都能跑。）
      final surgery = AppDatabase(NativeDatabase(file));
      await surgery.customStatement('DROP TABLE IF EXISTS note_assets');
      await surgery.customStatement('''
CREATE TABLE knowledge_points_v4 (
  id TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL,
  device_id TEXT NOT NULL,
  deleted_at INTEGER NULL,
  notebook_id TEXT NULL,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  definition TEXT NOT NULL,
  source_note_id TEXT NOT NULL,
  source_start INTEGER NOT NULL,
  source_end INTEGER NOT NULL,
  source_quote TEXT NOT NULL,
  origin TEXT NOT NULL,
  confidence REAL NOT NULL,
  PRIMARY KEY (id)
)''');
      await surgery.customStatement('''
INSERT INTO knowledge_points_v4 (
  id, version, updated_at, device_id, deleted_at, notebook_id, name, type,
  definition, source_note_id, source_start, source_end, source_quote,
  origin, confidence
)
SELECT
  id, version, updated_at, device_id, deleted_at, notebook_id, name, type,
  definition, source_note_id, source_start, source_end, source_quote,
  origin, confidence
FROM knowledge_points''');
      await surgery.customStatement('DROP TABLE knowledge_points');
      await surgery
          .customStatement('ALTER TABLE knowledge_points_v4 RENAME TO knowledge_points');
      await surgery.customStatement('PRAGMA user_version = 4');
      // 自检：降版后确实只剩 v4 的 15 列，且 note_assets 已不存在。
      expect(
        await surgery
            .customSelect('PRAGMA table_info(knowledge_points)')
            .get()
            .then((rows) => rows.length),
        15,
        reason: '回退后 knowledge_points 应是 v4 的 15 列',
      );
      await surgery.close();

      // ③ 重新打开：drift 发现 user_version=4 < schemaVersion=5 → 真正执行
      //    onUpgrade 的 `from < 5` 分支（不是 onCreate）。
      final migrated = AppDatabase(NativeDatabase(file));
      addTearDown(migrated.close);

      final rows = await migrated.select(migrated.knowledgePoints).get();
      expect(rows, hasLength(1), reason: '历史数据不能丢');

      final legacy = rows.single;
      expect(legacy.id, 'kp-legacy');
      expect(legacy.version, 7, reason: '迁移不能动既有版本值');
      // 注意：sqlite 里日期是 INTEGER 秒，回读成本地时区的 DateTime，
      // 而 Dart 的 `DateTime ==` 还要求 isUtc 一致，所以这里比时刻不比对象。
      expect(_instant(legacy.updatedAt), _instant(kLegacyUpdatedAt),
          reason: '迁移不能动 updated_at');

      // ★ 迁移的核心断言：历史行的创建时间用「当时已知的更新时间」近似回填。
      expect(legacy.createdAt, isNotNull, reason: 'created_at 必须被回填，不能留空');
      expect(_instant(legacy.createdAt!), _instant(kLegacyUpdatedAt),
          reason: 'created_at 应取自 updated_at（2024-01-02），而不是原值 2023-05-05');
      expect(_instant(legacy.createdAt!) == _instant(kLegacyCreatedAt), isFalse,
          reason: '必须是回填出来的新值，不是原来的 2023-05-05');
      expect(legacy.createdAt, legacy.updatedAt);

      // ★ 非空布尔新列的回填：历史行落 false（不置顶）。
      expect(legacy.pinned, isFalse);

      // ★ note_assets 表由迁移建出来。
      await migrated.into(migrated.noteAssets).insert(
            NoteAssetsCompanion.insert(
              id: 'asset-after-migration',
              noteId: 'note-legacy',
              dataBase64: 'iVBORw0KGgo=',
              updatedAt: DateTime.now().toUtc(),
              deviceId: 'legacy-device',
              name: const Value('迁移后可写.png'),
              mime: const Value('image/png'),
              sha1: const Value('da39a3ee5e6b4b0d3255bfef95601890afd80709'),
              bytes: const Value(8),
            ),
          );
      final assets = await migrated.select(migrated.noteAssets).get();
      expect(assets, hasLength(1));
      expect(assets.single.id, 'asset-after-migration');
      expect(assets.single.bytes, 8);
    });
  });

  group('附件 URI 纯函数（渲染与清理共用同一份）', () {
    test('assetUri 生成 aimindtree-asset://<id>', () {
      expect(assetUri('abc123'), 'aimindtree-asset://abc123');
      expect(assetUri('abc123').startsWith('$kAssetUriScheme://'), isTrue);
    });

    test('extractAssetIds 能解析出正文里引用的所有 id', () {
      final ids = extractAssetIds(
        '![图](${assetUri('a1')})\n\n文字\n\n![另一张](${assetUri('b2')})',
      );
      expect(ids, <String>{'a1', 'b2'});
    });

    test('extractAssetIds 去重且容错', () {
      final same = extractAssetIds('${assetUri('dup')} ${assetUri('dup')}');
      expect(same, <String>{'dup'}, reason: '同一 id 多次引用要去重');

      expect(extractAssetIds('没有任何附件的正文'), isEmpty);
      expect(extractAssetIds(''), isEmpty);
      expect(extractAssetIds('http://example.com/a.png'), isEmpty,
          reason: '普通 http 链接不能被误认成附件');
    });
  });
}
