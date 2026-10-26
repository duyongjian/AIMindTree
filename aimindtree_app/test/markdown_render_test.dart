/// 块级 Markdown 渲染测试（`markdown_render.dart`）。
///
/// 覆盖：标题 / 无序列表 / 有序列表 / 引用 / 代码块 / 分割线 / 表格 / 行内样式，
/// 以及关键容错：**图片缺失（resolveAsset 返回 null）时必须渲染占位块，
/// 而不能让整篇笔记渲染失败**。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:aimindtree_app/features/notes/markdown_render.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Uint8List?> _missingAsset(String assetId) async => null;

/// 一张真实的 2×2 纯红 PNG（供 Image.memory 解码），只有 69 字节。
const String _kTinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==';

Future<Uint8List?> _someAsset(String assetId) async =>
    Uint8List.fromList(base64Decode(_kTinyPngBase64));

Future<void> _pump(
  WidgetTester tester,
  String md, {
  AssetResolver? resolveAsset,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: renderMarkdownBlocks(
            md,
            resolveAsset: resolveAsset ?? _missingAsset,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
}

class _Rendered {
  const _Rendered(this.widget, this.text);

  final Text widget;
  final String text;
}

String _spanText(InlineSpan? span) {
  if (span == null) return '';
  final buf = StringBuffer();
  if (span is WidgetSpan) return buf.toString(); // 图片：文本在内嵌子树里
  if (span is TextSpan) {
    buf.write(span.text ?? '');
    for (final child in span.children ?? const <InlineSpan>[]) {
      buf.write(_spanText(child));
    }
  }
  return buf.toString();
}

List<_Rendered> _renderedTexts(WidgetTester tester) => <_Rendered>[
      for (final w in tester.widgetList<Text>(find.byType(Text)))
        _Rendered(w, w.data ?? _spanText(w.textSpan)),
    ];

/// 收集一棵 TextSpan 树里所有的 TextSpan（含自身），便于断言行内样式。
List<TextSpan> _flattenSpans(InlineSpan? span) {
  final out = <TextSpan>[];
  void collect(InlineSpan node) {
    if (node is TextSpan) {
      out.add(node);
      for (final child in node.children ?? const <InlineSpan>[]) {
        collect(child);
      }
    }
  }

  collect(span ?? const TextSpan());
  return out;
}

Iterable<_Rendered> _containing(WidgetTester tester, String text) =>
    _renderedTexts(tester).where((r) => r.text.contains(text));

void main() {
  testWidgets('标题：h1/h2/h3 分级渲染且字号递减', (WidgetTester tester) async {
    await _pump(tester, '# 大标题\n\n## 副标题\n\n### 小节');

    for (final title in <String>['大标题', '副标题', '小节']) {
      expect(_containing(tester, title), isNotEmpty, reason: '缺少标题：$title');
    }

    // 块级字号挂在 Text.rich 的**根** TextSpan 上。
    double? fontSizeOf(String title) {
      for (final r in _containing(tester, title)) {
        final style = r.widget.textSpan?.style;
        if (style != null && r.text.contains(title)) return style.fontSize;
      }
      return null;
    }

    expect(fontSizeOf('大标题'), 20);
    expect(fontSizeOf('副标题'), 17);
    expect(fontSizeOf('小节'), 15);
  });

  testWidgets('无序列表：渲染 bullet 与条目正文', (WidgetTester tester) async {
    await _pump(tester, '- 苹果\n- 香蕉');
    expect(_containing(tester, '苹果'), isNotEmpty);
    expect(_containing(tester, '香蕉'), isNotEmpty);
    expect(
      _renderedTexts(tester).where((r) => r.text == '• ').length,
      2,
    );
  });

  testWidgets('有序列表：沿用正文里的编号', (WidgetTester tester) async {
    await _pump(tester, '1. 第一步\n2. 第二步');
    expect(_containing(tester, '第一步'), isNotEmpty);
    final markers = _renderedTexts(tester)
        .map((r) => r.text)
        .where((t) => t == '1. ' || t == '2. ')
        .toList();
    expect(markers, <String>['1. ', '2. ']);
  });

  testWidgets('引用：独立块渲染，内容与其它块不混排', (WidgetTester tester) async {
    await _pump(tester, '正文\n\n> 引用的一句话\n\n收尾');
    expect(_containing(tester, '引用的一句话'), isNotEmpty);
    expect(_containing(tester, '正文'), isNotEmpty);
  });

  testWidgets('代码块：整段等宽渲染且不显示围栏符', (WidgetTester tester) async {
    await _pump(tester, '前\n\n```\nint a = 1;\nvoid main() {}\n```\n\n后');

    final code = _containing(tester, 'int a = 1;');
    expect(code, isNotEmpty);
    expect(code.first.widget.style?.fontFamily, 'monospace');
    expect(code.first.text.contains('```'), isFalse);
    expect(code.first.text.contains('void main() {}'), isTrue);
  });

  testWidgets('分割线：渲染 Divider', (WidgetTester tester) async {
    await _pump(tester, '上\n\n---\n\n下');
    expect(find.byType(Divider), findsOneWidget);
    expect(_containing(tester, '上'), isNotEmpty);
    expect(_containing(tester, '下'), isNotEmpty);
  });

  testWidgets('表格：等宽列渲染，表头与单元格都出来', (WidgetTester tester) async {
    await _pump(
        tester, '| 列1 | 列2 |\n| --- | --- |\n| 甲 | 乙 |\n| 丙 | 丁 |');

    expect(find.byType(Table), findsOneWidget);
    for (final cell in <String>['列1', '列2', '甲', '乙', '丙', '丁']) {
      expect(_containing(tester, cell), isNotEmpty, reason: '缺少单元格：$cell');
    }
    expect(_containing(tester, '---'), isEmpty);
  });

  testWidgets('行内：粗体/斜体/行内代码/链接各自带样式',
      (WidgetTester tester) async {
    await _pump(tester, '这是 **粗体** 和 *斜体* 与 `代码` 和 [官网](https://a.dev)');

    final spans = <TextSpan>[
      for (final r in _renderedTexts(tester)) ..._flattenSpans(r.widget.textSpan),
    ];

    TextSpan spanOf(String text) =>
        spans.firstWhere((s) => s.text == text, orElse: () => const TextSpan());

    expect(spanOf('粗体').style?.fontWeight, FontWeight.bold);
    expect(spanOf('斜体').style?.fontStyle, FontStyle.italic);
    expect(spanOf('代码').style?.fontFamily, 'monospace');
    expect(spanOf('官网').style?.decoration, TextDecoration.underline);
  });

  testWidgets('图片缺失：渲染占位块而不是让整篇失败',
      (WidgetTester tester) async {
    await _pump(
      tester,
      '正文开头 ![架构图](aimindtree-asset://missing-1) 正文结尾',
      resolveAsset: _missingAsset,
    );

    expect(find.byIcon(Icons.broken_image), findsOneWidget);
    expect(_containing(tester, '图片未同步'), isNotEmpty);
    // 整篇笔记没崩：前后正文都还在。
    expect(_containing(tester, '正文开头'), isNotEmpty);
    expect(_containing(tester, '正文结尾'), isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('图片可用：渲染 Image.memory', (WidgetTester tester) async {
    await _pump(
      tester,
      '![图](aimindtree-asset://ok-1)',
      resolveAsset: _someAsset,
    );

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.broken_image), findsNothing);
    expect(_containing(tester, '图片未同步'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空正文：不报错、不产生任何块', (WidgetTester tester) async {
    await _pump(tester, '');
    expect(_renderedTexts(tester), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('不支持的语法：原样当普通文本输出（容错）',
      (WidgetTester tester) async {
    await _pump(tester, '随便一段 |没有分隔行| 的文字');
    expect(_containing(tester, '随便一段'), isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  // ------------------------------------------------------------------
  // T3 新增：两个历史渲染缺口（设计 §6.3）+ 表格对齐（设计 §6.6 P1）
  // ------------------------------------------------------------------

  testWidgets('删除线：渲染出 lineThrough，正文里不出现 ~~',
      (WidgetTester tester) async {
    await _pump(tester, '删除线 ~~strike~~ 示例');

    final spans = <TextSpan>[
      for (final r in _renderedTexts(tester)) ..._flattenSpans(r.widget.textSpan),
    ];
    final strike = spans.firstWhere(
      (s) => s.text == 'strike',
      orElse: () => const TextSpan(),
    );
    expect(strike.style?.decoration, TextDecoration.lineThrough);
    // 标记符不能漏到屏幕上。
    expect(_containing(tester, '~~'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('任务列表：渲染可勾选的 Checkbox，不出现 • [ ] 原文',
      (WidgetTester tester) async {
    await _pump(tester, '- [ ] 待办一\n- [x] 已办二');

    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(_containing(tester, '待办一'), isNotEmpty);
    expect(_containing(tester, '已办二'), isNotEmpty);
    // 缺口的验收口径：不允许把 `- [ ] ` 当普通无序列表渲染。
    expect(_containing(tester, '• [ ]'), isEmpty);
    expect(_containing(tester, '[ ]'), isEmpty);
    expect(_renderedTexts(tester).where((r) => r.text == '• '), isEmpty);

    // 勾选态直接反映在 Checkbox 上（true / false 各一个）。
    final values = tester
        .widgetList<Checkbox>(find.byType(Checkbox))
        .map((c) => c.value)
        .toList();
    expect(values, <bool>[false, true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('表格对齐：左 / 中 / 右分别落到 TextAlign',
      (WidgetTester tester) async {
    await _pump(
        tester, '| 左 | 中 | 右 |\n| :--- | :---: | ---: |\n| a | b | c |');

    TextAlign? alignOf(String cell) {
      for (final r in _containing(tester, cell)) {
        if (r.text == cell) return r.widget.textAlign;
      }
      return null;
    }

    expect(alignOf('左'), TextAlign.left);
    expect(alignOf('中'), TextAlign.center);
    expect(alignOf('右'), TextAlign.right);
    expect(tester.takeException(), isNull);
  });
}
