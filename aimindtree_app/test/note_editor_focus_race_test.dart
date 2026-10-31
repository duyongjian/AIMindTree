/// 笔记编辑器「转换块类型后失焦变只读」bug 的回归测试。
///
/// 复现：在段落里写完字 → 点工具栏「一级标题」按钮，块确实变成了标题，
/// 但随后工具栏 focusable 的 `IconButton` 抢走编辑器 `TextField` 的焦点，
/// 触发焦点监听把 `_active` 清成 null（见 [NoteEditorController.focusNodeFor]
/// 的失焦分支）→ 刚转成的标题变只读、工具栏类型按钮全部置灰，
/// 用户「选不中、无法变样式」。
///
/// 修复（双保险）：
/// 1. 工具栏整体 `ExcludeFocus`，点击按钮不再抢焦点；
/// 2. `_convert` 在下一帧用 post-frame 回调把焦点还给这一行，覆盖任何抢焦点的情况。
///
/// 本文件同时提供：
/// - 控制器级、可确定性回放的「失焦竞态」复现（不依赖测试绑定的焦点行为）；
/// - 真·控件级测试：真的点工具栏 H1 按钮，断言块变成标题后**仍可读可编辑**。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aimindtree_app/features/notes/block_model.dart';
import 'package:aimindtree_app/features/notes/markdown_toolbar.dart';
import 'package:aimindtree_app/features/notes/note_editor_body.dart';
import 'package:aimindtree_app/features/notes/note_editor_controller.dart';

BlockRef _firstRef(NoteEditorController c) => BlockRef(c.doc.blocks.first.id);

void main() {
  // FocusNode / WidgetsBinding 需要 Widgets 绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('转换块类型后焦点竞态（选不中 bug）', () {
    testWidgets('转换后焦点被抢走：下一帧兜底把焦点还给编辑器这一行',
        (WidgetTester tester) async {
      final c = NoteEditorController(markdown: 'hello world');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 2);
      expect(c.active, isNotNull, reason: '前置：活动行已聚焦');

      // 用户点了工具栏「一级标题」按钮：_active 此刻还在，转换正常跑完 → 块变标题。
      c.convertActiveTo(BlockType.heading, level: 1);
      expect(c.doc.blocks.single, isA<HeadingBlock>(),
          reason: '转换后块一定是标题（与用户看到的「变成一级标题」一致）');

      // 模拟「按钮在 onPressed 之后才把焦点抢走」——直接把这一行的焦点节点失焦，
      // 触发焦点监听把 _active 清成 null（与真实 bug 的失焦路径同一来源）。
      //
      // ⚠️ 不能在同一个 tick 里断言 `active == null`：Flutter 的焦点变更由
      // FocusManager 统一在帧边界应用，`unfocus()` 只是登记意图，监听回调
      // （清 `_active` 的那段，见 `focusNodeFor`）要等下一个微任务/帧才跑。
      // 在同一 tick 断言只会测到「还没生效」，是**假失败**。
      // 真正要保证的不变式是「下一帧焦点回到这一行」，下面直接验它。
      c.focusNodeFor(ref).unfocus();

      // 下一帧：修复后的 _convert 会用 post-frame 兜底把焦点还给这一行。
      await tester.pump();
      expect(c.active, isNotNull,
          reason: '下一帧焦点必须回到编辑器这一行，否则仍「选不中」');
      expect(c.active!.blockId, ref.blockId);
      expect(c.activeBlock, isA<HeadingBlock>(),
          reason: '重新聚焦后仍然是标题，且工具栏据此保持启用');
      c.dispose();
    });

    testWidgets('段落→列表（引用形状变化）后同样兜底聚焦，不会掉出编辑态',
        (WidgetTester tester) async {
      final c = NoteEditorController(markdown: 'abc');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 1);
      c.convertActiveTo(BlockType.bulletList);

      expect(c.doc.blocks.single, isA<BulletListBlock>());
      // 抢焦点：列表的 itemId 引用失焦后把 active 清空。
      // （同前：失焦在帧边界才真正生效，这里只登记，pump 之后再断言。）
      final list = c.doc.blocks.single as BulletListBlock;
      final itemRef = BlockRef(list.id, itemId: list.items.single.id);
      c.focusNodeFor(itemRef).unfocus();

      await tester.pump();
      expect(c.isEditing, isTrue, reason: '换类型后必须仍在编辑态（不丢 active）');
      expect(c.active, isNotNull);
      expect(c.activeBlock, isA<BulletListBlock>());
      expect(c.textOf(c.active!), 'abc');
      c.dispose();
    });

    testWidgets('重新聚焦只覆盖被抢焦点的块：用户已切到别的块就不抢回',
        (WidgetTester tester) async {
      final c = NoteEditorController(markdown: '第一行\n\n第二行');
      final r0 = BlockRef(c.doc.blocks[0].id);
      final r1 = BlockRef(c.doc.blocks[1].id);
      c.focusBlock(r0, caret: 1);
      c.convertActiveTo(BlockType.heading, level: 1);
      // 失焦（用户主动点了第二行之前先被按钮抢一次）。
      // 失焦在帧边界生效，这里紧接着就切块 —— 正好覆盖「同一帧里既被抢焦点、
      // 又主动换块」的真实竞态顺序，不需要（也做不到）在同 tick 观察中间态。
      c.focusNodeFor(r0).unfocus();
      // 用户在被抢焦点的同一帧里主动切到了第二行。
      c.focusBlock(r1, caret: 1);
      expect(c.active!.blockId, c.doc.blocks[1].id);

      await tester.pump();
      // 兜底不应把焦点从用户主动选中的第二行抢回第一行。
      expect(c.active!.blockId, c.doc.blocks[1].id,
          reason: '兜底只在「焦点还停在被转换块」时生效，不抢用户已选的块');
      c.dispose();
    });
  });

  group('真·工具栏点击路径', () {
    testWidgets('点工具栏「一级标题」按钮：块变标题且仍可读可编辑',
        (WidgetTester tester) async {
      final c = NoteEditorController(markdown: 'hello world');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              MarkdownToolbar(controller: c),
              Expanded(child: NoteEditorBody(controller: c)),
            ],
          ),
        ),
      ));
      await tester.pump();
      expect(find.byType(TextField), findsNothing, reason: '初始：全是只读态');

      // 点只读段落 → 进入编辑态（出现 TextField）。
      await tester.tap(find.text('hello world'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget, reason: '点进去应有输入框');
      expect(c.isEditing, isTrue);

      // 点工具栏「一级标题」按钮（真实 IconButton，focusable）。
      await tester.tap(find.byTooltip('一级标题（# 标题）'));
      await tester.pumpAndSettle();

      // 块确实变成了标题，且**没有**变成只读（输入框还在 → 可读可编辑）。
      expect(c.doc.blocks.single, isA<HeadingBlock>());
      expect(c.active, isNotNull, reason: '转换后活动行必须保持聚焦');
      expect(c.activeBlock, isA<HeadingBlock>());
      expect(find.byType(TextField), findsOneWidget,
          reason: '标题块仍是可编辑的 TextField（不再「选不中」）');
      c.dispose();
    });

    testWidgets('点工具栏后焦点不应跳到按钮（编辑器焦点始终在场）',
        (WidgetTester tester) async {
      final c = NoteEditorController(markdown: '正文一');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              MarkdownToolbar(controller: c),
              Expanded(child: NoteEditorBody(controller: c)),
            ],
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('正文一'));
      await tester.pump();
      expect(c.isEditing, isTrue);

      await tester.tap(find.byTooltip('一级标题（# 标题）'));
      await tester.pumpAndSettle();

      // 兜底修复后，活动行仍聚焦；且其焦点节点 hasFocus 为 true（焦点没被按钮抢走）。
      expect(c.active, isNotNull);
      expect(c.focusNodeFor(c.active!).hasFocus, isTrue,
          reason: '编辑器 TextField 的焦点没有被工具栏按钮抢走');
      c.dispose();
    });
  });
}
