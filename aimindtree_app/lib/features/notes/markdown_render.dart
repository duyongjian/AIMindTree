/// 极简 Markdown 渲染器（PRD §5.10：Markdown 源码 + 分屏预览）。
///
/// 故意**不引第三方 markdown 包**（省原生依赖）；覆盖：
/// - 标题 `# ## ###`（h1/h2/h3）
/// - 列表 `- ` → `•`
/// - 加粗 `**...**`、斜体 `*...*`、行内代码 `\`...\``
/// - 空行分段
///
/// 解析失败或不支持的语法原样输出（容错）。
library;

import 'package:flutter/material.dart';

List<InlineSpan> renderMarkdown(String md) {
  final lines = md.split('\n');
  final spans = <InlineSpan>[];
  var inParagraph = false;
  final buf = StringBuffer();

  void flushParagraph() {
    if (buf.isEmpty) return;
    spans.addAll(_inlineSpans(buf.toString(), const TextStyle(fontSize: 14)));
    buf.clear();
    if (inParagraph) {
      spans.add(const TextSpan(text: '\n'));
    }
    inParagraph = false;
  }

  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final line = raw.trimRight();
    if (line.isEmpty) {
      flushParagraph();
      continue;
    }
    if (line.startsWith('### ')) {
      flushParagraph();
      spans.add(TextSpan(
        text: line.substring(4),
        style: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black87),
      ));
    } else if (line.startsWith('## ')) {
      flushParagraph();
      spans.add(TextSpan(
        text: line.substring(3),
        style: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87),
      ));
    } else if (line.startsWith('# ')) {
      flushParagraph();
      spans.add(TextSpan(
        text: line.substring(2),
        style: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 20, color: Colors.black87),
      ));
    } else if (line.startsWith('- ')) {
      flushParagraph();
      spans.addAll(_inlineSpans('• ${line.substring(2)}',
          const TextStyle(fontSize: 14)));
    } else {
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(line);
      inParagraph = true;
    }
    if (i < lines.length - 1 && inParagraph) {
      // 段落连续，最后统一 flush
    }
  }
  flushParagraph();
  return spans;
}

List<InlineSpan> _inlineSpans(String s, TextStyle base) {
  // 简单正则扫描：依次处理 `**bold**` / `*italic*` / `` `code` ``
  final result = <InlineSpan>[];
  final pattern = RegExp(
      r'(\*\*[^*]+\*\*)|(\*[^*]+\*)|(`[^`]+`)');
  var last = 0;
  for (final m in pattern.allMatches(s)) {
    if (m.start > last) {
      result.add(TextSpan(text: s.substring(last, m.start), style: base));
    }
    final raw = m.group(0)!;
    if (raw.startsWith('**')) {
      result.add(TextSpan(
        text: raw.substring(2, raw.length - 2),
        style: base.copyWith(fontWeight: FontWeight.bold),
      ));
    } else if (raw.startsWith('`')) {
      result.add(TextSpan(
        text: raw.substring(1, raw.length - 1),
        style: base.copyWith(
          fontFamily: 'monospace',
          backgroundColor: Colors.grey.shade200,
        ),
      ));
    } else {
      result.add(TextSpan(
        text: raw.substring(1, raw.length - 1),
        style: base.copyWith(fontStyle: FontStyle.italic),
      ));
    }
    last = m.end;
  }
  if (last < s.length) {
    result.add(TextSpan(text: s.substring(last), style: base));
  }
  return result;
}
