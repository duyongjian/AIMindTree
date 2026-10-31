/// 老师模式回复的富文本渲染：Markdown + LaTeX 公式。
///
/// **为什么单独一个组件**：老师（大模型）回复是 Markdown 正文里夹着数学公式
/// （行内 `$...$`、块级 `$$...$$`）。改造前 `_MessageBubble` 直接 `Text(content)`，
/// 于是 `## 标题`、`**粗体**`、`\frac{d}{dt}` 全部原样显示成源码，可读性很差。
///
/// **渲染策略**
/// - 先把文本按 `$$...$$` 切成「块级公式」与「普通 Markdown」两类片段：
///   块级公式用 [Math.tex]（display 样式）居中渲染；
/// - 普通 Markdown 片段交给 `flutter_markdown` 渲染，并注入一条行内公式语法
///   （[InlineSyntax] 匹配 `$...$`）+ 对应元素构建器 → 行内公式以 [Math.tex]
///   （text 样式）内联渲染；
/// - 其余标题 / 列表 / 代码 / 引用 / 加粗等由 `flutter_markdown` 原生处理。
///
/// 依赖：`flutter_markdown`（Markdown 排版）、`flutter_math_fork`（LaTeX）、
/// `markdown`（行内语法 AST：`Element` / `InlineSyntax`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

/// 把带 LaTeX 的 Markdown 文本渲染成富文本。
class MarkdownMessage extends StatelessWidget {
  const MarkdownMessage({super.key, required this.data});

  /// 原始文本（Markdown + `$`/`$$` 公式）。
  final String data;

  /// 块级公式：`$$ ... $$`（跨行、非贪婪）。
  static final RegExp _blockMath = RegExp(r'\$\$([\s\S]+?)\$\$');

  static const TextStyle _mathText =
      TextStyle(fontSize: 15, color: Colors.black87);

  @override
  Widget build(BuildContext context) {
    final segs = _split(data);
    // 只有一个普通文本片段（没有块级公式）时直接走 Markdown，省一层 Column。
    if (segs.length == 1 && !segs.single.isMath) {
      return _buildMarkdown(segs.single.text);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final seg in segs)
          if (seg.isMath)
            // 块级公式：Math.tex 按公式自然宽度排版、不会自动换行，遇到超宽公式会
            // 撑破外层 Column 导致「RenderFlex overflowed by N pixels on the right」。
            // 用横向 SingleChildScrollView 收住宽度（滚动查看），避免溢出。
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Math.tex(
                  seg.text,
                  mathStyle: MathStyle.display,
                  textStyle: _mathText,
                ),
              ),
            )
          else
            _buildMarkdown(seg.text),
      ],
    );
  }

  /// 按 `$$...$$` 切片；普通片段保留原样交给 Markdown。
  static List<_Seg> _split(String text) {
    final out = <_Seg>[];
    var cursor = 0;
    for (final m in _blockMath.allMatches(text)) {
      if (m.start > cursor) {
        out.add(_Seg(text.substring(cursor, m.start), isMath: false));
      }
      final tex = m.group(1)?.trim() ?? '';
      if (tex.isNotEmpty) out.add(_Seg(tex, isMath: true));
      cursor = m.end;
    }
    if (cursor < text.length) {
      out.add(_Seg(text.substring(cursor), isMath: false));
    }
    if (out.isEmpty) out.add(_Seg(text, isMath: false));
    return out;
  }

  Widget _buildMarkdown(String text) {
    return MarkdownBody(
      data: text,
      selectable: true,
      builders: <String, MarkdownElementBuilder>{
        'math': _MathElementBuilder(),
      },
      inlineSyntaxes: <md.InlineSyntax>[_InlineMathSyntax()],
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(fontSize: 14, height: 1.5, color: Colors.black87),
        h1: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        h2: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        h3: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        h4: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        code: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: Colors.black87,
        ),
        codeblockDecoration: BoxDecoration(
          color: const Color(0x0F000000),
          borderRadius: BorderRadius.circular(4),
        ),
        blockquoteDecoration: const BoxDecoration(
          color: Color(0x08000000),
          border: Border(
            left: BorderSide(color: Color(0xFFBDBDBD), width: 3),
          ),
        ),
        listBullet: const TextStyle(fontSize: 14, color: Colors.black87),
      ),
    );
  }
}

class _Seg {
  const _Seg(this.text, {required this.isMath});
  final String text;
  final bool isMath;
}

/// 行内公式语法：匹配 `$...$`（不匹配 `$$`，不跨行），产出一个 `math` 元素。
class _InlineMathSyntax extends md.InlineSyntax {
  _InlineMathSyntax() : super(r'\$(?!\$)([^\$\n]+?)\$(?!\$)');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final tex = match.group(1)?.trim() ?? '';
    if (tex.isEmpty) return false;
    parser.addNode(md.Element('math', <md.Node>[md.Text(tex)]));
    return true;
  }
}

/// 把 `math` 元素渲染成内联 [Math.tex]（text 样式）。
class _MathElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final tex = element.textContent.trim();
    if (tex.isEmpty) return const SizedBox.shrink();
    return Math.tex(
      tex,
      mathStyle: MathStyle.text,
      textStyle: preferredStyle ?? const TextStyle(fontSize: 14, color: Colors.black87),
    );
  }
}
