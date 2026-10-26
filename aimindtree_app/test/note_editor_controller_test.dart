/// T3 控制层验收测试（`note_editor_controller.dart`）。
///
/// 覆盖设计 §9 / §10 T3 的验收口径：
/// - **L1 字节直通**：`setMarkdown(md)` 之后 `markdown == md`（逐字节），
///   这是「打开没改却变脏」与「同步假冲突」的唯一根因；
/// - 换类型 / 分裂 / 退格后**字符不丢**，且 `caret` 锚点符合设计 §5.4–§5.6；
/// - 打字时的行内格式投影（加粗不会因为敲字被吃掉）；
/// - 回车 / 退格的语义矩阵（段落 / 标题 / 引用 / 列表 / 代码块 / 表格）；
/// - 任务勾选、表格单元格、代码块语言往返。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aimindtree_app/features/notes/block_model.dart';
import 'package:aimindtree_app/features/notes/block_view.dart';
import 'package:aimindtree_app/features/notes/note_editor_body.dart';
import 'package:aimindtree_app/features/notes/note_editor_controller.dart';

/// 语料：覆盖各种块形态（与 T1 的解析语料同源，但这里只关心「控制器不改原文」）。
const List<String> kCorpus = <String>[
  '',
  'hello world',
  '# 一级标题',
  '## 二级标题',
  '普通段落 含 **粗** 与 *斜* 与 `代码`',
  '删除线 ~~strike~~ 示例',
  '> 引用一行',
  '> 多行\n> 引用\n> 第三行',
  '- 无序一\n- 无序二',
  '1. 有序一\n2. 有序二',
  '- [ ] 待办一\n- [x] 已办二',
  '```dart\nvoid main() {}\n```',
  '| 表头 | 说明 |\n| --- | --- |\n| 行1 | a |',
  '---',
  '# 标题\n\n段落正文\n\n> 引用\n\n- 列表项',
  '前文 ![图](aimindtree-asset://id1) 后文',
  '段落一\n\n段落二\n\n段落三',
  '  行首空格保留',
  '行尾空格保留  \n',
  '随便一段 | 没有分隔行 |',
  '标题\n\n---\n\n段落',
];

BlockRef _firstRef(NoteEditorController c) => BlockRef(c.doc.blocks.first.id);

void main() {
  // FocusNode / HardwareKeyboard 需要 Widgets 绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('L1 字节直通（红线）', () {
    test('load → markdown 逐字节相等（未编辑文档）', () {
      for (final md in kCorpus) {
        final c = NoteEditorController();
        c.load(md);
        expect(c.markdown, md, reason: 'L1 直通失败：${md.replaceAll('\n', '\\n')}');
        c.dispose();
      }
    });

    test('进入 / 退出编辑态不算改动（不产生脏）', () {
      const md = '# 标题\n\n段落正文\n\n- 列表\n\n> 引用';
      final c = NoteEditorController(markdown: md);
      c.focusBlock(_firstRef(c), caret: 2);
      expect(c.isEditing, isTrue);
      c.blur();
      expect(c.isEditing, isFalse);
      expect(c.markdown, md);
      c.dispose();
    });

    test('空文档序列化为空串', () {
      final c = NoteEditorController();
      expect(c.markdown, '');
      expect(c.doc.blocks, hasLength(1));
      c.dispose();

      final onlyBlank = NoteEditorController(markdown: '\n\n');
      expect(onlyBlank.markdown, '\n\n');
      onlyBlank.dispose();
    });
  });

  group('换类型', () {
    test('标题 → 段落 → 标题：字符不丢，caret 严格不变', () {
      final c = NoteEditorController(markdown: '## 二级标题');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 2);
      expect(c.textOf(ref), '二级标题');

      c.convertActiveTo(BlockType.heading, level: 3);
      final h = c.doc.blocks.single as HeadingBlock;
      expect(h.level, 3);
      expect(c.textOf(ref), '二级标题');
      expect(c.caretOf(ref), 2, reason: '换类型不改文本 → 光标必须原地不动');
      expect(c.markdown, '### 二级标题');

      // 同一级再点一次 → 回落段落。
      c.convertActiveTo(BlockType.heading, level: 3);
      expect(c.doc.blocks.single, isA<ParagraphBlock>());
      expect(c.textOf(ref), '二级标题');
      expect(c.caretOf(ref), 2);
      expect(c.markdown, '二级标题');
      c.dispose();
    });

    test('段落 → 无序列表 → 引用：文本一个字都不丢', () {
      final c = NoteEditorController(markdown: '正文 **粗** 文本');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 3);

      c.convertActiveTo(BlockType.bulletList);
      expect(c.doc.blocks.single, isA<BulletListBlock>());
      expect(c.markdown, '- 正文 **粗** 文本');

      final list = c.doc.blocks.single as BulletListBlock;
      final itemRef = BlockRef(list.id, itemId: list.items.single.id);
      c.focusBlock(itemRef, caret: 3);
      c.convertActiveTo(BlockType.quote);
      expect(c.doc.blocks.single, isA<QuoteBlock>());
      expect(c.markdown, '> 正文 **粗** 文本');
      c.dispose();
    });

    test('引用多行只把光标那一行拎出来（其余行留在原块）', () {
      final c = NoteEditorController(markdown: '> 第一行\n> 第二行');
      final q = c.doc.blocks.single as QuoteBlock;
      c.focusBlock(quoteLineRef(q.id, 1), caret: 2);
      c.convertActiveTo(BlockType.heading, level: 2);

      expect(c.doc.blocks, hasLength(2));
      expect(c.doc.blocks[0], isA<QuoteBlock>());
      expect(c.doc.blocks[1], isA<HeadingBlock>());
      expect(plainTextOf((c.doc.blocks[0] as QuoteBlock).lines.single), '第一行');
      expect(plainTextOf((c.doc.blocks[1] as HeadingBlock).runs), '第二行');
      expect(c.caretOf(c.active!), 2);
      expect(c.markdown, '> 第一行\n\n## 第二行');
      c.dispose();
    });

    test('引用首行 → 标题：主块在前、残余引用在后（块顺序 + 行引用形状迁移）', () {
      // 与上一条互补：那条守 `li == 1`「只抬一行（残余在前）」；这条守 `li == 0`
      // 时**残余块的插入位置**（主块在前）。顺序反了会在 `as HeadingBlock` 处直接抛
      // TypeError，不是软断言 —— 将来若有人「顺手统一」成残余在前，这里必红。
      final c = NoteEditorController(markdown: '> 一\n> 二');
      final q = c.doc.blocks.single as QuoteBlock;
      c.focusBlock(quoteLineRef(q.id, 0));
      c.convertActiveTo(BlockType.heading, level: 1);

      expect(c.doc.blocks, hasLength(2));
      final h = c.doc.blocks[0] as HeadingBlock;
      final rest = c.doc.blocks[1] as QuoteBlock;
      expect(plainTextOf(h.runs), '一');
      expect(h.level, 1);
      expect(rest.lines, hasLength(1));
      expect(plainTextOf(rest.lines.single), '二');
      expect(h.id, q.id, reason: '主块占用原 id，残余引用才用新 id');
      expect(c.markdown, '# 一\n\n> 二');

      // 行引用形状迁移：`'q:0'`（引用行）→ `null`（块级）。标题不接受带 itemId 的
      // 行引用（`_isValidRef` 要求 null），所以控制器必须重新锚定到主块第一行 ——
      // 这正是「换类型后输入框消失」那个缺陷的根因形态，缺了这条断言看不出来。
      expect(c.active, isNotNull);
      expect(c.active!.blockId, h.id);
      expect(c.active!.itemId, isNull);
      expect(c.caretOf(c.active!), 0);
      c.dispose();
    });

    test('段落 → 列表后 active 必须指向新块的第一行（不许掉出编辑态）', () {
      // 回归：T4 接线时用探针发现的真缺陷 —— 换类型后行引用形状变了
      // （段落 → 列表多出 itemId），沿用旧 ref 会让该块「点完按钮输入框消失」。
      final c = NoteEditorController(markdown: 'abc');
      final blockId = c.doc.blocks.first.id;
      c.focusBlock(_firstRef(c), caret: 2);
      c.convertActiveTo(BlockType.bulletList);

      final list = c.doc.blocks.single as BulletListBlock;
      expect(c.isEditing, isTrue, reason: '换类型后必须仍在编辑态');
      expect(c.active!.blockId, blockId);
      expect(c.active!.itemId, list.items.single.id);
      expect(c.textOf(c.active!), 'abc');
      expect(c.caretOf(c.active!), 2, reason: '换类型不改文本 → 光标仍严格不变');
      c.dispose();
    });

    test('无序 → 有序：整块保留（条目与 id 全复用），光标不动', () {
      // 设计 §5.6：同类列表互转只换外壳、不拆块。T5a 起交给
      // `block_actions.setBlockType`（它的 retarget 保留每个条目的 id）。
      final c = NoteEditorController(markdown: '- 一\n- 二');
      final list = c.doc.blocks.single as BulletListBlock;
      final item = list.items[1];
      c.focusBlock(BlockRef(list.id, itemId: item.id), caret: 1);

      c.convertActiveTo(BlockType.orderedList);
      final ordered = c.doc.blocks.single as OrderedListBlock;
      expect(ordered.items, hasLength(2));
      expect(ordered.items[1].id, item.id, reason: '条目 id 必须复用，光标才不丢');
      expect(c.markdown, '1. 一\n2. 二');
      expect(c.caretOf(c.active!), 1);
      c.dispose();
    });

    test('多行块不接受「块级 ref」（幽灵行防护）', () {
      for (final md in <String>['- a', '> b', '| c |\n| --- |\n| d |']) {
        final c = NoteEditorController(markdown: md);
        final id = c.doc.blocks.first.id;
        c.focusBlock(BlockRef(id));
        expect(c.isEditing, isFalse, reason: '块级 ref 不能开启幽灵编辑态：$md');
        c.dispose();
      }
      // 单行块仍接受块级 ref（它们的行引用就是 BlockRef(blockId)）。
      final c = NoteEditorController(markdown: '段落');
      c.focusBlock(_firstRef(c), caret: 1);
      expect(c.isEditing, isTrue);
      c.dispose();
    });
  });

  group('Enter 分裂', () {
    test('段落分裂：两段拼接 == 原文，新块 caret 为 0', () {
      final c = NoteEditorController(markdown: 'abcdef');
      final ref = _firstRef(c);
      final firstId = c.doc.blocks.first.id;
      c.focusBlock(ref, caret: 3);
      c.onLineChanged(ref, 'abc\ndef');

      expect(c.doc.blocks, hasLength(2));
      expect(plainTextOf((c.doc.blocks[0] as ParagraphBlock).runs), 'abc');
      expect(plainTextOf((c.doc.blocks[1] as ParagraphBlock).runs), 'def');
      final joined = <String>[
        for (final b in c.doc.blocks)
          if (b is ParagraphBlock) plainTextOf(b.runs),
      ].join();
      expect(joined, 'abcdef', reason: '分裂不允许丢字符');
      expect(c.markdown, 'abc\n\ndef');

      expect(c.active, isNotNull);
      expect(c.active!.blockId, c.doc.blocks[1].id);
      expect(c.active!.blockId, isNot(firstId));
      expect(c.caretOf(c.active!), 0);
      c.dispose();
    });

    test('标题回车：下方新建段落（不是新标题）', () {
      final c = NoteEditorController(markdown: '# 标题');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 2);
      c.onLineChanged(ref, '标题\n');

      expect(c.doc.blocks, hasLength(2));
      expect(c.doc.blocks[0], isA<HeadingBlock>());
      expect(c.doc.blocks[1], isA<ParagraphBlock>());
      expect(c.markdown, '# 标题\n\n');
      c.dispose();
    });

    test('列表回车：块内分裂成两项，继续输入得到 - a / - b', () {
      final c = NoteEditorController(markdown: '- a');
      final list = c.doc.blocks.single as BulletListBlock;
      final ref = BlockRef(list.id, itemId: list.items.single.id);
      c.focusBlock(ref, caret: 1);
      c.onLineChanged(ref, 'a\n');

      expect(c.doc.blocks.single, isA<BulletListBlock>());
      expect((c.doc.blocks.single as BulletListBlock).items, hasLength(2));
      expect(c.markdown, '- a\n- ');

      final newRef = c.active!;
      expect(newRef.itemId, isNot(list.items.single.id));
      c.onLineChanged(newRef, 'b');
      expect(c.markdown, '- a\n- b');
      c.dispose();
    });

    test('空列表项再回车 → 列表收尾，该行降级成独立段落', () {
      final c = NoteEditorController(markdown: '- a');
      final list = c.doc.blocks.single as BulletListBlock;
      final ref = BlockRef(list.id, itemId: list.items.single.id);
      c.focusBlock(ref, caret: 1);
      c.onLineChanged(ref, 'a\n');
      c.onLineChanged(c.active!, '\n');

      expect(c.doc.blocks, hasLength(2));
      expect(c.doc.blocks[0], isA<BulletListBlock>());
      expect((c.doc.blocks[0] as BulletListBlock).items, hasLength(1));
      expect(c.doc.blocks[1], isA<ParagraphBlock>());
      expect(c.active!.blockId, c.doc.blocks[1].id);
      c.dispose();
    });

    test('引用回车：块内新增一行', () {
      final c = NoteEditorController(markdown: '> 一');
      final q = c.doc.blocks.single as QuoteBlock;
      final ref = quoteLineRef(q.id, 0);
      c.focusBlock(ref, caret: 1);
      c.onLineChanged(ref, '一\n');

      expect(c.doc.blocks.single, isA<QuoteBlock>());
      expect((c.doc.blocks.single as QuoteBlock).lines, hasLength(2));
      expect(c.active, quoteLineRef(q.id, 1));
      expect(c.markdown, '> 一\n> ');
      c.dispose();
    });

    test('多行引用：分裂的是光标那一行（行号必须走 itemIndex，不能当 itemId 传）', () {
      // 陷阱回归：行号编码在 `itemId`（`'q:<n>'`）里，若把 `'q:1'` 当 itemId 传给
      // `block_actions.splitBlock` 会静默失效（它只认真正的条目 id）→ 必须换成
      // `itemIndex: 1`，否则永远只分裂第一行。
      final c = NoteEditorController(markdown: '> 一\n> 二三');
      final q = c.doc.blocks.single as QuoteBlock;
      final ref = quoteLineRef(q.id, 1);
      c.focusBlock(ref, caret: 1);
      c.onLineChanged(ref, '二\n三');

      final lines = (c.doc.blocks.single as QuoteBlock).lines;
      expect(lines, hasLength(3));
      expect(plainTextOf(lines[0]), '一', reason: '第一行不能被牵连');
      expect(plainTextOf(lines[1]), '二');
      expect(plainTextOf(lines[2]), '三');
      expect(c.active, quoteLineRef(q.id, 2));
      c.dispose();
    });

    test('代码块回车是软换行；末空行再回车退出成段落', () {
      final c = NoteEditorController(markdown: '```dart\nab\n```');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 2);

      c.onLineChanged(ref, 'ab\n');
      expect(c.doc.blocks, hasLength(1), reason: '代码块里的回车不能分裂块');
      expect((c.doc.blocks.single as CodeBlock).code, 'ab\n');

      c.onLineChanged(ref, 'ab\n\n');
      expect(c.doc.blocks, hasLength(2));
      expect(c.doc.blocks[0], isA<CodeBlock>());
      expect((c.doc.blocks[0] as CodeBlock).code, 'ab\n');
      expect(c.doc.blocks[1], isA<ParagraphBlock>());
      c.dispose();
    });

    test('分段/换行切换：Shift 软换行不分裂（markSoftBreak）', () {
      final c = NoteEditorController(markdown: 'abcdef');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 3);
      c.markSoftBreak();
      c.onLineChanged(ref, 'abc\ndef');

      expect(c.doc.blocks, hasLength(1));
      expect(c.markdown, 'abc\ndef');
      c.dispose();
    });
  });

  group('退格（Notion 式两级）', () {
    test('标题退格先降级成段落，再退格合并进上一段', () {
      final c = NoteEditorController(markdown: '段落\n\n# 标题');
      final h = c.doc.blocks[1] as HeadingBlock;
      c.focusBlock(BlockRef(h.id), caret: 0);

      expect(c.backspaceAtStart(), isTrue);
      expect(c.doc.blocks, hasLength(2));
      expect(c.doc.blocks[1], isA<ParagraphBlock>());
      expect(c.textOf(BlockRef(h.id)), '标题', reason: '降级不允许丢字');

      expect(c.backspaceAtStart(), isTrue);
      expect(c.doc.blocks, hasLength(1));
      expect(c.markdown, '段落标题');
      expect(c.caretOf(c.active!), 2, reason: '光标落在拼接处');
      c.dispose();
    });

    test('段落且没有上一个块：不消费按键（不触发任何动作）', () {
      final c = NoteEditorController(markdown: '唯一的段落');
      c.focusBlock(_firstRef(c), caret: 0);
      expect(c.backspaceAtStart(), isFalse);
      expect(c.markdown, '唯一的段落');
      c.dispose();
    });

    test('上一个块是分割线 / 代码 / 表格 → 直接删掉它，光标留在当前段首', () {
      final c = NoteEditorController(markdown: '上\n\n---\n\n下');
      final para = c.doc.blocks[2];
      c.focusBlock(BlockRef(para.id), caret: 0);
      expect(c.backspaceAtStart(), isTrue);

      expect(c.doc.blocks, hasLength(2));
      expect(c.doc.blocks.any((b) => b is DividerBlock), isFalse);
      expect(c.doc.blocks[1], isA<ParagraphBlock>());
      expect(c.caretOf(c.active!), 0);
      c.dispose();
    });

    test('列表非首项：删项并入前一项（不跨块合并）', () {
      final c = NoteEditorController(markdown: '- 一\n- 二');
      final list = c.doc.blocks.single as BulletListBlock;
      final ref = BlockRef(list.id, itemId: list.items[1].id);
      c.focusBlock(ref, caret: 0);
      expect(c.backspaceAtStart(), isTrue);

      expect(c.doc.blocks.single, isA<BulletListBlock>());
      expect((c.doc.blocks.single as BulletListBlock).items, hasLength(1));
      expect(c.markdown, '- 一二');
      expect(c.caretOf(c.active!), 1);
      c.dispose();
    });

    test('列表首项：脱离成独立段落（放在列表上方）', () {
      final c = NoteEditorController(markdown: '前文\n\n- 一\n- 二');
      final list = c.doc.blocks[1] as BulletListBlock;
      c.focusBlock(BlockRef(list.id, itemId: list.items.first.id), caret: 0);
      expect(c.backspaceAtStart(), isTrue);

      expect(c.doc.blocks, hasLength(3));
      expect(c.doc.blocks[1], isA<ParagraphBlock>());
      expect(c.doc.blocks[2], isA<BulletListBlock>());
      expect(c.textOf(c.active!), '一');
      expect(c.markdown, '前文\n\n一\n\n- 二');
      c.dispose();
    });

    test('段落跟在列表后：行首退格 → 成为列表的新末项（设计 §5.4）', () {
      // 设计 §5.4「段落，上一个是列表 → 合并进上一个块末尾（成为其新末项）」。
      // T5a 起由 `block_actions.mergeBackward` 负责；此前本地实现是「并进最后一项的
      // 文本」，与设计不符 → 这条测试锁住正确的形态。
      final c = NoteEditorController(markdown: '- 一\n\n第二段');
      final para = c.doc.blocks[1] as ParagraphBlock;
      c.focusBlock(BlockRef(para.id), caret: 0);
      expect(c.backspaceAtStart(), isTrue);

      final list = c.doc.blocks.single as BulletListBlock;
      expect(list.items, hasLength(2));
      expect(plainTextOf(list.items[1].runs), '第二段');
      expect(c.active, BlockRef(list.id, itemId: list.items[1].id));
      expect(c.caretOf(c.active!), 0, reason: '新末项的光标落在行首');
      expect(c.markdown, '- 一\n- 第二段');
      c.dispose();
    });

    test('引用首行退格：降级成段落，其余行仍留在引用里', () {
      // 设计 §5.4 两级退格的第一步。守卫原因：T5b 之后「非首行并进上一行」也在
      // block_actions 里，两条路径共用一个入口，容易在收敛时把首行这条一起弄丢。
      final c = NoteEditorController(markdown: '> 一\n> 二');
      final q = c.doc.blocks.single as QuoteBlock;
      c.focusBlock(quoteLineRef(q.id, 0), caret: 0);
      expect(c.backspaceAtStart(), isTrue);

      expect(c.doc.blocks, hasLength(2));
      expect(c.doc.blocks[0], isA<ParagraphBlock>());
      expect(c.doc.blocks[1], isA<QuoteBlock>());
      expect(plainTextOf((c.doc.blocks[1] as QuoteBlock).lines.single), '二');
      expect(c.textOf(c.active!), '一', reason: '首行内容一个字不丢，光标落到这一行');
      expect(c.caretOf(c.active!), 0);
      expect(c.markdown, '一\n\n> 二');
      c.dispose();
    });

    test('引用第二行退格：并入上一行', () {
      final c = NoteEditorController(markdown: '> 第一行\n> 第二行');
      final q = c.doc.blocks.single as QuoteBlock;
      c.focusBlock(quoteLineRef(q.id, 1), caret: 0);
      expect(c.backspaceAtStart(), isTrue);

      expect((c.doc.blocks.single as QuoteBlock).lines, hasLength(1));
      expect(c.textOf(quoteLineRef(q.id, 0)), '第一行第二行');
      c.dispose();
    });

    test('表格单元格：不跨格 / 不跨块合并', () {
      final c = NoteEditorController(markdown: '| a | b |\n| --- | --- |\n| 1 | 2 |');
      final tb = c.doc.blocks.single as TableBlock;
      c.focusBlock(tableCellRef(tb.id, 1, 0), caret: 0);
      expect(c.backspaceAtStart(), isFalse);
      c.dispose();
    });
  });

  group('行内格式', () {
    test('打字时保留已有加粗（projectRuns 投影）', () {
      final c = NoteEditorController(markdown: '**粗体**后面');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 1);
      // 在「粗」与「体」之间插入 X → 继承 bold。
      c.onLineChanged(ref, '粗X体后面');
      expect(c.markdown, '**粗X体**后面');
      c.dispose();
    });

    test('有选区点加粗：立刻生效且正文里不含 *', () {
      final c = NoteEditorController(markdown: 'hello');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 5);
      final ctrl = c.lineControllerFor(ref);
      ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      expect(c.hasSelection, isTrue);
      expect(c.selectionText(), 'hello');

      c.toggleMark(InlineMarks.bold);
      expect(c.markdown, '**hello**');
      expect(c.textOf(ref), 'hello', reason: '编辑态的文本必须是纯文本');

      c.toggleMark(InlineMarks.bold);
      expect(c.markdown, 'hello');
      c.dispose();
    });

    test('无选区点加粗：攒成 pendingMarks，后续输入自动带样式', () {
      final c = NoteEditorController(markdown: 'hello');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 5);
      c.toggleMark(InlineMarks.bold);
      expect(c.pendingMarks.has(InlineMarks.bold), isTrue);

      c.onLineChanged(ref, 'hello!');
      expect(c.markdown, 'hello**!**');
      c.dispose();
    });

    test('代码块 / 表格不支持行内格式（工具栏据此置灰）', () {
      final c = NoteEditorController(markdown: '```\nx\n```');
      c.focusBlock(_firstRef(c), caret: 1);
      expect(c.activeSupportsInlineMarks, isFalse);
      c.toggleMark(InlineMarks.bold);
      expect(c.markdown, '```\nx\n```');
      c.dispose();
    });
  });

  group('代码块 / 表格', () {
    test('代码块语言往返保留（编辑后也不丢）', () {
      final c = NoteEditorController(markdown: '```dart\nvoid main() {}\n```');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 14);
      c.onLineChanged(ref, 'void main() {}\nprint(1);');

      final cb = c.doc.blocks.single as CodeBlock;
      expect(cb.language, 'dart');
      expect(cb.code, 'void main() {}\nprint(1);');
      expect(c.markdown, '```dart\nvoid main() {}\nprint(1);\n```');
      c.dispose();
    });

    test('表格单元格编辑 + 回车跳下一格', () {
      final c = NoteEditorController(markdown: '| a | b |\n| --- | --- |\n| 1 | 2 |');
      final tb = c.doc.blocks.single as TableBlock;
      final ref = tableCellRef(tb.id, 0, 0);
      c.focusBlock(ref, caret: 1);
      c.onLineChanged(ref, 'aX');
      expect(c.markdown, contains('| aX | b |'));

      c.onLineChanged(ref, 'aX\n');
      expect(c.active, tableCellRef(tb.id, 0, 1));
      // 换行不能进单元格。
      expect(c.textOf(ref), 'aX');
      c.dispose();
    });

    test('最后一格回车 → 追加一行', () {
      final c = NoteEditorController(markdown: '| a |\n| --- |\n| 1 |');
      final tb = c.doc.blocks.single as TableBlock;
      final ref = tableCellRef(tb.id, 1, 0);
      c.focusBlock(ref, caret: 1);
      c.onLineChanged(ref, '1\n');

      expect((c.doc.blocks.single as TableBlock).rows, hasLength(3));
      expect(c.active, tableCellRef(tb.id, 2, 0));
      c.dispose();
    });
  });

  group('任务列表 / 插入', () {
    test('点 Checkbox 直接勾选（写回 - [x]）', () {
      final c = NoteEditorController(markdown: '- [ ] 待办');
      final tl = c.doc.blocks.single as TaskListBlock;
      final ref = BlockRef(tl.id, itemId: tl.items.single.id);
      c.toggleTaskItem(ref);
      expect(c.markdown, '- [x] 待办');
      c.toggleTaskItem(ref);
      expect(c.markdown, '- [ ] 待办');
      c.dispose();
    });

    test('插入图片 / 分割线 / 表格都落到文档里且可序列化', () {
      final c = NoteEditorController(markdown: '正文');
      c.focusBlock(_firstRef(c), caret: 2);

      c.insertImageBlock('asset-1', alt: '图');
      expect(c.markdown, contains('![图](aimindtree-asset://asset-1)'));

      c.insertDividerBlock();
      expect(c.doc.blocks.whereType<DividerBlock>(), hasLength(1));
      expect(c.isEditing, isTrue, reason: '分割线后要留下可输入的空段落');

      c.insertTableBlock(rows: 2, cols: 2);
      expect(c.doc.blocks.whereType<TableBlock>(), hasLength(1));
      expect(c.active, isNotNull);
      expect(c.markdown, contains('| --- | --- |'));
      c.dispose();
    });

    test('点空白追加段落：文末多一段并聚焦', () {
      final c = NoteEditorController(markdown: '正文');
      c.appendParagraphAndFocus();
      expect(c.doc.blocks, hasLength(2));
      expect(c.active!.blockId, c.doc.blocks[1].id);
      expect(c.markdown, '正文\n\n');
      c.dispose();
    });
  });

  group('控制器生命周期', () {
    test('setMarkdown 重置活动行与行控制器', () {
      final c = NoteEditorController(markdown: 'a\n\nb');
      c.focusBlock(_firstRef(c), caret: 1);
      expect(c.active, isNotNull);
      c.setMarkdown('c');
      expect(c.active, isNull);
      expect(c.markdown, 'c');
      expect(c.lineControllerFor(_firstRef(c)).text, 'c');
      c.dispose();
    });

    test('dispose 后不再通知（页面 dispose 与回调竞争时的兜底）', () {
      final c = NoteEditorController(markdown: 'x');
      c.dispose();
      expect(() => c.setMarkdown('y'), returnsNormally);
    });
  });

  group('编辑态 buildTextSpan（真 WYSIWYG 的关键）', () {
    testWidgets('文本是纯文本，但加粗 / 行内代码照样有样式', (WidgetTester tester) async {
      final c = NoteEditorController(markdown: '这里是 **粗体** 与 `码`');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 0);
      final ctrl = c.lineControllerFor(ref, base: kNoteBase);

      late TextSpan span;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (BuildContext ctx) {
          span = ctrl.buildTextSpan(
            context: ctx,
            style: kNoteBase,
            withComposing: false,
          );
          return const SizedBox.shrink();
        }),
      ));

      // 1) 编辑框里看不到任何 Markdown 标记（N3）。
      expect(ctrl.text, '这里是 粗体 与 码');
      expect(span.toPlainText(), '这里是 粗体 与 码');
      expect(ctrl.text.contains('*'), isFalse);
      expect(ctrl.text.contains('`'), isFalse);

      // 2) 但样式仍在（N4 的反面证明：编辑态不是「素文本」）。
      final spans = <TextSpan>[];
      void collect(InlineSpan node) {
        if (node is TextSpan) {
          spans.add(node);
          for (final child in node.children ?? const <InlineSpan>[]) {
            collect(child);
          }
        }
      }

      collect(span);
      TextSpan textOf(String s) =>
          spans.firstWhere((e) => e.text == s, orElse: () => const TextSpan());
      expect(textOf('粗体').style?.fontWeight, FontWeight.bold);
      expect(textOf('码').style?.fontFamily, 'monospace');
      c.dispose();
    });

    testWidgets('runs 落后一帧（长度不等）时钳制，不抛 RangeError',
        (WidgetTester tester) async {
      final c = NoteEditorController(markdown: 'ab');
      final ref = _firstRef(c);
      c.focusBlock(ref, caret: 0);
      final ctrl = c.lineControllerFor(ref, base: kNoteBase);
      // 模拟「文本已变长，样式还没跟上」的那一帧。
      ctrl.runs = <InlineNode>[const TextRun('a', marks: InlineMarks.bold)];
      ctrl.value = const TextEditingValue(text: 'abcdef');

      late TextSpan span;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (BuildContext ctx) {
          span = ctrl.buildTextSpan(
            context: ctx,
            style: kNoteBase,
            withComposing: false,
          );
          return const SizedBox.shrink();
        }),
      ));
      expect(span.toPlainText(), 'abcdef');
      expect(tester.takeException(), isNull);
      c.dispose();
    });
  });

  group('渲染冒烟（BlockView / NoteEditorBody）', () {
    const sample = '# 一级标题\n\n正文 **粗** 与 `码`\n\n> 引用一行\n\n'
        '- 无序\n\n1. 有序\n\n- [ ] 待办\n\n```dart\nvoid main() {}\n```\n\n'
        '| 甲 | 乙 |\n| --- | --- |\n| 1 | 2 |\n\n---\n\n'
        '![图](aimindtree-asset://nope)';

    testWidgets('11 种块全部渲染，只读态看不到任何标记符', (WidgetTester tester) async {
      final c = NoteEditorController(markdown: sample);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NoteEditorBody(controller: c)),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('一级标题', findRichText: true), findsOneWidget);
      expect(find.textContaining('待办', findRichText: true), findsOneWidget);
      expect(find.byType(Checkbox), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      expect(find.byIcon(Icons.broken_image), findsOneWidget);

      final body = tester.widgetList<Text>(find.byType(Text)).map((t) {
        return t.data ?? t.textSpan?.toPlainText() ?? '';
      }).join('\n');
      expect(body.contains('# 一级标题'), isFalse);
      expect(body.contains('```'), isFalse);
      expect(body.contains('**粗**'), isFalse);
      expect(body.contains('> 引用'), isFalse);
      c.dispose();
    });

    testWidgets('点某块 → 该块变成 TextField（纯文本），其余块仍是只读',
        (WidgetTester tester) async {
      final c = NoteEditorController(markdown: '# 一级标题\n\n正文 **粗** 与 `码`');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NoteEditorBody(controller: c)),
      ));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);

      final heading = c.doc.blocks.first as HeadingBlock;
      c.focusBlock(BlockRef(heading.id), caret: 2);
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '一级标题', reason: '编辑态不能出现 #');
      expect(c.selectionOf(BlockRef(heading.id))?.baseOffset, 2);
      expect(tester.takeException(), isNull);
      c.dispose();
    });
  });
}
