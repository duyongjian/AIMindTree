/// 表格完整功能验收测试：
/// - 单元格多行输入不再命中 `TextField` 断言（`maxLines:null` + `newline` 必须配 `multiline`）；
/// - `insertTableBlock(20,5)` 生成合法 GFM 且可往返；
/// - 经控制器加/删行、加/删列后序列化合法、`aligns` 与列数同步；
/// - 单元格含 `|` 的往返（`a\|b` 序列化、解析后仍是同一格同一文本）；
/// - `rows:0` / `cols:0` 被 clamp 到 1；
/// - 多列表格渲染不溢出（横向滚动兜底）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aimindtree_app/features/notes/block_model.dart';
import 'package:aimindtree_app/features/notes/markdown_block_parser.dart';
import 'package:aimindtree_app/features/notes/note_editor_body.dart';
import 'package:aimindtree_app/features/notes/note_editor_controller.dart';

/// 一个只有单块表格的文档，返回控制器与表格块。
(NoteEditorController, TableBlock) _tableController(String md) {
  final c = NoteEditorController(markdown: md);
  final tb = c.doc.blocks.whereType<TableBlock>().single;
  return (c, tb);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('单元格编辑不再抛断言', () {
    testWidgets('点进单元格（多行 TextField）takeException 为 null',
        (WidgetTester tester) async {
      final c = NoteEditorController(
        markdown: '| a | b |\n| --- | --- |\n| 1 | 2 |',
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NoteEditorBody(controller: c)),
      ));
      await tester.pump();

      final tb = c.doc.blocks.single as TableBlock;
      // 聚焦一个单元格 → 该格渲染成可编辑 TextField。
      c.focusBlock(tableCellRef(tb.id, 0, 0), caret: 1);
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: 'maxLines:null + newline 必须配 multiline，否则命中 text_field 断言');
      expect(find.byType(TextField), findsWidgets);
      c.dispose();
    });
  });

  group('插入任意行列：合法 GFM + 往返', () {
    test('insertTableBlock(rows:20, cols:5) → 20 行 + 分隔行，往返行列一致', () {
      final c = NoteEditorController(markdown: '正文');
      c.focusBlock(BlockRef(c.doc.blocks.first.id), caret: 2);
      c.insertTableBlock(rows: 20, cols: 5);

      final tb = c.doc.blocks.whereType<TableBlock>().single;
      expect(tb.rows.length, 20);
      expect(tb.rows.every((r) => r.length == 5), isTrue);
      expect(tb.aligns.length, 5);

      // 表格行 = 20 内容行（首行表头）+ 1 分隔行。
      final md = c.markdown;
      final tableLines =
          md.split('\n').where((String l) => l.trim().startsWith('|')).toList();
      expect(tableLines.length, 21, reason: '20 内容行 + 1 分隔行');
      expect(
        tableLines[1].trim(),
        matches(RegExp(r'^\|(\s*:?-{3,}:?\s*\|)+$')),
        reason: '第二行必须是合法 GFM 分隔行',
      );

      // 重新解析回来：行列数一致。
      final re = parseMarkdownDoc(md);
      final tb2 = re.blocks.whereType<TableBlock>().single;
      expect(tb2.rows.length, 20);
      expect(tb2.rows.every((r) => r.length == 5), isTrue);
      expect(tb2.aligns.length, 5);
      c.dispose();
    });

    testWidgets('20 列表格渲染不溢出（横向滚动兜底）', (WidgetTester tester) async {
      final c = NoteEditorController(markdown: '正文');
      c.focusBlock(BlockRef(c.doc.blocks.first.id), caret: 2);
      c.insertTableBlock(rows: 2, cols: 20);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NoteEditorBody(controller: c)),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(Table), findsOneWidget);
      c.dispose();
    });
  });

  group('控制器增删行列：序列化合法 + aligns 同步', () {
    test('加行 / 删行 / 加列 / 删列各一次，结构始终自洽', () {
      final c = NoteEditorController(markdown: '正文');
      c.focusBlock(BlockRef(c.doc.blocks.first.id), caret: 2);
      c.insertTableBlock(rows: 3, cols: 3);
      final String id = c.doc.blocks.whereType<TableBlock>().single.id;

      c.insertTableRowAfter(id, 1);
      var tb = c.doc.blocks.whereType<TableBlock>().single;
      expect(tb.rows.length, 4);
      expect(tb.rows.every((r) => r.length == 3), isTrue);
      expect(tb.aligns.length, 3);

      c.removeTableRowAt(id, 0);
      tb = c.doc.blocks.whereType<TableBlock>().single;
      expect(tb.rows.length, 3);

      c.insertTableColumnAfter(id, 0);
      tb = c.doc.blocks.whereType<TableBlock>().single;
      expect(tb.aligns.length, 4);
      expect(tb.rows.every((r) => r.length == 4), isTrue);

      c.removeTableColumnAt(id, 0);
      tb = c.doc.blocks.whereType<TableBlock>().single;
      expect(tb.aligns.length, 3);
      expect(tb.rows.every((r) => r.length == 3), isTrue);

      // 序列化必须还能解析成同结构的表格。
      final re = parseMarkdownDoc(c.markdown);
      final tb2 = re.blocks.whereType<TableBlock>().single;
      expect(tb2.rows.length, 3);
      expect(tb2.rows.every((r) => r.length == 3), isTrue);
      expect(tb2.aligns.length, 3);
      c.dispose();
    });

    test('只剩一行 / 一列时删行删列无效（纯函数守卫，不提交）', () {
      final c = NoteEditorController(markdown: '| 表头 |\n| --- |');
      final tb = c.doc.blocks.single as TableBlock;
      final String before = c.markdown;
      c.removeTableRowAt(tb.id, 0);
      c.removeTableColumnAt(tb.id, 0);
      expect(c.markdown, before);
      expect((c.doc.blocks.single as TableBlock).rows.length, 1);
      expect((c.doc.blocks.single as TableBlock).aligns.length, 1);
      c.dispose();
    });

    test('deleteTableBlock 删掉整块且不粘连邻块', () {
      final c = NoteEditorController(markdown: '上一段\n\n| a | b |\n| --- | --- |\n\n下一段');
      final tb = c.doc.blocks.whereType<TableBlock>().single;
      c.deleteTableBlock(tb.id);
      expect(c.doc.blocks.whereType<TableBlock>(), isEmpty);
      // 仍有上下两段，且序列化后能重新解析成两段（不粘连）。
      final re = parseMarkdownDoc(c.markdown);
      expect(re.blocks.whereType<ParagraphBlock>().length, 2);
      c.dispose();
    });
  });

  group('单元格含 | 的往返', () {
    test('a|b 进 → 序列化为 a\\|b → 解析回来仍是单格 a|b', () {
      final (c, tb) = _tableController('| 表头 |\n| --- |\n| 值 |');
      final ref = tableCellRef(tb.id, 1, 0);
      c.focusBlock(ref, caret: 1);
      c.onLineChanged(ref, 'a|b');

      final md = c.markdown;
      expect(md.contains(r'a\|b'), isTrue, reason: '序列化要把 | 转义成 \\|');

      final re = parseMarkdownDoc(md);
      final tb2 = re.blocks.single as TableBlock;
      expect(tb2.rows[1].length, 1, reason: '仍是一格，不能因 | 错位成两格');
      expect(plainTextOf(tb2.rows[1][0]), 'a|b');
      c.dispose();
    });

    test('解析含 \\| 的表格：单格内含竖线，L1 原文直通', () {
      const md = '| a\\|b | c |\n| --- | --- |';
      final doc = parseMarkdownDoc(md);
      final tb = doc.blocks.single as TableBlock;
      expect(tb.rows.first.length, 2);
      expect(plainTextOf(tb.rows.first[0]), 'a|b');
      expect(serializeDoc(doc), md, reason: '未编辑块 source 直通，字节不变');
    });
  });

  group('0 行列被 clamp 到 1', () {
    test('TableBlock.empty(rows:0, cols:0) → 1×1', () {
      final t = TableBlock.empty(rows: 0, cols: 0);
      expect(t.rows.length, 1);
      expect(t.aligns.length, 1);
      expect(t.rows.single.length, 1);
    });

    test('insertTableBlock(rows:0, cols:0) → 1×1 且序列化仍是合法表', () {
      final c = NoteEditorController(markdown: '正文');
      c.focusBlock(BlockRef(c.doc.blocks.first.id), caret: 2);
      c.insertTableBlock(rows: 0, cols: 0);

      final tb = c.doc.blocks.whereType<TableBlock>().single;
      expect(tb.rows.length, 1);
      expect(tb.aligns.length, 1);
      expect(tb.rows.single.length, 1);

      final re = parseMarkdownDoc(c.markdown);
      expect(re.blocks.whereType<TableBlock>(), hasLength(1),
          reason: '不能生成序列化为空串的「隐形表」');
      c.dispose();
    });
  });
}
