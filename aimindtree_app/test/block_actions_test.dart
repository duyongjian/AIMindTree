/// T2 动作层验收测试：块级纯函数（设计 §5.3 / §5.4 / §5.6 / §6.1）。
///
/// 覆盖：`splitBlock` / `mergeBackward` / `setBlockType` / `toggleTaskItem` /
/// 表格增删行列 / `applyInlineMark`，以及跨动作的「不丢字符」与「L1 原文直通」不变量。
///
/// 每个动作至少 6 条断言，含正常 / 边界 / 越界 / 重复操作 / 空文档 / 长度钳制。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:aimindtree_app/features/notes/block_actions.dart';
import 'package:aimindtree_app/features/notes/block_model.dart';
import 'package:aimindtree_app/features/notes/markdown_block_parser.dart';

/// 解析一段 Markdown 并返回文档（测试里最常用的入口）。
NoteDoc d(String md) => parseMarkdownDoc(md);

/// 取第 [i] 块的锚点（整块）。
BlockRef ref(NoteDoc doc, [int i = 0]) => BlockRef(doc.blocks[i].id);

/// 取第 [i] 块里第 [k] 项的锚点（列表用）。
BlockRef itemRef(NoteDoc doc, int i, int k) {
  final b = doc.blocks[i];
  final ids = switch (b) {
    BulletListBlock(:final items) => <String>[for (final it in items) it.id],
    OrderedListBlock(:final items) => <String>[for (final it in items) it.id],
    TaskListBlock(:final items) => <String>[for (final it in items) it.id],
    _ => <String>[],
  };
  return BlockRef(b.id, itemId: ids[k]);
}

/// 整篇的「实质文本」（把块里的纯文本按顺序拼起来，用来断言不丢字符）。
String allText(NoteDoc doc) {
  final sb = StringBuffer();
  for (final b in doc.blocks) {
    switch (b) {
      case ParagraphBlock(:final runs):
      case HeadingBlock(:final runs):
        sb.write(plainTextOf(runs));
      case QuoteBlock(:final lines):
        for (final l in lines) sb.write(plainTextOf(l));
      case BulletListBlock(:final items):
        for (final it in items) sb.write(plainTextOf(it.runs));
      case OrderedListBlock(:final items):
        for (final it in items) sb.write(plainTextOf(it.runs));
      case TaskListBlock(:final items):
        for (final it in items) sb.write(plainTextOf(it.runs));
      case CodeBlock(:final code):
        sb.write(code);
      case TableBlock(:final rows):
        for (final r in rows) {
          for (final c in r) sb.write(plainTextOf(c));
        }
      case ImageBlock(:final alt):
        sb.write(alt);
      case RawBlock(:final text):
        sb.write(text);
      case DividerBlock():
        break;
    }
  }
  return sb.toString();
}

void main() {
  // =========================================================================
  // splitBlock —— 段落
  // =========================================================================
  group('splitBlock：段落', () {
    test('中间回车：两段拼接 == 原文，source 置空，caret 落在后一段', () {
      final doc = d('abcdef\n\nnext');
      final r = splitBlock(doc, ref(doc), caretOffset: 2);
      final p1 = r.doc.blocks[0] as ParagraphBlock;
      final p2 = r.doc.blocks[1] as ParagraphBlock;

      expect(plainTextOf(p1.runs) + plainTextOf(p2.runs), 'abcdef', reason: '不丢字符');
      expect(plainTextOf(p1.runs), 'ab');
      expect(plainTextOf(p2.runs), 'cdef');
      expect(p1.source, isNull, reason: '被改过 → 走规范化序列化');
      expect(p2.source, isNull);
      expect(r.caret, BlockRef(p2.id));
      expect(r.doc.blocks.length, 3);
      expect(serializeDoc(r.doc), 'ab\n\ncdef\n\nnext');
    });

    test('末尾回车：首块内容复用（source 保留、补上分隔），追加一个空段落', () {
      final doc = d('abc');
      final r = splitBlock(doc, ref(doc));
      // 内容没变 → source 继续直通（L1）。但**间隔必须补上**：文末块原本
      // `trailingGap == ''`，若直接复用原对象，新旧两块都带空间隔，序列化会退化成
      // `'abc'` —— 空段落连同分隔一起蒸发（用户实测「连按回车，保存后一行不剩」）。
      expect(r.doc.blocks[0].source, 'abc');
      expect(r.doc.blocks[0].trailingGap, '\n\n');
      expect(plainTextOf((r.doc.blocks[1] as ParagraphBlock).runs), isEmpty);
      expect(r.caret.blockId, r.doc.blocks[1].id);
      expect(r.doc.blocks.length, 2);
      // 空段落是用户敲出来的空行，必须能序列化出来，否则重开就没了。
      // （是否「文末多余空行」由控制器的 `_normalize` 统一收敛成单换行。）
      expect(serializeDoc(r.doc), 'abc\n\n');
    });

    test('开头回车：首段为空，原文整体进后一段', () {
      final doc = d('abc');
      final r = splitBlock(doc, ref(doc), caretOffset: 0);
      expect(plainTextOf((r.doc.blocks[0] as ParagraphBlock).runs), isEmpty);
      expect(plainTextOf((r.doc.blocks[1] as ParagraphBlock).runs), 'abc');
      expect(allText(r.doc), 'abc');
    });

    test('caretOffset 越界自动钳制（999 → 末尾；-5 → 开头），不抛', () {
      final doc = d('abc');
      final hi = splitBlock(doc, ref(doc), caretOffset: 999);
      expect(plainTextOf((hi.doc.blocks[0] as ParagraphBlock).runs), 'abc');
      expect(plainTextOf((hi.doc.blocks[1] as ParagraphBlock).runs), isEmpty);

      final lo = splitBlock(doc, ref(doc), caretOffset: -5);
      expect(plainTextOf((lo.doc.blocks[0] as ParagraphBlock).runs), isEmpty);
      expect(plainTextOf((lo.doc.blocks[1] as ParagraphBlock).runs), 'abc');
    });

    test('锚点不存在 → 原样返回同一个 doc 对象（不抛）', () {
      final doc = d('abc');
      final r = splitBlock(doc, const BlockRef('不存在的块'));
      expect(identical(r.doc, doc), isTrue);
      expect(r.caret, const BlockRef('不存在的块'));
    });

    test('空文档（NoteDoc.empty）分裂后仍是可序列化的空串', () {
      final doc = NoteDoc.empty();
      final r = splitBlock(doc, BlockRef(doc.blocks.first.id));
      expect(r.doc.blocks.length, 2);
      expect(serializeDoc(r.doc).trim(), '', reason: '不该凭空冒出可见内容');
      expect(allText(r.doc), '');
    });

    test('含软换行的段落：\n 被完整保留在前后两段里', () {
      final doc = NoteDoc(blocks: [
        ParagraphBlock(id: 'p1', runs: [const TextRun('ab\ncd')]),
        ParagraphBlock(id: 'p2', runs: [const TextRun('tail')]),
      ]);
      final r = splitBlock(doc, const BlockRef('p1'), caretOffset: 3);
      expect(plainTextOf((r.doc.blocks[0] as ParagraphBlock).runs), 'ab\n');
      expect(plainTextOf((r.doc.blocks[1] as ParagraphBlock).runs), 'cd');
      expect(allText(r.doc), 'ab\ncdtail');
    });

    test('带行内格式的段落：分裂后 marks 不丢', () {
      final doc = NoteDoc(blocks: [
        ParagraphBlock(id: 'p1', runs: [const TextRun('粗体字', marks: InlineMarks.bold)]),
      ]);
      final r = splitBlock(doc, const BlockRef('p1'), caretOffset: 1);
      final p1 = r.doc.blocks[0] as ParagraphBlock;
      final p2 = r.doc.blocks[1] as ParagraphBlock;
      expect((p1.runs.single as TextRun).marks, InlineMarks.bold);
      expect((p2.runs.single as TextRun).marks, InlineMarks.bold);
      expect(serializeDoc(r.doc), '**粗**\n\n**体字**');
    });
  });

  // =========================================================================
  // splitBlock —— 标题 / 引用
  // =========================================================================
  group('splitBlock：标题与引用', () {
    test('标题回车：前半留标题（级别不变），后半进新段落', () {
      final doc = d('## 标题甲乙\n\n正文');
      final r = splitBlock(doc, ref(doc), caretOffset: 3);
      final h = r.doc.blocks[0] as HeadingBlock;
      final p = r.doc.blocks[1] as ParagraphBlock;
      expect(h.level, 2);
      expect(plainTextOf(h.runs), '标题甲');
      expect(plainTextOf(p.runs), '乙');
      expect(plainTextOf(h.runs) + plainTextOf(p.runs), '标题甲乙', reason: '不丢字符');
      expect(r.caret, BlockRef(p.id));
      expect(serializeDoc(r.doc), '## 标题甲\n\n乙\n\n正文');
    });

    test('引用行中间回车：同一 QuoteBlock 内变成两行', () {
      final doc = d('> abcd\n\n尾');
      final r = splitBlock(doc, ref(doc), caretOffset: 2);
      final q = r.doc.blocks[0] as QuoteBlock;
      expect(q.lines.length, 2);
      expect(plainTextOf(q.lines[0]), 'ab');
      expect(plainTextOf(q.lines[1]), 'cd');
      expect(allText(r.doc), 'abcd尾');
      expect(serializeDoc(r.doc), '> ab\n> cd\n\n尾');
    });

    test('引用空行回车：该行退出引用成为段落（内容不丢）', () {
      final doc = d('> \n\n尾');
      final r = splitBlock(doc, ref(doc));
      expect(r.doc.blocks.first, isA<ParagraphBlock>());
      expect(allText(r.doc), '尾');
    });

    test('引用多行里的空行退出：其余行仍留在引用块里', () {
      final doc = NoteDoc(blocks: [
        QuoteBlock(id: 'q', lines: [
          [const TextRun('甲')],
          const <InlineNode>[],
          [const TextRun('乙')],
        ]),
      ]);
      final r = splitBlock(doc, const BlockRef('q'), itemIndex: 1);
      expect(r.doc.blocks.length, 2);
      expect(plainTextOf((r.doc.blocks[0] as QuoteBlock).lines.first), '甲');
      expect(allText(r.doc), '甲乙');
    });
  });

  // =========================================================================
  // splitBlock —— 列表
  // =========================================================================
  group('splitBlock：列表', () {
    test('无序列表项中间回车：块内裂成两项，文本不丢，caret 指到新项', () {
      final doc = d('- abcd\n- efg');
      final r = splitBlock(doc, itemRef(doc, 0, 0), caretOffset: 2);
      final list = r.doc.blocks[0] as BulletListBlock;
      expect(list.items.length, 3);
      expect(plainTextOf(list.items[0].runs), 'ab');
      expect(plainTextOf(list.items[1].runs), 'cd');
      expect(r.caret.itemId, list.items[1].id);
      expect(allText(r.doc), 'abcdefg');
      expect(serializeDoc(r.doc), '- ab\n- cd\n- efg');
    });

    test('空列表项回车 = 列表收尾：该项降级为列表下方的段落', () {
      final doc = NoteDoc(blocks: [
        BulletListBlock(id: 'ul', items: [
          ListItem(id: 'i1', runs: [const TextRun('a')]),
          ListItem(id: 'i2'),
        ]),
      ]);
      final r = splitBlock(doc, const BlockRef('ul', itemId: 'i2'));
      expect(r.doc.blocks.length, 2);
      expect((r.doc.blocks[0] as BulletListBlock).items.length, 1);
      expect(r.doc.blocks[1], isA<ParagraphBlock>());
      expect(r.caret.blockId, r.doc.blocks[1].id);
      expect(allText(r.doc), 'a');
      expect(serializeDoc(r.doc), '- a\n\n');
    });

    test('单项列表的空项回车：整个块原地变成段落', () {
      final doc = NoteDoc(blocks: [
        BulletListBlock(id: 'ul', items: [ListItem(id: 'i1')]),
      ]);
      final r = splitBlock(doc, const BlockRef('ul', itemId: 'i1'));
      expect(r.doc.blocks.length, 1);
      expect(r.doc.blocks.single, isA<ParagraphBlock>());
      expect(plainTextOf((r.doc.blocks.single as ParagraphBlock).runs), isEmpty);
      expect(allText(r.doc), '');
      expect(serializeDoc(r.doc), '');
    });

    test('有序列表分裂保持 start、序号连续', () {
      final doc = d('3. ab\n4. c');
      final r = splitBlock(doc, itemRef(doc, 0, 0), caretOffset: 1);
      final list = r.doc.blocks[0] as OrderedListBlock;
      expect(list.start, 3);
      expect(list.items.length, 3);
      expect(plainTextOf(list.items[0].runs), 'a');
      expect(plainTextOf(list.items[1].runs), 'b');
      expect(serializeDoc(r.doc), '3. a\n4. b\n5. c');
    });

    test('任务列表分裂：新项未勾选，检查状态不串位', () {
      final doc = d('- [x] ab');
      final r = splitBlock(doc, itemRef(doc, 0, 0), caretOffset: 1);
      final list = r.doc.blocks[0] as TaskListBlock;
      expect(list.items.length, 2);
      expect(list.items[0].checked, isTrue);
      expect(list.items[1].checked, isFalse);
      expect(allText(r.doc), 'ab');
      expect(serializeDoc(r.doc), '- [x] a\n- [ ] b');
    });

    test('itemId 过期 → 原样返回（不会误伤第 0 项）', () {
      final doc = d('- a\n- b');
      final r = splitBlock(doc, BlockRef(doc.blocks[0].id, itemId: '过期条目'));
      expect(identical(r.doc, doc), isTrue);
    });

    test('itemIndex 越界钳制到最后一项', () {
      final doc = d('- a\n- b');
      final r = splitBlock(doc, ref(doc), itemIndex: 99);
      final list = r.doc.blocks[0] as BulletListBlock;
      expect(plainTextOf(list.items[0].runs), 'a');
      expect(list.items.any((it) => plainTextOf(it.runs) == 'b'), isTrue);
      expect(allText(r.doc), 'ab');
    });
  });

  // =========================================================================
  // splitBlock —— 代码块 / 表格 / 图片等非文本块
  // =========================================================================
  group('splitBlock：代码块与非文本块', () {
    test('代码块内回车：插软换行，块数不变', () {
      final doc = d('```dart\nab\n```');
      final r = splitBlock(doc, ref(doc), caretOffset: 1);
      expect(r.doc.blocks.length, 1);
      final c = r.doc.blocks.single as CodeBlock;
      expect(c.code, 'a\nb');
      expect(c.language, 'dart', reason: '语言标注必须往返保留（R4）');
      expect(serializeDoc(r.doc), '```dart\na\nb\n```');
    });

    test('代码块末尾空行上再回车 → 退出代码块转段落，代码不丢', () {
      final doc = NoteDoc(blocks: [
        CodeBlock(id: 'c', language: 'sql', code: 'select 1\n'),
      ]);
      final r = splitBlock(doc, const BlockRef('c'));
      expect(r.doc.blocks.length, 2);
      expect((r.doc.blocks[0] as CodeBlock).code, 'select 1');
      expect(r.doc.blocks[1], isA<ParagraphBlock>());
      expect(r.caret.blockId, r.doc.blocks[1].id);
      expect(serializeDoc(r.doc).contains('select 1'), isTrue);
    });

    test('表格回车：追加一行，列数与 aligns 对齐', () {
      final doc = d('| a | b |\n| --- | :---: |\n| 1 | 2 |');
      final r = splitBlock(doc, ref(doc));
      final t = r.doc.blocks.single as TableBlock;
      expect(t.rows.length, 3);
      expect(t.rows.every((row) => row.length == 2), isTrue);
      expect(t.aligns.length, 2);
      expect(t.aligns[1], TableAlign.center);
      expect(serializeDoc(r.doc).split('\n').length, 4);
      expect(r.caret, BlockRef(t.id));
    });

    test('分割线 / 图片 / RawBlock：块本身不动（source 保留），下方插空段落', () {
      final docs = <(String, NoteDoc)>[
        ('---\n\n尾', d('---\n\n尾')),
        ('![图](aimindtree-asset://x)\n\n尾', d('![图](aimindtree-asset://x)\n\n尾')),
        ('<html>怪块</html>\n\n尾', NoteDoc(blocks: [
          RawBlock(id: 'raw', source: '<html>怪块</html>', text: '<html>怪块</html>'),
          ParagraphBlock(id: 'p', runs: [const TextRun('尾')], trailingGap: ''),
        ])),
      ];
      for (final (label, doc) in docs) {
        final before = serializeDoc(doc);
        final r = splitBlock(doc, ref(doc));
        expect(r.doc.blocks.length, 3, reason: '$label 应插入一个空段落');
        expect(r.doc.blocks[1], isA<ParagraphBlock>());
        expect(plainTextOf((r.doc.blocks[1] as ParagraphBlock).runs), isEmpty);
        expect(r.doc.blocks[0].source, isNotNull, reason: '$label 未编辑应保留 source');
        expect(serializeDoc(r.doc), before, reason: '$label 插入空段落不该改变 Markdown 字节');
        expect(r.caret.blockId, r.doc.blocks[1].id);
      }
    });
  });

  // =========================================================================
  // mergeBackward —— 段落回并
  // =========================================================================
  group('mergeBackward：段落', () {
    test('并入上一段：文本拼接、source 置空、块数减一', () {
      final doc = d('ab\n\ncd');
      final r = mergeBackward(doc, ref(doc, 1));
      expect(r.doc.blocks.length, 1);
      final p = r.doc.blocks.single as ParagraphBlock;
      expect(plainTextOf(p.runs), 'abcd');
      expect(p.source, isNull);
      expect(r.caret, BlockRef(p.id));
      expect(serializeDoc(r.doc), 'abcd');
    });

    test('并入标题：标题类型与级别保持，文本拼到标题末尾', () {
      final doc = d('# 标题\n\n尾巴');
      final r = mergeBackward(doc, ref(doc, 1));
      final h = r.doc.blocks.single as HeadingBlock;
      expect(h.level, 1);
      expect(plainTextOf(h.runs), '标题尾巴');
      expect(allText(r.doc), '标题尾巴');
      expect(serializeDoc(r.doc), '# 标题尾巴');
    });

    test('并入引用：成为引用的新末行', () {
      final doc = d('> 甲\n\n乙');
      final r = mergeBackward(doc, ref(doc, 1));
      final q = r.doc.blocks.single as QuoteBlock;
      expect(q.lines.length, 2);
      expect(plainTextOf(q.lines.last), '乙');
      expect(allText(r.doc), '甲乙');
      expect(serializeDoc(r.doc), '> 甲\n> 乙');
    });

    test('并入无序 / 有序 / 任务列表：成为新末项', () {
      final bullet = d('- a\n\nb');
      final rb = mergeBackward(bullet, ref(bullet, 1));
      final bl = rb.doc.blocks.single as BulletListBlock;
      expect(bl.items.length, 2);
      expect(plainTextOf(bl.items.last.runs), 'b');
      expect(rb.caret.itemId, bl.items.last.id);

      final ordered = d('2. a\n\nb');
      final ro = mergeBackward(ordered, ref(ordered, 1));
      final ol = ro.doc.blocks.single as OrderedListBlock;
      expect(ol.start, 2);
      expect(plainTextOf(ol.items.last.runs), 'b');
      expect(serializeDoc(ro.doc), '2. a\n3. b');

      final task = d('- [ ] a\n\nb');
      final rt = mergeBackward(task, ref(task, 1));
      final tl = rt.doc.blocks.single as TaskListBlock;
      expect(tl.items.length, 2);
      expect(tl.items.last.checked, isFalse);
      expect(serializeDoc(rt.doc), '- [ ] a\n- [ ] b');
    });

    test('上一块是代码块 / 表格 / 分割线 / 图片 / Raw → 删掉上一块，仍可序列化', () {
      final cases = <(String, NoteDoc)>[
        ('代码块', d('```dart\nx = 1\n```\n\n尾')),
        ('表格', d('| a | b |\n| --- | --- |\n| 1 | 2 |\n\n尾')),
        ('分割线', d('---\n\n尾')),
        ('图片', d('![图](aimindtree-asset://x)\n\n尾')),
        (
          'Raw',
          NoteDoc(blocks: [
            RawBlock(id: 'raw', source: '怪块', text: '怪块'),
            ParagraphBlock(id: 'p', runs: [const TextRun('尾')], trailingGap: ''),
          ]),
        ),
      ];
      for (final (label, doc) in cases) {
        final r = mergeBackward(doc, ref(doc, 1));
        expect(r.doc.blocks.length, 1, reason: '$label：上一块应被删掉');
        expect(r.doc.blocks.single, isA<ParagraphBlock>(), reason: label);
        expect(identical(r.doc.blocks.single, doc.blocks[1]), isTrue,
            reason: '$label：当前段落一个字没改，应复用原对象（L1）');
        expect(serializeDoc(r.doc), '尾', reason: label);
      }
    });

    test('首块段落无上一块 → 原样返回（不触发 pop）', () {
      final doc = d('abc');
      final r = mergeBackward(doc, ref(doc));
      expect(identical(r.doc, doc), isTrue);
      expect(r.caret, ref(doc));
    });
  });

  // =========================================================================
  // mergeBackward —— 两级降级
  // =========================================================================
  group('mergeBackward：两级降级（先降级、再合并）', () {
    test('标题 → 第一次退格降级为段落（文本保留），不再并进上一块', () {
      final doc = d('前\n\n## 标题');
      final r = mergeBackward(doc, ref(doc, 1));
      expect(r.doc.blocks.length, 2, reason: '降级不动块数');
      expect(r.doc.blocks[1], isA<ParagraphBlock>());
      expect(plainTextOf((r.doc.blocks[1] as ParagraphBlock).runs), '标题');
      expect(r.caret.blockId, r.doc.blocks[1].id);
      expect(serializeDoc(r.doc), '前\n\n标题');
    });

    test('代码块 → 降级为段落，代码内容一字不少', () {
      final doc = d('```\na = 1\nb = 2\n```');
      final r = mergeBackward(doc, ref(doc));
      final p = r.doc.blocks.single as ParagraphBlock;
      expect(plainTextOf(p.runs), 'a = 1\nb = 2');
      expect(serializeDoc(r.doc).contains('a = 1'), isTrue);
    });

    test('RawBlock → 降级为段落，原文保留', () {
      final doc = NoteDoc(blocks: [
        RawBlock(id: 'raw', source: '<div>x</div>', trailingGap: '', text: '<div>x</div>'),
      ]);
      final r = mergeBackward(doc, const BlockRef('raw'));
      expect(plainTextOf((r.doc.blocks.single as ParagraphBlock).runs), '<div>x</div>');
      expect(serializeDoc(r.doc), '<div>x</div>');
    });

    test('引用第一行 → 降级为段落，其余行仍是引用块', () {
      final doc = NoteDoc(blocks: [
        QuoteBlock(id: 'q', lines: [
          [const TextRun('甲')],
          [const TextRun('乙')],
        ]),
      ]);
      final r = mergeBackward(doc, const BlockRef('q'));
      expect(r.doc.blocks.length, 2);
      expect(plainTextOf((r.doc.blocks[0] as ParagraphBlock).runs), '甲');
      expect((r.doc.blocks[1] as QuoteBlock).lines.length, 1);
      expect(allText(r.doc), '甲乙');
    });

    test('引用非首行退格 → 并入上一行（块结构不变、行数不变）', () {
      final doc = NoteDoc(blocks: [
        QuoteBlock(id: 'q', trailingGap: '', lines: [
          [const TextRun('甲')],
          [const TextRun('乙')],
          [const TextRun('丙')],
        ]),
      ]);
      final r = mergeBackward(doc, const BlockRef('q'), itemIndex: 1);
      expect(r.doc.blocks.length, 1, reason: '不该冒出新块');
      final q = r.doc.blocks.single as QuoteBlock;
      expect(q.lines.length, 2, reason: '两行并成一行');
      expect(plainTextOf(q.lines[0]), '甲乙');
      expect(plainTextOf(q.lines[1]), '丙');
      expect(r.caret, BlockRef(q.id));
      expect(allText(r.doc), '甲乙丙', reason: '不丢字符');
      expect(serializeDoc(r.doc), '> 甲乙\n> 丙');
    });

    test('引用末行退格 → 并入倒数第二行，marks 保留', () {
      final doc = NoteDoc(blocks: [
        QuoteBlock(id: 'q', trailingGap: '', lines: [
          [const TextRun('甲')],
          [const TextRun('乙', marks: InlineMarks.bold)],
        ]),
      ]);
      final r = mergeBackward(doc, const BlockRef('q'), itemIndex: 99); // 越界 → clamp 到末行
      final q = r.doc.blocks.single as QuoteBlock;
      expect(q.lines.length, 1);
      expect(plainTextOf(q.lines.single), '甲乙');
      expect((q.lines.single.last as TextRun).marks, InlineMarks.bold);
      expect(serializeDoc(r.doc), '> 甲**乙**');
    });

    test('列表非首项 → 删本项并入前一项（不跨块）', () {
      final doc = d('- a\n- b\n- c');
      final r = mergeBackward(doc, itemRef(doc, 0, 1));
      final list = r.doc.blocks.single as BulletListBlock;
      expect(list.items.length, 2);
      expect(plainTextOf(list.items[0].runs), 'ab');
      expect(plainTextOf(list.items[1].runs), 'c');
      expect(r.caret.itemId, list.items[0].id);
      expect(allText(r.doc), 'abc');
      expect(serializeDoc(r.doc), '- ab\n- c');
    });

    test('列表首项 → 脱离列表成为独立段落；只有一项时整块变段落', () {
      final multi = d('- a\n- b');
      final r1 = mergeBackward(multi, itemRef(multi, 0, 0));
      expect(r1.doc.blocks.length, 2);
      expect(plainTextOf((r1.doc.blocks[0] as ParagraphBlock).runs), 'a');
      expect((r1.doc.blocks[1] as BulletListBlock).items.length, 1);
      expect(allText(r1.doc), 'ab');

      final single = d('- a');
      final r2 = mergeBackward(single, itemRef(single, 0, 0));
      expect(r2.doc.blocks.length, 1);
      expect(r2.doc.blocks.single, isA<ParagraphBlock>());
      expect(plainTextOf((r2.doc.blocks.single as ParagraphBlock).runs), 'a');
      expect(serializeDoc(r2.doc), 'a');
    });

    test('任务列表首项降级：勾选信息随条目一起退场，文本保留', () {
      final doc = d('- [x] a\n- [ ] b');
      final r = mergeBackward(doc, itemRef(doc, 0, 0));
      expect(plainTextOf((r.doc.blocks[0] as ParagraphBlock).runs), 'a');
      expect((r.doc.blocks[1] as TaskListBlock).items.single.checked, isFalse);
      expect(allText(r.doc), 'ab');
    });

    test('表格 / 分割线 / 图片：不跨块合并（无操作），单元格空也不动', () {
      for (final md in ['| a | b |\n| --- | --- |', '---', '![图](aimindtree-asset://x)']) {
        final doc = d(md);
        final r = mergeBackward(doc, ref(doc));
        expect(identical(r.doc, doc), isTrue, reason: md);
        expect(serializeDoc(r.doc), serializeDoc(doc), reason: md);
      }
    });

    test('锚点不存在 / 空文档的列表条目 → 不抛、不崩', () {
      final doc = d('- a');
      expect(identical(mergeBackward(doc, const BlockRef('没有这个块')).doc, doc), isTrue);
      expect(identical(mergeBackward(doc, BlockRef(doc.blocks[0].id, itemId: '过期')).doc, doc),
          isTrue);
    });
  });

  // =========================================================================
  // setBlockType
  // =========================================================================
  group('setBlockType', () {
    test('段落 → H2 → 段落：文本保真，两次都走规范化序列化', () {
      final doc = d('内容');
      final r1 = setBlockType(doc, ref(doc), BlockType.heading, headingLevel: 2);
      final h = r1.blocks.single as HeadingBlock;
      expect(h.level, 2);
      expect(plainTextOf(h.runs), '内容');
      expect(serializeDoc(r1), '## 内容');

      final r2 = setBlockType(r1, ref(r1), BlockType.paragraph);
      final p = r2.blocks.single as ParagraphBlock;
      expect(plainTextOf(p.runs), '内容');
      expect(serializeDoc(r2), '内容');
      expect(allText(r2), allText(r1));
    });

    test('标题互转只改 level，文本一个字不动；不传 level 时沿用原级别', () {
      final doc = d('### 标题');
      final r = setBlockType(doc, ref(doc), BlockType.heading, headingLevel: 1);
      final h = r.blocks.single as HeadingBlock;
      expect(h.level, 1);
      expect(plainTextOf(h.runs), '标题');
      expect(serializeDoc(r), '# 标题');

      final same = setBlockType(r, ref(r), BlockType.heading);
      expect(same.blocks.single, isA<HeadingBlock>());
      expect((same.blocks.single as HeadingBlock).level, 1);
    });

    test('headingLevel 越界收敛到 1..6（0 / 99）', () {
      final doc = d('x');
      final lo = setBlockType(doc, ref(doc), BlockType.heading, headingLevel: 0);
      expect((lo.blocks.single as HeadingBlock).level, 2, reason: '0 退化成默认 2 级');
      final hi = setBlockType(doc, ref(doc), BlockType.heading, headingLevel: 99);
      expect((hi.blocks.single as HeadingBlock).level, 6);
    });

    test('段落 → 无序 → 有序 → 任务 → 段落：文本保真，条目 id 全程复用', () {
      final doc = d('条目');
      final b = setBlockType(doc, ref(doc), BlockType.bulletList);
      final bl = b.blocks.single as BulletListBlock;
      expect(bl.items.length, 1, reason: '段落转列表 = 包成单项');
      expect(plainTextOf(bl.items.single.runs), '条目');
      expect(serializeDoc(b), '- 条目');

      final o = setBlockType(b, ref(b), BlockType.orderedList);
      final ol = o.blocks.single as OrderedListBlock;
      expect(ol.items.single.id, bl.items.single.id, reason: '条目 id 复用 → 光标不丢');
      expect(serializeDoc(o), '1. 条目');

      final t = setBlockType(o, ref(o), BlockType.taskList);
      final tl = t.blocks.single as TaskListBlock;
      expect(tl.items.single.id, ol.items.single.id);
      expect(serializeDoc(t), '- [ ] 条目');

      final back = setBlockType(t, ref(t), BlockType.paragraph);
      expect(plainTextOf((back.blocks.single as ParagraphBlock).runs), '条目');
      expect(serializeDoc(back), '条目');
    });

    test('列表项 → 标题：抬出为独立块，其余项仍留在列表里，全文字符不丢', () {
      final doc = d('- a\n- b\n- c');
      final r = setBlockType(doc, itemRef(doc, 0, 1), BlockType.heading, headingLevel: 3);
      expect(r.blocks.length, 2);
      final list = r.blocks[0] as BulletListBlock;
      final h = r.blocks[1] as HeadingBlock;
      expect(list.items.map((it) => plainTextOf(it.runs)).toList(), ['a', 'c']);
      expect(plainTextOf(h.runs), 'b');
      expect(h.level, 3);
      expect(allText(r), 'acb');
      expect(serializeDoc(r), '- a\n- c\n\n### b');
    });

    test('列表首项 → 段落：段落排在列表前面', () {
      final doc = d('- a\n- b');
      final r = setBlockType(doc, itemRef(doc, 0, 0), BlockType.paragraph);
      expect(r.blocks[0], isA<ParagraphBlock>());
      expect(r.blocks[1], isA<BulletListBlock>());
      expect(allText(r), 'ab');
    });

    test('引用第二行 → 标题：只改该行，残余引用在前，全文字符不丢', () {
      final doc = NoteDoc(blocks: [
        QuoteBlock(id: 'q', trailingGap: '', lines: [
          [const TextRun('甲')],
          [const TextRun('乙')],
          [const TextRun('丙')],
        ]),
      ]);
      final r = setBlockType(doc, const BlockRef('q'), BlockType.heading,
          headingLevel: 2, itemIndex: 1);
      expect(r.blocks.length, 2);
      final q = r.blocks[0] as QuoteBlock;
      final h = r.blocks[1] as HeadingBlock;
      expect(q.lines.length, 2, reason: '被抬出的行从引用里摘掉');
      expect(plainTextOf(q.lines[0]), '甲');
      expect(plainTextOf(q.lines[1]), '丙');
      expect(plainTextOf(h.runs), '乙');
      expect(h.level, 2);
      expect(h.id, 'q', reason: '主块占用原 id → 光标不丢');
      expect(allText(r), '甲丙乙');
      expect(serializeDoc(r), '> 甲\n> 丙\n\n## 乙');
    });

    test('setBlockType 的 itemIndex 越界 → clamp 到末行（不抛）', () {
      final doc = NoteDoc(blocks: [
        QuoteBlock(id: 'q', trailingGap: '', lines: [
          [const TextRun('甲')],
          [const TextRun('乙')],
        ]),
      ]);
      final r = setBlockType(doc, const BlockRef('q'), BlockType.paragraph, itemIndex: 99);
      expect(plainTextOf((r.blocks.last as ParagraphBlock).runs), '乙');
      expect(allText(r), '甲乙');
    });

    test('引用 → 段落：只抬第一行，其余行仍是引用', () {
      final doc = d('> 甲\n> 乙');
      final r = setBlockType(doc, ref(doc), BlockType.paragraph);
      expect(plainTextOf((r.blocks[0] as ParagraphBlock).runs), '甲');
      expect((r.blocks[1] as QuoteBlock).lines.length, 1);
      expect(allText(r), '甲乙');
    });

    test('段落 → 代码块 → 段落：文本保真', () {
      final doc = d('x = 1');
      final c = setBlockType(doc, ref(doc), BlockType.code);
      expect((c.blocks.single as CodeBlock).code, 'x = 1');
      expect(serializeDoc(c), '```\nx = 1\n```');
      final p = setBlockType(c, ref(c), BlockType.paragraph);
      expect(plainTextOf((p.blocks.single as ParagraphBlock).runs), 'x = 1');
    });

    test('表格 / 分割线 / 图片 ↔ 文本块：不可直接转 → 保持原样（不丢内容）', () {
      final table = d('| a | b |\n| --- | --- |');
      expect(identical(setBlockType(table, ref(table), BlockType.paragraph), table), isTrue);

      final divider = d('---');
      expect(identical(setBlockType(divider, ref(divider), BlockType.heading), divider), isTrue);

      final image = d('![图](aimindtree-asset://x)');
      expect(identical(setBlockType(image, ref(image), BlockType.paragraph), image), isTrue);

      final para = d('文本');
      expect(identical(setBlockType(para, ref(para), BlockType.table), para), isTrue);
      expect(identical(setBlockType(para, ref(para), BlockType.image), para), isTrue);
      expect(identical(setBlockType(para, ref(para), BlockType.divider), para), isTrue);
    });

    test('重复设置同一类型 → 返回同一个 doc（不打掉 source，L1）', () {
      final doc = d('- a');
      expect(identical(setBlockType(doc, ref(doc), BlockType.bulletList), doc), isTrue);
      final p = d('abc');
      expect(identical(setBlockType(p, ref(p), BlockType.paragraph), p), isTrue);
    });

    test('锚点不存在 → 原样返回', () {
      final doc = d('abc');
      expect(identical(setBlockType(doc, const BlockRef('查无此块'), BlockType.heading), doc), isTrue);
    });

    test('段落 → RawBlock：行内格式回落成 Markdown 字面（不丢加粗）', () {
      final doc = NoteDoc(blocks: [
        ParagraphBlock(
          id: 'p',
          trailingGap: '',
          runs: [const TextRun('粗', marks: InlineMarks.bold)],
        ),
      ]);
      final r = setBlockType(doc, const BlockRef('p'), BlockType.raw);
      final raw = r.blocks.single as RawBlock;
      expect(raw.text, '**粗**');
      expect(raw.source, isNull);
      expect(serializeDoc(r), '**粗**');
    });
  });

  // =========================================================================
  // toggleTaskItem
  // =========================================================================
  group('toggleTaskItem', () {
    test('勾选 / 取消：序列化出 [x] 与 [ ]', () {
      final doc = d('- [ ] 甲\n- [ ] 乙');
      final items = (doc.blocks.single as TaskListBlock).items;
      final on = toggleTaskItem(doc, ref(doc), items[1].id, true);
      expect((on.blocks.single as TaskListBlock).items[1].checked, isTrue);
      expect(serializeDoc(on), '- [ ] 甲\n- [x] 乙');

      final off = toggleTaskItem(on, ref(on), items[1].id, false);
      expect((off.blocks.single as TaskListBlock).items[1].checked, isFalse);
      expect(serializeDoc(off), '- [ ] 甲\n- [ ] 乙');
    });

    test('重复设置同一个值 → 原样返回同一个 doc（不打掉 source）', () {
      final doc = d('- [x] 甲');
      final id = (doc.blocks.single as TaskListBlock).items.single.id;
      expect(identical(toggleTaskItem(doc, ref(doc), id, true), doc), isTrue);
    });

    test('itemId 不存在 / 非任务块 → 原样返回', () {
      final doc = d('- [ ] 甲');
      expect(identical(toggleTaskItem(doc, ref(doc), '查无此项', true), doc), isTrue);
      final para = d('abc');
      expect(identical(toggleTaskItem(para, ref(para), 'x', true), para), isTrue);
    });

    test('锚点是别的块时，按 itemId 兜底找到任务列表（T4 点只读复选框的场景）', () {
      final doc = d('前言\n\n- [ ] 甲');
      final id = (doc.blocks[1] as TaskListBlock).items.single.id;
      final r = toggleTaskItem(doc, ref(doc), id, true);
      expect((r.blocks[1] as TaskListBlock).items.single.checked, isTrue);
      expect(r.blocks[0].source, isNotNull, reason: '前一块没被碰过，source 必须保留');
    });
  });

  // =========================================================================
  // 表格结构编辑
  // =========================================================================
  group('表格增删行列', () {
    test('插入行：列数保持一致，aligns 不变，序列化仍是合法 GFM', () {
      final doc = d('| a | b |\n| :-- | --: |\n| 1 | 2 |');
      final r = insertTableRow(doc, ref(doc), 1);
      final t = r.blocks.single as TableBlock;
      expect(t.rows.length, 3);
      expect(t.rows.every((row) => row.length == 2), isTrue);
      expect(t.aligns, [TableAlign.left, TableAlign.right]);
      final md = serializeDoc(r);
      expect(md.split('\n').length, 4);
      expect(md.contains('| :--- | ---: |'), isTrue, reason: '对齐规范化后仍是左/右对齐');
      expect(d(md).blocks.single, isA<TableBlock>(), reason: '输出必须还能解析回来');
    });

    test('插入行越界 → clamp 到末尾（不抛）', () {
      final doc = d('| a | b |\n| --- | --- |');
      for (final after in <int>[-10, 99]) {
        final t = insertTableRow(doc, ref(doc), after).blocks.single as TableBlock;
        expect(t.rows.length, 2, reason: 'afterRow=$after（原表只有表头一行）');
        expect(t.rows.every((row) => row.length == 2), isTrue);
      }
    });

    test('删除行：越界 / 只剩一行 → 原样返回', () {
      final doc = d('| a | b |\n| --- | --- |\n| 1 | 2 |');
      final r = removeTableRow(doc, ref(doc), 1);
      expect((r.blocks.single as TableBlock).rows.length, 1);
      expect(identical(removeTableRow(doc, ref(doc), 99), doc), isTrue);
      expect(identical(removeTableRow(doc, ref(doc), -1), doc), isTrue);
      final one = d('| a | b |\n| --- | --- |');
      expect(identical(removeTableRow(one, ref(one), 0), one), isTrue, reason: '不能没有表体');
    });

    test('插入列：每行补齐 + aligns 同步插入 none', () {
      final doc = d('| a | b |\n| --- | :---: |\n| 1 | 2 |');
      final r = insertTableColumn(doc, ref(doc), 0);
      final t = r.blocks.single as TableBlock;
      expect(t.aligns.length, 3);
      expect(t.aligns, [TableAlign.none, TableAlign.none, TableAlign.center]);
      expect(t.rows.every((row) => row.length == 3), isTrue);
      expect(serializeDoc(r).split('\n').first, '| a |  | b |', reason: '新列插在 afterCol 之后');
    });

    test('删除列：rows 与 aligns 同步裁掉；只剩一列 / 越界 → 原样返回', () {
      final doc = d('| a | b |\n| :-- | --: |\n| 1 | 2 |');
      final r = removeTableColumn(doc, ref(doc), 0);
      final t = r.blocks.single as TableBlock;
      expect(t.aligns, [TableAlign.right]);
      expect(t.rows.every((row) => row.length == 1), isTrue);
      expect(serializeDoc(r).split('\n').first, '| b |');

      final one = d('| a |\n| --- |');
      expect(identical(removeTableColumn(one, ref(one), 0), one), isTrue);
      expect(identical(removeTableColumn(doc, ref(doc), 5), doc), isTrue);
    });

    test('短行（手工构造的列数不一致）先补齐再操作', () {
      final doc = NoteDoc(blocks: [
        TableBlock(id: 'tb', aligns: const [], rows: [
          [<InlineNode>[const TextRun('h1')]],
          [<InlineNode>[const TextRun('a')], <InlineNode>[const TextRun('b')]],
        ]),
      ]);
      final r = insertTableRow(doc, const BlockRef('tb'), 0);
      final t = r.blocks.single as TableBlock;
      expect(t.rows.length, 3);
      expect(t.rows.every((row) => row.length == 2), isTrue, reason: '列数 = 最大列数');
      expect(t.aligns.length, 2);
      expect(serializeDoc(r).contains('| h1 |  |'), isTrue);
    });

    test('对非表格块做表格操作 → 原样返回', () {
      final doc = d('abc');
      expect(identical(insertTableRow(doc, ref(doc), 0), doc), isTrue);
      expect(identical(removeTableColumn(doc, ref(doc), 0), doc), isTrue);
      expect(identical(insertTableColumn(doc, const BlockRef('没有'), 0), doc), isTrue);
    });
  });

  // =========================================================================
  // applyInlineMark
  // =========================================================================
  group('applyInlineMark', () {
    test('区间加粗 / 取消：文本不变，marks 位正确', () {
      final runs = parseInline('hello world');
      final on = applyInlineMark(runs, 0, 5, InlineMarks.bold, on: true);
      expect(plainTextOf(on), 'hello world');
      expect((on[0] as TextRun).marks.has(InlineMarks.bold), isTrue);
      expect((on[1] as TextRun).marks.has(InlineMarks.bold), isFalse);

      final off2 = applyInlineMark(on, 0, 5, InlineMarks.bold, on: false);
      expect((off2.single as TextRun).marks.has(InlineMarks.bold), isFalse);
      expect(serializeInline(off2), 'hello world');
    });

    test('越界 clamp（-3 / 999）不抛', () {
      final runs = parseInline('abc');
      final r = applyInlineMark(runs, -3, 999, InlineMarks.italic, on: true);
      expect(plainTextOf(r), 'abc');
      expect((r.single as TextRun).marks.has(InlineMarks.italic), isTrue);
      expect(serializeInline(r), '*abc*');
    });

    test('折叠区间（start == end）原样返回，不打标记', () {
      final runs = parseInline('abc');
      final r = applyInlineMark(runs, 1, 1, InlineMarks.bold, on: true);
      expect(runsEqual(r, runs), isTrue);
      expect(serializeInline(r), 'abc');
    });
  });

  // =========================================================================
  // 跨动作：不丢字符 + L1 原文直通
  // =========================================================================
  group('全局不变量', () {
    test('未编辑的文档：序列化与原文逐字节相等（L1）', () {
      const md = '# 标题\n\n段落 **粗** 与 `code`\n\n- a\n- b\n\n> 引用\n\n```dart\nx\n```\n';
      final doc = d(md);
      expect(serializeDoc(doc), md);
    });

    test('改一个块不影响其它块的 source（L1 局部性）', () {
      final doc = d('# 标题\n\n段落\n\n- a\n- b\n\n尾');
      final r = setBlockType(doc, ref(doc, 2), BlockType.taskList);
      expect(r.blocks.length, 4);
      expect(r.blocks[0].source, isNotNull);
      expect(r.blocks[1].source, isNotNull);
      expect(r.blocks[2].source, isNull, reason: '被改的块必须置空');
      expect(r.blocks[3].source, isNotNull);
      expect(serializeDoc(r).startsWith('# 标题\n\n段落\n\n'), isTrue);
    });

    test('一串连续动作后：全文实质字符只增不减，且始终可序列化', () {
      final doc = d('# 标题\n\n段落甲\n\n- a\n- b');
      var cur = doc;
      cur = setBlockType(cur, ref(cur, 0), BlockType.paragraph); // 标题→段落
      cur = splitBlock(cur, ref(cur, 1), caretOffset: 2).doc; // 段落分裂
      cur = mergeBackward(cur, ref(cur, 2)).doc; // 与上一块合并
      cur = setBlockType(cur, ref(cur, 2), BlockType.taskList); // 列表变任务
      cur = splitBlock(cur, itemRef(cur, 2, 0), caretOffset: 1).doc; // 任务项分裂
      final md = serializeDoc(cur);
      expect(md.contains('标题'), isTrue);
      expect(md.contains('段落'), isTrue);
      expect(md.contains('a'), isTrue);
      expect(md.contains('b'), isTrue);
      expect(allText(cur), '标题段落甲ab', reason: '一个字都不能丢');
      expect(() => d(md), returnsNormally, reason: '输出必须还能被解析回来');
    });
  });
}
