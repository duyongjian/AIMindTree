/// 序列化往返 + 多行粘贴回归：验证多段笔记保存/重开后段落分隔不丢。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:aimindtree_app/features/notes/block_model.dart';
import 'package:aimindtree_app/features/notes/markdown_block_parser.dart';
import 'package:aimindtree_app/features/notes/note_editor_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('round-trip：多段落保存后段落分隔保留（不粘连）', () {
    const md = '第一段内容\n\n第二段内容\n\n第三段内容';
    final doc = parseMarkdownDoc(md);
    expect(doc.blocks.length, 3, reason: '应解析出 3 个段落块');

    final serialized = serializeDoc(doc);
    // 每个相邻段落之间应有空白行分隔。
    expect(serialized, contains('\n\n'), reason: '序列化应保留段间空行');

    // 再次解析应与原文一致（L1 字节直通）。
    final doc2 = parseMarkdownDoc(serialized);
    expect(doc2.blocks.length, 3, reason: '重解析仍应是 3 个段落');
    final serialized2 = serializeDoc(doc2);
    expect(serialized2, serialized, reason: '序列化应幂等');
  });

  test('编辑后序列化：段尾回车分出的空段落能存住、不粘连', () {
    // 模拟用户在两段文档的第一段末尾回车（拆出一个新段落）。
    final c = NoteEditorController(markdown: 'AAA\n\nBBB');
    expect(c.doc.blocks.length, 2);
    final ref = BlockRef(c.doc.blocks.first.id);
    c.focusBlock(ref, caret: 3);

    // TextField 里先落一个 `\n`，控制器据此判定「语义化回车」。
    c.onLineChanged(ref, 'AAA\n');

    expect(c.doc.blocks.length, 3, reason: '段尾回车应分出一个新的空段落');
    expect(c.markdown, startsWith('AAA'));

    // 关键：保存 → 重开，仍是 3 块（空段落没有被解析器并进前一块的间隔）。
    final reparsed = parseMarkdownDoc(c.markdown);
    expect(reparsed.blocks.length, 3, reason: '重解析应为 3 块，空段落不得塌进间隔');
    expect(plainTextOf((reparsed.blocks[1] as ParagraphBlock).runs), isEmpty,
        reason: '中间那块应仍是空段落');
    expect(plainTextOf((reparsed.blocks[2] as ParagraphBlock).runs), 'BBB');
    c.dispose();
  });

  group('多行粘贴 → 保存后不粘连', () {
    test('粘贴 3 行（\\n\\n 分隔）→ 3 个独立块，重解析仍 3 段', () {
      final c = NoteEditorController(markdown: '原文');
      final ref = BlockRef(c.doc.blocks.first.id);
      c.focusBlock(ref);

      // 模拟用户把「第一段\n\n第二段\n\n第三段」粘进活动行。
      c.onLineChanged(ref, '第一段\n\n第二段\n\n第三段');

      expect(c.doc.blocks.length, 3, reason: '多行粘贴应拆成 3 个独立段落块');
      expect(c.markdown, contains('第一段'));
      expect(c.markdown, contains('第二段'));
      expect(c.markdown, contains('第三段'));

      // 关键：保存（序列化）后重新打开，仍是 3 段而不是被 P3 贪吃成 1 段。
      final reopened = parseMarkdownDoc(c.markdown);
      expect(reopened.blocks.length, 3,
          reason: '保存重开后每段仍独立，不能粘成一段');
      expect(serializeDoc(reopened), c.markdown, reason: '往返幂等');
      c.dispose();
    });

    test('粘贴 3 行（单 \\n 分隔）→ 也拆成独立段落，不带残留单换行', () {
      final c = NoteEditorController(markdown: 'A');
      final ref = BlockRef(c.doc.blocks.first.id);
      c.focusBlock(ref);

      c.onLineChanged(ref, 'A\nB\nC');

      expect(c.doc.blocks.length, 3, reason: '单换行粘贴同样要拆成 3 段');
      expect(c.markdown, 'A\n\nB\n\nC',
          reason: '块间必须是空行分隔，否则 parser 会把相邻行并回一段');
      expect(parseMarkdownDoc(c.markdown).blocks.length, 3);
      c.dispose();
    });

    test('单回车仍是语义化 Enter，不被误判成粘贴', () {
      final c = NoteEditorController(markdown: 'AB');
      final ref = BlockRef(c.doc.blocks.first.id);
      c.focusBlock(ref, caret: 1);

      c.onLineChanged(ref, 'A\nB'); // 单个 \n = 回车分裂

      expect(c.doc.blocks.length, 2, reason: '单回车应分裂成 2 块');
      expect(c.markdown, contains('\n\n'), reason: '分裂后两段间应有空行');
      c.dispose();
    });

    test('粘贴文本里的 * 等字符原样保留（不跑 parseInline）', () {
      final c = NoteEditorController(markdown: 'X');
      final ref = BlockRef(c.doc.blocks.first.id);
      c.focusBlock(ref);

      c.onLineChanged(ref, 'a * b\n\nc_ d');

      // markdown 里会把特殊字符转义（`a \* b`），这是正确的无损落库；真正要守的是
      // 重新解析后编辑器里看到的纯文本仍是原字符，而没有被当作强调标记吞掉。
      final texts = parseMarkdownDoc(c.markdown)
          .blocks
          .whereType<ParagraphBlock>()
          .map((ParagraphBlock b) => plainTextOf(b.runs))
          .toList();
      expect(texts, contains('a * b'), reason: '星号不应被吞掉');
      expect(texts, contains('c_ d'), reason: '下划线不应被吞掉');
      c.dispose();
    });
  });
}
