/// 笔记编辑器「所见即所得」改造 —— 行内格式投影（T1 数据层）。
///
/// 设计依据：`docs/NOTE_EDITOR_WYSIWYG_DESIGN.md` §3.4（打字时的格式投影）。
///
/// 本文件只 import `block_model.dart`（纯模型），**不依赖任何 Widget**，可 100% 单测。
/// `plainTextOf` / `normalizeRuns` 定义在 block_model 里（行内片段序列是模型自己的类型），
/// 这里 `export` 出来，按文档从本文件 import 即可拿到全部行内工具。
library;

import 'block_model.dart';

export 'block_model.dart'
    show
        plainTextOf,
        normalizeRuns,
        InlineRuns,
        InlineNode,
        TextRun,
        InlineMarks;

/// 公共 API（冻结给 T2/T3）：
/// - `List<InlineNode> projectRuns(String oldText, InlineRuns oldRuns, String newText)`
/// - `List<InlineNode> applyMark(InlineRuns runs, int start, int end, InlineMarks mark, {required bool on})`
/// - `String plainTextOf(InlineRuns runs)`（来自 block_model）
/// - `InlineRuns normalizeRuns(InlineRuns runs)`（来自 block_model）

/// 旧纯文本 + 旧 run 序列 + 新纯文本 → 新 run 序列（保留未改动区间的格式）。
///
/// 算法（O(n)，每个按键一次，块级文本量足够小，设计 §3.4）：
/// 1. 求 `oldText` / `newText` 的公共前缀 `p`；
/// 2. 在剩余部分求公共后缀 `s`（严格 `<` 剩余长度，确保头/尾切片不重叠）；
/// 3. 头部 `oldText[0, p)` 的 runs 原样保留（可能裁剪最后一截）；
/// 4. 尾部 `oldText[oldLen-s, oldLen)` 的 runs 原样保留；
/// 5. 中间新增部分继承「插入点所在 run」的 marks + href（编辑器标准行为）；
/// 6. `normalizeRuns()`：合并相邻同属性 run、丢弃空 run。
///
/// 重要不变量：`plainTextOf(projectRuns(old, runs, new)) == newText` 一定成立
/// （头 p 字 + 中间 + 尾 s 字 ≡ 全文），T3 的 `buildTextSpan` 可据此做长度钳制。
List<InlineNode> projectRuns(String oldText, InlineRuns oldRuns, String newText) {
  final oldLen = plainTextOf(oldRuns).length;

  // 1. 公共前缀
  var p = 0;
  final minLen = oldText.length < newText.length ? oldText.length : newText.length;
  while (p < minLen && oldText.codeUnitAt(p) == newText.codeUnitAt(p)) p++;

  // 2. 公共后缀（在 prefix 之后的剩余部分里，严格 < 剩余长度 → 头尾不重叠）
  var s = 0;
  while (s < oldText.length - p &&
      s < newText.length - p &&
      oldText.codeUnitAt(oldText.length - 1 - s) ==
          newText.codeUnitAt(newText.length - 1 - s)) {
    s++;
  }

  final head = _sliceRuns(oldRuns, 0, p, oldLen);
  final tail = _sliceRuns(oldRuns, oldLen - s, oldLen, oldLen);
  final middle = newText.substring(p, newText.length - s);
  final (m, h) = _marksAt(oldRuns, p, oldLen);
  final mid = middle.isEmpty
      ? <InlineNode>[]
      : <InlineNode>[TextRun(middle, marks: m, href: h)];

  return normalizeRuns(<InlineNode>[...head, ...mid, ...tail]);
}

/// 给 `[start, end)` 区间加/取消某个 mark（工具栏入口）。
///
/// 越界自动 clamp；`start == end`（折叠选区）时原样返回（加粗折叠选区交给 pendingMarks）。
/// 行内代码 run 不会被其它 mark 覆盖（R5）；给非代码 run 加「代码」会把它整体换成 code。
List<InlineNode> applyMark(
  InlineRuns runs,
  int start,
  int end,
  InlineMarks mark, {
  required bool on,
}) {
  final total = plainTextOf(runs).length;
  final a = (start.clamp(0, total));
  final b = (end.clamp(0, total));
  final lo = a < b ? a : b;
  final hi = a < b ? b : a;
  if (hi <= lo) return normalizeRuns(runs);

  final before = _sliceRuns(runs, 0, lo, total);
  final middle = _sliceRuns(runs, lo, hi, total);
  final after = _sliceRuns(runs, hi, total, total);

  final toggled = <InlineNode>[
    for (final node in middle)
      if (node is TextRun) _applyOne(node, mark, on) else node,
  ];
  return normalizeRuns(<InlineNode>[...before, ...toggled, ...after]);
}

// ---------------------------------------------------------------------------
// 私有
// ---------------------------------------------------------------------------

/// 取 oldText 字符坐标 [from, to) 对应的 run 片段（自动 clamp 到 [0, total]）。
List<InlineNode> _sliceRuns(InlineRuns runs, int from, int to, int total) {
  from = from.clamp(0, total);
  to = to.clamp(0, total);
  if (from >= to) return <InlineNode>[];
  final out = <InlineNode>[];
  var pos = 0;
  for (final node in runs) {
    if (node is! TextRun) continue;
    final start = pos;
    final end = pos + node.text.length;
    pos = end;
    if (end <= from) continue;
    if (start >= to) break;
    final s = start < from ? from - start : 0;
    final e = end > to ? to - start : node.text.length;
    out.add(TextRun(
      node.text.substring(s, e),
      marks: node.marks,
      href: node.href,
    ));
  }
  return out;
}

/// 取 oldText 坐标 [pos] 处的 run 的 marks + href（pos == total 时取最后一个 run）。
(InlineMarks, String?) _marksAt(InlineRuns runs, int pos, int total) {
  if (runs.isEmpty) return (InlineMarks.none, null);
  if (pos >= total) {
    final last = runs.last;
    return last is TextRun ? (last.marks, last.href) : (InlineMarks.none, null);
  }
  var p = 0;
  for (final node in runs) {
    if (node is! TextRun) continue;
    if (p <= pos && pos < p + node.text.length) {
      return (node.marks, node.href);
    }
    p += node.text.length;
  }
  final last = runs.last;
  return last is TextRun ? (last.marks, last.href) : (InlineMarks.none, null);
}

InlineNode _applyOne(TextRun r, InlineMarks mark, bool on) {
  InlineMarks m;
  if (on) {
    if (mark.has(InlineMarks.code)) {
      // 代码不与其他 mark 叠加（R5），加代码直接整体置 code。
      m = InlineMarks.code;
    } else if (r.marks.has(InlineMarks.code)) {
      // 代码 run 不被其它 mark 覆盖。
      m = r.marks;
    } else {
      m = r.marks | mark;
    }
  } else {
    m = r.marks - mark;
  }
  return TextRun(r.text, marks: m, href: r.href);
}
