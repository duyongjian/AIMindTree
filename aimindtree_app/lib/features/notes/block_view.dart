/// 笔记编辑器的「单个块」渲染（T3 渲染层）。
///
/// 设计依据：`docs/NOTE_EDITOR_WYSIWYG_DESIGN.md` §2.2（分层图）、§5.2（编辑态仍显示加粗）、
/// §6.2–§6.5（渲染升级 / 两个缺口 / 表格选型 / 图片）。
///
/// **这个文件管什么**
/// - 一套**视觉语言常量**（字号 / 间距 / 灰底 / 边框），只读态与编辑态共用 →
///   「点进去」时不会跳变；也保证与改造前 `markdown_render.dart` 的预览栏视觉零差异；
/// - 11 种块各自的 Widget：[BlockView]（可编辑，依赖 [NoteEditorController]）；
/// - 只读版：[buildReadOnlyBlock] / [buildReadOnlyDoc]（供 `markdown_render.dart`
///   兼容 shim 与未来任何「只读展示 Markdown」的页面复用）；
/// - 编辑态的一行 = 一个 `TextField`，文本是**纯文本**（看不到 `#`/`-`/`>`/`**`），
///   样式由 [RichLineController.buildTextSpan] 逐段套回来。
///
/// **这个文件不管什么**
/// - 文档状态与块级编辑原语 → `note_editor_controller.dart`；
/// - 滚动容器 / 按键路由 → `note_editor_body.dart`；
/// - 解析与序列化 → `markdown_block_parser.dart`（本文件**不做任何解析**）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'block_model.dart';
import 'note_editor_controller.dart';

// ---------------------------------------------------------------------------
// 视觉语言（与改造前 markdown_render.dart 逐项对齐，禁止随手改字号）
// ---------------------------------------------------------------------------

/// 正文基准样式（改造前 `_kBase`）。
const TextStyle kNoteBase = TextStyle(fontSize: 14, height: 1.5);

/// 块与块之间的下间距（改造前 `_kBlockGap`）。
const double kNoteBlockGap = 10.0;

/// 代码块样式（改造前 `_buildCode` 的 `TextStyle`）。
const TextStyle kNoteCode = TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4);

/// 标题字号：**只有 3 档**（H1=20 / H2=17 / H3~H6=15）。
///
/// ⚠️ `test/markdown_render_test.dart` 硬断言了这三个数，改任何一档都会让测试变红
/// （见设计 §6.6「标题字号本轮不动」）。
double kNoteHeadingFontSize(int level) => switch (level) {
      1 => 20.0,
      2 => 17.0,
      _ => 15.0,
    };

/// 标题样式（改造前 `_buildHeading`）。
TextStyle kNoteHeadingStyle(int level) => kNoteBase.copyWith(
      fontSize: kNoteHeadingFontSize(level),
      fontWeight: FontWeight.bold,
      height: 1.3,
    );

/// 引用正文样式（改造前 `_buildQuote`）。
TextStyle kNoteQuoteTextStyle() => kNoteBase.copyWith(color: Colors.grey.shade700);

/// 表格单元格样式（改造前 `_buildTable` 的 13 号）。
TextStyle kNoteTableCellStyle({bool header = false}) => kNoteBase.copyWith(
      fontSize: 13,
      fontWeight: header ? FontWeight.bold : FontWeight.normal,
    );

/// 行内片段 → `TextSpan` 列表（只读态与编辑态共用同一套 mark 映射）。
List<InlineSpan> inlineSpansFor(InlineRuns runs, TextStyle base) {
  final out = <InlineSpan>[];
  for (final node in runs) {
    if (node is! TextRun || node.text.isEmpty) continue;
    out.add(TextSpan(
      text: node.text,
      style: richStyleForMarks(node.marks, base, href: node.href),
    ));
  }
  return out;
}

/// 任务项勾选回调（只读渲染不持有控制器，靠它把点击交回上层）。
typedef TaskToggleCallback = void Function(Block block, TaskItem item);

// ---------------------------------------------------------------------------
// 只读渲染（供 markdown_render.dart 兼容 shim 复用）
// ---------------------------------------------------------------------------

/// 把整篇文档渲染成一列块级 Widget（**只读**，不可编辑）。
List<Widget> buildReadOnlyDoc(
  NoteDoc doc, {
  AssetResolver? resolveAsset,
  TaskToggleCallback? onToggleTask,
}) {
  return <Widget>[
    for (final block in doc.blocks)
      buildReadOnlyBlock(
        block,
        resolveAsset: resolveAsset,
        onToggleTask: onToggleTask,
      ),
  ];
}

/// 单个块的只读渲染。
Widget buildReadOnlyBlock(
  Block block, {
  AssetResolver? resolveAsset,
  TaskToggleCallback? onToggleTask,
}) {
  switch (block) {
    case ParagraphBlock(:final runs):
      return Padding(
        padding: const EdgeInsets.only(bottom: kNoteBlockGap),
        child: _readOnlyLine(runs, kNoteBase),
      );
    case HeadingBlock(:final level, :final runs):
      return Padding(
        padding: const EdgeInsets.only(bottom: kNoteBlockGap),
        child: _readOnlyLine(runs, kNoteHeadingStyle(level)),
      );
    case QuoteBlock(:final lines):
      final style = kNoteQuoteTextStyle();
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: kNoteBlockGap),
        padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          border: Border(left: BorderSide(color: Colors.grey.shade400, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final line in lines) _readOnlyLine(line, style),
          ],
        ),
      );
    case BulletListBlock(:final items):
      return _listShell(<Widget>[
        for (final item in items)
          _listRow(
            marker: Text('• ', style: kNoteBase),
            runs: item.runs,
            style: kNoteBase,
          ),
      ]);
    case OrderedListBlock(:final start, :final items):
      return _listShell(<Widget>[
        for (var i = 0; i < items.length; i++)
          _listRow(
            marker: Text('${start + i}. ', style: kNoteBase),
            runs: items[i].runs,
            style: kNoteBase,
          ),
      ]);
    case TaskListBlock(:final items):
      return _listShell(<Widget>[
        for (final item in items)
          _taskRow(
            item: item,
            runs: item.runs,
            style: _taskTextStyle(item.checked),
            onToggle: onToggleTask == null ? null : () => onToggleTask(block, item),
          ),
      ]);
    case CodeBlock(:final language, :final code):
      return _codeShell(
        language: language,
        child: Text(code, style: kNoteCode),
      );
    case TableBlock():
      return Padding(
        padding: const EdgeInsets.only(bottom: kNoteBlockGap),
        child: _table(block, null),
      );
    case DividerBlock():
      return const Divider(height: 20, thickness: 1);
    case ImageBlock(:final assetId, :final alt):
      return Padding(
        padding: const EdgeInsets.only(bottom: kNoteBlockGap),
        child: NoteImageView(
          assetId: assetId,
          alt: alt,
          resolveAsset: resolveAsset,
        ),
      );
    case RawBlock(:final text):
      return _rawShell(text, null);
  }
}

// ---------------------------------------------------------------------------
// 可编辑的块
// ---------------------------------------------------------------------------

/// 单个块的可编辑渲染：活动行 = `TextField`，其余行 = 只读 Widget。
class BlockView extends StatelessWidget {
  const BlockView({
    super.key,
    required this.controller,
    required this.block,
    this.copyGap = '',
  });

  final NoteEditorController controller;
  final Block block;

  /// 该块与下一块之间的换行文本（末块为空）。复制时挂在块内最后一行的行尾，
  /// 让 `SelectionArea` 拼出来的跨块文本自带换行；渲染上零高度、无视觉影响。
  final String copyGap;

  /// 块内多行之间用单换行，最后一行用块间 [copyGap]。
  String _lineGap(bool isLastLine) => isLastLine ? copyGap : '\n';

  @override
  Widget build(BuildContext context) {
    switch (block) {
      case ParagraphBlock(:final runs):
        return Padding(
          padding: const EdgeInsets.only(bottom: kNoteBlockGap),
          child: _line(BlockRef(block.id), runs, kNoteBase, copyGap: copyGap),
        );
      case HeadingBlock(:final level, :final runs):
        return Padding(
          padding: const EdgeInsets.only(bottom: kNoteBlockGap),
          child: _line(BlockRef(block.id), runs, kNoteHeadingStyle(level), copyGap: copyGap),
        );
      case QuoteBlock(:final lines):
        final style = kNoteQuoteTextStyle();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: kNoteBlockGap),
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            border: Border(left: BorderSide(color: Colors.grey.shade400, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var i = 0; i < lines.length; i++)
                _line(quoteLineRef(block.id, i), lines[i], style,
                    copyGap: _lineGap(i == lines.length - 1)),
            ],
          ),
        );
      case BulletListBlock(:final items):
        return _listShell(<Widget>[
          for (var i = 0; i < items.length; i++)
            _listRow(
              marker: Text('• ', style: kNoteBase),
              runs: items[i].runs,
              style: kNoteBase,
              line: _line(
                BlockRef(block.id, itemId: items[i].id),
                items[i].runs,
                kNoteBase,
                copyGap: _lineGap(i == items.length - 1),
              ),
            ),
        ]);
      case OrderedListBlock(:final start, :final items):
        return _listShell(<Widget>[
          for (var i = 0; i < items.length; i++)
            _listRow(
              marker: Text('${start + i}. ', style: kNoteBase),
              runs: items[i].runs,
              style: kNoteBase,
              line: _line(
                BlockRef(block.id, itemId: items[i].id),
                items[i].runs,
                kNoteBase,
                copyGap: _lineGap(i == items.length - 1),
              ),
            ),
        ]);
      case TaskListBlock(:final items):
        return _listShell(<Widget>[
          for (var i = 0; i < items.length; i++)
            _taskRow(
              item: items[i],
              runs: items[i].runs,
              style: _taskTextStyle(items[i].checked),
              onToggle: () => controller.toggleTaskItem(
                BlockRef(block.id, itemId: items[i].id),
              ),
              line: _line(
                BlockRef(block.id, itemId: items[i].id),
                items[i].runs,
                _taskTextStyle(items[i].checked),
                copyGap: _lineGap(i == items.length - 1),
              ),
            ),
        ]);
      case CodeBlock(:final language, :final code):
        return _codeShell(
          language: language,
          child: _line(
            BlockRef(block.id),
            code.isEmpty ? const <InlineNode>[] : <InlineNode>[TextRun(code)],
            kNoteCode,
            asPlainText: true,
            copyGap: copyGap,
          ),
        );
      case TableBlock():
        return Padding(
          padding: const EdgeInsets.only(bottom: kNoteBlockGap),
          child: _table(block, controller),
        );
      case DividerBlock():
        return const Divider(height: 20, thickness: 1);
      case ImageBlock(:final assetId, :final alt):
        return Padding(
          padding: const EdgeInsets.only(bottom: kNoteBlockGap),
          child: NoteImageView(
            assetId: assetId,
            alt: alt,
            resolveAsset: controller.resolveAsset,
          ),
        );
      case RawBlock(:final text):
        return _rawShell(
          text,
          _line(
            BlockRef(block.id),
            text.isEmpty ? const <InlineNode>[] : <InlineNode>[TextRun(text)],
            kNoteCode,
            asPlainText: true,
            copyGap: copyGap,
          ),
        );
    }
  }

  /// 一行：活动 → 编辑态 `TextField`；否则只读 Widget（可点击定位光标）。
  Widget _line(
    BlockRef ref,
    InlineRuns runs,
    TextStyle style, {
    bool asPlainText = false,
    String copyGap = '',
  }) {
    if (controller.active == ref) {
      return _editableLine(ref, style, asPlainText: asPlainText);
    }
    return _ReadOnlyLine(
      controller: controller,
      ref: ref,
      runs: runs,
      style: style,
      asPlainText: asPlainText,
      copyGap: copyGap,
    );
  }

  Widget _editableLine(BlockRef ref, TextStyle style, {required bool asPlainText}) {
    final ctrl = controller.lineControllerFor(ref, base: style);
    return TextField(
      controller: ctrl,
      focusNode: controller.focusNodeFor(ref),
      style: style,
      maxLines: null,
      cursorWidth: 2,
      cursorHeight: style.fontSize == null ? null : style.fontSize! * 1.15,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      // 只读态是 Text.rich（零内边距），编辑态必须对齐，否则点进去会「跳一下」。
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintText: null,
      ),
      onChanged: (String value) => controller.onLineChanged(ref, value),
    );
  }
}

/// 一键进入编辑态的只读行：点哪儿就把光标放到哪儿。
class _ReadOnlyLine extends StatelessWidget {
  const _ReadOnlyLine({
    required this.controller,
    required this.ref,
    required this.runs,
    required this.style,
    this.asPlainText = false,
    this.copyGap = '',
  });

  final NoteEditorController controller;
  final BlockRef ref;
  final InlineRuns runs;
  final TextStyle style;
  final bool asPlainText;

  /// 复制到剪贴板时，接在本行文字后面的换行分隔（**渲染上零高度**）。
  ///
  /// `SelectionArea` 会把每个可选 Text 的选中文本**直接首尾拼接**（框架
  /// `SelectionContainerDelegate.getSelectedContent` 不插任何分隔符），所以跨块拖选
  /// 复制出来原本是「第一段第二段」粘成一坨。把块间 `trailingGap` 作为一个
  /// `fontSize:0 / height:0` 的 TextSpan 挂在该块最后一行末尾，选中跨越这一行时
  /// 这段换行就会跟着进剪贴板 → 局部复制粘贴也能带换行。零字号 + 零行高使它有
  /// 字符、无视觉高度（实测不增加行高），也不会影响点按定位光标。
  final String copyGap;

  /// 零高度的「复制用换行」span（只在 [copyGap] 非空时插入）。
  InlineSpan get _gapSpan => TextSpan(
        text: copyGap,
        style: const TextStyle(fontSize: 0, height: 0),
      );

  @override
  Widget build(BuildContext context) {
    final text = plainTextOf(runs);
    if (asPlainText) {
      // 代码块 / 原文块：不做任何行内解析。用 Text.rich 是为了把 [copyGap] 挂进
      // 同一个 RenderParagraph（style 仍原样传给 Text，等宽字体断言不受影响）。
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 用 onTapUp（抬起且未拖动）而非 onTapDown（按下即触发）：否则一拖拽、按下瞬间
        // 就进编辑态变成 TextField，SelectionArea 的跨块选区还没开始就被打断。
        onTapUp: (TapUpDetails d) => _focusAt(context, text, d.localPosition, double.infinity),
        child: Text.rich(
          TextSpan(
            style: style,
            children: <InlineSpan>[
              TextSpan(text: text.isEmpty ? ' ' : text),
              if (copyGap.isNotEmpty) _gapSpan,
            ],
          ),
          style: style,
        ),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 同 asPlainText 分支：onTapUp 让拖拽不被「进入编辑态」抢占，跨块选区才能成立。
          onTapUp: (TapUpDetails d) => _focusAt(context, text, d.localPosition, width),
          child: text.isEmpty
              // 空段落也要进可选区（否则跨空段拖选会把它两侧的段落粘连）。
              // 用一个空格撑起行高，并把 copyGap 挂在同一个段落里。
              ? SizedBox(
                  width: double.infinity,
                  height: style.fontSize == null ? 20 : style.fontSize! * 1.5,
                  child: Text.rich(
                    TextSpan(
                      style: style,
                      children: <InlineSpan>[
                        const TextSpan(text: ' '),
                        if (copyGap.isNotEmpty) _gapSpan,
                      ],
                    ),
                  ),
                )
              : Text.rich(
                  TextSpan(
                    style: style,
                    children: <InlineSpan>[
                      ...inlineSpansFor(runs, style),
                      if (copyGap.isNotEmpty) _gapSpan,
                    ],
                  ),
                ),
        );
      },
    );
  }

  void _focusAt(BuildContext context, String text, Offset local, double width) {
    final caret = caretForTap(
      text: text,
      style: style,
      maxWidth: width.isFinite ? width : MediaQuery.sizeOf(context).width,
      local: local,
      direction: Directionality.maybeOf(context) ?? TextDirection.ltr,
    );
    controller.focusBlock(ref, caret: caret);
  }
}

/// 点击位置 → 字符偏移（用 [TextPainter] 自己算，避免为了拿光标位置而引入
/// 一个永远可见的 `TextField`）。
int caretForTap({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required Offset local,
  TextDirection direction = TextDirection.ltr,
}) {
  if (text.isEmpty) return 0;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    maxLines: null,
  );
  painter.layout(maxWidth: maxWidth.isFinite ? maxWidth : 1048576.0);
  final pos = painter.getPositionForOffset(local);
  painter.dispose();
  return pos.offset.clamp(0, text.length);
}

// ---------------------------------------------------------------------------
// 行 / 列表 / 代码 / 表格 / 原文 的共用外观
// ---------------------------------------------------------------------------

Widget _readOnlyLine(InlineRuns runs, TextStyle style) {
  final text = plainTextOf(runs);
  if (text.isEmpty) {
    return SizedBox(height: style.fontSize == null ? 20 : style.fontSize! * 1.5);
  }
  return Text.rich(TextSpan(style: style, children: inlineSpansFor(runs, style)));
}

Widget _listShell(List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: kNoteBlockGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );

/// 列表行：marker + 正文。给了 [line] 就用它当正文（可编辑），否则只读渲染。
Widget _listRow({
  required Widget marker,
  required InlineRuns runs,
  required TextStyle style,
  Widget? line,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        marker,
        Expanded(child: line ?? _readOnlyLine(runs, style)),
      ],
    ),
  );
}

TextStyle _taskTextStyle(bool checked) => checked
    ? kNoteBase.copyWith(
        decoration: TextDecoration.lineThrough,
        color: Colors.grey.shade500,
      )
    : kNoteBase;

Widget _taskRow({
  required TaskItem item,
  required InlineRuns runs,
  TextStyle style = kNoteBase,
  VoidCallback? onToggle,
  Widget? line,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 26,
          height: 21,
          child: Checkbox(
            value: item.checked,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            onChanged: onToggle == null ? null : (_) => onToggle(),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(child: line ?? _readOnlyLine(runs, style)),
      ],
    ),
  );
}

Widget _codeShell({required String language, required Widget child}) {
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: kNoteBlockGap),
    padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
    decoration: BoxDecoration(
      color: Colors.grey.shade200,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (language.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              language,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),
        child,
      ],
    ),
  );
}

Widget _rawShell(String text, Widget? line) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        color: Colors.amber.shade100,
        child: Text(
          '此块含不支持的格式，按原文编辑',
          style: TextStyle(fontSize: 11, color: Colors.amber.shade900),
        ),
      ),
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: kNoteBlockGap),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(4),
        ),
        child: line ?? Text(text, style: kNoteCode),
      ),
    ],
  );
}

/// 表格：只读态与编辑态**共用一个 `Table`**（设计 §6.4 的取舍见交付说明）——
/// 单元格被点中时那一个格子换成 `TextField`，其余仍是 `Text.rich`。
Widget _table(Block block, NoteEditorController? controller) {
  if (block is! TableBlock) return const SizedBox.shrink();
  final rows = block.rows;
  var columns = block.aligns.length;
  for (final row in rows) {
    if (row.length > columns) columns = row.length;
  }
  if (columns <= 0) columns = 1;

  // 每列的最小像素宽（列再多也保证可点进编辑，不压成竖排单字）。
  const double kMinColWidth = 88;

  final Widget table = Table(
    border: TableBorder.all(color: Colors.grey.shade400, width: 0.5),
    defaultColumnWidth: const FixedColumnWidth(kMinColWidth),
    // 「最小 88px + 按比例伸缩」：MinColumnWidth 取两个宽度中的较小值，
    // 这里给它 (88, flex) —— flex 保证多余空间按列均分；列宽的下限由外层
    // 固定的 tableWidth（≥ 列数 × 88）兜底，故每列恒 ≥ 88。
    // 横向空间不足时整表按「每列 88」铺开并横向滚动，绝不把列压窄。
    columnWidths: <int, TableColumnWidth>{
      for (var i = 0; i < columns; i++)
        i: MinColumnWidth(
          const FixedColumnWidth(kMinColWidth),
          const FlexColumnWidth(1),
        ),
    },
    children: <TableRow>[
      for (var r = 0; r < rows.length; r++)
        TableRow(
          decoration: r == 0 && block.hasHeader
              ? BoxDecoration(color: Colors.grey.shade200)
              : null,
          children: <Widget>[
            for (var c = 0; c < columns; c++)
              _cell(
                block: block,
                controller: controller,
                row: r,
                col: c,
                runs: c < rows[r].length ? rows[r][c] : const <InlineNode>[],
                header: r == 0 && block.hasHeader,
              ),
          ],
        ),
    ],
  );

  return LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double minTableWidth = kMinColWidth * columns;
      final double available =
          constraints.maxWidth.isFinite ? constraints.maxWidth : minTableWidth;
      // 可用宽度够 → 铺满（多余宽度按列均分）；不够 → 按「每列 88」铺开并滚动。
      final double tableWidth =
          available > minTableWidth ? available : minTableWidth;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(width: tableWidth, child: table),
      );
    },
  );
}

Widget _cell({
  required TableBlock block,
  required NoteEditorController? controller,
  required int row,
  required int col,
  required InlineRuns runs,
  required bool header,
}) {
  final style = kNoteTableCellStyle(header: header);
  final align = col < block.aligns.length ? block.aligns[col] : TableAlign.none;
  final textAlign = switch (align) {
    TableAlign.center => TextAlign.center,
    TableAlign.right => TextAlign.right,
    TableAlign.left => TextAlign.left,
    TableAlign.none => TextAlign.left,
  };
  final ref = tableCellRef(block.id, row, col);

  Widget child;
  if (controller != null && controller.active == ref) {
    final ctrl = controller.lineControllerFor(ref, base: kNoteTableCellStyle(header: false));
    child = TextField(
      controller: ctrl,
      focusNode: controller.focusNodeFor(ref),
      style: kNoteTableCellStyle(header: false),
      maxLines: null,
      textAlign: textAlign,
      // `maxLines: null`（多行）+ `TextInputAction.newline` 必须配
      // `TextInputType.multiline`，否则会命中 text_field.dart 的断言
      // 「Use keyboardType TextInputType.multiline when using
      // TextInputAction.newline on a multiline TextField」。
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
      ),
      onChanged: (String value) => controller.onLineChanged(ref, value),
    );
  } else {
    final text = plainTextOf(runs);
    final content = text.isEmpty
        ? const SizedBox(height: 18)
        : Text.rich(
            TextSpan(style: style, children: inlineSpansFor(runs, style)),
            textAlign: textAlign,
          );
    child = controller == null
        ? content
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (TapDownDetails d) => controller.focusBlock(
              ref,
              caret: caretForTap(
                text: text,
                style: style,
                maxWidth: 1000,
                local: d.localPosition,
              ),
            ),
            child: content,
          );
  }

  return Padding(
    padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
    child: child,
  );
}

// ---------------------------------------------------------------------------
// 图片
// ---------------------------------------------------------------------------

/// 图片块：`aimindtree-asset://<id>` → 字节 → `Image.memory`。
///
/// 缺失 / 未同步 / 解码失败一律降级成「图片未同步」占位块 ——
/// **绝不让整篇笔记渲染失败**（改造前的语义，必须保留）。
class NoteImageView extends StatelessWidget {
  const NoteImageView({
    super.key,
    required this.assetId,
    this.alt = '',
    this.resolveAsset,
    this.height = 160,
  });

  final String assetId;
  final String alt;
  final AssetResolver? resolveAsset;
  final double height;

  @override
  Widget build(BuildContext context) {
    final resolver = resolveAsset;
    if (resolver == null) return _missing(alt);
    return FutureBuilder<Uint8List?>(
      future: resolver(assetId),
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _imageShell(
            const Center(
              child: Text(
                '加载中…',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          );
        }
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) return _missing(alt);
        return Image.memory(
          bytes,
          height: height,
          fit: BoxFit.contain,
          errorBuilder: (BuildContext _, Object __, StackTrace? ___) => _missing(alt),
        );
      },
    );
  }
}

Widget _imageShell(Widget child) => Container(
      width: 160,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.grey.shade300,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade400),
      ),
      alignment: Alignment.center,
      child: child,
    );

Widget _missing(String alt) => _imageShell(
      Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.broken_image, size: 22, color: Colors.grey.shade600),
          const SizedBox(height: 4),
          Text(
            alt.isEmpty ? '图片未同步' : '图片未同步：$alt',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
