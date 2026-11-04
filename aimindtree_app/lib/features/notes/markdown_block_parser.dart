/// 笔记编辑器「所见即所得」改造 —— Markdown 与块模型的**双向**解析/序列化（T1 数据层）。
///
/// 设计依据：`docs/NOTE_EDITOR_WYSIWYG_DESIGN.md` §3（序列化规则）、§4（无损红线与降级）。
///
/// **公共 API（冻结给 T2/T3 直接调用）**
/// - `NoteDoc parseMarkdownDoc(String md)`
/// - `String serializeDoc(NoteDoc doc)`
/// - `InlineRuns parseInline(String src)`
/// - `String serializeInline(InlineRuns runs)`
/// - `String escapeLineStart(String line)`
///
/// **三条红线（务必理解后再改）**
/// 1. L1 原文直通：块未被编辑（[Block.source] != null）时，`serializeDoc` 直接吐回 source，
///    于是 `serializeDoc(parseMarkdownDoc(md)) == md`（先 `\r\n→\n` 归一化）字节级相等。
///    每个块的 source 与块间 `trailingGap` 合起来精确重建原文。
/// 2. L2 规范化序列化：被编辑过的块走 `serialize*` 的规范化分支，结果幂等。
/// 3. L3 原文兜底：某段解析抛异常 → 该段整体装进 [RawBlock]，一个字符都不丢。
///
/// **完备性 8 条（设计 §4.2）对应实现位置**
/// - P1 逐行游标必须推进：`_scanBlock` 每个分支都推进 `next`；主循环另有 `if (next <= i) next = i+1` 兜底。
/// - P2 不 trimRight：段落 source 取原始行，绝不丢行尾空格（L1 已天然保真）。
/// - P3 段落懒续行：`_scanBlock` 段落分支碰到「非空白且非块起始」的行并入同一段。
/// - P4 列表续行：`_kUlItem`/`_kOlItem` 分支里把续行剥掉缩进后并入上一个 item。
/// - P5 未闭合围栏：到 EOF 没有收尾 ```` ``` ```` → 判为一个 CodeBlock，内容一字不少；规范化时补收尾围栏。
/// - P6 含图段落切开：段落里出现 `![…](aimindtree-asset://id)` → 切成 P / Image / P。
/// - P7 per-chunk try/catch：主循环 `try _scanBlock catch` → 该段原文进 RawBlock。
/// - P8 表格只在「当前行以 `|` 开头且下一行是合法分隔行」时触发，否则当段落（含转义，见 R8）。
///
/// 本文件**不 import flutter**，可 100% 纯 Dart 单测。
library;

import 'block_model.dart';

// ---------------------------------------------------------------------------
// 正则（纯 Dart，无需 flutter）
// ---------------------------------------------------------------------------

/// 开围栏 ``` 或 ```` ```lang ````（对原始行先 trim 再匹配）。
final _kFence = RegExp(r'^```([^\s`]*)');

/// 分割线 `---` / `***` / `___`（3 个及以上同字符，需整行）。
final _kDivider = RegExp(r'^(-{3,}|\*{3,}|_{3,})$');

/// 标题 `#{1,6}`，其后必须至少一个空白或行尾（排除以 `#话题` 误判；`#`/`##` 开头且无内容也判标题）。
final _kHeading = RegExp(r'^(#{1,6})(?:\s+(.*))?$');

/// 引用 `> `（允许 `> >` 嵌套写法被压平成多段正文），允许空内容（`>` 单独一行即空引用行）。
final _kQuote = RegExp(r'^(?:>\s?)+(.*)$');

/// 任务列表项 `- [ ] ` / `- [x] `（**必须排在 `_kUlItem` 之前判断**，否则 `[-*+]\s+` 会先把 `- ` 吃掉）。
final _kTaskItem = RegExp(r'^[-*+]\s+\[([ xX])\]\s+(.*)$');

/// 有序列表项 `n. `。
final _kOlItem = RegExp(r'^(\d+)\.\s+(.*)$');

/// 无序列表项 `- ` / `* ` / `+ `。
final _kUlItem = RegExp(r'^[-*+]\s+(.*)$');

/// 表格分隔单元格（`:---` / `:---:` / `---:` / `---`）。
final _kTableDivider = RegExp(r'^\s*:?-{2,}:?\s*$');

/// 行内图片（**只认 `aimindtree-asset://` 协议**，其它 URL 按普通文本处理，见设计 §6.6）。
final _kImage = RegExp(r'!\[([^\]]*)\]\((aimindtree-asset://[^)\s]+)\)');

/// 行首缩进（列表续行剥掉它，序列化时再统一补两空格 → 幂等）。
final _kLeadingSpace = RegExp(r'^[ \t]+');

/// 「非换行字符」——判某个间隔是不是**纯换行**（纯换行才允许拆成空段落块，
/// 带空格 / 制表符的空白行必须原样保留，否则 L1 字节直通就破了）。
final _kNonNewline = RegExp(r'[^\n]');

/// 可被反斜杠转义的行内字符。
final _kEscapable = RegExp(r'^[\\`*_{}\[\]()#+\-.!~|]');

// ---------------------------------------------------------------------------
// 公共 API
// ---------------------------------------------------------------------------

/// 把 Markdown 字符串解析成 [NoteDoc]。
NoteDoc parseMarkdownDoc(String md) {
  final normalized = md.replaceAll('\r\n', '\n');
  if (normalized.isEmpty) return NoteDoc.empty();

  final lines = normalized.split('\n');
  final blocks = <Block>[];

  // 正文开头的纯空白行 → prologue（保证整篇 byte-exact 还原）。
  var i = 0;
  while (i < lines.length && _isBlank(lines[i])) i++;
  final prologue = _joinLines(lines, 0, i);

  while (i < lines.length) {
    if (_isBlank(lines[i])) {
      i++;
      continue;
    }
    List<Block> produced;
    int next;
    try {
      final r = _scanBlock(lines, i);
      produced = r.blocks;
      next = r.next;
    } catch (_) {
      // L3：任何解析异常都不崩、不丢字符 → 原文进 RawBlock。
      produced = <Block>[RawBlock(id: newBlockId('raw'), text: lines[i])];
      next = i + 1;
    }
    if (next <= i) next = i + 1; // P1 兜底：游标必须推进，杜绝死循环 + 丢字符
    blocks.addAll(produced);
    i = next;
  }

  if (blocks.isEmpty) {
    // 整篇都是空行：用空段落兜底，原文空白已由 prologue 承载。
    return NoteDoc(blocks: <Block>[ParagraphBlock.empty()], prologue: prologue);
  }
  return NoteDoc(blocks: _expandBlankGaps(blocks), prologue: prologue);
}

/// 把「连续空行」里**多出来的空行**还原成真实的空段落块（每个空行一个块）。
///
/// 主循环遇空行只会 `i++` 跳过，间隔由 `_gapBetween` 全部塞进**前一块**的
/// `trailingGap`。于是用户在编辑器里连按回车敲出来的空行，保存后重开时会被
/// 静默吃掉（渲染只看块，`trailingGap` 不占视觉高度）：表现为「空了一屏，存完
/// 只剩一两行，而且点不动」。这里把多余空行各自变成一个空段落块 ——
///
/// - 第一行空白继续留给前一块的 `trailingGap`（承担段落分隔，视觉与以前一致）；
/// - 其余每个空行一个 `ParagraphBlock`，间隔 `'\n'`（它自己就是那个空行）。
///
/// 序列化回去的总换行数不变（2 + (n-2) = n），所以 **L1 逐字节还原仍然成立**；
/// 但空行成了真实块：可点、可编辑、能存住、能被复制带换行。
///
/// 只处理「纯换行」的间隔（空白行里带空格/制表符的原样保留）—— 不该顺手改字节。
List<Block> _expandBlankGaps(List<Block> blocks) {
  var touched = false;
  final out = <Block>[];
  for (final b in blocks) {
    final gap = b.trailingGap;
    final pureNewlines = gap.isNotEmpty && !gap.contains(_kNonNewline);
    if (!pureNewlines || gap.length <= 2) {
      out.add(b);
      continue;
    }
    touched = true;
    out.add(_withGap(b, '\n\n'));
    for (var k = 2; k < gap.length; k++) {
      out.add(ParagraphBlock(
        id: newBlockId('p'),
        trailingGap: '\n',
        runs: const <InlineNode>[],
      ));
    }
  }
  return touched ? out : blocks;
}

/// 「换个隔行间隔」的块重建（[Block] 没有 copyWith，这里集中一处；`source` 原样
/// 带走 → 未编辑块继续走 L1 字节直通）。
Block _withGap(Block b, String gap) {
  switch (b) {
    case ParagraphBlock(:final runs):
      return ParagraphBlock(
        id: b.id,
        source: b.source,
        trailingGap: gap,
        runs: runs,
      );
    case HeadingBlock(:final level, :final runs):
      return HeadingBlock(
        id: b.id,
        source: b.source,
        trailingGap: gap,
        level: level,
        runs: runs,
      );
    case QuoteBlock(:final lines):
      return QuoteBlock(
        id: b.id,
        source: b.source,
        trailingGap: gap,
        lines: lines,
      );
    case BulletListBlock(:final items):
      return BulletListBlock(
        id: b.id,
        source: b.source,
        trailingGap: gap,
        items: items,
      );
    case OrderedListBlock(:final start, :final items):
      return OrderedListBlock(
        id: b.id,
        source: b.source,
        trailingGap: gap,
        start: start,
        items: items,
      );
    case TaskListBlock(:final items):
      return TaskListBlock(
        id: b.id,
        source: b.source,
        trailingGap: gap,
        items: items,
      );
    case CodeBlock(:final language, :final code):
      return CodeBlock(
        id: b.id,
        source: b.source,
        trailingGap: gap,
        language: language,
        code: code,
      );
    case TableBlock(:final hasHeader, :final aligns, :final rows):
      return TableBlock(
        id: b.id,
        source: b.source,
        trailingGap: gap,
        hasHeader: hasHeader,
        aligns: aligns,
        rows: rows,
      );
    case DividerBlock():
      return DividerBlock(id: b.id, source: b.source, trailingGap: gap);
    case ImageBlock(:final assetId, :final alt):
      return ImageBlock(
        id: b.id,
        source: b.source,
        trailingGap: gap,
        assetId: assetId,
        alt: alt,
      );
    case RawBlock(:final text):
      return RawBlock(
        id: b.id,
        source: b.source,
        trailingGap: gap,
        text: text,
      );
  }
}

/// 把 [NoteDoc] 序列化成 Markdown 字符串（纯文本，硬约束，见设计 §1.3）。
String serializeDoc(NoteDoc doc) {
  // R1：空文档 / 仅含一个空段落 → 也序列化成 ''（不落垃圾空行）。
  if (doc.blocks.length == 1) {
    final only = doc.blocks.single;
    if (only is ParagraphBlock && only.source == null && plainTextOf(only.runs).isEmpty) {
      return doc.prologue;
    }
  }

  final sb = StringBuffer(doc.prologue);
  for (final b in doc.blocks) {
    sb.write(_serializeBlock(b)); // L1：source 非空时直接吐回 source
    sb.write(b.trailingGap);
  }
  return sb.toString();
}

/// 把一行 / 一个单元格 / 一个列表项的正文解析成行内片段序列。
InlineRuns parseInline(String src) {
  final out = <InlineNode>[];
  _scanInline(src, InlineMarks.none, null, out);
  // 兜底归并（理论上 _pushText 已合并，这里再保险一次）。
  return normalizeRuns(out);
}

/// 行内片段序列 → Markdown 字符串（R5 优先级、R8 转义）。
String serializeInline(InlineRuns runs) {
  final sb = StringBuffer();
  for (final node in normalizeRuns(runs)) {
    if (node is! TextRun) continue;
    sb.write(_serializeRun(node));
  }
  return sb.toString();
}

String _serializeRun(TextRun r) {
  // 行内代码优先级最高，且不与其他 mark 叠加（R5）。
  if (r.marks.has(InlineMarks.code)) return _wrapCode(r.text);

  // 链接：整段包在 [..](url) 里，不做首尾空白外移（链接结尾通常是词，不触发标记粘连）。
  if (r.href != null) {
    var mid = _escapeText(r.text);
    if (r.marks.has(InlineMarks.strike)) mid = '~~$mid~~';
    if (r.marks.has(InlineMarks.bold) && r.marks.has(InlineMarks.italic)) {
      mid = '***$mid***';
    } else if (r.marks.has(InlineMarks.bold)) {
      mid = '**$mid**';
    } else if (r.marks.has(InlineMarks.italic)) {
      mid = '*$mid*';
    }
    return '[$mid](${r.href})';
  }

  // 强调：把首尾空白移到标记外，避免 `**a**` 与 `*b*` 粘连成 `****ab****`
  // 这种无法回解的歧义（Markdown 强调解析的固有限制，T1 不建模多层嵌套）。
  final text = r.text;
  var ls = 0;
  while (ls < text.length && _isWs(text.codeUnitAt(ls))) ls++;
  var re = text.length;
  while (re > ls && _isWs(text.codeUnitAt(re - 1))) re--;
  final lead = _escapeText(text.substring(0, ls));
  final trail = _escapeText(text.substring(re));
  var mid = _escapeText(text.substring(ls, re));
  if (r.marks.has(InlineMarks.strike)) mid = '~~$mid~~';
  if (r.marks.has(InlineMarks.bold) && r.marks.has(InlineMarks.italic)) {
    mid = '***$mid***';
  } else if (r.marks.has(InlineMarks.bold)) {
    mid = '**$mid**';
  } else if (r.marks.has(InlineMarks.italic)) {
    mid = '*$mid*';
  }
  return '$lead$mid$trail';
}

bool _isWs(int c) => c == 0x20 || c == 0x09;

/// 只在「不转义就会被重新解析成别的块」时，在行首标记符前插 `\`（设计 §3.3 R8）。
///
/// 只对**被编辑过**的块生效（规范化序列化分支才调用），未编辑块走 source 直通不受影响。
String escapeLineStart(String line) {
  final m = RegExp(
    r'^([ \t]*)([-*+](?=\s)|#{1,6}(?=\s)|#{1,6}$|\d+\.(?=\s)|>(?=\s)|\|)',
  ).firstMatch(line);
  if (m == null) return line;
  final indentLen = m.group(1)!.length;
  return '${line.substring(0, indentLen)}\\${line.substring(indentLen)}';
}

// ---------------------------------------------------------------------------
// 块扫描
// ---------------------------------------------------------------------------

class _Scan {
  const _Scan(this.blocks, this.next);
  final List<Block> blocks;
  final int next;
}

/// 从 [lines] 的第 [idx] 行开始，扫描出一个块组（可能是一个块，也可能是图片切开后的多块）。
_Scan _scanBlock(List<String> lines, int idx) {
  final raw = lines[idx];
  final t = raw.trim();

  // 1. 围栏代码块（P5：未闭合 → 到 EOF）。
  if (t.startsWith('```')) {
    final lang = _kFence.firstMatch(t)?.group(1) ?? '';
    var j = idx + 1;
    while (j < lines.length && !lines[j].trim().startsWith('```')) j++;
    final closed = j < lines.length;
    final code = lines.sublist(idx + 1, j).join('\n');
    final stop = closed ? j + 1 : j;
    final next = _skipBlanks(lines, stop);
    return _Scan(
      <Block>[
        CodeBlock(
          id: newBlockId('c'),
          source: lines.sublist(idx, stop).join('\n'),
          trailingGap: _gapBetween(lines, stop, next),
          language: lang,
          code: code,
        ),
      ],
      next,
    );
  }

  // 2. 分割线。
  if (_kDivider.hasMatch(t)) {
    final stop = idx + 1;
    final next = _skipBlanks(lines, stop);
    return _Scan(
      <Block>[
        DividerBlock(
          id: newBlockId('hr'),
          source: raw,
          trailingGap: _gapBetween(lines, stop, next),
        ),
      ],
      next,
    );
  }

  // 3. 标题。
  final h = _kHeading.firstMatch(t);
  if (h != null) {
    final level = h.group(1)!.length;
    final text = h.group(2) ?? '';
    final stop = idx + 1;
    final next = _skipBlanks(lines, stop);
    return _Scan(
      <Block>[
        HeadingBlock(
          id: newBlockId('h'),
          source: raw,
          trailingGap: _gapBetween(lines, stop, next),
          level: level,
          runs: parseInline(text),
        ),
      ],
      next,
    );
  }

  // 4. 表格（P8）。
  if (t.startsWith('|') && idx + 1 < lines.length && _isTableDivider(lines[idx + 1])) {
    final header = _splitRow(lines[idx].trim());
    final aligns = _alignsOf(lines[idx + 1].trim());
    var j = idx + 2;
    while (j < lines.length && lines[j].trim().startsWith('|')) j++;
    final rows = <List<InlineRuns>>[];
    rows.add(<InlineRuns>[for (final c in header) parseInline(c)]);
    for (var k = idx + 2; k < j; k++) {
      rows.add(<InlineRuns>[for (final c in _splitRow(lines[k].trim())) parseInline(c)]);
    }
    final stop = j;
    final next = _skipBlanks(lines, stop);
    return _Scan(
      <Block>[
        TableBlock(
          id: newBlockId('tb'),
          source: lines.sublist(idx, stop).join('\n'),
          trailingGap: _gapBetween(lines, stop, next),
          aligns: aligns,
          rows: rows,
        ),
      ],
      next,
    );
  }

  // 5. 引用（连续 `>` 行合并成一块）。
  if (_kQuote.hasMatch(t)) {
    final out = <InlineRuns>[];
    var j = idx;
    while (j < lines.length) {
      final m = _kQuote.firstMatch(lines[j].trim());
      if (m == null) break;
      out.add(parseInline(m.group(1) ?? ''));
      j++;
    }
    final stop = j;
    final next = _skipBlanks(lines, stop);
    return _Scan(
      <Block>[
        QuoteBlock(
          id: newBlockId('q'),
          source: lines.sublist(idx, stop).join('\n'),
          trailingGap: _gapBetween(lines, stop, next),
          lines: out,
        ),
      ],
      next,
    );
  }

  // 6. 任务列表（必须排在 `--`/有序**之前**）。
  if (_kTaskItem.hasMatch(t)) {
    final items = <TaskItem>[];
    var j = idx;
    while (j < lines.length) {
      final tm = _kTaskItem.firstMatch(lines[j].trim());
      if (tm == null) break;
      items.add(TaskItem(
        id: newBlockId('ti'),
        runs: parseInline(tm.group(2)!),
        checked: tm.group(1) != ' ',
      ));
      j++;
    }
    final stop = j;
    final next = _skipBlanks(lines, stop);
    return _Scan(
      <Block>[
        TaskListBlock(
          id: newBlockId('tl'),
          source: lines.sublist(idx, stop).join('\n'),
          trailingGap: _gapBetween(lines, stop, next),
          items: items,
        ),
      ],
      next,
    );
  }

  // 7. 有序列表。
  if (_kOlItem.hasMatch(t)) {
    final startNum = int.tryParse(_kOlItem.firstMatch(t)!.group(1)!) ?? 1;
    final items = <ListItem>[];
    var j = idx;
    while (j < lines.length) {
      if (_isBlank(lines[j])) break;
      final om = _kOlItem.firstMatch(lines[j].trim());
      if (om != null) {
        items.add(ListItem(id: newBlockId('li'), runs: parseInline(om.group(2)!)));
        j++;
        continue;
      }
      if (j == idx) break;
      if (_startsBlock(lines[j])) break;
      final cont = lines[j].replaceFirst(_kLeadingSpace, '');
      _appendContinuation(items, parseInline(cont));
      j++;
    }
    final stop = j;
    final next = _skipBlanks(lines, stop);
    return _Scan(
      <Block>[
        OrderedListBlock(
          id: newBlockId('ol'),
          source: lines.sublist(idx, stop).join('\n'),
          trailingGap: _gapBetween(lines, stop, next),
          start: startNum,
          items: items,
        ),
      ],
      next,
    );
  }

  // 8. 无序列表（遇到任务项则断开，交给上一分支另起一块）。
  if (_kUlItem.hasMatch(t)) {
    final items = <ListItem>[];
    var j = idx;
    while (j < lines.length) {
      if (_isBlank(lines[j])) break;
      final um = _kUlItem.firstMatch(lines[j].trim());
      if (um != null) {
        if (_kTaskItem.hasMatch(lines[j].trim())) break;
        items.add(ListItem(id: newBlockId('li'), runs: parseInline(um.group(1)!)));
        j++;
        continue;
      }
      if (j == idx) break;
      if (_startsBlock(lines[j])) break;
      final cont = lines[j].replaceFirst(_kLeadingSpace, '');
      _appendContinuation(items, parseInline(cont));
      j++;
    }
    final stop = j;
    final next = _skipBlanks(lines, stop);
    return _Scan(
      <Block>[
        BulletListBlock(
          id: newBlockId('ul'),
          source: lines.sublist(idx, stop).join('\n'),
          trailingGap: _gapBetween(lines, stop, next),
          items: items,
        ),
      ],
      next,
    );
  }

  // 9. 段落（P3 懒续行；P6 含图切开）。
  final buf = <String>[];
  var j = idx;
  buf.add(lines[j]);
  j++;
  while (j < lines.length && !_isBlank(lines[j]) && !_startsBlock(lines[j])) {
    buf.add(lines[j]);
    j++;
  }
  final rawText = buf.join('\n');
  final stop = j;
  final next = _skipBlanks(lines, stop);
  return _Scan(_splitParagraph(rawText, _gapBetween(lines, stop, next)), next);
}

/// 把续行文本并入最后一个列表 item（行内加一个软换行，剥掉的缩进由序列化时统一补两空格）。
void _appendContinuation(List<ListItem> items, InlineRuns cont) {
  if (items.isEmpty) return;
  final last = items.removeLast();
  items.add(last.copyWith(
    runs: <InlineNode>[...last.runs, const TextRun('\n'), ...cont],
  ));
}

/// 含图段落切开：返回 P / Image / P 序列，最后一块带上 gap，其余 gap 为 ''。
List<Block> _splitParagraph(String raw, String gap) {
  final matches = _kImage.allMatches(raw).toList();
  if (matches.isEmpty) {
    return <Block>[
      ParagraphBlock(
        id: newBlockId('p'),
        source: raw,
        trailingGap: gap,
        runs: parseInline(raw),
      ),
    ];
  }

  final segs = <_Seg>[];
  var cursor = 0;
  for (final m in matches) {
    if (m.start > cursor) {
      segs.add(_Seg(false, raw.substring(cursor, m.start), null, ''));
    }
    final url = m.group(2)!;
    final assetId = url.startsWith(kAssetUrlPrefix)
        ? url.substring(kAssetUrlPrefix.length)
        : url;
    segs.add(_Seg(true, m.group(0)!, assetId, m.group(1)!));
    cursor = m.end;
  }
  if (cursor < raw.length) {
    segs.add(_Seg(false, raw.substring(cursor), null, ''));
  }

  final blocks = <Block>[];
  for (var k = 0; k < segs.length; k++) {
    final s = segs[k];
    final g = k == segs.length - 1 ? gap : '';
    if (s.isImage) {
      blocks.add(ImageBlock(
        id: newBlockId('img'),
        source: s.src,
        trailingGap: g,
        assetId: s.assetId!,
        alt: s.alt,
      ));
    } else {
      if (s.src.isEmpty) continue; // 空文本段不产块（与原文逐字节等价，空段不含字符）
      blocks.add(ParagraphBlock(
        id: newBlockId('p'),
        source: s.src,
        trailingGap: g,
        runs: parseInline(s.src.trim()),
      ));
    }
  }
  return blocks;
}

class _Seg {
  const _Seg(this.isImage, this.src, this.assetId, this.alt);
  final bool isImage;
  final String src;
  final String? assetId;
  final String alt;
}

// ---------------------------------------------------------------------------
// 序列化：逐块
// ---------------------------------------------------------------------------

String _serializeBlock(Block b) {
  if (b.source != null) return b.source!; // L1：未编辑块原文直通

  return switch (b) {
    ParagraphBlock(:final runs) =>
      // 行首可能以块起始符开头 → 转义，保证再解析仍是段落。
      serializeInline(runs).split('\n').map(escapeLineStart).join('\n'),
    HeadingBlock(:final level, :final runs) =>
      '${'#' * level} ${serializeInline(runs)}',
    QuoteBlock(:final lines) =>
      lines.map((l) => '> ${serializeInline(l)}').join('\n'),
    BulletListBlock(:final items) => items.map(_serializeBulletItem).join('\n'),
    OrderedListBlock(:final start, :final items) => [
      for (var i = 0; i < items.length; i++) _serializeOrderedItem(items[i], start + i)
    ].join('\n'),
    TaskListBlock(:final items) => items.map(_serializeTaskItem).join('\n'),
    CodeBlock(:final language, :final code) => '```$language\n$code\n```',
    TableBlock(:final rows, :final aligns) => _serializeTable(rows, aligns),
    DividerBlock() => '---',
    ImageBlock(:final assetId, :final alt) => '![$alt]($kAssetUrlPrefix$assetId)',
    RawBlock(:final text) => text,
  };
}

String _serializeBulletItem(ListItem item) {
  final parts = serializeInline(item.runs).split('\n');
  if (parts.length == 1) return '- ${parts.single}';
  return '- ${parts[0]}\n${[for (final p in parts.skip(1)) '  $p'].join('\n')}';
}

String _serializeOrderedItem(ListItem item, int num) {
  final parts = serializeInline(item.runs).split('\n');
  if (parts.length == 1) return '$num. ${parts.single}';
  return '$num. ${parts[0]}\n${[for (final p in parts.skip(1)) '   $p'].join('\n')}';
}

String _serializeTaskItem(TaskItem item) {
  final box = item.checked ? '[x] ' : '[ ] ';
  final parts = serializeInline(item.runs).split('\n');
  if (parts.length == 1) return '- $box${parts.single}';
  return '- $box${parts[0]}\n${[for (final p in parts.skip(1)) '  $p'].join('\n')}';
}

String _serializeTable(List<List<InlineRuns>> rows, List<TableAlign> aligns) {
  if (rows.isEmpty) return '';
  final cols = rows.fold(0, (m, r) => r.length > m ? r.length : m);
  final pa = [
    for (var i = 0; i < cols; i++) i < aligns.length ? aligns[i] : TableAlign.none,
  ];
  final sb = StringBuffer();
  sb.write(_serializeTableRow(rows.first));
  sb.write('\n');
  // 分隔行始终输出（保证 GFM 合法、可往返；没有它解析不出来表格）。
  sb.write('| ${[for (final a in pa) _alignDash(a)].join(' | ')} |');
  for (var r = 1; r < rows.length; r++) {
    sb.write('\n');
    sb.write(_serializeTableRow(rows[r]));
  }
  return sb.toString();
}

String _serializeTableRow(List<InlineRuns> row) =>
    '| ${[for (final c in row) serializeInline(c).replaceAll('|', r'\|')].join(' | ')} |';

String _alignDash(TableAlign a) => switch (a) {
      TableAlign.left => ':---',
      TableAlign.center => ':---:',
      TableAlign.right => '---:',
      TableAlign.none => '---',
    };

// ---------------------------------------------------------------------------
// 行内扫描
// ---------------------------------------------------------------------------

/// 把 [src] 解析出的行内片段追加到 [out]；[base]/[href] 为当前外层叠加的 mark/链接。
void _scanInline(String src, InlineMarks base, String? href, List<InlineNode> out) {
  var i = 0;
  while (i < src.length) {
    final c = src[i];

    // 1. 反斜杠转义：吃掉反斜杠，保留其后字符。
    if (c == '\\' && i + 1 < src.length && _kEscapable.hasMatch(src[i + 1])) {
      _pushText(out, src[i + 1], base, href);
      i += 2;
      continue;
    }

    // 2. 图片：保持原始字面（行内图片不在 InlineNode 建模，见设计 §3.2 R6）。
    if (c == '!' && i + 1 < src.length && src[i + 1] == '[') {
      final m = _kImage.firstMatch(src.substring(i));
      if (m != null) {
        _pushText(out, m.group(0)!, base, href);
        i += m.group(0)!.length;
        continue;
      }
    }

    // 3. 行内代码（内容原样，不递归解析）。
    if (c == '`') {
      final end = src.indexOf('`', i + 1);
      if (end == -1) {
        _pushText(out, '`', base, href);
        i++;
        continue;
      }
      final code = src.substring(i + 1, end);
      _pushText(out, code, InlineMarks.code, null);
      i = end + 1;
      continue;
    }

    // 4. 删除线 ~~x~~。
    if (src.startsWith('~~', i)) {
      final end = src.indexOf('~~', i + 2);
      if (end == -1) {
        _pushText(out, '~~', base, href);
        i += 2;
        continue;
      }
      final inner = src.substring(i + 2, end);
      _scanInline(inner, base | InlineMarks.strike, href, out);
      i = end + 2;
      continue;
    }

    // 5. 强调：**/***/* 与 __/___/_。
    if (c == '*' || c == '_') {
      // 单词内的 `_` 不当作强调（snake_case 不被误伤）。
      if (c == '_' && i > 0 && _isWord(src[i - 1])) {
        _pushText(out, c, base, href);
        i++;
        continue;
      }
      final kind = _matchEmphasis(src, i, c);
      if (kind != null) {
        final end = _findClosing(src, i, c, kind.$2);
        if (end != -1) {
          final inner = src.substring(i + kind.$2, end);
          _scanInline(inner, base | kind.$1, href, out);
          i = end + kind.$2;
          continue;
        }
      }
    }

    // 6. 链接 [label](url)（label 递归解析，并带上 href）。
    if (c == '[') {
      final m = RegExp(r'\[([^\]]*)\]\(([^)\s]+)\)').firstMatch(src.substring(i));
      if (m != null) {
        final label = m.group(1)!;
        final url = m.group(2)!;
        final saved = <InlineNode>[];
        _scanInline(label, InlineMarks.none, url, saved);
        out.addAll(saved);
        i += m.group(0)!.length;
        continue;
      }
    }

    _pushText(out, c, base, href);
    i++;
  }
}

void _pushText(List<InlineNode> out, String text, InlineMarks marks, String? href) {
  if (text.isEmpty) return;
  final last = out.isNotEmpty ? out.last : null;
  if (last is TextRun && last.marks == marks && last.href == href) {
    out[out.length - 1] = TextRun('${last.text}$text', marks: marks, href: href);
  } else {
    out.add(TextRun(text, marks: marks, href: href));
  }
}

/// 返回 `(叠加的 mark, 标记符长度)`；优先匹配最长（*** / ** / *）。
(InlineMarks, int)? _matchEmphasis(String src, int i, String c) {
  if (c == '*') {
    if (i + 2 < src.length && src[i + 1] == '*' && src[i + 2] == '*') {
      return (InlineMarks.boldItalic, 3);
    }
    if (i + 1 < src.length && src[i + 1] == '*') return (InlineMarks.bold, 2);
    return (InlineMarks.italic, 1);
  } else {
    if (i + 2 < src.length && src[i + 1] == '_' && src[i + 2] == '_') {
      return (InlineMarks.bold, 3); // ___x___
    }
    if (i + 1 < src.length && src[i + 1] == '_') return (InlineMarks.bold, 2);
    return (InlineMarks.italic, 1);
  }
}

/// 找到与 i 处开标记同长度的收尾标记位置；要求收尾后不是同一字符（避免与被夹在更长 run 里）。返回 -1 表示未闭合。
int _findClosing(String src, int i, String c, int len) {
  var j = i + len;
  while (j < src.length) {
    if (src[j] == '\\') {
      j += 2;
      continue;
    }
    if (src.startsWith(c * len, j)) {
      final after = j + len;
      if (after >= src.length || src[after] != c) return j;
    }
    j++;
  }
  return -1;
}

bool _isWord(String ch) => RegExp(r'\w').hasMatch(ch);

// ---------------------------------------------------------------------------
// 文本加工：行内代码包裹 / 转义
// ---------------------------------------------------------------------------

String _wrapCode(String text) {
  if (!text.contains('`')) return '`$text`';
  return '`` $text ``';
}

String _escapeText(String s) {
  // 反斜杠优先，避免破坏后面的转义。
  s = s.replaceAll('\\', '\\\\');
  s = s.replaceAll('`', r'\`');
  s = s.replaceAll('*', r'\*');
  // 防止被二次解析成链接（其余 Markdown 标点在这里不转义，避免过度噪声）。
  s = s.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\('),
    (m) => '\\[${m.group(1)}\\](',
  );
  return s;
}

// ---------------------------------------------------------------------------
// 行 / 表格辅助
// ---------------------------------------------------------------------------

bool _isBlank(String line) => line.trim().isEmpty;

/// 连接 [lines] 的 [from, to) 区间（保留原始换行），用于取某块的原文 source。
String _joinLines(List<String> lines, int from, int to) {
  final sb = StringBuffer();
  for (var j = from; j < to; j++) {
    sb.write(lines[j]);
    if (j < lines.length - 1) sb.write('\n');
  }
  return sb.toString();
}

int _skipBlanks(List<String> lines, int from) {
  var k = from;
  while (k < lines.length && _isBlank(lines[k])) k++;
  return k;
}

/// 计算「第 [stop-1] 行结束换行」+ [stop, next) 区间内原样空白 的精确间隔文本。
String _gapBetween(List<String> lines, int stop, int next) {
  final sb = StringBuffer();
  if (stop < lines.length) sb.write('\n');
  for (var j = stop; j < next; j++) {
    sb.write(lines[j]);
    if (j < lines.length - 1) sb.write('\n');
  }
  return sb.toString();
}

bool _startsBlock(String line) {
  final t = line.trim();
  if (t.isEmpty) return true;
  if (t.startsWith('```')) return true;
  if (_kDivider.hasMatch(t)) return true;
  if (_kHeading.hasMatch(t)) return true;
  if (_kQuote.hasMatch(t)) return true;
  if (_kTaskItem.hasMatch(t)) return true;
  if (_kOlItem.hasMatch(t)) return true;
  if (_kUlItem.hasMatch(t)) return true;
  if (t.startsWith('|')) return true;
  return false;
}

bool _isTableDivider(String line) {
  final t = line.trim();
  if (!t.startsWith('|')) return false;
  final cells = _splitRow(t);
  if (cells.isEmpty) return false;
  return cells.every((c) => _kTableDivider.hasMatch(c));
}

/// 把一行 GFM 表格拆成单元格。
///
/// 关键：按**未转义**的 `|` 切分，切完把 `\|` 还原成 `|` ——
/// 否则单元格里含 `|`（序列化成 `\|`）时再解析会错位成两格。
/// 其余 `\x` 转义原样保留，交给行内解析器（`parseInline`）继续处理。
List<String> _splitRow(String line) {
  var body = line.trim();
  if (body.startsWith('|')) body = body.substring(1);
  // 末尾分隔竖线（未转义）去掉；`\|` 结尾的是单元格内容里的竖线，不能删。
  if (body.isNotEmpty && body.endsWith('|')) {
    final String prev = body.length >= 2 ? body[body.length - 2] : '';
    if (prev != r'\') body = body.substring(0, body.length - 1);
  }
  final cells = <String>[];
  final buf = StringBuffer();
  var i = 0;
  while (i < body.length) {
    final String ch = body[i];
    if (ch == r'\' && i + 1 < body.length && body[i + 1] == '|') {
      buf.write('|'); // `\|` → 单元格内的字面竖线
      i += 2;
      continue;
    }
    if (ch == '|') {
      cells.add(buf.toString().trim());
      buf.clear();
      i++;
      continue;
    }
    buf.write(ch);
    i++;
  }
  cells.add(buf.toString().trim());
  return cells;
}

List<TableAlign> _alignsOf(String dividerLine) =>
    [for (final c in _splitRow(dividerLine)) _alignOf(c)];

TableAlign _alignOf(String cell) {
  final left = cell.startsWith(':');
  final right = cell.endsWith(':');
  if (left && right) return TableAlign.center;
  if (right) return TableAlign.right;
  if (left) return TableAlign.left;
  return TableAlign.none;
}
