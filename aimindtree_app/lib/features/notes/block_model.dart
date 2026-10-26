/// 笔记编辑器「所见即所得」改造 —— 块级数据模型（T1 数据层）。
///
/// 设计依据：`docs/NOTE_EDITOR_WYSIWYG_DESIGN.md` §3（核心数据模型）、§4（无损红线）。
///
/// **这个文件管什么**
/// - 文档容器 [NoteDoc] 与块定位句柄 [BlockRef]；
/// - 11 种块类型：段落 / 标题 / 引用 / 无序列表 / 有序列表 / 任务列表 /
///   围栏代码块 / 表格 / 分割线 / 图片 / 原文兜底（[RawBlock]）；
/// - 行内片段模型 [InlineNode]（目前只有 [TextRun]）与位标记 [InlineMarks]；
/// - [AssetResolver] 契约（图片字节解析，供 T3 渲染层使用）。
///
/// **这个文件不管什么**
/// - Markdown 的解析与序列化 → `markdown_block_parser.dart`；
/// - 打字时的格式投影 → `inline_projection.dart`；
/// - 任何 Widget —— 本文件**不 import flutter**，可 100% 纯 Dart 单测。
///
/// **两条必须记住的规矩**
/// 1. [Block.source] 非空 = 「该块尚未被用户编辑」→ 序列化时原文直通（byte-exact）；
///    一旦用户改了内容，就要用构造函数重造该块且**不传 source**，
///    source 变 null → 走规范化序列化（设计 §4 的 L1/L2）。
///    因此本文件的块类**刻意不提供 copyWith**：重造时必须显式决定要不要带 source，
///    避免「改了内容却保留旧原文」这种静默丢编辑的写法。
/// 2. 所有 `==` / `hashCode` **不比较 [Block.id] 与条目 id**。id 只是会话内的 UI 句柄
///    （ValueKey、焦点定位），不是内容；这样「解析两次得到不同 id」的文档仍然内容相等，
///    幂等断言（`structuralEquals`）与 T2/T3 的期望值构造才不会被 id 绊倒。
library;

import 'dart:typed_data';

/// 笔记内嵌图片的 URI 前缀：`![alt](aimindtree-asset://<assetId>)`。
///
/// 说明：`markdown_actions.dart` 里有一个同名常量（本轮该文件「保留不动」，见设计 §8），
/// 两处必须是同一个协议。新代码统一用本常量；旧文件不动。
const String kAssetUrlPrefix = 'aimindtree-asset://';

/// 把 assetId 解析成图片字节；`null` = 缺失 / 未同步。
///
/// 从 `markdown_render.dart` 上移到这里（设计 §6.5），`markdown_render.dart` 用
/// `export ... show AssetResolver` 再导出，老 import 方式零改动。
typedef AssetResolver = Future<Uint8List?> Function(String assetId);

/// 块 id 的自增序号（会话内唯一即可，不跨会话保证）。
int _idSeq = 0;

/// 生成会话内唯一的块 id；[prefix] 只是便于调试时看出块类型（`'p_3'`、`'h_7'`…）。
String newBlockId(String prefix) => '${prefix}_${_idSeq++}';

/// 块类型枚举（供 UI 层 `switch` 分流、工具栏禁用态判定使用）。
enum BlockType {
  paragraph,
  heading,
  quote,
  bulletList,
  orderedList,
  taskList,
  code,
  table,
  divider,
  image,
  raw,
}

// ---------------------------------------------------------------------------
// 行内片段模型
// ---------------------------------------------------------------------------

/// 行内节点（扁平序列，设计 §3.2 选定的方案 C）。
///
/// 目前只有 [TextRun] 一种：行内图片**不建模**（设计 §3.2 R6），
/// 解析阶段遇到 `![…](aimindtree-asset://id)` 会把段落切成「段 / 图 / 段」。
sealed class InlineNode {
  const InlineNode();
}

/// 行内片段序列（一个块的一行 / 一个单元格 / 一个列表项的正文）。
typedef InlineRuns = List<InlineNode>;

/// 行内格式的位标记（粗 / 斜 / 行内代码 / 删除线）。
///
/// 用 int 位域而非一组 bool：等值比较与 `|` / `-` 合并只要一行，
/// 且 [TextRun] 的 `==` 直接比较 bits 即可。
class InlineMarks {
  const InlineMarks._(this.bits);

  static const InlineMarks none = InlineMarks._(0);
  static const InlineMarks bold = InlineMarks._(1);
  static const InlineMarks italic = InlineMarks._(2);
  static const InlineMarks code = InlineMarks._(4);
  static const InlineMarks strike = InlineMarks._(8);

  /// 粗 + 斜（`***x***`）。
  static const InlineMarks boldItalic = InlineMarks._(3);

  final int bits;

  /// 没有任何格式。
  bool get isEmpty => bits == 0;

  /// 是否**全部**包含 [m] 的位（`has(InlineMarks.none)` 恒为 true）。
  bool has(InlineMarks m) => (bits & m.bits) == m.bits;

  bool get isBold => has(bold);
  bool get isItalic => has(italic);
  bool get isCode => has(code);
  bool get isStrike => has(strike);

  InlineMarks operator |(InlineMarks other) => InlineMarks._(bits | other.bits);

  InlineMarks operator -(InlineMarks other) => InlineMarks._(bits & ~other.bits);

  InlineMarks operator &(InlineMarks other) => InlineMarks._(bits & other.bits);

  @override
  bool operator ==(Object other) => other is InlineMarks && other.bits == bits;

  @override
  int get hashCode => bits;

  @override
  String toString() => 'Marks($bits)';
}

/// 文本片段。[text] 是**纯文本**，绝不含 Markdown 标记字符（设计 §3.2）。
class TextRun extends InlineNode {
  const TextRun(this.text, {this.marks = InlineMarks.none, this.href});

  final String text;

  /// 粗 / 斜 / 码 / 删除线 的按位组合。
  final InlineMarks marks;

  /// 非空 = 链接；渲染时 [text] 即链接文案（R5：`[**粗链接**](url)` 退化成
  /// 「一个同时带 bold 与 href 的 run」，无损且不必建模嵌套）。
  final String? href;

  bool get isLink => href != null;

  /// 改内容用（无 source 概念，可放心复制）。
  TextRun copyWith({String? text, InlineMarks? marks, String? href}) => TextRun(
        text ?? this.text,
        marks: marks ?? this.marks,
        href: href ?? this.href,
      );

  @override
  bool operator ==(Object other) =>
      other is TextRun &&
      other.text == text &&
      other.marks == marks &&
      other.href == href;

  @override
  int get hashCode => Object.hash(text, marks, href);

  @override
  String toString() =>
      'TextRun(m:${marks.bits}${href == null ? '' : ',href:$href'},"$text")';
}

/// 行内片段的纯文本（= 编辑态 `TextField` 里显示的内容）。
///
/// 放在 block_model 而非 inline_projection，是因为解析/序列化层也要用它
/// （例如「空段落」判定），而按设计 §2.2 的分层铁律，解析层不应依赖投影层。
/// `inline_projection.dart` 会再导出本符号，按文档从那里 import 也可以。
String plainTextOf(InlineRuns runs) {
  final sb = StringBuffer();
  for (final node in runs) {
    switch (node) {
      case TextRun(:final text):
        sb.write(text);
    }
  }
  return sb.toString();
}

/// 归并相邻同格式片段，丢弃空文本片段。
///
/// 保证「纯文本长度 == 各 run 文本长度之和」便于 assert（设计 §3.4）；
/// 也保证序列化时不会把相邻同格式 run 拆成多段标记，避免 `*a**b*` 这类噪声输出。
InlineRuns normalizeRuns(InlineRuns runs) {
  final out = <InlineNode>[];
  for (final node in runs) {
    if (node is TextRun) {
      if (node.text.isEmpty) continue;
      final last = out.isNotEmpty ? out.last : null;
      if (last is TextRun && last.marks == node.marks && last.href == node.href) {
        out[out.length - 1] = TextRun('${last.text}${node.text}', marks: node.marks, href: node.href);
      } else {
        out.add(node);
      }
    } else {
      out.add(node);
    }
  }
  return out;
}

/// 两个行内片段序列是否内容相等。
bool runsEqual(InlineRuns a, InlineRuns b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// 文档容器与定位句柄
// ---------------------------------------------------------------------------

/// 笔记文档 = 顶层块序列 + 原文「前言空白」。
///
/// [prologue] 是正文开头那些纯空白行（可能没有），序列化时原样拼回去，
/// 这是 `serializeDoc(parseMarkdownDoc(md)) == md` 字节级恒等的一半保障
/// （另一半是每个块的 `source` + `trailingGap`）。
class NoteDoc {
  const NoteDoc({required this.blocks, this.prologue = ''});

  final List<Block> blocks;

  /// 正文开头的纯空白行。
  final String prologue;

  /// 空文档：一个空段落（序列化回 `''`，不会落库成空行垃圾，见设计 §3.3 R1）。
  factory NoteDoc.empty() => NoteDoc(blocks: <Block>[ParagraphBlock.empty()]);

  NoteDoc copyWith({List<Block>? blocks, String? prologue}) =>
      NoteDoc(blocks: blocks ?? this.blocks, prologue: prologue ?? this.prologue);

  @override
  String toString() => 'NoteDoc(${blocks.length} blocks, prologue:${prologue.length})';
}

/// 块定位句柄（列表组块内部还要能定位到 item）。
class BlockRef {
  const BlockRef(this.blockId, {this.itemId});

  final String blockId;

  /// 列表 / 任务列表的条目 id（非列表块为 null）。
  final String? itemId;

  @override
  bool operator ==(Object other) =>
      other is BlockRef && other.blockId == blockId && other.itemId == itemId;

  @override
  int get hashCode => Object.hash(blockId, itemId);

  @override
  String toString() => 'BlockRef($blockId${itemId == null ? '' : '/$itemId'})';
}

/// 两个文档是否「结构相等」（忽略所有 id，只看类型 / 内容 / source / 间隔）。
///
/// 用途：设计 §4 的 L2 幂等断言 `structuralEquals(parse(s), parse(serialize(parse(s))))`。
bool structuralEquals(NoteDoc a, NoteDoc b) {
  if (a.prologue != b.prologue) return false;
  if (a.blocks.length != b.blocks.length) return false;
  for (var i = 0; i < a.blocks.length; i++) {
    if (a.blocks[i] != b.blocks[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// 块
// ---------------------------------------------------------------------------

/// 块基类。
///
/// **不提供 copyWith**：改内容请用子类的构造函数重造（见文件头注释第 1 条）。
sealed class Block {
  const Block({this.id = '', this.source, this.trailingGap = '\n\n'});

  /// 会话内稳定的 id，UI 层用作 `ValueKey`。不参与 `==`（见文件头注释第 2 条）。
  final String id;

  /// 解析时的原文片段（不含块间分隔符）。
  ///
  /// non-null = 「未被编辑」→ 序列化时原文直通（L1，byte-exact）；
  /// null = 「被用户改过 / 用户新建」→ 走规范化序列化（L2）。
  /// 这是设计 §4 无损红线的落点。
  final String? source;

  /// 本块与下一块之间的原始分隔（`''` / `'\n'` / `'\n\n'`…），保证整篇 byte-exact。
  /// 最后一块的这个字段承载「文末的空白」。
  final String trailingGap;

  BlockType get type;

  /// 该块的正文能否就地当文本编辑。
  ///
  /// false = 图片 / 分割线 / RawBlock —— 它们不是「不能编辑」，而是有**别的**
  /// 编辑入口（图片：替换/删除；Raw：等宽原文框，见设计 §4.1 L3）。
  bool get textEditable => true;
}

/// 段落（可含软换行 `\n`）。
class ParagraphBlock extends Block {
  const ParagraphBlock({
    super.id,
    super.source,
    super.trailingGap,
    this.runs = const <InlineNode>[],
  });

  final InlineRuns runs;

  factory ParagraphBlock.empty() => ParagraphBlock(id: newBlockId('p'));

  @override
  BlockType get type => BlockType.paragraph;

  @override
  bool operator ==(Object other) =>
      other is ParagraphBlock &&
      other.source == source &&
      other.trailingGap == trailingGap &&
      runsEqual(other.runs, runs);

  @override
  int get hashCode => Object.hash(source, trailingGap, Object.hashAll(runs));

  @override
  String toString() => 'Paragraph("${plainTextOf(runs)}")';
}

/// 标题（1~6 级）。
class HeadingBlock extends Block {
  const HeadingBlock({
    super.id,
    super.source,
    super.trailingGap,
    this.level = 1,
    this.runs = const <InlineNode>[],
  });

  final int level;
  final InlineRuns runs;

  factory HeadingBlock.empty({int level = 2}) =>
      HeadingBlock(id: newBlockId('h'), level: level);

  @override
  BlockType get type => BlockType.heading;

  @override
  bool operator ==(Object other) =>
      other is HeadingBlock &&
      other.level == level &&
      other.source == source &&
      other.trailingGap == trailingGap &&
      runsEqual(other.runs, runs);

  @override
  int get hashCode => Object.hash(level, source, trailingGap, Object.hashAll(runs));

  @override
  String toString() => 'H$level("${plainTextOf(runs)}")';
}

/// 引用（连续若干 `>` 行合并成一块）。
class QuoteBlock extends Block {
  const QuoteBlock({
    super.id,
    super.source,
    super.trailingGap,
    this.lines = const <InlineRuns>[],
  });

  /// 每个元素对应一行 `>` 的正文。
  final List<InlineRuns> lines;

  factory QuoteBlock.empty() => QuoteBlock(
        id: newBlockId('q'),
        lines: <InlineRuns>[<InlineNode>[const TextRun('')]],
      );

  @override
  BlockType get type => BlockType.quote;

  @override
  bool operator ==(Object other) =>
      other is QuoteBlock &&
      other.source == source &&
      other.trailingGap == trailingGap &&
      _runsListEqual(other.lines, lines);

  @override
  int get hashCode =>
      Object.hash(source, trailingGap, Object.hashAll(<Object>[for (final l in lines) Object.hashAll(l)]));

  @override
  String toString() => 'Quote(${lines.length} lines)';
}

/// 列表项（无序 / 有序共用）。
class ListItem {
  const ListItem({this.id = '', this.runs = const <InlineNode>[]});

  /// 条目 id（组块内部定位用）；不参与 `==`。
  final String id;
  final InlineRuns runs;

  ListItem copyWith({String? id, InlineRuns? runs}) =>
      ListItem(id: id ?? this.id, runs: runs ?? this.runs);

  @override
  bool operator ==(Object other) => other is ListItem && runsEqual(other.runs, runs);

  @override
  int get hashCode => Object.hashAll(runs);

  @override
  String toString() => 'ListItem("${plainTextOf(runs)}")';
}

/// 任务列表项（`- [ ] ` / `- [x] `）。
class TaskItem {
  const TaskItem({this.id = '', this.runs = const <InlineNode>[], this.checked = false});

  /// 条目 id（组块内部定位用）；不参与 `==`。
  final String id;
  final InlineRuns runs;
  final bool checked;

  TaskItem copyWith({String? id, InlineRuns? runs, bool? checked}) => TaskItem(
        id: id ?? this.id,
        runs: runs ?? this.runs,
        checked: checked ?? this.checked,
      );

  @override
  bool operator ==(Object other) =>
      other is TaskItem && other.checked == checked && runsEqual(other.runs, runs);

  @override
  int get hashCode => Object.hash(checked, Object.hashAll(runs));

  @override
  String toString() => 'TaskItem(${checked ? 'x' : ' '},"${plainTextOf(runs)}")';
}

/// 无序列表（`- ` / `* ` / `+ `）。
class BulletListBlock extends Block {
  const BulletListBlock({
    super.id,
    super.source,
    super.trailingGap,
    this.items = const <ListItem>[],
  });

  final List<ListItem> items;

  factory BulletListBlock.empty() => BulletListBlock(
        id: newBlockId('ul'),
        items: <ListItem>[ListItem(id: newBlockId('li'))],
      );

  @override
  BlockType get type => BlockType.bulletList;

  @override
  bool operator ==(Object other) =>
      other is BulletListBlock &&
      other.source == source &&
      other.trailingGap == trailingGap &&
      _itemsEqual(other.items, items);

  @override
  int get hashCode => Object.hash(source, trailingGap, Object.hashAll(items));

  @override
  String toString() => 'BulletList(${items.length} items)';
}

/// 有序列表（`n. `，沿用作者写的起始编号）。
class OrderedListBlock extends Block {
  const OrderedListBlock({
    super.id,
    super.source,
    super.trailingGap,
    this.start = 1,
    this.items = const <ListItem>[],
  });

  final int start;
  final List<ListItem> items;

  factory OrderedListBlock.empty() => OrderedListBlock(
        id: newBlockId('ol'),
        items: <ListItem>[ListItem(id: newBlockId('li'))],
      );

  @override
  BlockType get type => BlockType.orderedList;

  @override
  bool operator ==(Object other) =>
      other is OrderedListBlock &&
      other.start == start &&
      other.source == source &&
      other.trailingGap == trailingGap &&
      _itemsEqual(other.items, items);

  @override
  int get hashCode => Object.hash(start, source, trailingGap, Object.hashAll(items));

  @override
  String toString() => 'OrderedList($start,${items.length} items)';
}

/// 任务列表（`- [ ] ` / `- [x] `）。
class TaskListBlock extends Block {
  const TaskListBlock({
    super.id,
    super.source,
    super.trailingGap,
    this.items = const <TaskItem>[],
  });

  final List<TaskItem> items;

  factory TaskListBlock.empty() => TaskListBlock(
        id: newBlockId('tl'),
        items: <TaskItem>[TaskItem(id: newBlockId('ti'))],
      );

  @override
  BlockType get type => BlockType.taskList;

  @override
  bool operator ==(Object other) =>
      other is TaskListBlock &&
      other.source == source &&
      other.trailingGap == trailingGap &&
      _taskItemsEqual(other.items, items);

  @override
  int get hashCode => Object.hash(source, trailingGap, Object.hashAll(items));

  @override
  String toString() => 'TaskList(${items.length} items)';
}

/// 围栏代码块（语言标注必须往返保留，见设计 §3.3 R4）。
class CodeBlock extends Block {
  const CodeBlock({
    super.id,
    super.source,
    super.trailingGap,
    this.language = '',
    this.code = '',
  });

  final String language;
  final String code;

  factory CodeBlock.empty() => CodeBlock(id: newBlockId('c'));

  @override
  BlockType get type => BlockType.code;

  @override
  bool operator ==(Object other) =>
      other is CodeBlock &&
      other.language == language &&
      other.code == code &&
      other.source == source &&
      other.trailingGap == trailingGap;

  @override
  int get hashCode => Object.hash(language, code, source, trailingGap);

  @override
  String toString() => 'Code($language,${code.length} chars)';
}

/// 表格列对齐（GFM）。
enum TableAlign { none, left, center, right }

/// 表格（GFM：`| a | b |` + `| --- | --- |`）。
class TableBlock extends Block {
  const TableBlock({
    super.id,
    super.source,
    super.trailingGap,
    this.hasHeader = true,
    this.aligns = const <TableAlign>[],
    this.rows = const <List<InlineRuns>>[],
  });

  /// 首行是否为表头（解析出来的表格恒为 true）。
  final bool hasHeader;

  final List<TableAlign> aligns;

  /// 首行是表头行；[aligns] 与列数对齐。
  final List<List<InlineRuns>> rows;

  /// 建一张 `rows × cols` 的空表（工具栏「插入表格」用）。
  factory TableBlock.empty({int rows = 2, int cols = 2}) => TableBlock(
        id: newBlockId('tb'),
        aligns: List<TableAlign>.filled(cols, TableAlign.none),
        rows: <List<InlineRuns>>[
          for (var r = 0; r < rows; r++)
            <InlineRuns>[
              for (var c = 0; c < cols; c++) <InlineNode>[const TextRun('')],
            ],
        ],
      );

  @override
  BlockType get type => BlockType.table;

  @override
  bool operator ==(Object other) =>
      other is TableBlock &&
      other.hasHeader == hasHeader &&
      other.source == source &&
      other.trailingGap == trailingGap &&
      _alignsEqual(other.aligns, aligns) &&
      _rowsEqual(other.rows, rows);

  @override
  int get hashCode => Object.hash(
        hasHeader,
        source,
        trailingGap,
        Object.hashAll(aligns),
        Object.hashAll(<Object>[for (final r in rows) Object.hashAll(<Object>[for (final c in r) Object.hashAll(c)])]),
      );

  @override
  String toString() => 'Table(${rows.length}x${aligns.length})';
}

/// 分割线（`---` / `***` / `___`）。
class DividerBlock extends Block {
  const DividerBlock({super.id, super.source, super.trailingGap});

  @override
  BlockType get type => BlockType.divider;

  /// 没有正文可就地编辑（替换/删除走块级动作）。
  @override
  bool get textEditable => false;

  @override
  bool operator ==(Object other) =>
      other is DividerBlock && other.source == source && other.trailingGap == trailingGap;

  @override
  int get hashCode => Object.hash(BlockType.divider, source, trailingGap);

  @override
  String toString() => 'Divider()';
}

/// 图片块（**一图独占一行**，设计 §3.2 R6：行内图片在解析阶段被切开）。
class ImageBlock extends Block {
  const ImageBlock({
    super.id,
    super.source,
    super.trailingGap,
    required this.assetId,
    this.alt = '',
  });

  /// 附件 id（正文里只放 `aimindtree-asset://<assetId>` 短引用）。
  final String assetId;

  /// 替代文本（缺失图片的占位文案）。
  final String alt;

  /// 回填进 Markdown 的 URI。
  String get uri => '$kAssetUrlPrefix$assetId';

  @override
  BlockType get type => BlockType.image;

  /// 图片正文不可就地编辑（替换 / 删除走「别的编辑入口」）。
  @override
  bool get textEditable => false;

  @override
  bool operator ==(Object other) =>
      other is ImageBlock &&
      other.assetId == assetId &&
      other.alt == alt &&
      other.source == source &&
      other.trailingGap == trailingGap;

  @override
  int get hashCode => Object.hash(assetId, alt, source, trailingGap);

  @override
  String toString() => 'Image($assetId,"$alt")';
}

/// 原文兜底块（L3 消防通道）。
///
/// 解析器对某段**完全无法建模**或解析抛异常时，整段原文装进来；
/// 编辑态是等宽纯文本框 + 「此块含不支持格式」提示条 —— **字符一个都不能少**。
class RawBlock extends Block {
  const RawBlock({super.id, super.source, super.trailingGap, this.text = ''});

  /// 原文（原样进出，序列化不做任何加工）。
  final String text;

  @override
  BlockType get type => BlockType.raw;

  /// 走「别的编辑入口」：等宽框里按原文编辑（见类注释）。
  @override
  bool get textEditable => false;

  @override
  bool operator ==(Object other) =>
      other is RawBlock &&
      other.text == text &&
      other.source == source &&
      other.trailingGap == trailingGap;

  @override
  int get hashCode => Object.hash(text, source, trailingGap);

  @override
  String toString() => 'Raw(${text.length} chars)';
}

// ---------------------------------------------------------------------------
// 私有：列表内容比较（都不比较 id）
// ---------------------------------------------------------------------------

bool _runsListEqual(List<InlineRuns> a, List<InlineRuns> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!runsEqual(a[i], b[i])) return false;
  }
  return true;
}

bool _itemsEqual(List<ListItem> a, List<ListItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _taskItemsEqual(List<TaskItem> a, List<TaskItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _alignsEqual(List<TableAlign> a, List<TableAlign> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _rowsEqual(List<List<InlineRuns>> a, List<List<InlineRuns>> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_runsListEqual(a[i], b[i])) return false;
  }
  return true;
}
