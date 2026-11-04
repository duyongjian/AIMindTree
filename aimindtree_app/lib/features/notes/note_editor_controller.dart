/// 笔记编辑器「所见即所得」改造 —— 控制层（T3）。
///
/// 设计依据：`docs/NOTE_EDITOR_WYSIWYG_DESIGN.md` §5（编辑交互规格）、§7（保存与脏标记）。
///
/// **这个文件管什么**
/// - [NoteDoc] 的唯一可变持有者 [NoteEditorController]：解析 / 序列化缓存、活动行
///   （[BlockRef]）、每行 `TextEditingController` / `FocusNode` 的注册与释放；
/// - 块级编辑原语：改文本（含行内格式投影）、Enter 分裂、两级退格、换类型、
///   任务勾选、插入图片 / 表格 / 分割线、表格单元格写入；
/// - 编辑态富文本的入口 [RichLineController]（覆写 `buildTextSpan`，
///   让编辑态里加粗 / 斜体 / 行内代码 / 删除线**照样带样式**，但看不到任何 Markdown 符号）。
///
/// **这个文件不管什么**
/// - 任何具体块的视觉（字号 / 间距 / 配色）→ `block_view.dart`；
/// - 滚动容器与按键路由的挂载 → `note_editor_body.dart`；
/// - 工具栏按钮与页面接线 → T4（`markdown_toolbar.dart` / `note_editor_page.dart`）。
///
/// **与 T2 `block_actions.dart` 的关系（T5a 已收敛）**
/// 块级语义（Enter 分裂 / 行首退格回并 / 换类型 / 任务勾选 / 表格增删行列）
/// **只有一份实现**：`block_actions.dart` 里的纯函数 `splitBlock` / `mergeBackward` /
/// `setBlockType` / `toggleTaskItem` / `insertTableRow|removeTableRow|insertTableColumn|
/// removeTableColumn`。本文件只负责：
/// 1. **行引用与 caret 映射**（`BlockRef` ↔ 块内某一行，含引用行 `'q:<n>'` 的换算）；
/// 2. **焦点编排**（改完之后点哪个输入框、光标落在第几个字符）；
/// 3. 富文本行控制器 / 序列化缓存 / `notifyListeners`。
///
/// 少数 block_actions 未覆盖（或语义与设计 §5.4 / §5.6 不一致）的边界仍留在本文件，
/// 每处都有注释说明原因（引用非首行退格、引用「按光标行」换类型、表格单元格跳格）。
///
/// **L1 字节直通（红线）**
/// `setMarkdown(md)` 后 `markdown == md`（`\r\n` 归一化后逐字节相等）：
/// 未编辑的块靠 [Block.source] 原文直通，只有被用户改过的块才走规范化序列化。
/// 这同时根治「打开没改却变脏」与「同步假冲突」。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart' show Colors, FontStyle, FontWeight, TextDecoration, TextStyle;
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter/widgets.dart';

import 'block_actions.dart' as actions;
import 'block_model.dart';
import 'inline_projection.dart';
import 'markdown_block_parser.dart';

// ---------------------------------------------------------------------------
// 行引用（BlockRef）编码：多行块内部怎么定位到「某一行」
// ---------------------------------------------------------------------------

/// 引用块第 [index] 行的行引用（`itemId = 'q:<index>'`）。
///
/// 设计 §5.4 / §5.6 要求「引用多行时只降级/分裂光标所在那一行」，
/// 但 [QuoteBlock] 的每行没有自己的 id（不像列表有 [ListItem.id]），
/// 因此这里用行号编码成 [BlockRef.itemId]，避免给冻结的模型加字段。
BlockRef quoteLineRef(String blockId, int index) => BlockRef(blockId, itemId: 'q:$index');

/// 表格第 [row] 行第 [col] 列单元格的行引用（`itemId = 't:<row>:<col>'`）。
BlockRef tableCellRef(String blockId, int row, int col) =>
    BlockRef(blockId, itemId: 't:$row:$col');

/// 解析 [quoteLineRef] 编码；不是引用行则返回 null。
int? quoteLineIndexOf(BlockRef ref) {
  final id = ref.itemId;
  if (id == null || !id.startsWith('q:')) return null;
  return int.tryParse(id.substring(2));
}

/// 解析 [tableCellRef] 编码；不是单元格则返回 null。
(int, int)? tableCellOf(BlockRef ref) {
  final id = ref.itemId;
  if (id == null || !id.startsWith('t:')) return null;
  final parts = id.substring(2).split(':');
  if (parts.length != 2) return null;
  final r = int.tryParse(parts[0]);
  final c = int.tryParse(parts[1]);
  if (r == null || c == null) return null;
  return (r, c);
}

/// 一个块里所有「可就地编辑的行」的引用（顺序 == 视觉顺序）。
///
/// 图片 / 分割线没有行（它们走块级入口）；表格每个单元格一行。
List<BlockRef> editableRefsOf(Block block) {
  switch (block) {
    case ParagraphBlock():
    case HeadingBlock():
    case CodeBlock():
    case RawBlock():
      return <BlockRef>[BlockRef(block.id)];
    case QuoteBlock(:final lines):
      return <BlockRef>[for (var i = 0; i < lines.length; i++) quoteLineRef(block.id, i)];
    case BulletListBlock(:final items):
    case OrderedListBlock(:final items):
      return <BlockRef>[for (final it in items) BlockRef(block.id, itemId: it.id)];
    case TaskListBlock(:final items):
      return <BlockRef>[for (final it in items) BlockRef(block.id, itemId: it.id)];
    case TableBlock(:final rows):
      return <BlockRef>[
        for (var r = 0; r < rows.length; r++)
          for (var c = 0; c < rows[r].length; c++) tableCellRef(block.id, r, c),
      ];
    case DividerBlock():
    case ImageBlock():
      return const <BlockRef>[];
  }
}

/// 取 [runs] 中字符区间 `[from, to)` 的片段（越界自动 clamp，空区间返回空列表）。
///
/// 与 `inline_projection.dart` 里的私有切片同语义；这里是 T3 自己的入口，
/// T4 起可改用 `block_actions.dart` 的公开版本。
InlineRuns sliceRuns(InlineRuns runs, int from, int to) {
  final total = plainTextOf(runs).length;
  final a = from.clamp(0, total);
  final b = to.clamp(0, total);
  if (a >= b) return const <InlineNode>[];
  final out = <InlineNode>[];
  var pos = 0;
  for (final node in runs) {
    if (node is! TextRun) continue;
    final start = pos;
    final end = pos + node.text.length;
    pos = end;
    if (end <= a) continue;
    if (start >= b) break;
    final s = start < a ? a - start : 0;
    final e = end > b ? b - start : node.text.length;
    out.add(TextRun(node.text.substring(s, e), marks: node.marks, href: node.href));
  }
  return normalizeRuns(out);
}

// ---------------------------------------------------------------------------
// 编辑态的「一行」控制器
// ---------------------------------------------------------------------------

/// 编辑态单行的 `TextEditingController`：文本是**纯文本**，
/// 样式由覆写的 [buildTextSpan] 按 [runs] 逐段套回来（设计 §5.2）。
///
/// 两条必须记住的防御（设计 §12 的 R-1 / R-2）：
/// 1. 长度钳制：`runs` 可能落后文本一帧（`onChanged` 之前 Flutter 已用旧 runs
///    渲染过新文本），逐段切分时越界一律回退到 base 样式，**绝不允许 RangeError**；
/// 2. 输入法组字期（`composing.isValid && !isCollapsed`）整体回退父类实现，
///    避免拼音组字过程中样式错位 / 错字。
class RichLineController extends TextEditingController {
  RichLineController({
    required this.base,
    InlineRuns runs = const <InlineNode>[],
    String? text,
  })  : runs = runs,
        super(text: text ?? plainTextOf(runs));

  /// 本行的基础样式（段落 14 号 / 标题分级字号 / 代码等宽…）。
  TextStyle base;

  /// 本行的行内格式片段；纯文本长度应与 [text] 一致（允许一帧滞后）。
  InlineRuns runs;

  /// 由**变更动作**调用：替换 runs 并立即重绘（会 notify）。
  ///
  /// 注意：`build` 期间同步 runs 请用 [syncRunsQuiet] —— 在 build 里 notify
  /// 会触发「setState during build」。
  void applyRuns(InlineRuns next) {
    final normalized = normalizeRuns(next);
    if (runsEqual(runs, normalized)) return;
    runs = normalized;
    notifyListeners();
  }

  /// 由**构建**调用：静默替换 runs（本轮 rebuild 就会用上新样式）。
  void syncRunsQuiet(InlineRuns next) {
    final normalized = normalizeRuns(next);
    if (runsEqual(runs, normalized)) return;
    runs = normalized;
  }

  void setBaseQuiet(TextStyle next) {
    if (base == next) return;
    base = next;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // 0) 组字期回退父类：中文输入法优先正确性。
    if (withComposing && value.composing.isValid && !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final text = value.text;
    final merged = (style ?? const TextStyle()).merge(base);
    if (text.isEmpty) return TextSpan(text: '', style: merged);

    final children = <InlineSpan>[];
    var pos = 0;
    for (final node in runs) {
      if (pos >= text.length) break;
      if (node is! TextRun) continue;
      final end = math.min(pos + node.text.length, text.length);
      if (end <= pos) continue;
      // 用「真实文本」而不是 run.text 切片：长度不一致的那一帧也不会 RangeError，
      // 且字符永远是用户刚敲进去的那一份（样式可能慢半拍，内容绝不会错）。
      children.add(TextSpan(
        text: text.substring(pos, end),
        style: richStyleForMarks(node.marks, merged, href: node.href),
      ));
      pos = end;
    }
    // 1) 钳制收尾：runs 覆盖不到的尾巴一律按 base 样式渲染。
    if (pos < text.length) {
      children.add(TextSpan(text: text.substring(pos), style: merged));
    }
    return TextSpan(style: merged, children: children);
  }
}

/// 行内位标记 → 具体 `TextStyle`（只读态与编辑态共用同一套映射，视觉零跳变）。
TextStyle richStyleForMarks(InlineMarks marks, TextStyle base, {String? href}) {
  var s = base;
  if (marks.isCode) {
    s = s.copyWith(
      fontFamily: 'monospace',
      backgroundColor: Colors.grey.shade200,
    );
  }
  if (marks.isBold) s = s.copyWith(fontWeight: FontWeight.bold);
  if (marks.isItalic) s = s.copyWith(fontStyle: FontStyle.italic);
  if (marks.isStrike) s = s.copyWith(decoration: TextDecoration.lineThrough);
  if (href != null) {
    s = s.copyWith(
      color: Colors.blue.shade700,
      decoration: TextDecoration.underline,
    );
  }
  return s;
}

// ---------------------------------------------------------------------------
// 控制器
// ---------------------------------------------------------------------------

/// 笔记正文的状态机（设计 §5.1）：READ ⇄ EDIT(block=n)。
///
/// 用法（T4 接线口径）：
/// ```dart
/// final c = NoteEditorController();
/// c.setMarkdown(row.contentMd);   // 加载
/// // UI: AnimatedBuilder(animation: c, builder: … NoteEditorBody(controller: c))
/// // 保存: repo.saveNote(Note(contentMd: c.markdown))
/// ```
class NoteEditorController extends ChangeNotifier {
  factory NoteEditorController({String markdown = '', AssetResolver? resolveAsset}) {
    final doc = parseMarkdownDoc(markdown);
    return NoteEditorController._(
      doc: doc,
      markdown: serializeDoc(doc),
      resolveAsset: resolveAsset,
    );
  }

  NoteEditorController._({
    required NoteDoc doc,
    required String markdown,
    AssetResolver? resolveAsset,
  })  : _doc = doc,
        _markdown = markdown,
        _resolveAsset = resolveAsset;

  // ===== 公开状态 =====

  /// 当前文档（不可变视图；任何变更都会换新实例并 notify）。
  NoteDoc get doc => _doc;

  /// 当前正文的 Markdown 纯文本（**序列化缓存**，每次变更时重算）。
  ///
  /// 未编辑过的块走 `source` 原文直通，因此「加载 → 不做任何事」时
  /// 它与加载时的输入逐字节相同（设计 §4 L1）。
  String get markdown => _markdown;

  /// 当前活动行（null = READ 态）。
  BlockRef? get active => _active;

  /// 是否处于编辑态。
  bool get isEditing => _active != null;

  /// 当前活动块（可能为 null）。
  Block? get activeBlock {
    final ref = _active;
    return ref == null ? null : blockOf(ref);
  }

  /// 工具栏上下文用的「活动块」：失焦后仍回退到**最后编辑过**的块，
  /// 使桌面端点工具栏时按钮不置灰（否则 `_active` 被清空的瞬间按钮变
  /// disabled，点击被吞 —— 即桌面端加粗 / 改标题失效的根因之一）。
  Block? get toolbarActiveBlock {
    final ref = _active ?? _lastActiveRef;
    return ref == null ? null : blockOf(ref);
  }

  /// 工具栏上下文用的「是否支持行内格式」（见 [toolbarActiveBlock]）。
  bool get toolbarSupportsInlineMarks =>
      toolbarActiveBlock != null && _supportsInlineMarks(toolbarActiveBlock!);

  /// 活动块或最后编辑过的块（供需要在失焦后仍拿到行引用的入口，如链接对话框）。
  BlockRef? get activeOrLast => _active ?? _lastActiveRef;

  /// 无选区时点工具栏攒下的待生效格式（设计 §6.1「按钮呈按下态」）。
  InlineMarks get pendingMarks => _pending;

  /// 图片字节解析器（可后设，null = 一律当缺失，渲染成「图片未同步」）。
  AssetResolver? get resolveAsset => _resolveAsset;
  set resolveAsset(AssetResolver? value) {
    if (identical(_resolveAsset, value)) return;
    _resolveAsset = value;
    _notify();
  }

  // ===== 内部状态 =====

  NoteDoc _doc;
  String _markdown;
  BlockRef? _active;
  InlineMarks _pending = InlineMarks.none;

  /// 最后一次编辑的块引用：失焦（桌面端点工具栏瞬间）后 [_active] 会被清空，
  /// 但格式化动作应能回退到它，避免「点了没反应」（桌面端加粗 / 改标题失效修复）。
  BlockRef? _lastActiveRef;

  /// 失焦前记录的最后有效（非折叠）选区，按块引用存：桌面端点工具栏会让选区
  /// 塌缩成光标，保住它才能对「刚选中的文字」加格式。
  final Map<BlockRef, TextSelection> _lastSelectionByRef =
      <BlockRef, TextSelection>{};

  AssetResolver? _resolveAsset;

  /// 每行一个 `TextEditingController`（设计 §10.7 第 4 条：由本类统一 dispose）。
  final Map<BlockRef, RichLineController> _lines = <BlockRef, RichLineController>{};

  /// 每行一个 `FocusNode`（同上）。
  final Map<BlockRef, FocusNode> _nodes = <BlockRef, FocusNode>{};

  /// 已失效但还不能立刻 dispose 的行（对应 Widget 要到下一帧才消失）。
  final Set<BlockRef> _stale = <BlockRef>{};

  /// 程序性写 controller 时的重入闸（阻止 onChanged 自我递归）。
  bool _applying = false;

  /// Shift+Enter 的软换行标记（由 `note_editor_body` 的按键观察器置位）。
  bool _softBreak = false;

  bool _disposed = false;

  /// [InlineMarks] 的全部单标记（用于 pendingMarks 逐位应用）。
  static const List<InlineMarks> _kSingleMarks = <InlineMarks>[
    InlineMarks.bold,
    InlineMarks.italic,
    InlineMarks.code,
    InlineMarks.strike,
  ];

  // ===== 加载 / 序列化 =====

  /// 加载一篇笔记（Markdown → 块模型）。
  ///
  /// 语义与 `note_editor_page._load()` 对齐：**先**同步页面自己的 `_lastBody`
  /// **再**调用本方法，这样不会误标脏。
  void setMarkdown(String md) {
    _flushStale();
    _doc = parseMarkdownDoc(md);
    _markdown = serializeDoc(_doc);
    _active = null;
    _pending = InlineMarks.none;
    _disposeLines();
    _notify();
  }

  /// [setMarkdown] 的同义入口（任务书里叫 `load`，设计文档里叫 `setMarkdown`）。
  void load(String md) => setMarkdown(md);

  // ===== 焦点 / 选中 =====

  /// 聚焦某一行；[caret] 为行内字符偏移（默认行首）。
  ///
  /// 换类型不改文本时调用方传同一个 `caret`，即可做到「光标严格不变」（设计 §5.6）。
  void focusBlock(BlockRef ref, {int? caret}) {
    if (!_isValidRef(ref)) return;
    _active = ref;
    _lastActiveRef = ref;
    final ctrl = lineControllerFor(ref);
    final c = (caret ?? 0).clamp(0, ctrl.text.length);
    ctrl.selection = TextSelection.collapsed(offset: c);
    focusNodeFor(ref).requestFocus();
    _pending = InlineMarks.none;
    _notify();
  }

  /// 退出编辑态（回到 READ）。
  void blur() {
    final ref = _active;
    _active = null;
    if (ref != null) {
      final node = _nodes[ref];
      if (node != null && node.hasFocus) node.unfocus();
    }
    _notify();
  }

  /// 某一行当前的选区（未创建过控制器 → null）。
  TextSelection? selectionOf(BlockRef ref) => _lines[ref]?.selection;

  /// 某一行当前的光标偏移（无控制器 / 选区非法 → 0）。
  int caretOf(BlockRef ref) {
    final ctrl = _lines[ref];
    final sel = ctrl?.selection;
    if (sel == null || !sel.isValid) return 0;
    return sel.extentOffset <= 0 ? 0 : sel.extentOffset;
  }

  /// 活动行选区里的文字（无选区 → ''）。
  String selectionText() {
    final ref = _active;
    if (ref == null) return '';
    final ctrl = _lines[ref];
    if (ctrl == null) return '';
    final text = ctrl.text;
    final sel = ctrl.selection;
    if (!sel.isValid) return '';
    final a = sel.start < 0 ? 0 : sel.start.clamp(0, text.length);
    final b = sel.end < 0 ? 0 : sel.end.clamp(0, text.length);
    return a >= b ? '' : text.substring(a, b);
  }

  /// 活动行是否有非空选区（工具栏「有选区 → 直接格式化」的判据）。
  bool get hasSelection => selectionText().isNotEmpty;

  // ===== 行控制器注册表 =====

  /// 取（必要时创建）某一行的富文本控制器。
  ///
  /// **必须在 build 里调用**：只做静默同步（不 notify），否则会
  /// 「setState during build」。文本 / runs 的变更由各个 mutation 方法负责。
  RichLineController lineControllerFor(
    BlockRef ref, {
    TextStyle base = const TextStyle(fontSize: 14, height: 1.5),
  }) {
    final existing = _lines[ref];
    if (existing != null) {
      existing.setBaseQuiet(base);
      existing.syncRunsQuiet(runsOf(ref));
      return existing;
    }
    final runs = runsOf(ref);
    final ctrl = RichLineController(
      base: base,
      runs: runs,
      text: plainTextOf(runs),
    );
    _lines[ref] = ctrl;
    focusNodeFor(ref);
    return ctrl;
  }

  /// 取（必要时创建）某一行的焦点节点。
  ///
  /// 失焦即回到 READ 态（设计 §5.1「失焦 / 点其它块 / 点空白」）；
  /// 只有「当前活动行」失焦才清 active，避免焦点转移瞬间把新活动行也清掉。
  FocusNode focusNodeFor(BlockRef ref) => _nodes.putIfAbsent(ref, () {
        final node = FocusNode(debugLabel: 'note-line:$ref');
        node.addListener(() {
          if (node.hasFocus) {
            if (_active != ref) {
              _active = ref;
              _lastActiveRef = ref;
              _notify();
            }
            return;
          }
          if (_active == ref) {
            // 桌面端点工具栏会让 TextField 失焦且选区塌缩：清 active 前先记下
            // 最后选区与最后编辑块，供工具栏的加粗 / 改样式在失焦后仍能生效。
            final sel = _lines[ref]?.selection;
            if (sel != null && sel.isValid && !sel.isCollapsed) {
              _lastSelectionByRef[ref] = sel;
            }
            _lastActiveRef = ref;
            _active = null;
            _notify();
          }
        });
        return node;
      });

  // ===== 读取 =====

  /// 块引用 → 块（找不到 → null）。
  Block? blockOf(BlockRef ref) => _blockById(ref.blockId);

  /// 某一行的纯文本（编辑态 `TextField` 显示的内容）。
  String textOf(BlockRef ref) {
    final b = _blockById(ref.blockId);
    if (b == null) return '';
    switch (b) {
      case ParagraphBlock(:final runs):
      case HeadingBlock(:final runs):
        return plainTextOf(runs);
      case QuoteBlock(:final lines):
        final i = quoteLineIndexOf(ref);
        if (i == null || i >= lines.length) return '';
        return plainTextOf(lines[i]);
      case BulletListBlock(:final items):
        final i = _itemIndex(items, ref.itemId);
        return i < 0 ? '' : plainTextOf(items[i].runs);
      case OrderedListBlock(:final items):
        final i = _itemIndex(items, ref.itemId);
        return i < 0 ? '' : plainTextOf(items[i].runs);
      case TaskListBlock(:final items):
        final i = _taskIndex(items, ref.itemId);
        return i < 0 ? '' : plainTextOf(items[i].runs);
      case CodeBlock(:final code):
        return code;
      case TableBlock(:final rows):
        final rc = tableCellOf(ref);
        if (rc == null || rc.$1 >= rows.length || rc.$2 >= rows[rc.$1].length) {
          return '';
        }
        return plainTextOf(rows[rc.$1][rc.$2]);
      case RawBlock(:final text):
        return text;
      case DividerBlock():
      case ImageBlock():
        return '';
    }
  }

  /// 某一行的行内片段（代码 / 原文块用单 run 包一层，方便统一处理）。
  InlineRuns runsOf(BlockRef ref) {
    final b = _blockById(ref.blockId);
    if (b == null) return const <InlineNode>[];
    switch (b) {
      case ParagraphBlock(:final runs):
      case HeadingBlock(:final runs):
        return runs;
      case QuoteBlock(:final lines):
        final i = quoteLineIndexOf(ref);
        if (i == null || i >= lines.length) return const <InlineNode>[];
        return lines[i];
      case BulletListBlock(:final items):
        final i = _itemIndex(items, ref.itemId);
        return i < 0 ? const <InlineNode>[] : items[i].runs;
      case OrderedListBlock(:final items):
        final i = _itemIndex(items, ref.itemId);
        return i < 0 ? const <InlineNode>[] : items[i].runs;
      case TaskListBlock(:final items):
        final i = _taskIndex(items, ref.itemId);
        return i < 0 ? const <InlineNode>[] : items[i].runs;
      case CodeBlock(:final code):
        return code.isEmpty ? const <InlineNode>[] : <InlineNode>[TextRun(code)];
      case TableBlock(:final rows):
        final rc = tableCellOf(ref);
        if (rc == null || rc.$1 >= rows.length || rc.$2 >= rows[rc.$1].length) {
          return const <InlineNode>[];
        }
        return rows[rc.$1][rc.$2];
      case RawBlock(:final text):
        return text.isEmpty ? const <InlineNode>[] : <InlineNode>[TextRun(text)];
      case DividerBlock():
      case ImageBlock():
        return const <InlineNode>[];
    }
  }

  /// 活动行是否支持行内格式（代码块 / 表格 / 原文 / 图片 / 分割线不支持，
  /// 工具栏据此置灰 —— 设计 §5.5 第 2 条）。
  bool get activeSupportsInlineMarks {
    final b = activeBlock;
    return b != null && _supportsInlineMarks(b);
  }

  /// 某个块是否支持行内格式（无活动行时的判据也存在 → 抽成静态）。
  static bool _supportsInlineMarks(Block b) =>
      b is ParagraphBlock ||
      b is HeadingBlock ||
      b is QuoteBlock ||
      b is BulletListBlock ||
      b is OrderedListBlock ||
      b is TaskListBlock;

  /// 当前形状下 [mark] 是否算「已打开」（有选区看全选区，无选区看 pending）。
  bool isMarkOn(InlineMarks mark) {
    final ref = _active;
    if (ref == null) return _pending.has(mark);
    final sel = _lines[ref]?.selection;
    if (sel == null || !sel.isValid || sel.isCollapsed) return _pending.has(mark);
    return _isMarkOnWith(mark, ref, sel);
  }

  /// 对指定 [sel]（而非当前实时选区）判定 [mark] 是否全开；供 [toggleMark]
  /// 在桌面端点工具栏导致实时选区塌缩后，用失焦前记录的最后选区判定。
  bool _isMarkOnWith(InlineMarks mark, BlockRef ref, TextSelection sel) {
    final text = textOf(ref);
    final a = sel.start.clamp(0, text.length);
    final b = sel.end.clamp(0, text.length);
    if (a >= b) return _pending.has(mark);
    var pos = 0;
    var all = true;
    for (final node in runsOf(ref)) {
      if (node is! TextRun) continue;
      final start = pos;
      final end = pos + node.text.length;
      pos = end;
      if (end <= a || start >= b) continue;
      if (!node.marks.has(mark)) all = false;
    }
    return all;
  }

  // ===== 文本变更（TextField.onChanged 的唯一入口） =====

  /// `TextField.onChanged` 的统一入口。
  ///
  /// 三条分支（设计 §5.3 的实现口径：**不做原生按键拦截**，靠 onChanged 判定）：
  /// 1. 插入单个 `\n` 且不是 Shift+Enter → 先撤掉 `\n`，再执行语义化「回车」；
  /// 2. 代码块 / 原文块的回车 → 就是软换行（末空行再回车则退出代码块）；
  /// 3. 其它（打字 / 删除 / 粘贴 / Shift+Enter）→ 行内格式投影。
  void onLineChanged(BlockRef ref, String newText) {
    if (_applying) return;
    final b = blockOf(ref);
    if (b == null) return;

    final old = textOf(ref);
    if (old == newText) {
      _notify();
      return;
    }

    final p = _commonPrefixLength(old, newText);
    final singleNewline = newText.length == old.length + 1 &&
        p < newText.length &&
        newText.codeUnitAt(p) == 0x0A;

    // 表格单元格：GFM 单元格里不能有换行 → 回车 = 跳到下一格，粘贴多行降级成空格。
    if (b is TableBlock) {
      if (newText.contains('\n')) {
        if (singleNewline) {
          _writeLineValue(ref, old, caret: p);
          _enterTable(ref);
          return;
        }
        final sanitized = newText.replaceAll('\n', ' ');
        _writeLineValue(ref, sanitized, caret: sanitized.length);
        newText = sanitized;
      }
      _applyText(ref, old, newText, p);
      return;
    }

    // 多行粘贴（带 `\n` 但不是「单个回车」）：必须按行拆成独立段落块。
    // 若把 `\n` 原样写进同一块的 runs，序列化只会吐出**单换行**，parser 的
    // 「段落懒续行」(P3) 会把相邻行并回同一段 → 保存重开后「每一段都连着下一段」。
    // 代码块 / 原文块的换行是内容本身；多行块（引用/列表）另有行结构，都不在这里拆。
    final multiLinePaste = !singleNewline &&
        newText.contains('\n') &&
        b is! CodeBlock &&
        b is! RawBlock &&
        b is! QuoteBlock &&
        b is! BulletListBlock &&
        b is! OrderedListBlock &&
        b is! TaskListBlock;
    if (multiLinePaste) {
      _pasteMultiline(ref, newText);
      return;
    }

    final soft = _softBreak || HardwareKeyboard.instance.isShiftPressed;
    if (singleNewline && !soft && b is! CodeBlock && b is! RawBlock) {
      _writeLineValue(ref, old, caret: p);
      _handleEnter(ref, p);
      return;
    }

    _softBreak = false;
    _applyText(ref, old, newText, p);

    // 代码块：在最后一个空行上再回车（连续两个换行）→ 退出代码块成段落。
    if (b is CodeBlock && newText.endsWith('\n\n')) {
      _exitCodeBlock(ref, newText);
    }
  }

  /// `Shift+Enter` 的软换行标记（由 `note_editor_body` 的按键观察器置位）。
  ///
  /// `onChanged` 到达时 `HardwareKeyboard` 一般还能读到 Shift，但部分平台 /
  /// 输入法会先松键 → 这条标记是兜底（设计 §5.3 的 R-7）。
  void markSoftBreak() => _softBreak = true;

  // ===== 行内格式 =====

  /// 加粗 / 斜体 / 行内代码 / 删除线的开关（工具栏入口）。
  ///
  /// - 有选区 → 立即对该区间加/取消该 mark（`applyMark`）；
  /// - 无选区 → 只是翻转 [pendingMarks]（后续输入的字符自动带上该样式）。
  void toggleMark(InlineMarks mark) {
    final ref = _active ?? _lastActiveRef;
    if (ref == null) return;
    final blk = blockOf(ref);
    if (blk == null || !_supportsInlineMarks(blk)) return;
    final text = textOf(ref);
    var sel = _lines[ref]?.selection;
    if (sel == null || !sel.isValid || sel.isCollapsed) {
      // 桌面端点工具栏瞬间选区塌缩：回退到失焦前记录的最后选区。
      final last = _lastSelectionByRef[ref];
      if (last != null && last.isValid && !last.isCollapsed) sel = last;
    }
    if (sel == null || !sel.isValid || sel.isCollapsed) {
      _pending = _pending.has(mark) ? _pending - mark : _pending | mark;
      _notify();
      return;
    }
    final a = math.min(sel.start, sel.end).clamp(0, text.length);
    final b = math.max(sel.start, sel.end).clamp(0, text.length);
    if (a >= b) return;
    final on = !_isMarkOnWith(mark, ref, sel);
    final next = applyMark(runsOf(ref), a, b, mark, on: on);
    _pending = InlineMarks.none;
    _setRunsFor(ref, next);
    // 保活 + 保留选区：把焦点还给这一行，并把选区还原成 [a,b]。
    // 桌面端点工具栏会令 TextField 失焦、选区塌缩；这里先还原 [a,b]，失焦
    // 监听就能把 [a,b] 记进 _lastSelectionByRef，用户再点一次仍可切换 / 去格式。
    // 即便焦点没丢（如单元测试直接连点两次、或键盘快捷键 Ctrl+B），保留的 [a,b]
    // 选区也让第二次 toggle 能正确识别「已加粗」并去掉格式。
    focusBlock(ref, caret: b);
    lineControllerFor(ref).selection = TextSelection(baseOffset: a, extentOffset: b);
    _notify();
    _reassertFocusPostFrame(ref, b);
  }

  /// 清空待生效格式（点空白 / 换块时用）。
  void clearPendingMarks() {
    if (_pending.isEmpty) return;
    _pending = InlineMarks.none;
    _notify();
  }

  /// 给选区（或光标处）挂链接；[label] 为空时只把 href 挂到选中文字上。
  ///
  /// 有选区：把选中文字整段替换成「[label] 带 href」的一个 run（内容以用户
  /// 在对话框里确认的文案为准，所以可能改字，这是链接的固有语义）；
  /// 无选区：在光标处插入 [label]。
  void setLink(String label, String url) {
    final ref = _active;
    if (ref == null) return;
    setLinkOn(ref, label, url);
  }

  /// 给**指定行**挂链接（工具栏「链接」对话框的落点）。
  ///
  /// 为什么需要它：对话框会抢走焦点 → [active] 变 null，[setLink] 的 active
  /// 口径在那一刻拿不到行引用。调用方在弹框**之前**记下 [ref] 与选区区间，
  /// 确认后用它显式写回（[start] / [end] 为空时退回该行当前选区）。
  void setLinkOn(BlockRef ref, String label, String url, {int? start, int? end}) {
    final b = blockOf(ref);
    if (b == null || !_supportsInlineMarks(b)) return;
    final text = textOf(ref);
    final sel = _lines[ref]?.selection;
    final hasSel = sel != null && sel.isValid && !sel.isCollapsed;
    final int a;
    final int bEnd;
    if (start != null || end != null) {
      a = (start ?? 0).clamp(0, text.length);
      bEnd = (end ?? a).clamp(a, text.length);
    } else if (hasSel) {
      a = math.min(sel.start, sel.end).clamp(0, text.length);
      bEnd = math.max(sel.start, sel.end).clamp(0, text.length);
    } else {
      a = caretOf(ref).clamp(0, text.length);
      bEnd = a;
    }
    final word = label.isEmpty && a < bEnd ? text.substring(a, bEnd) : label;
    final marks = a < bEnd ? _marksAt(text, runsOf(ref), a) : _pending;
    final inserted = <InlineNode>[
      TextRun(word, marks: marks - InlineMarks.code, href: url),
    ];
    final next = <InlineNode>[
      ...sliceRuns(runsOf(ref), 0, a),
      ...inserted,
      ...sliceRuns(runsOf(ref), bEnd, text.length),
    ];
    _setRunsFor(ref, next);
    final caret = a + word.length;
    _lines[ref]?.selection = TextSelection.collapsed(offset: caret);
    _pending = InlineMarks.none;
  }

  // ===== 块类型转换 =====

  /// 把活动行转成 [type]（标题带 [level]）。
  ///
  /// 「同类型再点一次 → 回落段落」的 toggle 语义在这里落地（设计 §6.1）。
  /// 只改类型不改文本 → `caret` 严格不变（设计 §5.6）。
  void convertActiveTo(BlockType type, {int level = 1}) {
    final ref = _active ?? _lastActiveRef;
    if (ref == null) return;
    final b = blockOf(ref);
    if (b == null) return;
    if (b is TableBlock || b is ImageBlock || b is DividerBlock) return;

    final sameType = b.type == type &&
        (type != BlockType.heading || (b is HeadingBlock && b.level == level));
    final target = sameType ? BlockType.paragraph : type;
    _convert(ref, b, target, level);
  }

  /// 「代码块」按钮：代码块 → 段落，其它 → 代码块。
  ///
  /// 必须用 [toolbarActiveBlock] 而非 [activeBlock]：点工具栏瞬间活动行已失焦
  /// （[active] 被清空，见 [toolbarActiveBlock] 的注释），但工具栏启用判定用的是
  /// 回退到「最后编辑块」的口径；此处若还用 [activeBlock] 会因 null 提前 return，
  /// 表现为「点了没反应」（桌面端代码块按钮失效的根因）。
  void convertActiveToCode() {
    final b = toolbarActiveBlock;
    if (b == null) return;
    convertActiveTo(b is CodeBlock ? BlockType.paragraph : BlockType.code);
  }

  // ===== Enter 分裂 / 退格 =====

  /// 语义化回车（在活动行光标处）。
  void splitActive() {
    final ref = _active;
    if (ref == null) return;
    _handleEnter(ref, caretOf(ref));
  }

  /// 行首退格（Notion 式两级：先降级、再合并）。返回 true = 已消费该按键。
  ///
  /// 语义全在 `block_actions.mergeBackward`：列表非首项并项 / 列表首项降级成段落 /
  /// 标题降级 / 段落并入上一块（上一块不可拼接就删掉它）/ 代码块与原文块降级 /
  /// 引用首行降级、引用非首行并入上一行。
  /// 这里只做「哪些块不走回并」的分流与「改完聚焦哪一行、光标落哪」。
  bool backspaceAtStart() {
    final ref = _active;
    if (ref == null) return false;
    final b = blockOf(ref);
    if (b == null) return false;

    switch (b) {
      case TableBlock():
      case DividerBlock():
      case ImageBlock():
        // 单元格空：不跨单元格合并，也不跨块（设计 §5.4 最后一行）。
        return false;
      case ParagraphBlock():
      case HeadingBlock():
      case QuoteBlock():
      case BulletListBlock():
      case OrderedListBlock():
      case TaskListBlock():
      case CodeBlock():
      case RawBlock():
        break;
    }

    // 引用行的行号在 `BlockRef.itemId`（`'q:<n>'`）里，`mergeBackward` 要的是下标参数
    // → 取出行号走 `itemIndex`（把 `'q:1'` 当 itemId 传会静默失效）。
    final lineIndex = b is QuoteBlock ? quoteLineIndexOf(ref) : null;

    final mergedText = textOf(ref);
    final result = actions.mergeBackward(_doc, ref, itemIndex: lineIndex);
    if (identical(result.doc, _doc)) return false;
    _commit(result.doc);

    final target = _rowRefFor(b, lineIndex, result.caret);
    focusBlock(target, caret: _caretInMergedRow(target, mergedText));
    return true;
  }

  /// 把 `mergeBackward` 返回的 caret 翻成控制器要求的行引用。
  ///
  /// 引用块没有行 id，`block_actions` 只能返回块级 ref，两种情况落点不同：
  /// - **段落并入引用块** → 内容落在末行；
  /// - **引用第 n 行（n>0）并进上一行** → 光标应落在 n-1 行。
  /// 其余情形返回的已经是有效行引用，原样透传。
  BlockRef _rowRefFor(Block before, int? lineIndex, BlockRef caret) {
    if (_isValidRef(caret)) return caret;
    final b = _blockById(caret.blockId);
    if (b is QuoteBlock && b.lines.isNotEmpty) {
      final li = lineIndex;
      if (before is QuoteBlock && li != null && li > 0) {
        return quoteLineRef(caret.blockId, li - 1);
      }
      return quoteLineRef(caret.blockId, b.lines.length - 1);
    }
    return caret;
  }

  /// 回并之后光标落在哪一行的第几个字符。
  ///
  /// 只有「拼到上一行末尾」的情形才落在拼接处（= 回并后长度 − 被并入的文本长度）；
  /// 「成为新末行 / 新末项」一律落在行首。判据：拼接后该行一定以被并入文本结尾且
  /// 更长；而「新末行 / 新末项」的内容就是被并入的文本本身（长度相等）→ 不会误判。
  int _caretInMergedRow(BlockRef target, String mergedText) {
    final rowText = textOf(target);
    if (mergedText.isEmpty) return rowText.length;
    if (rowText.length > mergedText.length && rowText.endsWith(mergedText)) {
      return rowText.length - mergedText.length;
    }
    return 0;
  }

  // ===== 插入 =====

  /// 在活动块之后插入图片块（工具栏「插入图片」的落点，设计 §6.1）。
  void insertImageBlock(String assetId, {String alt = ''}) {
    final block = ImageBlock(id: newBlockId('img'), assetId: assetId, alt: alt);
    _insertAfterActive(block);
  }

  /// 插入 `rows × cols` 空表格，并聚焦第一个单元格。
  ///
  /// 行列数会 clamp 到 `[1, 50]`（`0` 行列会序列化成空串「隐形表」）。
  void insertTableBlock({int rows = 2, int cols = 2}) {
    final int r = TableBlock.clampSize(rows);
    final int c = TableBlock.clampSize(cols);
    final block = TableBlock.empty(rows: r, cols: c);
    final index = _insertAfterActive(block);
    if (index < 0) return;
    focusBlock(tableCellRef(block.id, 0, 0));
  }

  /// 插入分割线，并在其后补一个空段落（否则用户没有一个「能点的地方」）。
  void insertDividerBlock() {
    final divider = DividerBlock(id: newBlockId('hr'));
    final index = _insertAfterActive(divider);
    if (index < 0) return;
    final para = ParagraphBlock(id: newBlockId('p'), runs: const <InlineNode>[]);
    _insertBlockAt(index + 1, para);
    focusBlock(BlockRef(para.id));
  }

  /// 点整个滚动区底部空白：追加一个空段落并聚焦（设计 §5.1「永不出现死区」）。
  void appendParagraphAndFocus() {
    final blocks = _doc.blocks;
    final last = blocks.isEmpty ? null : blocks.last;
    if (last is ParagraphBlock &&
        last.source == null &&
        plainTextOf(last.runs).isEmpty) {
      focusBlock(BlockRef(last.id));
      return;
    }
    final para = ParagraphBlock(id: newBlockId('p'), runs: const <InlineNode>[]);
    _insertBlockAt(blocks.length, para);
    focusBlock(BlockRef(para.id));
  }

  // ===== 任务列表 =====

  /// 勾选 / 取消勾选一个任务项（点 Checkbox 直接生效，无需进编辑态）。
  void toggleTaskItem(BlockRef ref) {
    final b = blockOf(ref);
    if (b is! TaskListBlock) return;
    final i = _taskIndex(b.items, ref.itemId);
    if (i < 0) return;
    final next = actions.toggleTaskItem(
      _doc,
      ref,
      b.items[i].id,
      !b.items[i].checked,
    );
    if (identical(next, _doc)) return;
    _commit(next);
  }

  // ===== 表格 =====

  /// 表格末尾追加一行（Enter 在最后一格时调用；也供 T5 的表格工具条复用）。
  ///
  /// 结构变更（含列数与 `aligns` 补齐）走 `block_actions.insertTableRow`；
  /// 聚焦留给调用方（`_enterTable` 要聚焦到新行首格）。
  void appendTableRow(BlockRef ref) {
    final b = blockOf(ref);
    if (b is! TableBlock) return;
    final next = actions.insertTableRow(_doc, ref, b.rows.length - 1);
    if (identical(next, _doc)) return;
    _commit(next);
  }

  /// 在表格第 [row] 行**下方**插入一行（表格工具条「+行」）。
  ///
  /// 越界由 `block_actions.insertTableRow` clamp 到末行之后；无变化直接返回。
  /// 结构变更（列数与 `aligns` 补齐）全在纯函数里，这里只负责取块 + 提交。
  void insertTableRowAfter(String tableId, int row) {
    final ref = BlockRef(tableId);
    final b = blockOf(ref);
    if (b is! TableBlock) return;
    final next = actions.insertTableRow(_doc, ref, row);
    if (identical(next, _doc)) return;
    _commit(next);
  }

  /// 删除表格第 [row] 行（工具条「-行」）。只剩一行 / 越界 → 纯函数原样返回。
  void removeTableRowAt(String tableId, int row) {
    final ref = BlockRef(tableId);
    final b = blockOf(ref);
    if (b is! TableBlock) return;
    final next = actions.removeTableRow(_doc, ref, row);
    if (identical(next, _doc)) return;
    _commit(next);
    _blurIfActiveInvalid();
  }

  /// 在表格第 [col] 列**右侧**插入一列（工具条「+列」；`aligns` 同步补 `none`）。
  void insertTableColumnAfter(String tableId, int col) {
    final ref = BlockRef(tableId);
    final b = blockOf(ref);
    if (b is! TableBlock) return;
    final next = actions.insertTableColumn(_doc, ref, col);
    if (identical(next, _doc)) return;
    _commit(next);
  }

  /// 删除表格第 [col] 列（工具条「-列」）。只剩一列 / 越界 → 原样返回。
  void removeTableColumnAt(String tableId, int col) {
    final ref = BlockRef(tableId);
    final b = blockOf(ref);
    if (b is! TableBlock) return;
    final next = actions.removeTableColumn(_doc, ref, col);
    if (identical(next, _doc)) return;
    _commit(next);
    _blurIfActiveInvalid();
  }

  /// 删除整个表格块（工具条「删除表格」）。
  ///
  /// 直接整块从文档移除；`_replaceRange` → `_normalize` 会给留下相邻块补 `\n`，
  /// 保证序列化后不会和邻块粘成一行（同 `_insertBlockAt` 的防粘连语义）。
  void deleteTableBlock(String tableId) {
    final idx = _indexOfBlock(tableId);
    if (idx < 0) return;
    final BlockRef? a = _active;
    if (a != null && a.blockId == tableId) blur();
    _replaceRange(idx, 1, const <Block>[]);
  }

  /// 活动行因结构变更（删行/删列）失效时退出编辑态，避免悬空引用。
  void _blurIfActiveInvalid() {
    final BlockRef? a = _active;
    if (a != null && !_isValidRef(a)) blur();
  }

  // ===== 文本写回（内部） =====

  /// 普通输入：`projectRuns` 投影 + pendingMarks 落到新插入的字符上。
  void _applyText(BlockRef ref, String old, String newText, int prefix) {
    var next = projectRuns(old, runsOf(ref), newText);
    if (!_pending.isEmpty) {
      final suffix = _commonSuffixLength(old, newText, prefix);
      final lo = prefix.clamp(0, newText.length);
      final hi = (newText.length - suffix).clamp(lo, newText.length);
      if (hi > lo) {
        for (final mark in _kSingleMarks) {
          if (_pending.has(mark)) {
            next = applyMark(next, lo, hi, mark, on: true);
          }
        }
      }
    }
    _setRunsFor(ref, next);
  }

  /// 用 [runs] 替换某一行并提交（`source` 变 null → 走规范化序列化）。
  void _setRunsFor(BlockRef ref, InlineRuns runs) {
    final b = blockOf(ref);
    if (b == null) return;
    final idx = _indexOfBlock(b.id);
    if (idx < 0) return;
    final normalized = normalizeRuns(runs);
    _replaceRange(idx, 1, <Block>[_blockWithRuns(b, ref, normalized)]);
    // 编辑态立刻看到加粗等效果（同一帧）：控制器的 span 需要跟着换。
    _lines[ref]?.applyRuns(normalized);
  }

  /// 程序性写回某一行的文本（撤掉多敲的 `\n`、表格换行降级成空格等），
  /// 不会触发 `onChanged`（Flutter 只在用户交互时回调）。
  void _writeLineValue(BlockRef ref, String text, {int? caret}) {
    final ctrl = _lines[ref];
    if (ctrl == null) return;
    _applying = true;
    final c = (caret ?? text.length).clamp(0, text.length);
    ctrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: c),
    );
    _applying = false;
  }

  /// 多行粘贴 → 逐行拆成独立段落块，块间用 `\n\n` 分隔。
  ///
  /// 首块沿用原块类型与 id（标题粘贴后仍是标题、活动行引用不失效），其余新建段落。
  /// 粘贴文本按**原样**存成 TextRun（不跑 `parseInline`），避免把纯文本里的
  /// `*`/`_` 之类误解析成行内标记而吞掉字符。
  void _pasteMultiline(BlockRef ref, String newText) {
    final idx = _indexOfBlock(ref.blockId);
    if (idx < 0) return;
    final old = _doc.blocks[idx];

    // 粘贴里的空行只表达「段落分隔」，不产生空块（否则 '\n\n' 会多出一个空段落，
    // 连续空行更会造出一串空块）。空行直接跳过，非空行各自成一个段落。
    final parts = <String>[
      for (final line in newText.split('\n'))
        if (line.trim().isNotEmpty) line,
    ];
    if (parts.isEmpty) parts.add('');

    final inserts = <Block>[];
    for (var i = 0; i < parts.length; i++) {
      final isLast = i == parts.length - 1;
      final gap = isLast ? old.trailingGap : '\n\n';
      final runs = parts[i].isEmpty
          ? const <InlineNode>[]
          : <InlineNode>[TextRun(parts[i])];
      if (i == 0) {
        inserts.add(_withGap(_blockWithRuns(old, ref, runs), gap));
      } else {
        inserts.add(ParagraphBlock(
          id: newBlockId('p'),
          trailingGap: gap,
          runs: runs,
        ));
      }
    }
    _replaceRange(idx, 1, inserts);
    focusBlock(BlockRef(inserts.last.id), caret: parts.last.length);
  }

  // ===== 回车语义 =====

  /// 语义化回车（在活动行光标处）。
  ///
  /// 块级语义**全部**在 `block_actions.splitBlock`（段落 / 标题 / 引用 / 三类列表 /
  /// 代码块 / 表格 / 图片 / 分割线的分支都在那边，只此一份实现）。
  /// 这里只做三件事：分流「不该分裂的块」、喂对 `caretOffset` / `itemIndex`、
  /// 决定改完聚焦哪一行。
  void _handleEnter(BlockRef ref, int caret) {
    final b = blockOf(ref);
    if (b == null) return;

    switch (b) {
      case TableBlock():
        // Enter 在表格里是「跳到下一格」，只有到表尾才追加行；`splitBlock` 的表格分支
        // 只会「追加一行」（T2 也把单元格跳格标为控制器职责）→ 这一小块留在本地。
        _enterTable(ref);
        return;
      case CodeBlock():
      case RawBlock():
        // 代码块 / 原文块的换行就是软换行（`onLineChanged` 已直接接受）；
        // 代码块的「末空行退出」走 [_exitCodeBlock]，不从这里分裂。
        return;
      case ParagraphBlock():
      case HeadingBlock():
      case QuoteBlock():
      case BulletListBlock():
      case OrderedListBlock():
      case TaskListBlock():
      case DividerBlock():
      case ImageBlock():
        break;
    }

    // 引用行的行号编码在 `BlockRef.itemId`（`'q:<n>'`）里，而 `splitBlock` 要的是下标
    // 参数 → 必须把行号取出来走 `itemIndex`（把 `'q:2'` 当 itemId 传会静默失效）。
    // 列表项的 itemId 是真 id，`splitBlock` 自己就能定位，不需要 itemIndex。
    final lineIndex = b is QuoteBlock ? quoteLineIndexOf(ref) : null;

    final result = actions.splitBlock(
      _doc,
      ref,
      caretOffset: caret,
      itemIndex: lineIndex,
    );
    if (identical(result.doc, _doc)) return;
    _commit(result.doc);
    focusBlock(_splitTargetOf(b, lineIndex, result.caret));
  }

  /// 分裂后该聚焦哪一行。
  ///
  /// 段落 / 标题 / 列表 / 图片 / 分割线：`splitBlock` 返回的就是新行引用，直接用。
  /// 引用行是唯一例外 —— 多行块没有行 id，`splitBlock` 只能给「块级」ref，这里按
  /// 「新行紧跟原行」补成行引用（原行是空行时该行已退出引用，返回的 caret 本身有效）。
  BlockRef _splitTargetOf(Block before, int? lineIndex, BlockRef caret) {
    if (before is QuoteBlock && !_isValidRef(caret)) {
      return quoteLineRef(before.id, (lineIndex ?? 0) + 1);
    }
    return caret;
  }

  /// 表格：光标跳下一单元格；最后一行最后一格 → 追加一行。
  void _enterTable(BlockRef ref) {
    final b = blockOf(ref);
    if (b is! TableBlock) return;
    final rc = tableCellOf(ref);
    if (rc == null) return;
    final cols = _columnCount(b);
    if (rc.$2 + 1 < cols) {
      focusBlock(tableCellRef(b.id, rc.$1, rc.$2 + 1));
      return;
    }
    if (rc.$1 + 1 < b.rows.length) {
      focusBlock(tableCellRef(b.id, rc.$1 + 1, 0));
      return;
    }
    appendTableRow(ref);
    focusBlock(tableCellRef(b.id, b.rows.length, 0));
  }

  /// 代码块：末空行再回车 → 退出代码块，下方补一个段落。
  ///
  /// `_applyText` 已经把那个多余的 `\n` 提交进 `code`；这里交给 `splitBlock` 的
  /// 代码块分支去掉它并补段落。输入框里多出来的换行由 `_commit → _syncLineControllers`
  /// 收回（不再手工 `_writeLineValue`，避免与输入法组字打架）。
  void _exitCodeBlock(BlockRef ref, String text) {
    final b = blockOf(ref);
    if (b is! CodeBlock) return;
    final result = actions.splitBlock(_doc, ref, caretOffset: text.length);
    if (identical(result.doc, _doc)) return;
    _commit(result.doc);
    focusBlock(result.caret);
  }

  // ===== 换类型 =====

  void _convert(BlockRef ref, Block b, BlockType target, int level) {
    final caret = caretOf(ref);
    // 引用行的行号同样只能通过 `itemIndex` 传（`'q:<n>'` 不是真 itemId）：
    // 设计 §5.6 要求「只有光标所在行改变」，其它行留在残余引用块里。
    final lineIndex = b is QuoteBlock ? quoteLineIndexOf(ref) : null;
    final next = actions.setBlockType(
      _doc,
      ref,
      target,
      headingLevel: level,
      itemIndex: lineIndex,
    );
    if (identical(next, _doc)) return;
    _commit(next);

    // 行引用的形状可能变了（段落/标题 ↔ 列表/引用）：旧 ref 还有效就原地不动
    // （caret 严格不变），否则聚焦新块的第一行 —— 否则输入框会直接消失。
    BlockRef? targetRef;
    if (_isValidRef(ref)) {
      targetRef = ref;
    } else {
      final created = _blockById(b.id);
      if (created != null) {
        final refs = editableRefsOf(created);
        if (refs.isNotEmpty) targetRef = refs.first;
      }
    }

    // 立即聚焦 + 下一帧兜底。工具栏的按钮是 focusable 的 `IconButton`，被点击后会把
    // 焦点抢到按钮上，触发焦点监听（见 [focusNodeFor] 失焦分支，第 ~459 行）把
    // `_active` 清成 null —— 于是刚转成的标题 / 列表变成只读、工具栏所有类型按钮置灰，
    // 用户「选不中、变不了样式」（即本 bug）。这里先把焦点还给这一行，再安排下一帧
    // 重新聚焦，覆盖任何被工具栏抢走焦点的情况，保证该块始终可编辑、工具栏保持启用。
    if (targetRef != null) focusBlock(targetRef, caret: caret);
    _reassertFocusPostFrame(targetRef, caret);
  }

  /// 下一帧把焦点重新还给 [ref]（[caret] 字符偏移）。
  ///
  /// 只作为 [focusBlock] 之后的兜底：换块类型 / 插入块等动作若因工具栏按钮抢焦点
  /// 而丢了 `_active`，下一帧这里强制把焦点还给编辑器这一行，保证它始终可编辑、
  /// 工具栏保持启用。若用户在这期间主动切到了**别的**块（`_active` 变成了不同的
  /// 引用），则不强行抢回。
  void _reassertFocusPostFrame(BlockRef? ref, int caret) {
    if (ref == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      // 用户已主动切换到了别的块 → 不抢回焦点。
      if (_active != null && _active != ref) return;
      focusBlock(ref, caret: caret);
    });
  }

  // ===== 块树操作（内部） =====

  /// 在活动块之后插入 [block]，返回它的下标（失败 -1）。
  int _insertAfterActive(Block block) {
    final ref = _active;
    final int index;
    if (ref == null) {
      index = _doc.blocks.length;
    } else {
      final i = _indexOfBlock(ref.blockId);
      if (i < 0) return -1;
      index = i + 1;
    }
    _insertBlockAt(index, block);
    return index;
  }

  /// 在第 [index] 个位置插入 [block]；若前一块的间隔为空（文末），补成 `'\n\n'`，
  /// 否则序列化后新旧两块会粘成一行（内容虽然不丢，但结构会被重新解析）。
  ///
  /// 插在**文末**时，新块自己用空间隔（末块的 `trailingGap` 是整篇的尾部空白，
  /// 不该因为「新起一段」就凭空多出空行）。
  void _insertBlockAt(int index, Block block) {
    final at = index.clamp(0, _doc.blocks.length);
    final insert = at >= _doc.blocks.length ? _withGap(block, '') : block;
    if (at > 0) {
      final prev = _doc.blocks[at - 1];
      if (!prev.trailingGap.contains('\n')) {
        _replaceRange(at - 1, 1, <Block>[_withGap(prev, '\n\n'), insert]);
        return;
      }
    }
    _replaceRange(at, 0, <Block>[insert]);
  }

  /// 「把第 [index] 个块替换成 [inserts]」的唯一出口（所有变更都经过这里）。
  void _replaceRange(int index, int removeCount, List<Block> inserts) {
    final blocks = <Block>[..._doc.blocks];
    final start = index.clamp(0, blocks.length);
    final end = (index + removeCount).clamp(start, blocks.length);
    blocks.replaceRange(start, end, inserts);
    _commit(NoteDoc(blocks: _normalize(blocks), prologue: _doc.prologue));
  }

  /// 提交新文档：重算序列化缓存 + 同步行控制器 + 通知 UI。
  void _commit(NoteDoc next) {
    _flushStale();
    // 所有变更的唯一收口：**间隔规范化在这里做**。语义化回车 / 换类型等动作走的是
    // `actions.*`，直接返回新 doc，不经过 `_replaceRange`——只在 `_replaceRange` 里
    // 规范化会漏掉它们（连按回车造的空段落间隔全成 `'\n\n'`，存盘重开时多算出行）。
    final blocks = next.blocks.isEmpty
        ? <Block>[ParagraphBlock.empty()]
        : _normalize(next.blocks);
    _doc = NoteDoc(blocks: blocks, prologue: next.prologue);
    _markdown = serializeDoc(_doc);
    _syncLineControllers();
    _markStale();
    _notify();
  }

  /// 间隔规范化：保证序列化后的 Markdown 能**原样解析回这些块**。
  ///
  /// 三条规则（都是间隔，绝不碰内容 / `source`）：
  /// 1. 空段落（用户敲出来的空行）间隔恒为单个 `'\n'`——它自己就是那个空行，
  ///    再加空行就会多算出块；末块也留一个，否则存盘重开时这一行会被解析器
  ///    当成间隔收进前一块，用户看到的空行「凭空少一行」。
  /// 2. 非末块与下一块之间至少要有一个换行，否则两块会粘成一行。
  /// 3. 下一块是空段落时，当前块必须给**两个**换行——只给一个的话，解析器会把
  ///    那个换行当成「段落分隔」，空段落本身活不下来。
  List<Block> _normalize(List<Block> blocks) {
    if (blocks.length < 2) return blocks;
    final out = <Block>[...blocks];
    for (var i = 0; i < out.length; i++) {
      final b = out[i];
      if (_isBlankParagraph(b)) {
        if (b.trailingGap != '\n') out[i] = _withGap(b, '\n');
        continue;
      }
      if (i == out.length - 1) {
        // 末块自己不是空行时不需要收尾换行——否则「空行里开始打字」会把那个
        // 换行永久留在文末，之后每次编辑都揣着一个多余的行尾。
        if (b.trailingGap == '\n') out[i] = _withGap(b, '');
        continue;
      }
      final gap = b.trailingGap;
      if (!gap.contains('\n')) {
        out[i] = _withGap(b, '\n\n');
      } else if (gap == '\n' && _isBlankParagraph(out[i + 1])) {
        out[i] = _withGap(b, '\n\n');
      }
    }
    return out;
  }

  /// 这一块是不是「用户敲出来的空行」（空段落且未编辑过 → 不是源文档里的块）。
  static bool _isBlankParagraph(Block b) =>
      b is ParagraphBlock && b.source == null && plainTextOf(b.runs).isEmpty;

  /// 把文档侧的新文本同步进已注册的行控制器（`setMarkdown` / 结构变更后用）。
  void _syncLineControllers() {
    if (_lines.isEmpty) return;
    _applying = true;
    for (final entry in _lines.entries.toList()) {
      final ref = entry.key;
      final ctrl = entry.value;
      if (!_isValidRef(ref)) continue;
      if (!ctrl.value.composing.isCollapsed) continue;
      final docText = textOf(ref);
      if (ctrl.text == docText) continue;
      final caret = ctrl.selection.isValid ? ctrl.selection.extentOffset : docText.length;
      ctrl.value = TextEditingValue(
        text: docText,
        selection: TextSelection.collapsed(offset: caret.clamp(0, docText.length)),
      );
    }
    _applying = false;
  }

  void _markStale() {
    for (final ref in _lines.keys) {
      if (!_isValidRef(ref)) _stale.add(ref);
    }
  }

  void _flushStale() {
    if (_stale.isEmpty) return;
    for (final ref in _stale.toList()) {
      _lines.remove(ref)?.dispose();
      _nodes.remove(ref)?.dispose();
    }
    _stale.clear();
  }

  void _disposeLines() {
    for (final ctrl in _lines.values) {
      ctrl.dispose();
    }
    for (final node in _nodes.values) {
      node.dispose();
    }
    _lines.clear();
    _nodes.clear();
    _stale.clear();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _disposeLines();
    super.dispose();
  }

  // ===== 小工具 =====

  Block? _blockById(String id) {
    for (final b in _doc.blocks) {
      if (b.id == id) return b;
    }
    return null;
  }

  int _indexOfBlock(String id) {
    for (var i = 0; i < _doc.blocks.length; i++) {
      if (_doc.blocks[i].id == id) return i;
    }
    return -1;
  }

  /// [ref] 是否指向**真实存在的可编辑行**。
  ///
  /// 多行块（列表 / 引用 / 表格）必须带 [BlockRef.itemId]，否则就是「幽灵行」：
  /// `focusBlock` 会让 `active` 指向一个不存在的行 —— 该块在 UI 上仍是只读态
  /// （`active` 不等于任何真实行引用），用户看到的却是「点进去没反应 / 输入框消失」。
  /// T4 的换类型缺陷（段落→列表后沿用旧 ref）就是这一条的实例，这里从源头堵住。
  bool _isValidRef(BlockRef ref) {
    final b = _blockById(ref.blockId);
    if (b == null) return false;
    final itemId = ref.itemId;
    switch (b) {
      case ParagraphBlock():
      case HeadingBlock():
      case CodeBlock():
      case RawBlock():
        return itemId == null;
      case QuoteBlock(:final lines):
        final i = quoteLineIndexOf(ref);
        return i != null && i >= 0 && i < lines.length;
      case BulletListBlock(:final items):
        return _itemIndex(items, itemId) >= 0;
      case OrderedListBlock(:final items):
        return _itemIndex(items, itemId) >= 0;
      case TaskListBlock(:final items):
        return _taskIndex(items, itemId) >= 0;
      case TableBlock(:final rows):
        final rc = tableCellOf(ref);
        if (rc == null) return false;
        return rc.$1 >= 0 && rc.$1 < rows.length && rc.$2 >= 0 && rc.$2 < rows[rc.$1].length;
      case DividerBlock():
      case ImageBlock():
        return false;
    }
  }

  /// 用 [runs] 造一个同 id 的新块（`source` 归 null → 规范化序列化）。
  Block _blockWithRuns(Block b, BlockRef ref, InlineRuns runs) {
    switch (b) {
      case ParagraphBlock():
        return ParagraphBlock(id: b.id, trailingGap: b.trailingGap, runs: runs);
      case HeadingBlock(:final level):
        return HeadingBlock(
          id: b.id,
          level: level,
          trailingGap: b.trailingGap,
          runs: runs,
        );
      case QuoteBlock(:final lines):
        final i = quoteLineIndexOf(ref) ?? 0;
        final next = <InlineRuns>[...lines];
        while (next.length <= i) {
          next.add(const <InlineNode>[TextRun('')]);
        }
        next[i] = runs;
        return QuoteBlock(id: b.id, trailingGap: b.trailingGap, lines: next);
      case BulletListBlock(:final items):
        final i = _itemIndex(items, ref.itemId);
        if (i < 0) return b;
        final next = <ListItem>[...items];
        next[i] = ListItem(id: items[i].id, runs: runs);
        return BulletListBlock(id: b.id, trailingGap: b.trailingGap, items: next);
      case OrderedListBlock(:final start, :final items):
        final i = _itemIndex(items, ref.itemId);
        if (i < 0) return b;
        final next = <ListItem>[...items];
        next[i] = ListItem(id: items[i].id, runs: runs);
        return OrderedListBlock(
          id: b.id,
          trailingGap: b.trailingGap,
          start: start,
          items: next,
        );
      case TaskListBlock(:final items):
        final i = _taskIndex(items, ref.itemId);
        if (i < 0) return b;
        final next = <TaskItem>[...items];
        next[i] = TaskItem(id: items[i].id, runs: runs, checked: items[i].checked);
        return TaskListBlock(id: b.id, trailingGap: b.trailingGap, items: next);
      case CodeBlock(:final language):
        return CodeBlock(
          id: b.id,
          language: language,
          trailingGap: b.trailingGap,
          code: plainTextOf(runs),
        );
      case TableBlock(:final hasHeader, :final aligns, :final rows):
        final rc = tableCellOf(ref);
        if (rc == null) return b;
        final next = <List<InlineRuns>>[
          for (final row in rows) <InlineRuns>[...row],
        ];
        while (next.length <= rc.$1) {
          next.add(<InlineRuns>[]);
        }
        final row = next[rc.$1];
        while (row.length <= rc.$2) {
          row.add(const <InlineNode>[TextRun('')]);
        }
        row[rc.$2] = runs;
        return TableBlock(
          id: b.id,
          hasHeader: hasHeader,
          aligns: aligns,
          trailingGap: b.trailingGap,
          rows: next,
        );
      case RawBlock():
        return RawBlock(
          id: b.id,
          trailingGap: b.trailingGap,
          text: plainTextOf(runs),
        );
      case DividerBlock():
      case ImageBlock():
        return b;
    }
  }

  static int _itemIndex(List<ListItem> items, String? id) {
    if (id == null) return -1;
    for (var i = 0; i < items.length; i++) {
      if (items[i].id == id) return i;
    }
    return -1;
  }

  static int _taskIndex(List<TaskItem> items, String? id) {
    if (id == null) return -1;
    for (var i = 0; i < items.length; i++) {
      if (items[i].id == id) return i;
    }
    return -1;
  }

  static int _columnCount(TableBlock b) {
    var cols = b.aligns.length;
    for (final row in b.rows) {
      if (row.length > cols) cols = row.length;
    }
    return cols;
  }

  static int _commonPrefixLength(String a, String b) {
    final n = math.min(a.length, b.length);
    var i = 0;
    while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  static int _commonSuffixLength(String a, String b, int prefix) {
    var s = 0;
    while (s < a.length - prefix &&
        s < b.length - prefix &&
        a.codeUnitAt(a.length - 1 - s) == b.codeUnitAt(b.length - 1 - s)) {
      s++;
    }
    return s;
  }

  /// 取 [pos] 处（含该字符）所在 run 的 marks。
  static InlineMarks _marksAt(String text, InlineRuns runs, int pos) {
    var p = 0;
    var last = InlineMarks.none;
    for (final node in runs) {
      if (node is! TextRun) continue;
      final next = p + node.text.length;
      if (pos < next) return node.marks;
      p = next;
      last = node.marks;
    }
    return last;
  }
}

/// 「换个间隔」的块重建（[Block] 没有 copyWith，这里集中一处免得散落）。
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
