/// 回归测试：saveNote 必须在每次保存（含编辑）时递增 version 并刷新 updatedAt。
///
/// 背景（修复「同篇笔记跨设备编辑不传播」）：旧 saveNote 原样写回传入的
/// version / updatedAt，而编辑器 `_note!.copyWith(title, contentMd)` 不传这两者，
/// 导致编辑后的行与旧版本号 / 时间戳同值。接收方 LWW 在 `==` 平局分支里判
/// 成「keep local」，编辑被静默丢弃。删除 / 恢复路径都做了 version+1，saveNote
/// 必须口径一致。
///
/// 本文件任何一个用例变红都说明修复被回退：
/// 1. 每次 saveNote 都让该笔记的 version +1；
/// 2. 每次 saveNote 都让 updatedAt 晚于上一次；
/// 3. 即使调用方传入一个过时的 version，也按「现有行 + 1」算，不被传入值左右。
library;

import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 'test-device');
  });

  tearDown(() async {
    await db.close();
  });

  Future<Note> save(Note n) async {
    final res = await repo.saveNote(n);
    return (res as Success<Note>).value;
  }

  group('saveNote 编辑递增版本（回归：跨设备编辑不传播的根因）', () {
    test('每次 saveNote 都 +1 且刷新 updatedAt', () async {
      final first = await save(Note(id: 'n1', contentMd: 'v1'));
      expect(first.version, 1, reason: '首存从 1 起算（无现有行时 0+1）');

      // 模拟编辑器：copyWith 只换内容 / 标题，不传 version（沿用旧值）。
      final second =
          await save(first.copyWith(title: '改了', contentMd: 'v2'));
      expect(second.version, first.version + 1,
          reason: '编辑未 bump 版本 → 接收方 LWW 平局丢弃编辑（旧 bug）');
      expect(second.updatedAt.isAfter(first.updatedAt), isTrue,
          reason: 'updatedAt 不刷新 → 平局分支仍判 keep local');

      final third = await save(second.copyWith(contentMd: 'v3'));
      expect(third.version, second.version + 1);
    });

    test('传入过时 version 也按「现有行 + 1」算，不被传入值左右', () async {
      final a = await save(Note(id: 'n2', contentMd: 'x'));
      // 即便调用方传了一个过时的 version（例如从缓存里拿到的旧对象）。
      final stale = a.copyWith(version: 0, contentMd: 'y');
      final b = await save(stale);
      expect(b.version, a.version + 1,
          reason: 'saveNote 读现有行算 nextVersion，不信任传入 version');
    });

    test('连续多次编辑单调递增，无回退', () async {
      var cur = await save(Note(id: 'n3', contentMd: '0'));
      for (var i = 1; i <= 5; i++) {
        cur = await save(cur.copyWith(contentMd: '$i'));
        expect(cur.version, i + 1, reason: '第 $i 次编辑应为版本 ${i + 1}');
      }
    });
  });
}
