/// 笔记编辑器回归测试：跨块拖选复制（Bug 1） + 代码块按钮口径（Bug 2）。
///
/// 背景：
/// - Bug 1：只读行是 `Text`/`Text.rich`（默认不可选），旧实现没有 SelectionArea，
///   鼠标只能选活动行那个 `TextField`，表现为「拖选最多一行」。
///   必要修复 = 用 `SelectionArea` 包住正文 Column；但**真根因**在只读行原先用
///   `onTapDown`（按下即进编辑态），拖拽按下瞬间第一块被改成 `TextField`，跨块选区
///   起点被截断。故必须改 `onTapDown → onTapUp`：轻点仍进编辑态，拖拽期间 `onTapUp`
///   不触发、块保持只读，SelectionArea 才能接管任意方向跨块拖选（见 commit 999240c）。
/// - Bug 1b（本次）：`SelectionArea` 把各块的选中文本**首尾直拼**（框架不插分隔符），
///   复制出来是「第一段第二段」。修复 = 每个非末块的最后一行末尾挂一个零高度的
///   `copyGap` TextSpan，选中跨过该行时换行一起进剪贴板 → 局部复制粘贴也能带换行。
/// - Bug 2：`convertActiveToCode` 旧版用 `activeBlock`（仅 `_active`，失焦后为 null），
///   而工具栏启用判定用 `toolbarActiveBlock`（回退 `_lastActiveRef`），点工具栏瞬间
///   活动行失焦 → 提前 return → 「点了没效果」。修复 = 改用 `toolbarActiveBlock`。
library;

import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aimindtree_app/features/notes/block_model.dart';
import 'package:aimindtree_app/features/notes/note_editor_body.dart';
import 'package:aimindtree_app/features/notes/note_editor_controller.dart';

/// 只读行现在会在末尾挂一个零高度的 copyGap span，故 `find.text` 的精确匹配
/// 不再成立；用「plainText 以目标开头」定位对应的 RichText（其 RenderObject 就是
/// RenderParagraph，可直接读 selections）。
Finder lineWidget(String prefix) => find.byWidgetPredicate(
      (Widget w) => w is RichText && w.text.toPlainText().startsWith(prefix),
    );

/// 取 `SelectionArea` 当前选区拼出来的剪贴板文本（框架原生复制用的就是它）。
/// 必须用 SelectionArea 内部的 Column 上下文：从某个 RichText 往上找会命中
/// Text 自带的 `_SelectableTextContainerDelegate`（只管它自己那一行），而非外层
/// 的 `StaticSelectionContainerDelegate`（管全部块）。
String copiedText(WidgetTester tester) {
  final ctx = tester.element(find.descendant(
    of: find.byType(SelectionArea),
    matching: find.byType(Column),
  ).first);
  final handler = SelectionContainer.maybeOf(ctx) as SelectionHandler?;
  return handler?.getSelectedContent()?.plainText ?? '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Bug 1：跨块拖选复制', () {
    testWidgets('正文被 SelectionArea 包裹，可跨块拖选且复制自带换行',
        (tester) async {
      final c = NoteEditorController(markdown: '段落一 content\n\n段落二 content');
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: NoteEditorBody(controller: c))),
      );
      await tester.pumpAndSettle();

      // 1) SelectionArea 已包裹整篇正文。
      expect(find.byType(SelectionArea), findsOneWidget);

      // 2) 跨块拖选：从「段落一」左端一路拖到「段落二」右端。
      final p1 = tester.getRect(lineWidget('段落一 content'));
      final p2 = tester.getRect(lineWidget('段落二 content'));
      final start = Offset(p1.left + 4, p1.center.dy);
      final end = Offset(p2.right - 4, p2.center.dy);
      // 桌面端（鼠标）用 TapAndPanGestureRecognizer，可识别任意方向拖选；
      // 模拟鼠标设备才能复现纵向跨块拖选（触摸识别器只认横向）。
      await tester.dragFrom(start, end, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      // 3) 选区应跨两块：两段各自的 RenderParagraph 都应有非折叠选区。
      final p1Para = tester.renderObject<RenderParagraph>(lineWidget('段落一 content'));
      final p2Para = tester.renderObject<RenderParagraph>(lineWidget('段落二 content'));
      expect(p1Para.selections, isNotEmpty, reason: '第一段应有选中范围');
      expect(p2Para.selections, isNotEmpty, reason: '第二段应有选中范围');
      expect(p1Para.selections.first.isCollapsed, isFalse,
          reason: '第一段选区应非折叠');
      expect(p2Para.selections.first.isCollapsed, isFalse,
          reason: '第二段选区应非折叠');

      // 4) 关键：复制内容两段之间带换行（旧实现是「段落一 content段落二 content」粘一坨）。
      final copied = copiedText(tester).replaceAll('\r\n', '\n');
      expect(copied, contains('段落一 content'), reason: '复制应含第一段');
      expect(copied, contains('段落二 content'), reason: '复制应含第二段');
      expect(copied, contains('\n\n'),
          reason: '跨段复制必须带换行符，否则粘贴回去段落会粘连');
      expect(copied.indexOf('段落一 content'), lessThan(copied.indexOf('\n\n')));
      expect(copied.indexOf('\n\n'), lessThan(copied.indexOf('段落二 content')));
      c.dispose();
    });

    testWidgets('末尾块不挂 copyGap：整篇复制不会多出尾部空行', (tester) async {
      final c = NoteEditorController(markdown: '唯一一段');
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: NoteEditorBody(controller: c))),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(lineWidget('唯一一段'));
      await tester.dragFrom(
        Offset(rect.left + 2, rect.center.dy),
        Offset(rect.right - 2, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(copiedText(tester).trim(), '唯一一段',
          reason: '单段/末块复制不应带尾部换行');
      c.dispose();
    });

    testWidgets('SelectionArea 不破坏「点一下进入编辑态」', (tester) async {
      final c = NoteEditorController(markdown: '段落一 content\n\n段落二 content');
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: NoteEditorBody(controller: c))),
      );
      await tester.pumpAndSettle();

      // 点「段落一」应进入编辑态（出现 TextField），且不是 SelectionArea 吞掉手势。
      final p1 = tester.getRect(lineWidget('段落一 content'));
      await tester.tapAt(p1.center);
      await tester.pumpAndSettle();
      expect(c.isEditing, isTrue, reason: '点只读行应就地进入编辑态（回归守卫）');
      c.dispose();
    });
  });

  group('Bug 2：代码块按钮口径', () {
    test('失焦后点工具栏仍能 段落→代码块→段落（activeBlock→toolbarActiveBlock）',
        () {
      final c = NoteEditorController(markdown: 'hello world');
      final ref = BlockRef(c.doc.blocks.first.id);
      c.focusBlock(ref); // 设定 _active 与 _lastActiveRef
      c.blur(); // 清空 _active，保留 _lastActiveRef（模拟点工具栏瞬间）
      expect(c.active, isNull, reason: 'blur 后活动行应被清空');

      // 旧实现这里会因 activeBlock==null 提前 return；修复后走 toolbarActiveBlock。
      c.convertActiveToCode();
      expect(c.doc.blocks.first, isA<CodeBlock>(),
          reason: '段落应被转成代码块');

      c.convertActiveToCode(); // 再点一次应回落段落（toggle 语义）
      expect(c.doc.blocks.first, isA<ParagraphBlock>(),
          reason: '代码块再点应回落段落');

      // L1 红线：内容字节直通（只是改了类型，文本不变）。
      expect(c.markdown, 'hello world');
      c.dispose();
    });

    test('源码守卫：工具栏代码块按钮仍指向 convertActiveToCode（且用回退口径）', () {
      final toolbar =
          File('lib/features/notes/markdown_toolbar.dart').readAsStringSync();
      expect(toolbar, contains('controller.convertActiveToCode'));
      final ctrl = File('lib/features/notes/note_editor_controller.dart')
          .readAsStringSync();
      expect(ctrl, contains('void convertActiveToCode()'));
      expect(ctrl, contains('final b = toolbarActiveBlock;'));
    });
  });
}
