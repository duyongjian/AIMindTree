/// 笔记正文的滚动容器（T3）。
///
/// 设计依据：`docs/NOTE_EDITOR_WYSIWYG_DESIGN.md` §5.1（状态机）、§5.3（回车）、§5.4（退格）。
///
/// **这个文件管什么**
/// - `SingleChildScrollView + Column` 排布所有 [BlockView]；
/// - **块间按键路由**：把「行首退格」和「Shift+Enter」从键盘事件层面接住
///   （退格在 offset 0 时不会产生 `onChanged`，所以必须拦按键；回车则交给
///   `onChanged` 里检测新增的 `\n`，天然兼容软键盘与输入法）；
/// - 点底部空白 → 追加空段落并聚焦（永不出现「没地方点」的死区）。
///
/// **这个文件不管什么**
/// - 单个块长什么样 → `block_view.dart`；
/// - 文档状态与编辑原语 → `note_editor_controller.dart`；
/// - 页面壳体（标题 / AppBar / 工具栏 / 知识点）→ T4 的 `note_editor_page.dart`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'block_view.dart';
import 'note_editor_controller.dart';

/// 正文滚动容器。页面里只需 `Expanded(child: NoteEditorBody(controller: c))`。
class NoteEditorBody extends StatefulWidget {
  const NoteEditorBody({
    super.key,
    required this.controller,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 0),
    this.tailHeight = 120,
  });

  /// 正文状态机（焦点 / 光标 / 文档都在它手里）。
  final NoteEditorController controller;

  /// 正文内边距。
  final EdgeInsetsGeometry padding;

  /// 底部「可点空白」的高度：点它 = 文末新起一段。
  final double tailHeight;

  @override
  State<NoteEditorBody> createState() => _NoteEditorBodyState();
}

class _NoteEditorBodyState extends State<NoteEditorBody> {
  NoteEditorController get _c => widget.controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? _) {
        final blocks = _c.doc.blocks;
        return Focus(
          // 只做按键观察，不参与 Tab 焦点遍历，也永不抢焦点。
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKeyEvent,
          child: SingleChildScrollView(
            padding: widget.padding,
            // 整篇拖选复制：用 SelectionArea 把每个只读块的 Text/Text.rich 统一成一个
            // 可选区，鼠标可从这一块一路拖到另一块（设计 §5.5「跨块选区 v1 不支持」的
            // 可视化兜底）。活动块仍是独立 TextField，用自己的选区，互不影响。
            // SelectionArea 默认不注册 TapGestureRecognizer，不会抢走「点一下进入
            // 编辑态」的手势（见 [_ReadOnlyLine]）。
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final block in blocks)
                    BlockView(
                      key: ValueKey<String>(block.id),
                      controller: _c,
                      block: block,
                    ),
                  _tail(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 底部空白热区：点一下就在文末新起一段（设计 §5.1 最后一条）。
  Widget _tail() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _c.appendParagraphAndFocus,
      child: SizedBox(height: widget.tailHeight, width: double.infinity),
    );
  }

  /// 键盘事件：只**拦截**「行首退格」；回车只观察 Shift 状态、不消费。
  ///
  /// 为什么退格一定要拦：`EditableText` 在 offset 0 时按退格不会产生文本变化，
  /// 所以拿不到 `onChanged`，只能靠祖先 `Focus` 的 `onKeyEvent`（设计 §5.4）。
  /// 为什么回车不拦：桌面 / 移动端 / 输入法的换行都会落到 `onChanged`，
  /// 在那里检测新增的 `\n` 更可靠（设计 §5.3）。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final ref = _c.active;
    if (ref == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      final sel = _c.selectionOf(ref);
      if (sel == null || !sel.isValid || !sel.isCollapsed) {
        return KeyEventResult.ignored;
      }
      if (sel.baseOffset > 0) return KeyEventResult.ignored;
      return _c.backspaceAtStart()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        // 只置标记、不消费：让 TextField 自己把换行插进文本（软换行）。
        _c.markSoftBreak();
      }
      return KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }
}
