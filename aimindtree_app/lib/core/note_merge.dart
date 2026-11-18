/// 笔记正文的三方合并（段级），供 [SyncEngine] 的 P2 块级同步使用。
///
/// 受控反向依赖：本文件位于 `lib/core/`，但引用了 `lib/features/notes` 的块级
/// 解析器（[parseMarkdownDoc] / [serializeDoc]）。这是 P2 路径 C 唯一允许的
/// 一处反向依赖（研究结论：在 `lib/core/` 放最小切分器，避免 data 层直接 import
/// features 层，从而不破坏 L1 红线、不动编辑器）。其它同步代码仍走常规分层。
library;

import '../features/notes/markdown_block_parser.dart';

/// 把 base / local / remote 三份 Markdown 做**段级三方合并**。
///
/// 返回合并后的 Markdown；若无法干净合并（base / local / remote 在同一段都改了，
/// 即「两边都动了同一段」）返回 null，由调用方升级为冲突副本。
///
/// 不变量（L1）：返回的字符串满足 `serializeDoc(parseMarkdownDoc(x)) == x`，
/// 否则视为合并不安全、返回 null——绝不让同步写出「打开后内容对不上的正文」。
String? threeWayMergeNotes(String base, String local, String remote) {
  final bDoc = parseMarkdownDoc(base);
  final lDoc = parseMarkdownDoc(local);
  final rDoc = parseMarkdownDoc(remote);

  final bp = bDoc.blocks;
  final lp = lDoc.blocks;
  final rp = rDoc.blocks;

  final n = <int>[bp.length, lp.length, rp.length].reduce((a, b) => a > b ? a : b);
  final chosen = <String>[];
  final gaps = <String>[];
  var conflict = false;

  for (var i = 0; i < n; i++) {
    final bs = i < bp.length ? (bp[i].source ?? '') : '';
    final ls = i < lp.length ? (lp[i].source ?? '') : '';
    final rs = i < rp.length ? (rp[i].source ?? '') : '';

    // 选每块时，同时记录该块取自哪一侧，段后分隔沿用「被采用那一侧」的
    // trailingGap，避免本地/远端对段落间距的编辑在合并时被基线覆盖。
    String pick;
    String gap;
    if (ls == rs) {
      pick = ls; // 两边相同：任取
      gap = i < lp.length ? lp[i].trailingGap : (i < bp.length ? bp[i].trailingGap : '\n\n');
    } else if (ls == bs) {
      pick = rs; // 本地没动这块，采用远端
      gap = i < rp.length ? rp[i].trailingGap : (i < bp.length ? bp[i].trailingGap : '\n\n');
    } else if (rs == bs) {
      pick = ls; // 远端没动这块，采用本地
      gap = i < lp.length ? lp[i].trailingGap : (i < bp.length ? bp[i].trailingGap : '\n\n');
    } else {
      // 两边都动了同一块：先尝试段内「行级」三方合并——若两端改的是块内不同行
      // （典型：本地/远端各在段落里改了不同的一行），仍可合并留住双方改动，
      // 避免一有同块改动就整篇回退。仅当**同一行**两端都改且不一致时，才视为
      // 真冲突，留本地并升级为整篇内联合并。
      final lineMerged = _mergeBlockLines(bs, ls, rs);
      if (lineMerged != null) {
        pick = lineMerged;
        gap = i < lp.length ? lp[i].trailingGap : (i < bp.length ? bp[i].trailingGap : '\n\n');
      } else {
        pick = ls;
        gap = i < lp.length ? lp[i].trailingGap : (i < bp.length ? bp[i].trailingGap : '\n\n');
        conflict = true;
      }
    }
    chosen.add(pick);
    gaps.add(gap);
  }

  if (conflict) return null;

  // 文档级 prologue（正文前的引导文字）：优先采用「相对基线改过」的一侧，
  // 避免某一端对引言的编辑在合并时被基线的旧 prologue 覆盖。
  final prologue = lDoc.prologue != bDoc.prologue
      ? lDoc.prologue
      : (rDoc.prologue != bDoc.prologue ? rDoc.prologue : bDoc.prologue);
  final sb = StringBuffer(prologue);
  for (var i = 0; i < n; i++) {
    sb.write(chosen[i]);
    sb.write(gaps[i]);
  }
  final merged = sb.toString();

  // L1 安全校验：合并结果必须能无损重开，否则认为不安全。
  if (serializeDoc(parseMarkdownDoc(merged)) != merged) return null;
  return merged;
}

/// 段内行级三方合并：把 base / local / remote 三份**块文本**按行做三方合并。
///
/// 用于 [threeWayMergeNotes] 在同「块」冲突时降级——若两端改的是块内**不同行**
/// （典型：本地与远端各在段落里改了不同的一行），仍可合并留住双方改动；
/// 仅当**同一行**两端都改且不一致时才返回 null（真冲突），交由上层整篇内联。
String? _mergeBlockLines(String base, String local, String remote) {
  final bl = base.split('\n');
  final ll = local.split('\n');
  final rl = remote.split('\n');
  final n = [bl.length, ll.length, rl.length].reduce((a, b) => a > b ? a : b);
  final out = <String>[];
  for (var i = 0; i < n; i++) {
    final b = i < bl.length ? bl[i] : '';
    final l = i < ll.length ? ll[i] : '';
    final r = i < rl.length ? rl[i] : '';
    if (l == r) {
      out.add(l);
    } else if (l == b) {
      out.add(r);
    } else if (r == b) {
      out.add(l);
    } else {
      // 同一行两端都改了且不一致 → 真冲突。
      return null;
    }
  }
  return out.join('\n');
}

/// 把「输方」中、胜方**没有**的行作为标记段落追加进「胜方」正文，得到**单篇**
/// 合并笔记（P0 内联合并）。
///
/// 与另开冲突副本不同：这里直接在胜方笔记里追加一段明确标注的「同步冲突」区块，
/// 把输方相对胜方**新增/不同的行**一并保留，笔记数量不膨胀。
///
/// 细粒度：只追加「输方有、胜方没有」的行，而不是把整篇输方复制一遍（这正是旧版
/// 「整个笔记被重复复制」的根因，见同步排障记录）。返回合并后的 Markdown；以下
/// 情况返回 null（表示「直接用胜方即可」，调用方回落为仅保留胜方）：
/// - 输方为空；
/// - 输方相对胜方无新增行（重复 pull / 对端已拉回，避免无限增长）；
/// - 合并结果未过 L1 字节校验（护栏，理论上不会触发）。
String? inlineMergeNotesConflict(
  String winner,
  String loser,
  String? loserDevice,
  DateTime? loserTime,
) {
  final loserTrim = loser.trim();
  if (loserTrim.isEmpty) return null;

  // 细粒度：仅保留「输方有、胜方没有」的行，避免整篇输方被重复追加。
  final winnerLines = winner
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toSet();
  final missing = <String>[];
  for (final line in loser.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue; // 跳过空白行
    if (!winnerLines.contains(t)) missing.add(line);
  }
  if (missing.isEmpty) return null; // 输方相对胜方无新增 → 不追加（防重复 pull）

  final ts = _conflictTs(loserTime ?? DateTime.now());
  final dev = (loserDevice != null && loserDevice.isNotEmpty)
      ? loserDevice
      : '未知设备';
  // 注意：冲突区块结尾不加独立换行，保证结果满足 L1 字节级恒等（round-trip 无损）。
  final section = '\n\n---\n\n'
      '## 同步冲突（已合并保留 · 来自 $dev · $ts）\n\n'
      '${missing.join('\n')}';
  final merged = '$winner$section';
  // L1 护栏：合并结果必须能无损重开，否则退化为仅保留胜方，避免正文损坏。
  if (serializeDoc(parseMarkdownDoc(merged)) != merged) return null;
  return merged;
}

/// 冲突区块时间戳（本地可读，形如 `2026-11-16 14:30`）。
String _conflictTs(DateTime t) =>
    '${t.year}-${_p2(t.month)}-${_p2(t.day)} ${_p2(t.hour)}:${_p2(t.minute)}';

String _p2(int n) => n.toString().padLeft(2, '0');
