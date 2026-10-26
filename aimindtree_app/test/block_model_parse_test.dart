/// T1 数据层验收测试：解析 / 序列化 / 无损三级降级 / 行内投影。
///
/// 重点覆盖设计 §9（T1 验收标准）：
/// - L1 字节相等：`serializeDoc(parseMarkdownDoc(md)) == md`（先 `\r\n→\n` 归一化）
/// - L2 幂等：规范化序列化是解析的固定点（编辑态也稳定）
/// - L3 字符零丢失（stripNoise 保真）
/// - 未闭合围栏补齐且幂等、含图段落切开、删除线、任务列表不被当普通列表、
///   表格对齐往返、代码块语言往返
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:aimindtree_app/features/notes/block_model.dart';
import 'package:aimindtree_app/features/notes/markdown_block_parser.dart';

/// 去掉所有空白与 Markdown 标点，只保留「实质字符」，用于比较是否丢字。
String stripNoise(String s) => s
    .replaceAll(RegExp(r'[\s`*_~\[\]()#+\-.!~|>:\\/]'), '')
    .replaceAll('aimindtree-asset://', '');

/// 跨越多结构的语料（≥30 条），覆盖中文 / 标点 / 缩进 / CRLF / 行尾空格 / 转义等。
const List<String> kCorpus = <String>[
  '', // 空
  'hello world', // 单段落
  '# 一级标题',
  '## 二级标题',
  '### 三级标题 带 *粗*',
  '普通段落 含 **粗** 与 *斜* 与 `代码`',
  '删除线 ~~strike~~ 示例',
  '> 引用一行',
  '> 多行\n> 引用\n> 第三行',
  '- 无序一\n- 无序二\n- 无序三',
  '* 星号列表',
  '+ 加号列表',
  '1. 有序一\n2. 有序二\n3. 有序三',
  '- [ ] 待办一\n- [x] 已办二',
  '```\n纯代码块\n```',
  '```dart\nvoid main() {}\n```',
  '| 表头 | 说明 |\n| --- | --- |\n| 行1 | a |\n| 行2 | b |',
  '| 左 | 中 | 右 |\n| :--- | :---: | ---: |\n| a | b | c |',
  '---',
  '***',
  '___',
  '# 标题\n\n段落正文\n\n> 引用\n\n- 列表项',
  '前文 ![图](aimindtree-asset://id1) 后文',
  '![单独图](aimindtree-asset://id2)',
  '段落一\n\n段落二\n\n段落三',
  '行尾空格保留  \n', // 带行尾两空格
  '  行首空格保留',
  '混合 **粗 _斜_ 嵌套** 文本',
  '[链接文本](https://example.com) 普通',
  '5.不是列表\n普通行', // 点后无空白 → 不是有序列表
  '#话题 不应是标题',
  '| 没有下一行分隔的竖线表',
  '嵌套缩进续行\n- 父\n  子续行一\n  子续行二',
  '未闭合围栏代码\n```\nint x = 1;',
  '随便一段 | 没有分隔行 |',
  '引用里 **粗** 与 `码`\n> 引用 *斜* 文本',
  '标题\n\n---\n\n段落',
  'CRLF 测试\r\n第二行', // CRLF 会被归一化
  '表格后接普通\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n尾部段落',
];

/// 把所有块的 source 清空（模拟「被用户编辑过」），用于验证规范化序列化路径。
NoteDoc _edited(NoteDoc doc) => NoteDoc(
      prologue: doc.prologue,
      blocks: <Block>[for (final b in doc.blocks) _clearSource(b)],
    );

Block _clearSource(Block b) => switch (b) {
      ParagraphBlock(:final id, :final runs, :final trailingGap) =>
        ParagraphBlock(id: id, runs: runs, trailingGap: trailingGap),
      HeadingBlock(:final id, :final level, :final runs, :final trailingGap) =>
        HeadingBlock(id: id, level: level, runs: runs, trailingGap: trailingGap),
      QuoteBlock(:final id, :final lines, :final trailingGap) =>
        QuoteBlock(id: id, lines: lines, trailingGap: trailingGap),
      BulletListBlock(:final id, :final items, :final trailingGap) =>
        BulletListBlock(id: id, items: items, trailingGap: trailingGap),
      OrderedListBlock(:final id, :final start, :final items, :final trailingGap) =>
        OrderedListBlock(id: id, start: start, items: items, trailingGap: trailingGap),
      TaskListBlock(:final id, :final items, :final trailingGap) =>
        TaskListBlock(id: id, items: items, trailingGap: trailingGap),
      CodeBlock(:final id, :final language, :final code, :final trailingGap) =>
        CodeBlock(id: id, language: language, code: code, trailingGap: trailingGap),
      TableBlock(
        :final id,
        :final hasHeader,
        :final aligns,
        :final rows,
        :final trailingGap
      ) =>
        TableBlock(
          id: id,
          hasHeader: hasHeader,
          aligns: aligns,
          rows: rows,
          trailingGap: trailingGap,
        ),
      DividerBlock(:final id, :final trailingGap) =>
        DividerBlock(id: id, trailingGap: trailingGap),
      ImageBlock(:final id, :final assetId, :final alt, :final trailingGap) =>
        ImageBlock(id: id, assetId: assetId, alt: alt, trailingGap: trailingGap),
      RawBlock(:final id, :final text, :final trailingGap) =>
        RawBlock(id: id, text: text, trailingGap: trailingGap),
    };

void main() {
  // ---------------------------------------------------------------------
  // L1：未编辑块 byte-exact 直通
  // ---------------------------------------------------------------------
  test('L1：serializeDoc(parseMarkdownDoc(md)) == md（多语料字节相等）', () {
    for (final md in kCorpus) {
      final normalized = md.replaceAll('\r\n', '\n');
      final doc = parseMarkdownDoc(normalized);
      expect(serializeDoc(doc), normalized, reason: 'L1 失败于语料：\n<<$md>>');
    }
  });

  // ---------------------------------------------------------------------
  // L2：规范化序列化幂等（设计 §4.1 原定义：parse(serialize(parse(md))) ≡ parse(md)）
  // 注：未编辑块序列化走 source 直通（L1），故该等式天然成立；此处逐语料锁死。
  // ---------------------------------------------------------------------
  test('L2：parse(serialize(parse(md))) ≡ parse(md)（结构相等）', () {
    for (final md in kCorpus) {
      final normalized = md.replaceAll('\r\n', '\n');
      final doc = parseMarkdownDoc(normalized);
      final doc2 = parseMarkdownDoc(serializeDoc(doc)); // serialize 走 source 直通 → 回到 md
      expect(structuralEquals(doc, doc2), isTrue,
          reason: 'L2 失败于语料：\n<<$md>>');
    }
  });

  // 额外：编辑态（source 清空）下，常见块规范化往返稳定（不含多层嵌套强调邻接这种
  // Markdown 固有歧义的情形，那一类用 L1 原文直通覆盖）。
  test('L2（编辑态）：常见块规范化往返稳定', () {
    const simples = <String>[
      '# 标题',
      '- 列表一\n- 列表二',
      '1. 一\n2. 二',
      '- [ ] a\n- [x] b',
      '```dart\nvoid main() {}\n```',
      '| a | b |\n| --- | --- |\n| 1 | 2 |',
      '普通段落 含 **粗** 与 *斜* 与 `代码`',
      '删除线 ~~strike~~ 示例',
      '> 引用一行',
    ];
    for (final md in simples) {
      final normalized = md.replaceAll('\r\n', '\n');
      final doc = parseMarkdownDoc(normalized);
      final s1 = serializeDoc(_edited(doc));
      final doc2 = parseMarkdownDoc(s1);
      final s2 = serializeDoc(_edited(doc2));
      expect(s2, s1, reason: '编辑态往返失败于：\n<<$md>>');
    }
  });

  // ---------------------------------------------------------------------
  // L3：字符零丢失
  // ---------------------------------------------------------------------
  test('字符零丢失：stripNoise 前后保真', () {
    for (final md in kCorpus) {
      final normalized = md.replaceAll('\r\n', '\n');
      final doc = parseMarkdownDoc(normalized);
      expect(
        stripNoise(serializeDoc(doc)),
        stripNoise(normalized),
        reason: '字符丢失于语料：\n<<$md>>',
      );
    }
  });

  // ---------------------------------------------------------------------
  // 解析器鲁棒性：刁钻输入不崩、不丢字符
  // ---------------------------------------------------------------------
  test('解析器对刁钻输入不崩、不丢字符', () {
    const inputs = <String>[
      '> > nested\n> quote',
      '1. 一\n2. 二\n   缩进续行',
      '- a\n- b\n\n- c',
      '~~未闭合删除线\n**未闭合粗体',
      '   ',
      '---',
      '* a\n* b',
      '[链接](https://example.com)',
      'a `code 里含 * 星号` b',
      '普通段落里含 ![外链](http://x.com/a.png) 不切开', // 非 asset 协议 → 当文字
    ];
    for (final inp in inputs) {
      final normalized = inp.replaceAll('\r\n', '\n');
      final doc = parseMarkdownDoc(normalized);
      expect(
        stripNoise(serializeDoc(doc)),
        stripNoise(normalized),
        reason: '刁钻输入丢字：\n<<$inp>>',
      );
    }
  });

  // ---------------------------------------------------------------------
  // 具体验收点
  // ---------------------------------------------------------------------
  test('含图段落 → P / Image / P（且 assetId / alt 正确）', () {
    final doc = parseMarkdownDoc('前文 ![alt文字](aimindtree-asset://abc123) 后文');
    expect(
      doc.blocks.map((b) => b.type).toList(),
      [BlockType.paragraph, BlockType.image, BlockType.paragraph],
    );
    final img = doc.blocks[1] as ImageBlock;
    expect(img.assetId, 'abc123');
    expect(img.alt, 'alt文字');
    // 序列化回去仍是原样
    expect(serializeDoc(doc), '前文 ![alt文字](aimindtree-asset://abc123) 后文');
  });

  test('~~删除线~~ → strike run', () {
    final doc = parseMarkdownDoc('这是 ~~删除线~~ 文本');
    final p = doc.blocks.single as ParagraphBlock;
    final strikeRun = p.runs.whereType<TextRun>().firstWhere(
      (r) => r.marks.has(InlineMarks.strike),
    );
    expect(strikeRun.text, '删除线');
    expect(plainTextOf(p.runs), '这是 删除线 文本');
  });

  test('- [ ] 任务列表 不被当普通列表', () {
    final doc = parseMarkdownDoc('- [ ] 未做\n- [x] 已做');
    expect(doc.blocks.single, isA<TaskListBlock>());
    final tl = doc.blocks.single as TaskListBlock;
    expect(tl.items.length, 2);
    expect(tl.items[0].checked, isFalse);
    expect(tl.items[1].checked, isTrue);
    // 串行化回去
    expect(serializeDoc(doc), '- [ ] 未做\n- [x] 已做');
  });

  test('表格对齐往返保留', () {
    const md =
        '| 左 | 中 | 右 |\n| :--- | :---: | ---: |\n| a | b | c |';
    final doc = parseMarkdownDoc(md);
    final tb = doc.blocks.single as TableBlock;
    expect(tb.aligns[0], TableAlign.left);
    expect(tb.aligns[1], TableAlign.center);
    expect(tb.aligns[2], TableAlign.right);
    expect(serializeDoc(doc), md);
  });

  test('代码块语言往返保留', () {
    const md = '```dart\nvoid main() {}\n```';
    final doc = parseMarkdownDoc(md);
    final cb = doc.blocks.single as CodeBlock;
    expect(cb.language, 'dart');
    expect(cb.code, 'void main() {}');
    expect(serializeDoc(doc), md);
  });

  test('未闭合围栏：补齐且幂等', () {
    const md = '```\nint x = 0;';
    final doc = parseMarkdownDoc(md);
    // 源未编辑，L1 仍原样（不擅自补围栏）
    expect(serializeDoc(doc), md);

    // 模拟「被编辑过」：重造 CodeBlock（source 置空）
    final edited = NoteDoc(
      blocks: <Block>[
        CodeBlock(
          id: doc.blocks.single.id,
          language: (doc.blocks.single as CodeBlock).language,
          code: (doc.blocks.single as CodeBlock).code,
          trailingGap: doc.blocks.single.trailingGap,
        ),
      ],
    );
    final out = serializeDoc(edited);
    expect(out, '```\nint x = 0;\n```'); // 补齐收尾围栏

    // 补齐后再解析、再规范化，结果稳定（幂等）
    final doc2 = parseMarkdownDoc(out);
    final out2 = serializeDoc(NoteDoc(
      blocks: <Block>[
        CodeBlock(
          id: doc2.blocks.single.id,
          language: (doc2.blocks.single as CodeBlock).language,
          code: (doc2.blocks.single as CodeBlock).code,
          trailingGap: doc2.blocks.single.trailingGap,
        ),
      ],
    ));
    expect(out2, out);
  });

  test('RawBlock 兜底：原文可编辑、字符不丢', () {
    const text = '# 这不是标题，是原文\n- 也不是列表';
    final rb = RawBlock(id: 'r', text: text, trailingGap: '');
    expect(rb.textEditable, isFalse); // 走「别的编辑入口」（等宽原文框）
    expect(serializeDoc(NoteDoc(blocks: <Block>[rb])), text);
  });

  test('NoteDoc.empty() 序列化为空串（R1）', () {
    expect(serializeDoc(NoteDoc.empty()), '');
  });

  test('escapeLineStart：行首块起始符被转义，二次解析仍是段落', () {
    // 段落首字符像列表 → 转义
    final out = escapeLineStart('- 看起来像列表');
    expect(out, r'\- 看起来像列表');
    final doc = parseMarkdownDoc(out);
    expect(doc.blocks.single, isA<ParagraphBlock>());
    // 标题 / 引用 / 数字. / 竖线 同理
    expect(escapeLineStart('# 不是标题'), r'\# 不是标题');
    expect(escapeLineStart('> 不是引用'), r'\> 不是引用');
    expect(escapeLineStart('1. 不是有序'), r'\1. 不是有序');
    expect(escapeLineStart('| 不是表格'), r'\| 不是表格');
  });
}
