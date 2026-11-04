/// 笔记编辑器「所见即所得」改造 —— 块级动作层（T2）。
///
/// 设计依据：`docs/NOTE_EDITOR_WYSIWYG_DESIGN.md`
/// §5.3（Enter 行为矩阵）、§5.4（行首退格矩阵）、§5.6（换类型后保持光标）、
/// §6.1（工具栏 19 个按钮的新行为）。
///
/// **这个文件管什么**
/// - 块级编辑原语：分裂 [splitBlock] / 行首回并 [mergeBackward] /
///   换块类型 [setBlockType] / 任务勾选 [toggleTaskItem] /
///   表格增删行列 / 行内标记封装 [applyInlineMark]；
/// - 全部是 `NoteDoc → NoteDoc` 的**纯函数**：不改全局状态、不 import flutter、可 100% 单测。
///
/// **这个文件不管什么**
/// - Markdown 解析/序列化 → `markdown_block_parser.dart`（本文件只借用 `serializeInline`）；
/// - 打字时的格式投影 → `inline_projection.dart`；
/// - 焦点 / 选区 / `TextEditingController` 编排 → T3 的 `NoteEditorController`；
/// - 「什么时候调用哪个动作」（按键拦截、工具栏点击、开关回落段落）→ T3 / T4。
///
/// **五条不变量（改这个文件前必须读）**
/// 1. **不丢字符**：分裂与合并之后，相关块 `plainTextOf` 的拼接必须等于原文 —— 这是数据安全红线。
/// 2. **L1 原文直通**：没被改动的块原样留在 doc 里（**同一个对象**，`source` 不丢）；
///    被改动的块一律用构造函数重造且**不传 source**（source = null → 走规范化序列化，与 T1 的
///    `_edited()` 约定一致）。
/// 3. **越界不抛**：所有下标先 clamp；锚点（blockId / itemId）找不到时**原样返回** doc。
/// 4. **id 是句柄**：动作只改内容，**不换主块的 id**（T3 靠它维持光标/焦点）；被拆出来的
///    附属块（残余引用多行、残余列表项）才用 `newBlockId()`。
/// 5. **纯函数**：同样的入参永远得到同样的结构（`newBlockId()` 产生的 id 除外，id 不参与 `==`）。
///
/// **与冻结契约的三处「加法」（都是可选具名参数，向后兼容，见交付报告）**
/// - [splitBlock] / [mergeBackward] 各多了一个**可选具名参数**：块内偏移与条目/行下标 ——
///   因为 `BlockRef` 只承载 `(blockId, itemId)`，装不下「光标在块内第几个字符」。
///   不传时退化为「在末尾回车 / 首项」的默认语义，冻结的调用形状 `splitBlock(doc, at)` 依然成立。
/// - [setBlockType] 多了两个可选具名参数：`headingLevel`（H1–H6 必须能指定级别）与
///   `itemIndex`（引用行没有 id，要支持「只改光标所在那一行」就必须能传行号，设计 §5.6）。
library;

import 'block_model.dart';
import 'inline_projection.dart' show applyMark;
import 'markdown_block_parser.dart' show serializeInline;

// ---------------------------------------------------------------------------
// Enter：分裂
// ---------------------------------------------------------------------------

/// Enter：在 [at] 处把块一分为二。返回新 doc 与新 caret 锚点。
///
/// 行为按设计 §5.3 的矩阵：
/// - 段落 → 按光标分裂成两个段落；
/// - 标题 → 前半留在标题，后半进**下方新建的段落**（避免连写标题，且一个字都不丢）；
/// - 引用 → 同一 `QuoteBlock` 内把当前行裂成两行；当前行是空行 → 该行退出引用变成独立段落；
/// - 无序 / 有序 / 任务列表 → 同一 list 块内把当前项裂成两项（新项未勾选）；
///   当前项是空项 → 列表收尾：该项降级为列表下方的独立段落；
/// - 代码块 → 插入软换行 `\n`；**末尾恰好是空行时再按 Enter** → 退出代码块、下方新建段落；
/// - 表格 → 追加一行（设计里「跳下一单元格」是控制器职责，见 T3；到表尾才追加）；
/// - 图片 / 分割线 / RawBlock → 块本身不动（`source` 保留），下方插一个空段落并聚焦。
///
/// [caretOffset] 块内光标偏移（缺省 = 文本末尾，即「在末尾回车」）；越界自动 clamp。
/// [itemIndex] 列表项 / 引用行的下标（列表优先用 [BlockRef.itemId] 定位，itemId 缺失或不匹配时才用它）。
({NoteDoc doc, BlockRef caret}) splitBlock(
  NoteDoc doc,
  BlockRef at, {
  int? caretOffset,
  int? itemIndex,
}) {
  final i = _indexOf(doc, at.blockId);
  if (i < 0) return (doc: doc, caret: at);
  final b = doc.blocks[i];
  final isLast = i == doc.blocks.length - 1;
  // 前半块用分隔（沿用原块分隔，空则用标准两空行）；后半块在文末不带分隔（避免落库出现文末空行垃圾）。
  final headGap = _gapOf(b);
  final tailGap = isLast ? '' : b.trailingGap;

  // 1) 段落：按光标一分为二。
  if (b is ParagraphBlock) {
    final text = plainTextOf(b.runs);
    final off = _clamp(caretOffset ?? text.length, text.length);
    // 光标在末尾时首块内容未变 → 复用原对象，source 继续直通（L1）。
    // **但间隔必须补上**：文末块（`trailingGap == ''`）回车后若直接复用原对象，
    // 新旧两块都带空间隔，序列化就退化成「AAA」——空段落连同分隔全部蒸发
    // （用户实测：连按回车看到空白行，保存后一行都没了）。内容没变 → source 照带。
    final head = off >= text.length
        ? (b.trailingGap == headGap
            ? b
            : ParagraphBlock(
                id: b.id,
                source: b.source,
                trailingGap: headGap,
                runs: b.runs,
              ))
        : ParagraphBlock(id: b.id, trailingGap: headGap, runs: _slice(b.runs, 0, off));
    final tail = ParagraphBlock(
      id: newBlockId('p'),
      trailingGap: tailGap,
      runs: _slice(b.runs, off, text.length),
    );
    return (doc: _splice(doc, i, 1, <Block>[head, tail]), caret: BlockRef(tail.id));
  }

  // 2) 标题：前半留标题，后半进下方新段落。
  if (b is HeadingBlock) {
    final text = plainTextOf(b.runs);
    final off = _clamp(caretOffset ?? text.length, text.length);
    final head = HeadingBlock(
      id: b.id,
      trailingGap: headGap,
      level: b.level,
      runs: _slice(b.runs, 0, off),
    );
    final tail = ParagraphBlock(
      id: newBlockId('p'),
      trailingGap: tailGap,
      runs: _slice(b.runs, off, text.length),
    );
    return (doc: _splice(doc, i, 1, <Block>[head, tail]), caret: BlockRef(tail.id));
  }

  // 3) 引用：当前行裂成两行；空行回车 = 退出引用。
  if (b is QuoteBlock) {
    final lines = b.lines;
    if (lines.isEmpty) {
      // 空引用块：补一行空引用（不崩、不丢），光标留在块内。
      final q = QuoteBlock(id: b.id, trailingGap: b.trailingGap, lines: <InlineRuns>[_emptyRuns()]);
      return (doc: _splice(doc, i, 1, <Block>[q]), caret: BlockRef(q.id));
    }
    final li = _clamp(itemIndex ?? 0, lines.length - 1);
    final cur = lines[li];
    final text = plainTextOf(cur);
    final off = _clamp(caretOffset ?? text.length, text.length);

    if (text.isEmpty) {
      // 空行 → 该行退出引用（其余行仍是引用块，位置按被指向的行前后保持顺序）。
      final rest = <InlineRuns>[...lines]..removeAt(li);
      if (rest.isEmpty) {
        final para = ParagraphBlock(id: b.id, trailingGap: b.trailingGap, runs: cur);
        return (doc: _splice(doc, i, 1, <Block>[para]), caret: BlockRef(para.id));
      }
      final paraId = newBlockId('p');
      if (li == 0) {
        final para = ParagraphBlock(id: paraId, trailingGap: headGap, runs: cur);
        final quote = QuoteBlock(id: b.id, trailingGap: tailGap, lines: rest);
        return (
          doc: _splice(doc, i, 1, <Block>[para, quote]),
          caret: BlockRef(para.id),
        );
      }
      final quote = QuoteBlock(id: b.id, trailingGap: headGap, lines: rest);
      final para = ParagraphBlock(id: paraId, trailingGap: tailGap, runs: cur);
      return (
        doc: _splice(doc, i, 1, <Block>[quote, para]),
        caret: BlockRef(para.id),
      );
    }

    final newLines = <InlineRuns>[
      ...lines.sublist(0, li),
      _slice(cur, 0, off),
      _slice(cur, off, text.length),
      ...lines.sublist(li + 1),
    ];
    final quote = QuoteBlock(id: b.id, trailingGap: b.trailingGap, lines: newLines);
    return (doc: _splice(doc, i, 1, <Block>[quote]), caret: BlockRef(quote.id));
  }

  // 4) 无序列表。
  if (b is BulletListBlock) {
    final items = b.items;
    if (items.isEmpty) {
      final list = BulletListBlock(
        id: b.id,
        trailingGap: b.trailingGap,
        items: <ListItem>[ListItem(id: newBlockId('li'))],
      );
      return (
        doc: _splice(doc, i, 1, <Block>[list]),
        caret: BlockRef(list.id, itemId: list.items.single.id),
      );
    }
    final ii = _itemPos(<String>[for (final it in items) it.id], at.itemId, itemIndex);
    if (ii < 0) return (doc: doc, caret: at); // 锚点过期（条目已被删）→ 不动
    final cur = items[ii];
    final text = plainTextOf(cur.runs);
    final off = _clamp(caretOffset ?? text.length, text.length);

    // 空项回车 = 列表收尾（设计 §5.3）。
    if (text.isEmpty) {
      final rest = <ListItem>[...items]..removeAt(ii);
      if (rest.isEmpty) {
        final para = ParagraphBlock(id: b.id, trailingGap: b.trailingGap, runs: cur.runs);
        return (doc: _splice(doc, i, 1, <Block>[para]), caret: BlockRef(para.id));
      }
      final list = BulletListBlock(id: b.id, trailingGap: headGap, items: rest);
      final para = ParagraphBlock(
        id: newBlockId('p'),
        trailingGap: tailGap,
        runs: cur.runs,
      );
      return (
        doc: _splice(doc, i, 1, <Block>[list, para]),
        caret: BlockRef(para.id),
      );
    }

    final tail = ListItem(id: newBlockId('li'), runs: _slice(cur.runs, off, text.length));
    final newItems = <ListItem>[
      ...items.sublist(0, ii),
      ListItem(id: cur.id, runs: _slice(cur.runs, 0, off)),
      tail,
      ...items.sublist(ii + 1),
    ];
    final list = BulletListBlock(id: b.id, trailingGap: b.trailingGap, items: newItems);
    return (
      doc: _splice(doc, i, 1, <Block>[list]),
      caret: BlockRef(list.id, itemId: tail.id),
    );
  }

  // 5) 有序列表（start 保持，分裂不重新编号）。
  if (b is OrderedListBlock) {
    final items = b.items;
    if (items.isEmpty) {
      final list = OrderedListBlock(
        id: b.id,
        trailingGap: b.trailingGap,
        start: b.start,
        items: <ListItem>[ListItem(id: newBlockId('li'))],
      );
      return (
        doc: _splice(doc, i, 1, <Block>[list]),
        caret: BlockRef(list.id, itemId: list.items.single.id),
      );
    }
    final ii = _itemPos(<String>[for (final it in items) it.id], at.itemId, itemIndex);
    if (ii < 0) return (doc: doc, caret: at); // 锚点过期（条目已被删）→ 不动
    final cur = items[ii];
    final text = plainTextOf(cur.runs);
    final off = _clamp(caretOffset ?? text.length, text.length);

    if (text.isEmpty) {
      final rest = <ListItem>[...items]..removeAt(ii);
      if (rest.isEmpty) {
        final para = ParagraphBlock(id: b.id, trailingGap: b.trailingGap, runs: cur.runs);
        return (doc: _splice(doc, i, 1, <Block>[para]), caret: BlockRef(para.id));
      }
      final list =
          OrderedListBlock(id: b.id, trailingGap: headGap, start: b.start, items: rest);
      final para = ParagraphBlock(
        id: newBlockId('p'),
        trailingGap: tailGap,
        runs: cur.runs,
      );
      return (
        doc: _splice(doc, i, 1, <Block>[list, para]),
        caret: BlockRef(para.id),
      );
    }

    final tail = ListItem(id: newBlockId('li'), runs: _slice(cur.runs, off, text.length));
    final newItems = <ListItem>[
      ...items.sublist(0, ii),
      ListItem(id: cur.id, runs: _slice(cur.runs, 0, off)),
      tail,
      ...items.sublist(ii + 1),
    ];
    final list =
        OrderedListBlock(id: b.id, trailingGap: b.trailingGap, start: b.start, items: newItems);
    return (
      doc: _splice(doc, i, 1, <Block>[list]),
      caret: BlockRef(list.id, itemId: tail.id),
    );
  }

  // 6) 任务列表（新项一律未勾选，避免「复制出一个已完成的待办」）。
  if (b is TaskListBlock) {
    final items = b.items;
    if (items.isEmpty) {
      final list = TaskListBlock(
        id: b.id,
        trailingGap: b.trailingGap,
        items: <TaskItem>[TaskItem(id: newBlockId('ti'))],
      );
      return (
        doc: _splice(doc, i, 1, <Block>[list]),
        caret: BlockRef(list.id, itemId: list.items.single.id),
      );
    }
    final ii = _itemPos(<String>[for (final it in items) it.id], at.itemId, itemIndex);
    if (ii < 0) return (doc: doc, caret: at); // 锚点过期（条目已被删）→ 不动
    final cur = items[ii];
    final text = plainTextOf(cur.runs);
    final off = _clamp(caretOffset ?? text.length, text.length);

    if (text.isEmpty) {
      final rest = <TaskItem>[...items]..removeAt(ii);
      if (rest.isEmpty) {
        final para = ParagraphBlock(id: b.id, trailingGap: b.trailingGap, runs: cur.runs);
        return (doc: _splice(doc, i, 1, <Block>[para]), caret: BlockRef(para.id));
      }
      final list = TaskListBlock(id: b.id, trailingGap: headGap, items: rest);
      final para = ParagraphBlock(
        id: newBlockId('p'),
        trailingGap: tailGap,
        runs: cur.runs,
      );
      return (
        doc: _splice(doc, i, 1, <Block>[list, para]),
        caret: BlockRef(para.id),
      );
    }

    final tail = TaskItem(id: newBlockId('ti'), runs: _slice(cur.runs, off, text.length));
    final newItems = <TaskItem>[
      ...items.sublist(0, ii),
      TaskItem(id: cur.id, runs: _slice(cur.runs, 0, off), checked: cur.checked),
      tail,
      ...items.sublist(ii + 1),
    ];
    final list = TaskListBlock(id: b.id, trailingGap: b.trailingGap, items: newItems);
    return (
      doc: _splice(doc, i, 1, <Block>[list]),
      caret: BlockRef(list.id, itemId: tail.id),
    );
  }

  // 7) 代码块：软换行；末尾空行上再回车 → 退出代码块。
  if (b is CodeBlock) {
    final code = b.code;
    final off = _clamp(caretOffset ?? code.length, code.length);
    if (off >= code.length && code.endsWith('\n')) {
      final cb = CodeBlock(
        id: b.id,
        trailingGap: headGap,
        language: b.language,
        code: code.substring(0, code.length - 1),
      );
      final para = ParagraphBlock(
        id: newBlockId('p'),
        trailingGap: tailGap,
        runs: _emptyRuns(),
      );
      return (doc: _splice(doc, i, 1, <Block>[cb, para]), caret: BlockRef(para.id));
    }
    final cb = CodeBlock(
      id: b.id,
      trailingGap: b.trailingGap,
      language: b.language,
      code: '${code.substring(0, off)}\n${code.substring(off)}',
    );
    return (doc: _splice(doc, i, 1, <Block>[cb]), caret: BlockRef(cb.id));
  }

  // 8) 表格：表尾回车 = 追加一行（单元格间跳转是控制器职责）。
  if (b is TableBlock) {
    final t = _withRow(b, _appendRow(b));
    return (doc: _splice(doc, i, 1, <Block>[t]), caret: BlockRef(t.id));
  }

  // 9) 图片 / 分割线 / RawBlock：块不动（source 保留），下方插空段落。
  //    新段落的分隔留空：原块的 trailingGap 已经承担了「与下一块之间的空行」，
  //    空段落序列化成 ''，所以整篇的字节与视觉都不会多出空行。
  final para = ParagraphBlock(
    id: newBlockId('p'),
    trailingGap: '',
    runs: _emptyRuns(),
  );
  return (doc: _splice(doc, i, 1, <Block>[b, para]), caret: BlockRef(para.id));
}

// ---------------------------------------------------------------------------
// 行首退格：回并（Notion 式两级）
// ---------------------------------------------------------------------------

/// 块首退格：合并到上一块（Notion 式两级）。返回新 doc 与新 caret 锚点。
///
/// 行为按设计 §5.4 的矩阵：
/// - 列表 / 任务列表的**非首项** → 删本项，文本并入前一项（不跨块）；
/// - 列表 / 任务列表的**首项** → 该项脱离列表成为独立段落（内容保留，不与上一块合并）；
///   列表只剩这一项时，整块原地变成一个段落；
/// - 标题 / 引用第一行 / 代码块 / RawBlock → **先降级为段落**（内容保留），第二次退格才走合并；
/// - 段落 → 并入上一块：段落/标题=文本拼接，引用=成为新末行，列表=成为新末项；
///   上一块是**代码块 / 表格 / 分割线 / 图片 / RawBlock** → 直接删掉上一块（等价于选中删除），
///   光标留在当前段落头；
/// - 段落且没有上一块 → 无操作；表格（单元格空）→ 不跨块合并，无操作。
///
/// [itemIndex] 列表项 / 引用行的下标（列表优先用 [BlockRef.itemId]）。
///
/// 返回的 [BlockRef] 只给**块级锚点**；块内偏移按语义由调用方推导
/// （例如「并入前一块末尾」= 合并前那一块的文本长度），因为 `BlockRef` 装不下偏移。
({NoteDoc doc, BlockRef caret}) mergeBackward(
  NoteDoc doc,
  BlockRef at, {
  int? itemIndex,
}) {
  final i = _indexOf(doc, at.blockId);
  if (i < 0) return (doc: doc, caret: at);
  final b = doc.blocks[i];

  // 1) 列表类：非首项并进前一项，首项降级为段落。
  if (b is BulletListBlock && at.itemId != null) {
    return _mergeList3(_BulletOps(b), doc, i, at, itemIndex);
  }
  if (b is OrderedListBlock && at.itemId != null) {
    return _mergeList3(_OrderedOps(b), doc, i, at, itemIndex);
  }
  if (b is TaskListBlock && at.itemId != null) {
    return _mergeList3(_TaskOps(b), doc, i, at, itemIndex);
  }

  // 2) 标题 → 降级为段落。
  if (b is HeadingBlock) {
    final para = ParagraphBlock(id: b.id, trailingGap: b.trailingGap, runs: b.runs);
    return (doc: _splice(doc, i, 1, <Block>[para]), caret: BlockRef(para.id));
  }

  // 3) 引用：**首行**降级为段落（设计 §5.4 两级退格的第一步）；
  //    第 2 行起 → 并入**上一行**（与「列表非首项并进前一项」同款，块结构不变）。
  if (b is QuoteBlock) {
    final lines = b.lines;
    if (lines.isEmpty) return (doc: doc, caret: at);
    final li = _clamp(itemIndex ?? 0, lines.length - 1);

    // 非首行：行内文本拼接，行数与块结构都不变（一个字都不丢，也不多冒出块）。
    if (li > 0) {
      final merged = <InlineRuns>[
        ...lines.sublist(0, li - 1),
        _concat(lines[li - 1], lines[li]),
        ...lines.sublist(li + 1),
      ];
      final quote = QuoteBlock(id: b.id, trailingGap: b.trailingGap, lines: merged);
      return (doc: _splice(doc, i, 1, <Block>[quote]), caret: BlockRef(quote.id));
    }

    // 首行：降级为独立段落，其余行仍留在引用块里。
    final cur = lines.first;
    final rest = lines.sublist(1);
    if (rest.isEmpty) {
      final para = ParagraphBlock(id: b.id, trailingGap: b.trailingGap, runs: cur);
      return (doc: _splice(doc, i, 1, <Block>[para]), caret: BlockRef(para.id));
    }
    final para = ParagraphBlock(id: newBlockId('p'), trailingGap: _gapOf(b), runs: cur);
    final quote = QuoteBlock(id: b.id, trailingGap: b.trailingGap, lines: rest);
    return (doc: _splice(doc, i, 1, <Block>[para, quote]), caret: BlockRef(para.id));
  }

  // 4) 代码块 / RawBlock → 文本原样降级为段落（一个字不少）。
  if (b is CodeBlock) {
    final para = ParagraphBlock(
      id: b.id,
      trailingGap: b.trailingGap,
      runs: <InlineNode>[TextRun(b.code)],
    );
    return (doc: _splice(doc, i, 1, <Block>[para]), caret: BlockRef(para.id));
  }
  if (b is RawBlock) {
    final para = ParagraphBlock(
      id: b.id,
      trailingGap: b.trailingGap,
      runs: <InlineNode>[TextRun(b.text)],
    );
    return (doc: _splice(doc, i, 1, <Block>[para]), caret: BlockRef(para.id));
  }

  // 5) 表格 / 分割线 / 图片：不跨块合并（表格单元格为空时不合并，见设计 §5.4）。
  if (b is TableBlock || b is DividerBlock || b is ImageBlock) {
    return (doc: doc, caret: at);
  }

  // 6) 段落：并入上一块（或删掉不可合并的上一块）。
  if (b is ParagraphBlock) {
    if (i == 0) return (doc: doc, caret: at); // 首块无处可并
    final prev = doc.blocks[i - 1];

    // 上一块没有可承载正文的载体 → 直接删掉它（等价于选中删除）。
    if (prev is CodeBlock ||
        prev is TableBlock ||
        prev is DividerBlock ||
        prev is ImageBlock ||
        prev is RawBlock) {
      // 当前段落本身一个字都不改 → 保留原对象（source 继续直通，L1）。
      return (doc: _splice(doc, i - 1, 1, const <Block>[]), caret: BlockRef(b.id));
    }

    if (prev is ParagraphBlock) {
      final merged = ParagraphBlock(
        id: prev.id,
        trailingGap: b.trailingGap,
        runs: _concat(prev.runs, b.runs),
      );
      return (
        doc: _splice(doc, i - 1, 2, <Block>[merged]),
        caret: BlockRef(merged.id),
      );
    }

    if (prev is HeadingBlock) {
      final merged = HeadingBlock(
        id: prev.id,
        trailingGap: b.trailingGap,
        level: prev.level,
        runs: _concat(prev.runs, b.runs),
      );
      return (
        doc: _splice(doc, i - 1, 2, <Block>[merged]),
        caret: BlockRef(merged.id),
      );
    }

    if (prev is QuoteBlock) {
      final merged = QuoteBlock(
        id: prev.id,
        trailingGap: b.trailingGap,
        lines: <InlineRuns>[...prev.lines, b.runs],
      );
      return (
        doc: _splice(doc, i - 1, 2, <Block>[merged]),
        caret: BlockRef(merged.id),
      );
    }

    if (prev is BulletListBlock) {
      final item = ListItem(id: newBlockId('li'), runs: b.runs);
      final merged = BulletListBlock(
        id: prev.id,
        trailingGap: b.trailingGap,
        items: <ListItem>[...prev.items, item],
      );
      return (
        doc: _splice(doc, i - 1, 2, <Block>[merged]),
        caret: BlockRef(merged.id, itemId: item.id),
      );
    }

    if (prev is OrderedListBlock) {
      final item = ListItem(id: newBlockId('li'), runs: b.runs);
      final merged = OrderedListBlock(
        id: prev.id,
        trailingGap: b.trailingGap,
        start: prev.start,
        items: <ListItem>[...prev.items, item],
      );
      return (
        doc: _splice(doc, i - 1, 2, <Block>[merged]),
        caret: BlockRef(merged.id, itemId: item.id),
      );
    }

    if (prev is TaskListBlock) {
      final item = TaskItem(id: newBlockId('ti'), runs: b.runs);
      final merged = TaskListBlock(
        id: prev.id,
        trailingGap: b.trailingGap,
        items: <TaskItem>[...prev.items, item],
      );
      return (
        doc: _splice(doc, i - 1, 2, <Block>[merged]),
        caret: BlockRef(merged.id, itemId: item.id),
      );
    }
  }

  return (doc: doc, caret: at);
}

// ---------------------------------------------------------------------------
// 工具栏：切换块类型
// ---------------------------------------------------------------------------

/// 工具栏切换块类型（段落 / H1–H6 / 引用 / 无序 / 有序 / 任务列表 / 代码块 / 分割线 / 图片 互转）。
///
/// **取舍（写死在实现里，调用方不用猜）**
/// - 段落 ↔ 标题：只改外壳，文本一个字不动；
/// - 标题 ↔ 标题：只改 [headingLevel]，文本不动；不给 level 时沿用原级别；
/// - 无序 / 有序 / 任务互转：整块保留，各项文本与**条目 id 全部复用**（光标不丢）；
///   任务 → 其它列表时 `checked` 信息自然丢失（目标类型无处承载），这是有损但不可避的语义；
/// - 列表项 → 标题 / 段落 / 引用 / 代码：把**被指向的那一项抬出为独立块**，
///   其余项仍留在原列表块里（位置按被指向项的前后保持顺序）；
/// - 段落 / 标题 → 列表：整段文本包成**单项**列表；
/// - 段落 / 标题 → 代码块：文本原样进 `code`（行内格式无法承载，会退化成纯文本）；
/// - 引用 → 段落 / 标题 / 列表 / 代码：只抬出**被指向的那一行**（默认第一行，可用 [itemIndex] 指定），
///   其余行仍是引用块（与设计 §5.6 的「只有光标所在行改变」一致）；
/// - 代码块 / RawBlock → 其它文本块：正文原样降级，不丢字符；
/// - 表格 / 分割线 / 图片 → 文本块：**保持原样**（没有可承载的正文载体，硬转会丢内容）；
///   同理文本块 → 表格 / 分割线 / 图片也保持原样（表格需要行列结构、图片需要 assetId）；
///   需要建表格/分割线/图片请用 T3 的 `insertTableBlock` / `insertDividerBlock` / `insertImageBlock`；
/// - 目标类型就是当前类型（标题还要级别相同）→ **原样返回 doc**，
///   这样不会无谓地把 `source` 打掉（L1）。
///
/// [itemIndex] 只对引用有意义（引用行没有 id，`BlockRef` 也装不下行号）：缩放后越界自动 clamp，
/// 缺省 = 第一行。列表 / 其它块忽略该参数（列表用 [BlockRef.itemId] 定位）。
///
/// 注意：设计 §6.1 的「同一类型再点一次 → 回落段落」的**开关语义不在本函数**里，
/// 由工具栏/T3 决定（否则 `setBlockType` 会变得不幂等，难以推理）。
NoteDoc setBlockType(
  NoteDoc doc,
  BlockRef at,
  BlockType type, {
  int? headingLevel,
  int? itemIndex,
}) {
  final i = _indexOf(doc, at.blockId);
  if (i < 0) return doc;
  final b = doc.blocks[i];

  if (b.type == type) {
    if (type != BlockType.heading) return doc;
    final h = b as HeadingBlock;
    if (headingLevel == null || headingLevel == h.level) return doc;
    return _splice(doc, i, 1, <Block>[
      HeadingBlock(
        id: h.id,
        trailingGap: h.trailingGap,
        level: _level(headingLevel),
        runs: h.runs,
      ),
    ]);
  }

  final repl = _convert(b, at, type, headingLevel, itemIndex);
  if (repl == null) return doc; // 不可直接转 → 保持（绝不丢内容）
  return _splice(doc, i, 1, repl);
}

/// 任务列表项勾选/取消。
///
/// - 同一个值重复设置 → 原样返回 doc（不打掉 `source`）；
/// - [at] 指向的不是任务列表时，兜底按 [itemId] 在全篇任务列表里查找（T4 从只读视图点勾选时很方便）。
NoteDoc toggleTaskItem(NoteDoc doc, BlockRef at, String itemId, bool done) {
  var idx = _indexOf(doc, at.blockId);
  if (idx < 0 || doc.blocks[idx] is! TaskListBlock) {
    idx = doc.blocks.indexWhere((b) => b is TaskListBlock && b.items.any((it) => it.id == itemId));
  }
  if (idx < 0) return doc;
  final b = doc.blocks[idx];
  if (b is! TaskListBlock) return doc;

  final items = <TaskItem>[];
  var hit = false;
  var changed = false;
  for (final it in b.items) {
    if (it.id != itemId) {
      items.add(it);
      continue;
    }
    hit = true;
    if (it.checked != done) changed = true;
    items.add(TaskItem(id: it.id, runs: it.runs, checked: done));
  }
  if (!hit || !changed) return doc;

  final list = TaskListBlock(id: b.id, trailingGap: b.trailingGap, items: items);
  return _splice(doc, idx, 1, <Block>[list]);
}

// ---------------------------------------------------------------------------
// 表格结构编辑（任何操作后都保证「每行列数 == 最大列数」）
// ---------------------------------------------------------------------------

/// 在 [afterRow] 之后插入一行空单元格（越界自动 clamp 到末行之后）。
NoteDoc insertTableRow(NoteDoc doc, BlockRef table, int afterRow) {
  final hit = _tableAt(doc, table);
  if (hit == null) return doc;
  final (i, t) = hit;
  final cols = _colsOf(t);
  final rows = _padRows(t.rows, cols);
  final pos = rows.isEmpty ? 0 : _clamp(afterRow, rows.length - 1) + 1;
  rows.insert(pos, _emptyRow(cols));
  final out = TableBlock(
    id: t.id,
    trailingGap: t.trailingGap,
    hasHeader: t.hasHeader,
    aligns: _padAligns(t.aligns, cols),
    rows: rows,
  );
  return _splice(doc, i, 1, <Block>[out]);
}

/// 删除第 [row] 行；只有一行 / 越界 → 原样返回（表格不能没有表体）。
NoteDoc removeTableRow(NoteDoc doc, BlockRef table, int row) {
  final hit = _tableAt(doc, table);
  if (hit == null) return doc;
  final (i, t) = hit;
  final cols = _colsOf(t);
  final rows = _padRows(t.rows, cols);
  if (rows.length <= 1 || row < 0 || row >= rows.length) return doc;
  rows.removeAt(row);
  final out = TableBlock(
    id: t.id,
    trailingGap: t.trailingGap,
    hasHeader: t.hasHeader,
    aligns: _padAligns(t.aligns, cols),
    rows: rows,
  );
  return _splice(doc, i, 1, <Block>[out]);
}

/// 在 [afterCol] 之后插入一列空格（`aligns` 同步补 `none`；越界 clamp 到末列之后）。
NoteDoc insertTableColumn(NoteDoc doc, BlockRef table, int afterCol) {
  final hit = _tableAt(doc, table);
  if (hit == null) return doc;
  final (i, t) = hit;
  final cols = _colsOf(t);
  if (cols <= 0 || t.rows.isEmpty) return doc;
  final pos = _clamp(afterCol, cols - 1) + 1;
  final rows = <List<InlineRuns>>[
    for (final r in _padRows(t.rows, cols))
      <InlineRuns>[...r.sublist(0, pos), _emptyRuns(), ...r.sublist(pos)],
  ];
  final aligns = _padAligns(t.aligns, cols)..insert(pos, TableAlign.none);
  final out = TableBlock(
    id: t.id,
    trailingGap: t.trailingGap,
    hasHeader: t.hasHeader,
    aligns: aligns,
    rows: rows,
  );
  return _splice(doc, i, 1, <Block>[out]);
}

/// 删除第 [col] 列（`aligns` 同步裁掉）；只有一列 / 越界 → 原样返回。
NoteDoc removeTableColumn(NoteDoc doc, BlockRef table, int col) {
  final hit = _tableAt(doc, table);
  if (hit == null) return doc;
  final (i, t) = hit;
  final cols = _colsOf(t);
  if (cols <= 1 || t.rows.isEmpty || col < 0 || col >= cols) return doc;
  final rows = <List<InlineRuns>>[
    for (final r in _padRows(t.rows, cols))
      <InlineRuns>[...r.sublist(0, col), ...r.sublist(col + 1)],
  ];
  final aligns = _padAligns(t.aligns, cols)..removeAt(col);
  final out = TableBlock(
    id: t.id,
    trailingGap: t.trailingGap,
    hasHeader: t.hasHeader,
    aligns: aligns,
    rows: rows,
  );
  return _splice(doc, i, 1, <Block>[out]);
}

// ---------------------------------------------------------------------------
// 行内标记（便捷封装）
// ---------------------------------------------------------------------------

/// 行内标记在文本块（段落/标题/引用/列表项）上的应用/取消。
///
/// 纯转发 `inline_projection.applyMark`：区间自动 clamp，折叠选区（`start == end`）原样返回
/// （折叠态加粗由 T3 的 `pendingMarks` 负责）。这里单独开一个入口，是为了让工具栏
/// 只需要 import 本文件就能拿到「块级 + 行内」两套动作。
InlineRuns applyInlineMark(
  InlineRuns runs,
  int start,
  int end,
  InlineMarks mark, {
  required bool on,
}) =>
    applyMark(runs, start, end, mark, on: on);

// ---------------------------------------------------------------------------
// 私有：文档/块定位
// ---------------------------------------------------------------------------

int _indexOf(NoteDoc doc, String blockId) {
  for (var i = 0; i < doc.blocks.length; i++) {
    if (doc.blocks[i].id == blockId) return i;
  }
  return -1;
}

/// 用 [replacement] 替换 `[index, index + removeCount)`。
NoteDoc _splice(NoteDoc doc, int index, int removeCount, List<Block> replacement) {
  final blocks = <Block>[
    ...doc.blocks.sublist(0, index),
    ...replacement,
    ...doc.blocks.sublist(index + removeCount),
  ];
  return NoteDoc(blocks: blocks, prologue: doc.prologue);
}

/// 表格定位：返回 `(块下标, 表格)`；锚点不是表格 → null（调用方原样返回 doc）。
(int, TableBlock)? _tableAt(NoteDoc doc, BlockRef ref) {
  final i = _indexOf(doc, ref.blockId);
  if (i < 0) return null;
  final b = doc.blocks[i];
  if (b is! TableBlock) return null;
  return (i, b);
}

/// 列表项定位：优先 itemId，其次 itemIndex，最后默认第一项。
///
/// 显式给了 [itemId] 却在列表里找不到 → 返回 -1（宁可不动，也不要悄悄作用到第 0 项上）。
int _itemPos(List<String> ids, String? itemId, int? itemIndex) {
  if (ids.isEmpty) return -1;
  if (itemId != null) {
    final k = ids.indexOf(itemId);
    if (k >= 0) return k;
    if (itemIndex == null) return -1;
    return _clamp(itemIndex, ids.length - 1);
  }
  if (itemIndex != null) return _clamp(itemIndex, ids.length - 1);
  return 0;
}

// ---------------------------------------------------------------------------
// 私有：行内片段切片
// ---------------------------------------------------------------------------

InlineRuns _emptyRuns() => <InlineNode>[const TextRun('')];

/// 取 `[from, to)` 区间对应的行内片段（自动 clamp、保留 marks 与 href）。
InlineRuns _slice(InlineRuns runs, int from, int to) {
  final out = <InlineNode>[];
  var pos = 0;
  for (final node in runs) {
    if (node is! TextRun) continue;
    final start = pos;
    final end = pos + node.text.length;
    pos = end;
    if (end <= from || start >= to) continue;
    final a = start < from ? from - start : 0;
    final b = end > to ? to - start : node.text.length;
    out.add(TextRun(node.text.substring(a, b), marks: node.marks, href: node.href));
  }
  return out;
}

/// 拼接两段行内片段（相邻同格式会归并，空 run 丢弃）。
InlineRuns _concat(InlineRuns a, InlineRuns b) =>
    normalizeRuns(<InlineNode>[...a, ...b]);

int _clamp(int v, int max) {
  if (max < 0) return 0;
  if (v < 0) return 0;
  if (v > max) return max;
  return v;
}

/// 块与下一块之间的分隔：沿用原分隔，空则用标准两空行。
String _gapOf(Block b) => b.trailingGap.isEmpty ? '\n\n' : b.trailingGap;

/// 标题级别：缺省 2 级，始终收敛到 1..6（越界 / 0 都退化成 2 级）。
int _level(int? level) {
  final v = level ?? 2;
  if (v < 1) return 2;
  return v > 6 ? 6 : v;
}

// ---------------------------------------------------------------------------
// 私有：换块类型
// ---------------------------------------------------------------------------

/// 把 [b] 转成 [target]；返回 `null` = 「不可直接转，保持原样」。
///
/// 约定：返回列表里**占用原 id 的那一个就是主块**（T3 靠它维持光标）。
List<Block>? _convert(
  Block b,
  BlockRef at,
  BlockType target,
  int? headingLevel,
  int? itemIndex,
) {
  final gap = b.trailingGap;
  final id = b.id;

  if (b is ParagraphBlock) return _fromRuns(id, gap, b.runs, target, headingLevel);
  if (b is HeadingBlock) return _fromRuns(id, gap, b.runs, target, headingLevel);

  if (b is CodeBlock) {
    if (target == BlockType.code ||
        target == BlockType.table ||
        target == BlockType.divider ||
        target == BlockType.image) {
      return null;
    }
    return _fromRuns(id, gap, <InlineNode>[TextRun(b.code)], target, headingLevel);
  }

  if (b is RawBlock) {
    if (target == BlockType.raw ||
        target == BlockType.table ||
        target == BlockType.divider ||
        target == BlockType.image) {
      return null;
    }
    return _fromRuns(id, gap, <InlineNode>[TextRun(b.text)], target, headingLevel);
  }

  if (b is QuoteBlock) return _liftFromQuote(b, at, target, headingLevel, itemIndex);

  if (b is BulletListBlock) return _liftFromList(_BulletOps(b), at, target, headingLevel);
  if (b is OrderedListBlock) return _liftFromList(_OrderedOps(b), at, target, headingLevel);
  if (b is TaskListBlock) return _liftFromList(_TaskOps(b), at, target, headingLevel);

  // 表格 / 分割线 / 图片：没有可承载的正文载体 → 保持原样。
  return null;
}

/// 由一段行内片段构造目标类型的块。
List<Block>? _fromRuns(
  String id,
  String gap,
  InlineRuns runs,
  BlockType target,
  int? headingLevel,
) {
  switch (target) {
    case BlockType.paragraph:
      return <Block>[ParagraphBlock(id: id, trailingGap: gap, runs: runs)];
    case BlockType.heading:
      return <Block>[
        HeadingBlock(
          id: id,
          trailingGap: gap,
          level: _level(headingLevel),
          runs: runs,
        ),
      ];
    case BlockType.quote:
      return <Block>[
        QuoteBlock(id: id, trailingGap: gap, lines: <InlineRuns>[runs]),
      ];
    case BlockType.bulletList:
      return <Block>[
        BulletListBlock(
          id: id,
          trailingGap: gap,
          items: <ListItem>[ListItem(id: newBlockId('li'), runs: runs)],
        ),
      ];
    case BlockType.orderedList:
      return <Block>[
        OrderedListBlock(
          id: id,
          trailingGap: gap,
          items: <ListItem>[ListItem(id: newBlockId('li'), runs: runs)],
        ),
      ];
    case BlockType.taskList:
      return <Block>[
        TaskListBlock(
          id: id,
          trailingGap: gap,
          items: <TaskItem>[TaskItem(id: newBlockId('ti'), runs: runs)],
        ),
      ];
    case BlockType.code:
      return <Block>[
        CodeBlock(id: id, trailingGap: gap, code: plainTextOf(runs)),
      ];
    case BlockType.raw:
      // RawBlock 按原文进出：把行内格式序列化回 Markdown 字面，避免丢加粗/链接。
      return <Block>[
        RawBlock(id: id, trailingGap: gap, text: serializeInline(runs)),
      ];
    case BlockType.table:
    case BlockType.divider:
    case BlockType.image:
      return null; // 需要行列结构 / assetId / 无文本载体 → 不可直接转
  }
}

/// 引用 → 其它类型：只抬出**被指向的那一行**（默认第一行），其余行留在原引用块里。
///
/// 取舍：引用行没有 id，行号只能由调用方通过 [itemIndex] 给（设计 §5.6 要求「只有光标所在行改变」）。
/// 被抬出的主块**占用原 id**（光标不丢）；残余引用块用新 id，位置按被指向行保持阅读顺序：
/// 首行 → 主块在前、残余在后；非首行 → 残余在前、主块在后。两种排法都让最后一块接管原 `trailingGap`。
List<Block>? _liftFromQuote(
  QuoteBlock b,
  BlockRef at,
  BlockType target,
  int? headingLevel,
  int? itemIndex,
) {
  if (b.lines.isEmpty) return null;
  final li = _clamp(itemIndex ?? 0, b.lines.length - 1);
  final cur = b.lines[li];
  final rest = b.lines.sublist(0, li) + b.lines.sublist(li + 1);

  final primaryGap = rest.isEmpty ? b.trailingGap : (li == 0 ? _gapOf(b) : b.trailingGap);
  final restGap = li == 0 ? b.trailingGap : _gapOf(b);

  final primary = _fromRuns(b.id, primaryGap, cur, target, headingLevel);
  if (primary == null) return null;
  if (rest.isEmpty) return primary;

  final remainder = QuoteBlock(
    id: newBlockId('q'),
    trailingGap: restGap,
    lines: rest,
  );
  return li == 0 ? <Block>[...primary, remainder] : <Block>[remainder, ...primary];
}

/// 列表 → 其它类型：列表内部互转整块保留；转到非列表则抬出被指向的那一项。
List<Block>? _liftFromList(
  _ListOps ops,
  BlockRef at,
  BlockType target,
  int? headingLevel,
) {
  // 1) 列表家族内部互转：整块保留，条目文本与 id 全部复用。
  if (_isListType(target)) {
    return <Block>[ops.retarget(target)];
  }

  final ids = ops.ids;
  if (ids.isEmpty) return null;
  final ii = _itemPos(ids, at.itemId, null);
  if (ii < 0) return null; // 锚点过期（条目已被删）→ 保持原样
  final cur = ops.runsAt(ii);
  final rest = <_Entry>[...ops.entries]..removeAt(ii);

  // ii == 0：主块在前、残余列表在后；ii > 0：残余列表在前、主块在后。
  // 两种排法都要让「最后一块」接管原块的 trailingGap，中间那块用 _gapOf。
  final primaryGap =
      rest.isEmpty ? ops.trailingGap : (ii == 0 ? _gapOf(ops.block) : ops.trailingGap);
  final restGap = ii == 0 ? ops.trailingGap : _gapOf(ops.block);

  final primary = _fromRuns(ops.id, primaryGap, cur, target, headingLevel);
  if (primary == null) return null;
  if (rest.isEmpty) return primary;

  final restBlock = ops.withItems(rest, newBlockId(ops.prefix), restGap);
  return ii == 0 ? <Block>[...primary, restBlock] : <Block>[restBlock, ...primary];
}

bool _isListType(BlockType t) =>
    t == BlockType.bulletList || t == BlockType.orderedList || t == BlockType.taskList;

/// 列表项的中间表示（三种列表共用一套操作，避免三段复制粘贴）。
typedef _Entry = ({String id, InlineRuns runs, bool checked});

/// 列表操作的适配器基类（三个子类只负责「读字段」与「按目标类型重建」）。
abstract class _ListOps {
  _ListOps(this.block);

  final Block block;

  String get id => block.id;
  String get trailingGap => block.trailingGap;
  String get prefix;
  List<_Entry> get entries;

  List<String> get ids => <String>[for (final e in entries) e.id];
  InlineRuns runsAt(int i) => entries[i].runs;

  /// 按剩余项重建同类块（用于「抬出一项，其余仍是列表」）。
  Block withItems(List<_Entry> items, String newId, String gap);

  /// 列表家族内部互转（bullet ⇄ ordered ⇄ task），条目 id 复用。
  Block retarget(BlockType target);
}

class _BulletOps extends _ListOps {
  _BulletOps(BulletListBlock b) : super(b);

  BulletListBlock get _b => block as BulletListBlock;

  @override
  String get prefix => 'ul';

  @override
  List<_Entry> get entries =>
      <_Entry>[for (final it in _b.items) (id: it.id, runs: it.runs, checked: false)];

  @override
  Block withItems(List<_Entry> items, String newId, String gap) => BulletListBlock(
        id: newId,
        trailingGap: gap,
        items: <ListItem>[for (final e in items) ListItem(id: e.id, runs: e.runs)],
      );

  @override
  Block retarget(BlockType target) {
    final items = <ListItem>[
      for (final e in entries) ListItem(id: e.id, runs: e.runs),
    ];
    if (target == BlockType.orderedList) {
      return OrderedListBlock(id: id, trailingGap: trailingGap, items: items);
    }
    return TaskListBlock(
      id: id,
      trailingGap: trailingGap,
      items: <TaskItem>[
        for (final e in entries) TaskItem(id: e.id, runs: e.runs, checked: e.checked),
      ],
    );
  }
}

class _OrderedOps extends _ListOps {
  _OrderedOps(OrderedListBlock b) : super(b);

  OrderedListBlock get _b => block as OrderedListBlock;

  @override
  String get prefix => 'ol';

  @override
  List<_Entry> get entries =>
      <_Entry>[for (final it in _b.items) (id: it.id, runs: it.runs, checked: false)];

  @override
  Block withItems(List<_Entry> items, String newId, String gap) => OrderedListBlock(
        id: newId,
        trailingGap: gap,
        start: _b.start,
        items: <ListItem>[for (final e in items) ListItem(id: e.id, runs: e.runs)],
      );

  @override
  Block retarget(BlockType target) {
    final items = <ListItem>[
      for (final e in entries) ListItem(id: e.id, runs: e.runs),
    ];
    if (target == BlockType.bulletList) {
      return BulletListBlock(id: id, trailingGap: trailingGap, items: items);
    }
    return TaskListBlock(
      id: id,
      trailingGap: trailingGap,
      items: <TaskItem>[
        for (final e in entries) TaskItem(id: e.id, runs: e.runs, checked: e.checked),
      ],
    );
  }
}

class _TaskOps extends _ListOps {
  _TaskOps(TaskListBlock b) : super(b);

  TaskListBlock get _b => block as TaskListBlock;

  @override
  String get prefix => 'tl';

  @override
  List<_Entry> get entries => <_Entry>[
        for (final it in _b.items) (id: it.id, runs: it.runs, checked: it.checked),
      ];

  @override
  Block withItems(List<_Entry> items, String newId, String gap) => TaskListBlock(
        id: newId,
        trailingGap: gap,
        items: <TaskItem>[
          for (final e in items) TaskItem(id: e.id, runs: e.runs, checked: e.checked),
        ],
      );

  @override
  Block retarget(BlockType target) {
    if (target == BlockType.bulletList) {
      return BulletListBlock(
        id: id,
        trailingGap: trailingGap,
        items: <ListItem>[for (final e in entries) ListItem(id: e.id, runs: e.runs)],
      );
    }
    return OrderedListBlock(
      id: id,
      trailingGap: trailingGap,
      items: <ListItem>[for (final e in entries) ListItem(id: e.id, runs: e.runs)],
    );
  }
}

// ---------------------------------------------------------------------------
// 私有：列表回并
// ---------------------------------------------------------------------------

/// 三种列表共用的回并逻辑（三个子类共用一套分支，避免三段复制粘贴）。
({NoteDoc doc, BlockRef caret}) _mergeList3(
  _ListOps ops,
  NoteDoc doc,
  int i,
  BlockRef at,
  int? itemIndex,
) {
  final entries = ops.entries;
  if (entries.isEmpty) return (doc: doc, caret: at);
  final ii = _itemPos(ops.ids, at.itemId, itemIndex);
  if (ii < 0) return (doc: doc, caret: at);

  // 非首项：删本项，文本并入前一项（不跨块）。
  if (ii > 0) {
    final prev = entries[ii - 1];
    final merged = <_Entry>[
      ...entries.sublist(0, ii - 1),
      (id: prev.id, runs: _concat(prev.runs, entries[ii].runs), checked: prev.checked),
      ...entries.sublist(ii + 1),
    ];
    final list = ops.withItems(merged, ops.id, ops.trailingGap);
    return (
      doc: _splice(doc, i, 1, <Block>[list]),
      caret: BlockRef(list.id, itemId: prev.id),
    );
  }

  // 首项：降级为独立段落（内容保留，不与上一块合并）。
  final cur = entries.first.runs;
  final rest = entries.sublist(1);
  if (rest.isEmpty) {
    final para = ParagraphBlock(id: ops.id, trailingGap: ops.trailingGap, runs: cur);
    return (doc: _splice(doc, i, 1, <Block>[para]), caret: BlockRef(para.id));
  }
  final para = ParagraphBlock(id: newBlockId('p'), trailingGap: _gapOf(ops.block), runs: cur);
  final list = ops.withItems(rest, ops.id, ops.trailingGap);
  return (
    doc: _splice(doc, i, 1, <Block>[para, list]),
    caret: BlockRef(para.id),
  );
}

// ---------------------------------------------------------------------------
// 私有：表格辅助
// ---------------------------------------------------------------------------

int _colsOf(TableBlock t) {
  var c = t.aligns.length;
  for (final r in t.rows) {
    if (r.length > c) c = r.length;
  }
  return c;
}

List<InlineRuns> _emptyRow(int cols) =>
    <InlineRuns>[for (var i = 0; i < cols; i++) _emptyRuns()];

/// 所有行补齐到 [cols] 列（短行补空串），保证列数一致。
List<List<InlineRuns>> _padRows(List<List<InlineRuns>> rows, int cols) => <List<InlineRuns>>[
      for (final r in rows)
        <InlineRuns>[...r, for (var k = r.length; k < cols; k++) _emptyRuns()],
    ];

List<TableAlign> _padAligns(List<TableAlign> aligns, int cols) => <TableAlign>[
      ...aligns,
      for (var k = aligns.length; k < cols; k++) TableAlign.none,
    ];

List<List<InlineRuns>> _appendRow(TableBlock t) {
  final cols = _colsOf(t);
  final rows = _padRows(t.rows, cols);
  rows.add(_emptyRow(cols));
  return rows;
}

TableBlock _withRow(TableBlock t, List<List<InlineRuns>> rows) {
  final cols = _colsOf(t);
  return TableBlock(
    id: t.id,
    trailingGap: t.trailingGap,
    hasHeader: t.hasHeader,
    aligns: _padAligns(t.aligns, cols),
    rows: rows,
  );
}
