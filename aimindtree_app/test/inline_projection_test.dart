/// T1 数据层验收测试：行内格式投影（设计 §3.4）。
///
/// 覆盖：`projectRuns` 公共前后缀法、`applyMark`、`normalizeRuns`、`plainTextOf`。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:aimindtree_app/features/notes/inline_projection.dart';

void main() {
  // ---------------------------------------------------------------------
  // projectRuns
  // ---------------------------------------------------------------------
  test('projectRuns：不变量 plainTextOf(result) == newText 恒成立', () {
    const cases = <(String, InlineRuns, String)>[
      ('ab', [TextRun('ab', marks: InlineMarks.bold)], 'abc'),
      ('abc', [TextRun('a'), TextRun('bc', marks: InlineMarks.italic)], 'aXbc'),
      ('abc', [TextRun('abc', marks: InlineMarks.bold)], 'ab'),
      ('', const <InlineNode>[], 'hi'),
      ('你好世界', const [TextRun('你好世界')], '你好新世界'),
      ('list', [TextRun('list', marks: InlineMarks.strike)], 'list!'),
    ];
    for (final (oldText, runs, newText) in cases) {
      final r = projectRuns(oldText, runs, newText);
      expect(plainTextOf(r), newText,
          reason: '不变量失败：old=$oldText new=$newText');
    }
  });

  test('projectRuns：末尾继续输入继承左侧格式', () {
    final r = projectRuns('ab', [TextRun('ab', marks: InlineMarks.bold)], 'abc');
    expect(r, [TextRun('abc', marks: InlineMarks.bold)]);
  });

  test('projectRuns：中间插入继承插入点所在 run 的格式', () {
    final runs = [TextRun('a'), TextRun('bc', marks: InlineMarks.italic)];
    final r = projectRuns('abc', runs, 'aXbc');
    expect(plainTextOf(r), 'aXbc');
    // 插入点 oldText[1] 落在 italic run 内 → 继承 italic
    expect((r.last as TextRun).marks.has(InlineMarks.italic), isTrue);
  });

  test('projectRuns：删除中间字符，首尾格式各自保留', () {
    final runs = [
      TextRun('a', marks: InlineMarks.bold),
      TextRun('MID', marks: InlineMarks.strike),
      TextRun('z', marks: InlineMarks.italic),
    ];
    // old 'aMIDz' → 删掉 'MID' → 'az'
    final r = projectRuns('aMIDz', runs, 'az');
    expect(plainTextOf(r), 'az');
    expect((r[0] as TextRun).marks.has(InlineMarks.bold), isTrue);
    expect((r[1] as TextRun).marks.has(InlineMarks.italic), isTrue);
  });

  test('projectRuns：链接内继续输入保留 href', () {
    final runs = [TextRun('点我', href: 'http://x')];
    final r = projectRuns('点我', runs, '点我啊');
    expect(plainTextOf(r), '点我啊');
    expect((r.single as TextRun).href, 'http://x');
  });

  test('projectRuns：被替换成完全不同的文本，沿用尾部格式兜底', () {
    final runs = [TextRun('old', marks: InlineMarks.bold)];
    final r = projectRuns('old', runs, 'new text');
    expect(plainTextOf(r), 'new text');
    expect((r.single as TextRun).marks.has(InlineMarks.bold), isTrue);
  });

  // ---------------------------------------------------------------------
  // applyMark
  // ---------------------------------------------------------------------
  test('applyMark：区间加粗 / 取消', () {
    final runs = [TextRun('hello world')];
    final bolded =
        applyMark(runs, 0, 5, InlineMarks.bold, on: true);
    expect(plainTextOf(bolded), 'hello world');
    expect((bolded[0] as TextRun).marks.has(InlineMarks.bold), isTrue);
    expect((bolded[1] as TextRun).marks.has(InlineMarks.bold), isFalse);

    final toggled =
        applyMark(bolded, 0, 5, InlineMarks.bold, on: false);
    expect(plainTextOf(toggled), 'hello world');
    expect(toggled, [TextRun('hello world')]); // 取消后归并回单个纯文本 run
  });

  test('applyMark：越界自动 clamp，不抛', () {
    final r = applyMark([TextRun('abc')], -3, 100, InlineMarks.bold, on: true);
    expect(plainTextOf(r), 'abc');
    expect((r.single as TextRun).marks.has(InlineMarks.bold), isTrue);
  });

  test('applyMark：折叠选区（start==end）原样返回', () {
    final runs = [TextRun('abc')];
    final r = applyMark(runs, 2, 2, InlineMarks.bold, on: true);
    expect(r, runs);
  });

  test('applyMark：加 code 时清空其它 mark；代码 run 不被其它 mark 覆盖', () {
    final r1 =
        applyMark([TextRun('abc', marks: InlineMarks.bold)], 0, 3, InlineMarks.code, on: true);
    expect((r1.single as TextRun).marks.has(InlineMarks.code), isTrue);
    expect((r1.single as TextRun).marks.has(InlineMarks.bold), isFalse);

    final r2 =
        applyMark([TextRun('abc', marks: InlineMarks.code)], 0, 3, InlineMarks.bold, on: true);
    expect((r2.single as TextRun).marks.has(InlineMarks.code), isTrue);
    expect((r2.single as TextRun).marks.has(InlineMarks.bold), isFalse);
  });

  // ---------------------------------------------------------------------
  // normalizeRuns / plainTextOf
  // ---------------------------------------------------------------------
  test('normalizeRuns：合并相邻同格式、丢弃空 run', () {
    final runs = [
      TextRun('a'),
      TextRun('b'),
      TextRun('', marks: InlineMarks.bold),
      TextRun('c', marks: InlineMarks.bold),
    ];
    final n = normalizeRuns(runs);
    expect(n, [TextRun('ab'), TextRun('c', marks: InlineMarks.bold)]);
  });

  test('plainTextOf：多 run 拼接', () {
    expect(
      plainTextOf([
        TextRun('a', marks: InlineMarks.bold),
        TextRun('b', href: 'http://x'),
        TextRun('c', marks: InlineMarks.strike),
      ]),
      'abc',
    );
  });
}
