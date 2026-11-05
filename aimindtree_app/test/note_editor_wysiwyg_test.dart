/// T4 接线层验收测试：**所见即所得**（去掉双框）的端到端行为。
///
/// 设计依据：`docs/NOTE_EDITOR_WYSIWYG_DESIGN.md` §1.1（N1–N4）、§10 T4 验收 7 条。
///
/// 七条对应关系：
/// 1. 不存在「Markdown 原文」hint 的源码输入框（双框已移除）；
/// 2. 点 H2 → 渲染 17pt 加粗，且编辑态文本里不含 `#`；
/// 3. 选区加粗 → 出现 bold run / bold span，且文本里不含 `*`；
/// 4. 列表里回车 → 分裂成两项，序列化得 `- a\n- b`；
/// 5. 标题行首退格 → 先降级为段落、再退格 → 合并进上一段；
/// 6. **L1 红线（端到端）**：加载旧笔记什么都不改 → 保存 → 库里的 `content_md`
///    与原文逐字节相同；
/// 7. AI 链路不被破坏：送 LLM 的正文仍是 Markdown 字符串。
library;

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/extraction_service.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/repositories/group_repository.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/note_asset_repository.dart';
import 'package:aimindtree_app/data/repositories/notebook_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:aimindtree_app/features/notes/block_model.dart';
import 'package:aimindtree_app/features/notes/block_view.dart';
import 'package:aimindtree_app/features/notes/markdown_toolbar.dart';
import 'package:aimindtree_app/features/notes/note_editor_body.dart';
import 'package:aimindtree_app/features/notes/note_editor_controller.dart';
import 'package:aimindtree_app/features/notes/note_editor_page.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录送到 LLM 的正文（用来验证「AI 拿到的仍是 Markdown」）。
class _RecordingProvider extends AiProvider {
  final List<String> noteTexts = <String>[];

  @override
  String get id => 'stub';

  @override
  String get protocol => 'stub';

  @override
  Future<AiTaskResult> runTask(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 120),
    String? variant,
  }) async {
    final text = inputs['note_text'];
    if (text is String) noteTexts.add(text);
    return const AiTaskResult(
      content: '{}',
      parsed: <String, dynamic>{
        'knowledge_points': <dynamic>[
          <String, dynamic>{
            'name': '导数',
            'type': 'concept',
            'definition': '描述变化率',
            'source_quote': '导数',
          },
        ],
      },
    );
  }

  @override
  Stream<AiChunk> streamChat(
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 120),
    AiTask? task,
    String? variant,
    String? jobId,
  }) =>
      const Stream<AiChunk>.empty();

  @override
  void dispose() {}
}

/// 最小接线壳：工具栏 + 正文（不含页面壳体），便于直接读 `controller.markdown`。
Widget _harness(NoteEditorController c) => MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            MarkdownToolbar(controller: c),
            Expanded(child: NoteEditorBody(controller: c)),
          ],
        ),
      ),
    );

/// 点正文首块 → 它就地变成输入框（所见即所得的进入方式）。
Future<Finder> _tapFirstBlock(WidgetTester tester) async {
  final body = find.byType(NoteEditorBody);
  await tester.tapAt(tester.getRect(body).topLeft + const Offset(24, 12));
  await tester.pumpAndSettle();
  return find.descendant(of: body, matching: find.byType(TextField));
}

/// 页面里的「进入正文编辑态」（正文容器有稳定 Key `note-body`）。
Future<Finder> _enterPageBody(WidgetTester tester) async {
  final body = find.byKey(const ValueKey<String>('note-body'));
  expect(body, findsOneWidget);
  await tester.tapAt(tester.getRect(body).topLeft + const Offset(24, 12));
  await tester.pumpAndSettle();
  return find.descendant(of: body, matching: find.byType(TextField));
}

void main() {
  late AppDatabase db;
  late _RecordingProvider stub;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    stub = _RecordingProvider();
  });

  tearDown(() async {
    await db.close();
  });

  ExtractionService makeService() => ExtractionService(
        repo: KnowledgeRepository(db, deviceId: 'd'),
        notebooks: NotebookRepository(db, deviceId: 't'),
        trees: TreeRepository(db, deviceId: 'd'),
        groups: GroupRepository(db, deviceId: 'd'),
        jobs: AiJobService(baseUrl: 'http://127.0.0.1:1'),
        ai: AiService(router: AiTaskRouter(providers: const {}, fallback: stub)),
        assets: NoteAssetRepository(db, deviceId: 'd'),
      );

  testWidgets('① 双框已移除：页面里没有「Markdown 原文」源码输入框', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(service: makeService(), db: db),
    ));
    await tester.pumpAndSettle();

    final hints = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((TextField f) => f.decoration?.hintText ?? '')
        .toList();
    expect(
      hints.any((String h) => h.contains('Markdown 原文')),
      isFalse,
      reason: 'N1/N2：不允许再出现 Markdown 源码框',
    );
    // 只剩标题一个输入框（正文这时候是只读渲染态）。
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(NoteEditorBody), findsOneWidget);
    expect(find.byType(VerticalDivider), findsNothing, reason: '旧分屏的分隔线必须消失');
  });

  testWidgets('② 点「二级标题」→ 17pt 加粗，编辑态文本里没有 #', (WidgetTester tester) async {
    final c = NoteEditorController();
    await tester.pumpWidget(_harness(c));

    final field = await _tapFirstBlock(tester);
    await tester.enterText(field, '标题');
    await tester.pump();

    await tester.tap(find.byTooltip('二级标题（## 标题）'));
    await tester.pumpAndSettle();

    final w = tester.widget<TextField>(find.byType(TextField));
    expect(w.style?.fontSize, 17);
    expect(w.style?.fontWeight, FontWeight.bold);
    expect(w.controller!.text, '标题');
    expect(w.controller!.text.contains('#'), isFalse, reason: 'N3：编辑态看不到 #');
    // 持久化侧仍是 Markdown（数据面不变）。
    expect(c.markdown, contains('## 标题'));
    c.dispose();
  });

  testWidgets('③ 选区加粗 → bold run + bold span，文本里没有 *', (WidgetTester tester) async {
    final c = NoteEditorController(markdown: 'abc');
    await tester.pumpWidget(_harness(c));

    final ref = BlockRef(c.doc.blocks.first.id);
    c.focusBlock(ref, caret: 3);
    await tester.pumpAndSettle();

    final w = tester.widget<TextField>(find.byType(TextField));
    final line = w.controller! as RichLineController;
    line.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await tester.pump();

    await tester.tap(find.byTooltip('加粗（**粗体文字**）'));
    await tester.pumpAndSettle();

    // 编辑态：runs 带 bold，显示文本不含 *
    expect(line.text, 'abc');
    expect(line.text.contains('*'), isFalse, reason: 'N3：编辑态看不到 **');
    expect(
      line.runs.any((InlineNode n) => n is TextRun && n.marks.isBold),
      isTrue,
      reason: '加粗必须落在行内片段上（不是插字符）',
    );
    // 编辑态的 span 也带 bold（所见即所得：不用退出编辑态就能看到）
    final span = line.buildTextSpan(
      context: tester.element(find.byType(TextField)),
      style: kNoteBase,
      withComposing: false,
    );
    final weights = <FontWeight?>[];
    span.visitChildren((InlineSpan s) {
      if (s is TextSpan && s.style != null) weights.add(s.style!.fontWeight);
      return true;
    });
    expect(weights.contains(FontWeight.bold), isTrue);
    // 序列化侧是标准 Markdown
    expect(c.markdown, contains('**abc**'));
    c.dispose();
  });

  testWidgets('④ 列表里回车 → 分裂成两项，序列化得 - a / - b', (WidgetTester tester) async {
    final c = NoteEditorController(markdown: 'a');
    await tester.pumpWidget(_harness(c));

    final ref = BlockRef(c.doc.blocks.first.id);
    c.focusBlock(ref, caret: 1);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('无序列表（- 列表项）'));
    await tester.pumpAndSettle();
    expect(c.markdown, contains('- a'));

    // 模拟在行尾按回车：onChanged 收到「新增一个 \n」（桌面 / 软键盘同一条路径）。
    await tester.enterText(find.byType(TextField), 'a\n');
    await tester.pumpAndSettle();

    final list = c.doc.blocks.whereType<BulletListBlock>().single;
    expect(list.items, hasLength(2), reason: '回车应当在同一个列表块里分裂成两项');

    await tester.enterText(find.byType(TextField), 'b');
    await tester.pumpAndSettle();
    expect(c.markdown, contains('- a\n- b'));
    c.dispose();
  });

  testWidgets('⑤ 标题行首退格：先降级段落，再退格合并进上一段', (WidgetTester tester) async {
    final c = NoteEditorController(markdown: '前一段\n\n# 标题');
    await tester.pumpWidget(_harness(c));

    final headingRef = BlockRef(c.doc.blocks[1].id);
    c.focusBlock(headingRef, caret: 0);
    await tester.pumpAndSettle();
    expect(c.doc.blocks[1], isA<HeadingBlock>());

    // 第一次退格：只降级（不吞进上一段），文本一个字不少
    expect(c.backspaceAtStart(), isTrue);
    await tester.pumpAndSettle();
    expect(c.doc.blocks[1], isA<ParagraphBlock>());
    expect(c.textOf(BlockRef(c.doc.blocks[1].id)), '标题');
    expect(c.markdown.contains('# 标题'), isFalse);

    // 第二次退格：合并进上一段
    expect(c.backspaceAtStart(), isTrue);
    await tester.pumpAndSettle();
    expect(c.doc.blocks, hasLength(1));
    expect(c.textOf(BlockRef(c.doc.blocks.single.id)), '前一段标题');
    expect(find.textContaining('# 标题', findRichText: true), findsNothing);
    c.dispose();
  });

  testWidgets('⑥ L1 红线：加载旧笔记不改 → 保存 → content_md 逐字节相同',
      (WidgetTester tester) async {
    const original = '# 标题\n\n段落 **粗** 与 `码` 与 *斜*\n\n'
        '- 列表一\n- 列表二\n\n'
        '> 引用一行\n\n'
        '1. 有序一\n2. 有序二\n\n'
        '- [ ] 待办\n\n'
        '```dart\nvoid main() {}\n```\n\n'
        '| 甲 | 乙 |\n| --- | --- |\n| 1 | 2 |\n\n'
        '---\n\n'
        '![图](aimindtree-asset://nope)\n';
    await db.into(db.notes).insert(NotesCompanion(
          id: const Value<String>('n1'),
          title: const Value<String>('旧笔记'),
          contentMd: const Value<String>(original),
          updatedAt: Value<DateTime>(DateTime.utc(2026, 1, 1)),
          deviceId: const Value<String>('local-dev'),
        ));

    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(service: makeService(), db: db, noteId: 'n1'),
    ));
    await tester.pumpAndSettle();

    // 什么都不改，直接保存。
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();

    final row = await (db.select(db.notes)..where((t) => t.id.equals('n1')))
        .getSingle();
    expect(row.contentMd, original, reason: 'L1：未编辑必须原文直通，一个字节都不能变');
    expect(tester.takeException(), isNull);
  });

  testWidgets('⑦ AI 提取拿到的仍是 Markdown 字符串', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(service: makeService(), db: db),
    ));
    await tester.pumpAndSettle();

    // 正文里打「小节」→ 点二级标题（= 变成 `## 小节`）
    final field = await _enterPageBody(tester);
    await tester.enterText(field, '小节');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('二级标题（## 标题）'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('提取知识点 (T1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始提取'));
    await tester.pumpAndSettle();

    expect(stub.noteTexts, isNotEmpty, reason: '提取必须真的调用 T1');
    expect(stub.noteTexts.first, contains('## 小节'),
        reason: 'AI 链路的正文入口必须仍是 Markdown 纯文本');
    expect(tester.takeException(), isNull);
  });

  testWidgets('⑧ 目录跳转：点标题就地进入编辑态（块引用而不是字符偏移）',
      (WidgetTester tester) async {
    const md = '# 第一节\n\n正文一行\n\n## 第二节';
    await db.into(db.notes).insert(NotesCompanion(
          id: const Value<String>('n2'),
          title: const Value<String>('目录'),
          contentMd: const Value<String>(md),
          updatedAt: Value<DateTime>(DateTime.utc(2026, 1, 1)),
          deviceId: const Value<String>('local-dev'),
        ));
    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(service: makeService(), db: db, noteId: 'n2'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('目录 / 大纲'));
    await tester.pumpAndSettle();
    // 正文里也渲染着「第二节」，所以只在抽屉内找（否则会命中两个）。
    final tocItem = find.descendant(
      of: find.byType(Drawer),
      matching: find.text('第二节'),
    );
    expect(tocItem, findsOneWidget);

    await tester.tap(tocItem);
    await tester.pumpAndSettle();

    // 跳转 = 把该标题块变成输入框；`_isValidRef` 收紧后这条路径必须仍然成立
    // （标题是单行块，接受块级 ref），且编辑态文本不含 `##`。
    final field = find.descendant(
      of: find.byKey(const ValueKey<String>('note-body')),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget, reason: '目录跳转必须真的把光标落到标题块上');
    expect(tester.widget<TextField>(field).controller!.text, '第二节');
    expect(tester.takeException(), isNull);
  });
}
