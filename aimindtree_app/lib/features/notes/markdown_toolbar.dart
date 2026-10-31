/// 笔记编辑器的富文本工具栏（T4 接线层）。
///
/// 设计依据：`docs/NOTE_EDITOR_WYSIWYG_DESIGN.md` §5.5（禁用态）、§6.1（19 个按钮的新行为）。
///
/// **这个文件管什么**
/// - 19 个按钮 → [NoteEditorController] 动作的一一映射；
/// - 按钮的**按下态**（`isMarkOn`）与**禁用态**（`activeSupportsInlineMarks`）；
/// - 「链接」的轻量对话框（文案 + 网址）；
/// - 「插入图片」仍走页面注入的异步回调（选文件 → 入库 → 插图）。
///
/// **这个文件不管什么**
/// - 任何 Markdown 文本操作：**这里不再 import `markdown_actions.dart`**。
///   全仓运行时只有一条路径 —— 按钮 → 控制器 → 块级动作；
///   `markdown_actions.dart` 降级为源码级工具库（仍被它自己的单测覆盖）。
/// - 块怎么渲染 / 光标怎么编排 → `block_view.dart` / `note_editor_controller.dart`。
///
/// **tooltip 是测试契约**（设计 §1.3 硬约束 5）：19 条文案一个字都不能改；
/// 只有在按钮置灰时才在原文**后面追加**一句说明，前缀保持原样。
library;

import 'package:flutter/material.dart';

import 'block_model.dart'
    show
        Block,
        BlockType,
        BulletListBlock,
        CodeBlock,
        DividerBlock,
        HeadingBlock,
        ImageBlock,
        InlineMarks,
        OrderedListBlock,
        QuoteBlock,
        TableBlock,
        TaskListBlock;
import 'note_editor_controller.dart';

/// 富文本工具栏（宽度不足时横向滚动）。
///
/// 本控件自己监听 [controller]（内部 `AnimatedBuilder`），因为按钮的按下态 /
/// 禁用态全部来自控制器状态；页面只需把它摆进去，不必再套一层。
class MarkdownToolbar extends StatelessWidget {
  const MarkdownToolbar({
    super.key,
    required this.controller,
    this.onInsertImage,
    this.padding = const EdgeInsets.symmetric(horizontal: 4),
  });

  /// 正文状态机（焦点 / 选区 / 块类型都由它管）。
  final NoteEditorController controller;

  /// 「插入图片」回调（选文件 + 入库 + 插入图片块，异步）。
  /// null = 不显示该按钮（调用方没接图片链路）。
  final Future<void> Function()? onInsertImage;

  /// 工具栏左右留白。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? _) => _buildBar(context),
    );
  }

  Widget _buildBar(BuildContext context) {
    final Block? block = controller.activeBlock;
    final bool inlineOk = controller.activeSupportsInlineMarks;
    // 换块类型：表格 / 图片 / 分割线没有「由文本直接转换」的语义（控制器也会拒）。
    final bool canConvert =
        block != null && block is! TableBlock && block is! ImageBlock && block is! DividerBlock;
    // 代码块：设计 §6.1 只在 image / divider 上禁用（表格由控制器内部忽略）。
    final bool canCode = block != null && block is! ImageBlock && block is! DividerBlock;

    return ExcludeFocus(
      // 工具栏按钮是 focusable 的 `IconButton`：点击会抢走编辑器 `TextField` 的焦点，
      // 触发焦点监听把 `_active` 清成 null，导致刚转成的块变只读、工具栏类型按钮全部
      // 置灰（即用户反馈的「变成一级标题后选不中、无法变样式」的 bug）。把整条工具栏
      // 排除在焦点系统之外，点击按钮就不再抢焦点 —— 编辑器焦点始终是赢家。
      // 注：只影响「聚焦」，按钮的点击 / tooltip / 禁用态都不受影响。
      excluding: true,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: padding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _markButton(Icons.format_bold, '加粗（**粗体文字**）', InlineMarks.bold, inlineOk),
              _markButton(Icons.format_italic, '斜体（*斜体文字*）', InlineMarks.italic, inlineOk),
              _markButton(Icons.code, '行内代码（`代码`）', InlineMarks.code, inlineOk),
              _markButton(
                Icons.strikethrough_s,
                '删除线（~~文字~~）',
                InlineMarks.strike,
                inlineOk,
              ),
              const _ToolDivider(),
              _headingButton(Icons.looks_one, '一级标题（# 标题）', 1, canConvert),
              _headingButton(Icons.looks_two, '二级标题（## 标题）', 2, canConvert),
              _headingButton(Icons.looks_3, '三级标题（### 标题）', 3, canConvert),
              _headingButton(Icons.looks_4, '四级标题（#### 标题）', 4, canConvert),
              _headingButton(Icons.looks_5, '五级标题（##### 标题）', 5, canConvert),
              _headingButton(Icons.looks_6, '六级标题（###### 标题）', 6, canConvert),
              const _ToolDivider(),
              _typeButton(
                icon: Icons.format_list_bulleted,
                tooltip: '无序列表（- 列表项）',
                type: BlockType.bulletList,
                enabled: canConvert,
                on: block is BulletListBlock,
              ),
              _typeButton(
                icon: Icons.format_list_numbered,
                tooltip: '有序列表（1. 列表项）',
                type: BlockType.orderedList,
                enabled: canConvert,
                on: block is OrderedListBlock,
              ),
              _typeButton(
                icon: Icons.format_quote,
                tooltip: '引用（> 引文）',
                type: BlockType.quote,
                enabled: canConvert,
                on: block is QuoteBlock,
              ),
              _typeButton(
                icon: Icons.check_box,
                tooltip: '任务列表（- [ ] 待办）',
                type: BlockType.taskList,
                enabled: canConvert,
                on: block is TaskListBlock,
              ),
              const _ToolDivider(),
              _toolButton(
                icon: Icons.data_object,
                tooltip: '代码块（``` 代码块 ```）',
                onPressed: canCode ? controller.convertActiveToCode : null,
                on: block is CodeBlock,
                unsupported: !canCode,
              ),
              _toolButton(
                icon: Icons.link,
                tooltip: '链接（[链接文字](https://…)）',
                onPressed: inlineOk ? () => _openLinkDialog(context) : null,
                unsupported: !inlineOk,
              ),
              if (onInsertImage != null)
                _toolButton(
                  icon: Icons.image_outlined,
                  tooltip: '插入图片（选本地图片，存入笔记附件）',
                  onPressed: onInsertImage,
                ),
              _toolButton(
                icon: Icons.table_chart,
                tooltip: '插入 2×2 表格',
                onPressed: () => controller.insertTableBlock(rows: 2, cols: 2),
              ),
              _toolButton(
                icon: Icons.horizontal_rule,
                tooltip: '分割线（---）',
                onPressed: controller.insertDividerBlock,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 按钮工厂
  // -------------------------------------------------------------------------

  /// 行内格式按钮：无选区时是「开关」（后续输入带上样式），有选区时立即生效。
  Widget _markButton(
    IconData icon,
    String tooltip,
    InlineMarks mark,
    bool enabled,
  ) {
    return _toolButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: enabled ? () => controller.toggleMark(mark) : null,
      on: enabled && controller.isMarkOn(mark),
      unsupported: !enabled,
    );
  }

  /// 标题按钮：同一级再点一次回落段落（控制器内部实现 toggle 语义）。
  Widget _headingButton(IconData icon, String tooltip, int level, bool enabled) {
    final block = controller.activeBlock;
    final on = block is HeadingBlock && block.level == level;
    return _toolButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: enabled
          ? () => controller.convertActiveTo(BlockType.heading, level: level)
          : null,
      on: on,
      unsupported: !enabled,
    );
  }

  /// 列表 / 引用按钮（同类型再点一次回落段落）。
  Widget _typeButton({
    required IconData icon,
    required String tooltip,
    required BlockType type,
    required bool enabled,
    required bool on,
  }) {
    return _toolButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: enabled ? () => controller.convertActiveTo(type) : null,
      on: enabled && on,
      unsupported: !enabled,
    );
  }

  /// 统一外观：按下态 = 蓝色前景 + 浅蓝底；禁用态 = 灰掉并**保留** tooltip
  /// （设计 §5.5：置灰而不是隐藏，隐藏会让用户以为功能没了）。
  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
    bool on = false,
    bool unsupported = false,
  }) {
    final Color color;
    if (onPressed == null) {
      color = Colors.grey.shade400;
    } else if (on) {
      color = Colors.blue.shade700;
    } else {
      color = Colors.grey.shade800;
    }
    return IconButton(
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      icon: Icon(icon, size: 20, color: color),
      tooltip: unsupported ? '$tooltip 当前块不支持该操作' : tooltip,
      style: on ? IconButton.styleFrom(backgroundColor: Colors.blue.shade50) : null,
      onPressed: onPressed,
    );
  }

  // -------------------------------------------------------------------------
  // 链接：轻量对话框（文案 + 网址）
  // -------------------------------------------------------------------------

  /// 弹「插入链接」对话框，确认后写到活动行。
  ///
  /// 为什么不用 `controller.setLink`：对话框会抢走焦点 → `active` 变 null，
  /// `setLink` 的 active 口径那一刻拿不到行引用。这里**先**记下行引用与选区，
  /// 再走 `setLinkOn(ref, …)` 显式指定落点，最后把焦点还给该行。
  Future<void> _openLinkDialog(BuildContext context) async {
    final ref = controller.active;
    if (ref == null) return;
    final sel = controller.selectionOf(ref);
    final a = (sel != null && sel.isValid) ? sel.start : controller.caretOf(ref);
    final b = (sel != null && sel.isValid) ? sel.end : a;
    final selected = controller.selectionText();

    final labelCtrl = TextEditingController(text: selected);
    final urlCtrl = TextEditingController(text: 'https://');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('插入链接'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: labelCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '链接文字',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '网址',
                hintText: 'https://…',
                isDense: true,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('插入'),
          ),
        ],
      ),
    );

    final label = labelCtrl.text;
    final url = urlCtrl.text.trim();
    labelCtrl.dispose();
    urlCtrl.dispose();
    if (confirmed != true || url.isEmpty) return;

    // 对话框开着的时候 active 已被清空 → 用显式区间写入，再把焦点还给该行。
    controller.setLinkOn(ref, label, url, start: a, end: b);
    controller.focusBlock(ref, caret: a + label.length);
  }
}

/// 工具组之间的竖分隔。
class _ToolDivider extends StatelessWidget {
  const _ToolDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        width: 1,
        height: 20,
        child: ColoredBox(color: Colors.grey.shade400),
      ),
    );
  }
}
