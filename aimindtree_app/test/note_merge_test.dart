/// 段级三方合并（P2 路径 C）的纯函数单元测试。
///
/// 不依赖数据库：只验证 [threeWayMergeNotes] 在三份 Markdown（base / local /
/// remote）上的段级判定与 L1 安全护栏。
import 'package:aimindtree_app/core/note_merge.dart';
import 'package:aimindtree_app/features/notes/markdown_block_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 三个块：标题 / 第一段 / 第二段（块间以空行分隔）。
  const base = '# Title\n\nFirst paragraph.\n\nSecond paragraph.';
  const localEditedFirst = '# Title\n\nFirst paragraph LOCAL.\n\nSecond paragraph.';
  const remoteEditedSecond =
      '# Title\n\nFirst paragraph.\n\nSecond paragraph REMOTE.';
  const remoteEditedFirst =
      '# Title\n\nFirst paragraph REMOTE.\n\nSecond paragraph.';
  const bothEditedFirstLocal =
      '# Title\n\nFirst paragraph LOCAL.\n\nSecond paragraph.';
  const bothEditedFirstRemote =
      '# Title\n\nFirst paragraph REMOTE.\n\nSecond paragraph.';

  test('仅本地改了一段 → 保留本地改动（rs==bs 取 ls）', () {
    final merged = threeWayMergeNotes(base, localEditedFirst, base);
    expect(merged, isNotNull);
    expect(merged, contains('First paragraph LOCAL.'));
    expect(merged, contains('Second paragraph.'));
  });

  test('仅远端改了一段 → 采用远端改动（ls==bs 取 rs）', () {
    final merged = threeWayMergeNotes(base, base, remoteEditedSecond);
    expect(merged, isNotNull);
    expect(merged, contains('Second paragraph REMOTE.'));
    expect(merged, contains('First paragraph.'));
  });

  test('两端改了不同段 → 两段改动合并保留', () {
    final merged = threeWayMergeNotes(base, localEditedFirst, remoteEditedSecond);
    expect(merged, isNotNull);
    expect(merged, contains('First paragraph LOCAL.'));
    expect(merged, contains('Second paragraph REMOTE.'));
  });

  test('两端改了同一段 → 冲突，返回 null', () {
    final merged =
        threeWayMergeNotes(base, bothEditedFirstLocal, bothEditedFirstRemote);
    expect(merged, isNull);
  });

  test('三方完全一致 → 返回任一内容', () {
    final merged = threeWayMergeNotes(base, base, base);
    expect(merged, base);
  });

  test('合并结果满足 L1 字节级恒等（round-trip 无损）', () {
    final merged = threeWayMergeNotes(base, localEditedFirst, remoteEditedSecond);
    expect(merged, isNotNull);
    // 与函数内部同样的守恒校验：合并结果必须能无损重开。
    expect(serializeDoc(parseMarkdownDoc(merged!)), merged);
  });

  group('inlineMergeNotesConflict（内联合并，不另开副本）', () {
    test('输方正文被追加进胜方，并带「同步冲突」标记区块', () {
      final merged =
          inlineMergeNotesConflict('胜方内容', '输方内容', 'dev-B', null);
      expect(merged, isNotNull);
      expect(merged, contains('胜方内容'));
      expect(merged, contains('输方内容'));
      expect(merged, contains('同步冲突'));
      expect(merged, contains('dev-B'));
    });

    test('胜方已含输方内容时返回 null（防重复 pull 反复追加）', () {
      final winner = '胜方内容\n\n---\n\n## 同步冲突\n\n输方内容\n';
      final merged = inlineMergeNotesConflict(winner, '输方内容', 'dev-B', null);
      expect(merged, isNull);
    });

    test('输方为空时返回 null（直接用胜方）', () {
      expect(inlineMergeNotesConflict('胜方内容', '', 'dev-B', null), isNull);
    });

    test('输方仅部分行新增时只追加新增行（防整篇复制回归）', () {
      const winner = '# 卫通\n\n本地改了第一段。';
      const loser = '# 卫通\n\n本地改了第一段。\n\n远端也改了第二段。';
      final merged = inlineMergeNotesConflict(winner, loser, 'dev-B', null)!;
      expect(merged, contains('本地改了第一段。')); // 胜方内容保留
      expect(merged, contains('远端也改了第二段。')); // 输方新增行保留
      // 冲突标记之后不应再出现胜方已存在的标题行（否则等于整篇复制）
      final idx = merged.indexOf('## 同步冲突');
      expect(idx, greaterThanOrEqualTo(0));
      expect(merged.substring(idx), isNot(contains('# 卫通')));
    });
  });

  group('threeWayMergeNotes 段内行级降级', () {
    test('同块但改了不同行 → 行级合并保留双方改动', () {
      const b = '# T\n\nL1\nL2\nL3';
      const l = '# T\n\nL1-local\nL2\nL3';
      const r = '# T\n\nL1\nL2\nL3-remote';
      final merged = threeWayMergeNotes(b, l, r);
      expect(merged, isNotNull);
      expect(merged, contains('L1-local'));
      expect(merged, contains('L3-remote'));
      expect(merged, contains('L2'));
    });

    test('同块同一行两端都改 → 仍视为冲突返回 null', () {
      const b = '# T\n\nL1\nL2';
      const l = '# T\n\nL1-local\nL2';
      const r = '# T\n\nL1-remote\nL2';
      final merged = threeWayMergeNotes(b, l, r);
      expect(merged, isNull);
    });
  });
}
