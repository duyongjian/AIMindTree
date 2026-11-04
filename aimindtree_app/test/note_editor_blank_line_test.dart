/// 空段落（空行）持久化回归。
///
/// 用户实测两个症状（2026-11-04）：
/// 1. 连按回车空出一屏，保存后只剩一两行 —— 空行根本没落库；
/// 2. 那些空行点不动，点一下就没了。
///
/// 根因有三处，本文件逐条钉住：
/// - `splitBlock` 在「光标在文末」时直接复用原块对象，把间隔丢了 → 序列化还是原文，
///   空段落全部蒸发；
/// - `parseMarkdownDoc` 把连续空行全塞进前一块的 `trailingGap`，空行不产生块 →
///   存盘重开必然塌掉，且没有任何可点击的块；
/// - `_normalize` 不认空段落，间隔规则不保证空段落能活过「序列化 → 重解析」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aimindtree_app/features/notes/block_model.dart';
import 'package:aimindtree_app/features/notes/markdown_block_parser.dart';
import 'package:aimindtree_app/features/notes/note_editor_body.dart';
import 'package:aimindtree_app/features/notes/note_editor_controller.dart';

/// 连按 [times] 次回车（每次都在当前活动行尾），返回最后的活动行引用。
BlockRef _enterTimes(NoteEditorController c, int times) {
  var ref = BlockRef(c.doc.blocks.first.id);
  c.focusBlock(ref, caret: c.lineControllerFor(ref).text.length);
  for (var i = 0; i < times; i++) {
    c.onLineChanged(ref, '${c.lineControllerFor(ref).text}\n');
    ref = c.active ?? ref;
  }
  return ref;
}

Widget _host(NoteEditorController c) => MaterialApp(
      home: Scaffold(
        body: SizedBox(height: 800, child: NoteEditorBody(controller: c)),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('解析：连续空行 → 真实的空段落块', () {
    test('A + 3 空行 + B → 5 块，且 L1 逐字节还原', () {
      const md = 'A\n\n\n\n\nB';
      final doc = parseMarkdownDoc(md);
      expect(doc.blocks.length, 5, reason: 'A、3 个空段落、B');
      expect(
        doc.blocks.whereType<ParagraphBlock>().length,
        5,
        reason: '多余空行要变成真正的段落块（否则点不动、存不住）',
      );
      expect(
        plainTextOf((doc.blocks[1] as ParagraphBlock).runs),
        isEmpty,
        reason: '第 2 块应是空段落',
      );
      expect(serializeDoc(doc), md, reason: 'L1：序列化必须逐字节回到原文');
      expect(parseMarkdownDoc(serializeDoc(doc)).blocks.length, 5, reason: '往返幂等');
    });

    test('尾部空行也保留成空段落（不被收进 trailingGap 就算完）', () {
      const md = 'A\n\n\n';
      final doc = parseMarkdownDoc(md);
      expect(doc.blocks.length, 2);
      expect(serializeDoc(doc), md);
    });

    test('只有一个空行的段落分隔不额外产生空段落（既有文档行为不变）', () {
      final doc = parseMarkdownDoc('A\n\nB');
      expect(doc.blocks.length, 2);
    });

    test('空行里带空格 → 不拆块、字节原样（不擅自规范化别人的文件）', () {
      const md = 'A\n  \n\nB';
      final doc = parseMarkdownDoc(md);
      expect(serializeDoc(doc), md);
    });
  });

  group('编辑器：连按回车造的空行能存住', () {
    test('回车 3 次 → 3 个空段落；存盘重开仍是 3 个，且往返稳定', () {
      final c = NoteEditorController(markdown: '正文');
      _enterTimes(c, 3);

      expect(c.doc.blocks.length, 4, reason: '正文 + 3 个空段落');
      expect(
        c.doc.blocks.skip(1).every((b) => plainTextOf((b as ParagraphBlock).runs).isEmpty),
        isTrue,
      );
      expect(
        c.markdown.replaceAll('\n', ''),
        '正文',
        reason: '空行必须真落进 Markdown（之前这里是纯「正文」，空行全丢）',
      );

      final reopened = NoteEditorController(markdown: c.markdown);
      expect(reopened.doc.blocks.length, 4, reason: '保存重开后空行一个都不能少');
      expect(reopened.markdown, c.markdown, reason: '再存一轮不增不减');

      reopened.dispose();
      c.dispose();
    });

    test('空行里打字：上面的空行不塌，且文末不留多余空行', () {
      final c = NoteEditorController(markdown: '正文');
      final ref = _enterTimes(c, 2);

      // 在最末一个空段落里输入。
      c.onLineChanged(ref, 'X');

      expect(c.doc.blocks.length, 3, reason: '两个空段落 + 正文，块数不变');
      expect(c.markdown, '正文\n\n\nX', reason: '两个空行保留，且没有多余的行尾');

      final reopened = NoteEditorController(markdown: c.markdown);
      expect(reopened.doc.blocks.length, 3);
      reopened.dispose();
      c.dispose();
    });

    testWidgets('点空段落 → 进编辑态（块不消失），能直接输入', (WidgetTester tester) async {
      final c = NoteEditorController(markdown: '正文');
      _enterTimes(c, 2);
      c.blur();

      await tester.pumpWidget(_host(c));
      await tester.pump();

      final target = find.byKey(ValueKey<String>(c.doc.blocks[1].id));
      final before = tester.getRect(target);
      await tester.tapAt(before.center);
      await tester.pump();
      await tester.pump();

      expect(c.active?.blockId, c.doc.blocks[1].id, reason: '点空段落应进入编辑态');
      expect(c.doc.blocks.length, 3, reason: '点一下不能把空行点没了');
      expect(
        tester.getRect(find.byKey(ValueKey<String>(c.doc.blocks[1].id))).height,
        greaterThan(0),
        reason: '空段落仍要占一行高度（否则看起来就是「点一下就消失」）',
      );

      // 直接在那个空段落里输入。
      await tester.enterText(find.byType(TextField), '插入');
      await tester.pump();
      expect(c.markdown.contains('插入'), isTrue);
      expect(c.doc.blocks.length, 3);
      c.dispose();
    });
  });
}
