/// 知识点排序比较器测试（T03：置顶 + 时间字段 + 名称兜底）。
///
/// 覆盖 [compareKp] 的三条优先级：
/// 1. 置顶恒在最前（与字段、方向无关）；
/// 2. 选定时间字段按 asc 决定方向（更新时间 / 创建时间）；
/// 3. 时间相同按名称升序（稳定可复现）；
/// 以及创建时间的 `effectiveCreatedAt` 兜底（createdAt 为 null → updatedAt）。
library;

import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/features/knowledge/kp_sort.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 造一个知识点（手动入口：锚点豁免）。
  KnowledgePoint kp(
    String name, {
    bool pinned = false,
    DateTime? updatedAt,
    DateTime? createdAt,
  }) =>
      KnowledgePoint(
        name: name,
        sourceNoteId: '',
        sourceStart: -1,
        sourceEnd: -1,
        sourceQuote: '',
        pinned: pinned,
        updatedAt: updatedAt,
        createdAt: createdAt,
      );

  List<String> names(
    List<KnowledgePoint> list, {
    required KpSortField field,
    required bool asc,
  }) =>
      (list.toList()
            ..sort((a, b) => compareKp(a, b, field: field, asc: asc)))
          .map((k) => k.name)
          .toList();

  group('置顶优先', () {
    test('置顶点恒在最前，与字段、方向无关', () {
      final a = kp('旧置顶', pinned: true, updatedAt: DateTime.utc(2024, 1, 1));
      final b = kp('新普通', updatedAt: DateTime.utc(2024, 6, 1));
      final c = kp('中置顶', pinned: true, updatedAt: DateTime.utc(2024, 3, 1));

      for (final field in KpSortField.values) {
        for (final asc in const [true, false]) {
          expect(
            names(<KnowledgePoint>[b, a, c], field: field, asc: asc),
            // 置顶两组按时间排，普通点恒在最后。
            asc ? <String>['旧置顶', '中置顶', '新普通'] : <String>['中置顶', '旧置顶', '新普通'],
          );
        }
      }
    });

    test('两边都置顶 / 都没置顶 → 退回时间字段比较', () {
      final a = kp('A', pinned: true, updatedAt: DateTime.utc(2024, 5, 1));
      final b = kp('B', pinned: true, updatedAt: DateTime.utc(2024, 1, 1));
      expect(
        names(<KnowledgePoint>[a, b],
            field: KpSortField.updatedAt, asc: false),
        <String>['A', 'B'],
      );
    });
  });

  group('时间字段', () {
    test('updatedAt：asc = 最早在上，false = 最新在上', () {
      final old = kp('旧', updatedAt: DateTime.utc(2024, 1, 1));
      final mid = kp('中', updatedAt: DateTime.utc(2024, 3, 15));
      final new_ = kp('新', updatedAt: DateTime.utc(2024, 6, 30));
      final list = <KnowledgePoint>[mid, old, new_];

      expect(names(list, field: KpSortField.updatedAt, asc: true),
          <String>['旧', '中', '新']);
      expect(names(list, field: KpSortField.updatedAt, asc: false),
          <String>['新', '中', '旧']);
    });

    test('createdAt 走 effectiveCreatedAt：null 回落到 updatedAt', () {
      // 两个点 createdAt 均为 null → 都应回落到各自的 updatedAt。
      final a = kp('回落旧', updatedAt: DateTime.utc(2024, 1, 1));
      final b = kp('回落新', updatedAt: DateTime.utc(2024, 9, 1));
      expect(
        names(<KnowledgePoint>[b, a],
            field: KpSortField.createdAt, asc: true),
        <String>['回落旧', '回落新'],
      );

      // 有 createdAt 的点按 createdAt 排，与 updatedAt 无关。
      final earlyCreated = kp('建得早改得晚',
          updatedAt: DateTime.utc(2024, 12, 1), createdAt: DateTime.utc(2024, 1, 1));
      final lateCreated = kp('建得晚改得早',
          updatedAt: DateTime.utc(2024, 2, 1), createdAt: DateTime.utc(2024, 11, 1));
      expect(
        names(<KnowledgePoint>[lateCreated, earlyCreated],
            field: KpSortField.createdAt, asc: true),
        <String>['建得早改得晚', '建得晚改得早'],
      );
      // 同一组数据按 updatedAt 排则顺序相反（证明字段真的在起作用）。
      expect(
        names(<KnowledgePoint>[earlyCreated, lateCreated],
            field: KpSortField.updatedAt, asc: true),
        <String>['建得晚改得早', '建得早改得晚'],
      );
    });
  });

  group('名称兜底', () {
    test('时间相同（含同时刻）按名称升序', () {
      final t = DateTime.utc(2024, 6, 1, 12);
      final b = kp('Banana', updatedAt: t);
      final a = kp('Apple', updatedAt: t);
      final c = kp('Cherry', updatedAt: t);

      for (final asc in const [true, false]) {
        expect(
          names(<KnowledgePoint>[c, b, a],
              field: KpSortField.updatedAt, asc: asc),
          <String>['Apple', 'Banana', 'Cherry'],
        );
      }
    });
  });
}
