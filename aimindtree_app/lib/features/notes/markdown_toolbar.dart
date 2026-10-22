/// Markdown 富文本快捷工具栏（一行紧凑 IconButton，宽度不足时横向滚动）。
///
/// 全部动作都走 `markdown_actions.dart` 的纯函数，本文件只负责：
/// 1. 把按钮点击映射到具体的 Markdown 动作；
/// 2. 把结果写回 [TextEditingController]（正文 + 选区）；
/// 3. 尽量把焦点还给输入框。
///
/// **图片插入是唯一异步动作**：选文件 → 入附件库 → 拿 id 拼引用，
/// 所以它不走「同步纯函数」模式，而是由调用方通过 [onInsertImage]
/// 注入整条流水线（见 `note_editor_page._insertImage`）。
library;

import 'package:flutter/material.dart';

import 'markdown_actions.dart';

/// 富文本工具栏。
class MarkdownToolbar extends StatelessWidget {
  const MarkdownToolbar({
    super.key,
    required this.controller,
    this.focusNode,
    this.onInsertImage,
    this.padding = const EdgeInsets.symmetric(horizontal: 4),
  });

  /// 正文输入框的控制器（Markdown 源码）。
  final TextEditingController controller;

  /// 正文输入框焦点：传入后每次插入都会把焦点还给输入框。
  final FocusNode? focusNode;

  /// 「插入图片」回调（选文件 + 入库 + 插入引用，异步）。
  /// null = 不显示该按钮（调用方没接图片链路）。
  final Future<void> Function()? onInsertImage;

  /// 工具栏左右留白。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
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
            _toolButton(
              icon: Icons.format_bold,
              tooltip: '加粗（**粗体文字**）',
              apply: () => wrapInline(
                  controller.text, controller.selection, '**'),
            ),
            _toolButton(
              icon: Icons.format_italic,
              tooltip: '斜体（*斜体文字*）',
              apply: () =>
                  wrapInline(controller.text, controller.selection, '*'),
            ),
            _toolButton(
              icon: Icons.code,
              tooltip: '行内代码（`代码`）',
              apply: () =>
                  wrapInline(controller.text, controller.selection, '`'),
            ),
            const _ToolDivider(),
            _toolButton(
              icon: Icons.looks_one,
              tooltip: '一级标题（# 标题）',
              apply: () =>
                  toggleLinePrefix(controller.text, controller.selection, '# '),
            ),
            _toolButton(
              icon: Icons.looks_two,
              tooltip: '二级标题（## 标题）',
              apply: () => toggleLinePrefix(
                  controller.text, controller.selection, '## '),
            ),
            _toolButton(
              icon: Icons.looks_3,
              tooltip: '三级标题（### 标题）',
              apply: () => toggleLinePrefix(
                  controller.text, controller.selection, '### '),
            ),
            const _ToolDivider(),
            _toolButton(
              icon: Icons.format_list_bulleted,
              tooltip: '无序列表（- 列表项）',
              apply: () =>
                  toggleLinePrefix(controller.text, controller.selection, '- '),
            ),
            _toolButton(
              icon: Icons.format_list_numbered,
              tooltip: '有序列表（1. 列表项）',
              apply: () => toggleLinePrefix(
                  controller.text, controller.selection, '1. '),
            ),
            _toolButton(
              icon: Icons.format_quote,
              tooltip: '引用（> 引文）',
              apply: () =>
                  toggleLinePrefix(controller.text, controller.selection, '> '),
            ),
            const _ToolDivider(),
            _toolButton(
              icon: Icons.data_object,
              tooltip: '代码块（``` 代码块 ```）',
              apply: () => insertFence(controller.text, controller.selection),
            ),
            _toolButton(
              icon: Icons.link,
              tooltip: '链接（[链接文字](https://…)）',
              apply: () => insertLink(controller.text, controller.selection),
            ),
            if (onInsertImage != null)
              _toolButton(
                icon: Icons.image_outlined,
                tooltip: '插入图片（选本地图片，存入笔记附件）',
                onPressedOverride: onInsertImage,
              ),
            _toolButton(
              icon: Icons.table_chart,
              tooltip: '插入 2×2 表格',
              apply: () => insertTable(controller.text, controller.selection),
            ),
            _toolButton(
              icon: Icons.horizontal_rule,
              tooltip: '分割线（---）',
              apply: () => insertDivider(controller.text, controller.selection),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    MarkdownEditResult Function()? apply,
    Future<void> Function()? onPressedOverride,
  }) {
    return IconButton(
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      icon: Icon(icon, size: 20, color: Colors.grey.shade800),
      tooltip: tooltip,
      // 异步动作（插入图片）直接透传回调；同步动作走「纯函数 → 写回」。
      onPressed: onPressedOverride ??
          (apply == null ? null : () => _apply(apply())),
    );
  }

  /// 把 [result] 写回 controller，并把焦点还给输入框。
  void _apply(MarkdownEditResult result) {
    controller.value = controller.value.copyWith(
      text: result.text,
      selection: result.selection,
      composing: TextRange.empty,
    );
    focusNode?.requestFocus();
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
