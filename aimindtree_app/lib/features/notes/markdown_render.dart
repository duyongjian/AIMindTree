/// 块级 Markdown 渲染器（PRD §5.10：Markdown 源码 + 分屏预览）。
///
/// 故意**不引第三方 markdown 包**（省原生依赖）。支持的块级语法：
/// - 标题 `# ## ###`（以及 4~6 级）
/// - 无序列表 `- * +`、有序列表 `1.`
/// - 引用 `>`
/// - 围栏代码块 ``` ```` ```
/// - 分割线 `---` / `***` / `___`
/// - 简版表格（`|` 分列、**等宽**渲染，不支持对齐/合并单元格）
/// - 普通段落（连续非空行合并，保留行内换行）
///
/// 行内：`**粗体**`、`*斜体*`、`` `代码` ``、`[文案](url)`、
/// `![替代文本](aimindtree-asset://<assetId>)`。
///
/// **图片不碰仓储**：图片的字节由调用方通过 [resolveAsset] 回调注入；返回
/// `null`（未同步 / 缺失）时降级为「图片未同步」占位块，保证整篇笔记永远能渲染。
/// 因此本文件可以 100% 单测（见 `test/markdown_render_test.dart`）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'markdown_actions.dart' show kAssetUrlPrefix;

/// 把 assetId 解析成图片字节；`null` = 缺失 / 未同步。
typedef AssetResolver = Future<Uint8List?> Function(String assetId);

/// 把 [md] 渲染成一列块级 Widget（供 `Column(children: ...)` 直接使用）。
///
/// [resolveAsset] 用于解析笔记内嵌图片，缺失时必须返回 `null`。
List<Widget> renderMarkdownBlocks(String md,
    {required AssetResolver resolveAsset}) {
  final blocks = _parseBlocks(md);
  return <Widget>[
    for (final block in blocks) _buildBlock(block, resolveAsset),
  ];
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

RegExp get _kFence => RegExp(r'^```\s*(\w*)\s*$');
RegExp get _kDivider => RegExp(r'^(-{3,}|\*{3,}|_{3,})$');
RegExp get _kHeading => RegExp(r'^(#{1,6})\s*(.*)$');
RegExp get _kQuote => RegExp(r'^(?:>\s?)+(.+)$');
RegExp get _kUlItem => RegExp(r'^[-*+]\s+(.+)$');
RegExp get _kOlItem => RegExp(r'^(\d+)\.\s+(.+)$');
RegExp get _kTableCell => RegExp(r'^\s*:?-{2,}:?\s*$');

/// 图片：`![alt](url)` 放在链接前面，避免被链接规则先吃掉。
RegExp get _kInline => RegExp(
      r'!\[([^\]]*)\]\(([^)\s]+)\)' // 图片
      r'|\[([^\]]*)\]\(([^)\s]+)\)' // 链接
      r'|(\*\*[^*]+\*\*)' // 粗体
      r'|(\*[^*]+\*)' // 斜体
      r'|(`[^`]+`)', // 行内代码
    );

/// 解析成块列表（纯数据，便于单测）。
List<_Block> _parseBlocks(String md) {
  final lines = md.replaceAll('\r\n', '\n').split('\n');
  final blocks = <_Block>[];
  var i = 0;

  while (i < lines.length) {
    final current = lines[i];

    if (current.trim().isEmpty) {
      i++;
      continue;
    }

    // 围栏代码块。
    final fence = _kFence.firstMatch(current.trim());
    if (fence != null) {
      final buf = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        buf.add(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // 吃掉收尾的 ```
      blocks.add(_CodeBlock(code: buf.join('\n')));
      continue;
    }

    final trimmed = current.trim();

    // 分割线。
    if (_kDivider.hasMatch(trimmed)) {
      blocks.add(const _DividerBlock());
      i++;
      continue;
    }

    // 标题。
    final heading = _kHeading.firstMatch(trimmed);
    if (heading != null) {
      blocks.add(_HeadingBlock(
        level: (heading.group(1) ?? '#').length,
        text: heading.group(2) ?? '',
      ));
      i++;
      continue;
    }

    // 表格：当前行以 | 开头，且下一行是 | --- | 分隔行。
    if (trimmed.startsWith('|') &&
        i + 1 < lines.length &&
        _isTableDivider(lines[i + 1].trim())) {
      final rows = <List<String>>[_splitRow(trimmed)];
      i += 2; // 表头行 + 分隔行
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        rows.add(_splitRow(lines[i].trim()));
        i++;
      }
      blocks.add(_TableBlock(rows: rows));
      continue;
    }

    // 引用（连续若干行合并成一个引用块）。
    if (_kQuote.hasMatch(trimmed)) {
      final buf = <String>[];
      while (i < lines.length) {
        final m = _kQuote.firstMatch(lines[i].trim());
        if (m == null) break;
        buf.add(m.group(1) ?? '');
        i++;
      }
      blocks.add(_QuoteBlock(lines: buf));
      continue;
    }

    // 无序列表。
    if (_kUlItem.hasMatch(trimmed)) {
      final items = <_ListItem>[];
      while (i < lines.length) {
        final m = _kUlItem.firstMatch(lines[i].trim());
        if (m == null) break;
        items.add(_ListItem(marker: '•', text: m.group(1) ?? ''));
        i++;
      }
      blocks.add(_ListBlock(items: items));
      continue;
    }

    // 有序列表（沿用作者写的编号）。
    if (_kOlItem.hasMatch(trimmed)) {
      final items = <_ListItem>[];
      while (i < lines.length) {
        final m = _kOlItem.firstMatch(lines[i].trim());
        if (m == null) break;
        items.add(_ListItem(marker: '${m.group(1)}.', text: m.group(2) ?? ''));
        i++;
      }
      blocks.add(_ListBlock(items: items));
      continue;
    }

    // 段落：连续非空行合并；遇到任何块级起始就断开。
    if (_startsBlock(lines, i)) {
      // 起始符后面没有有效内容（例如孤立的 `|`）→ 当普通文本渲染。
      blocks.add(_ParagraphBlock(text: current.trimRight()));
      i++;
      continue;
    }
    final buf = <String>[];
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !_startsBlock(lines, i)) {
      buf.add(lines[i].trimRight());
      i++;
    }
    blocks.add(_ParagraphBlock(text: buf.join('\n')));
  }

  return blocks;
}

/// 第 [i] 行是否是另一个块级语法的起始（用于打断连续段落）。
bool _startsBlock(List<String> lines, int i) {
  final trimmed = lines[i].trim();
  if (trimmed.isEmpty) return true;
  if (_kFence.hasMatch(trimmed)) return true;
  if (_kDivider.hasMatch(trimmed)) return true;
  if (_kHeading.hasMatch(trimmed)) return true;
  if (_kQuote.hasMatch(trimmed)) return true;
  if (_kUlItem.hasMatch(trimmed)) return true;
  if (_kOlItem.hasMatch(trimmed)) return true;
  if (trimmed.startsWith('|')) return true;
  return false;
}

/// 是否是表格分隔行（`| --- | --- |`）。
bool _isTableDivider(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('|')) return false;
  final cells = _splitRow(trimmed);
  if (cells.length < 2) return false;
  return cells.every(_kTableCell.hasMatch);
}

/// 拆一行表格单元格：`| a | b |` → `['a', 'b']`。
List<String> _splitRow(String line) {
  final trimmed = line.trim();
  final body = trimmed.startsWith('|') ? trimmed.substring(1) : trimmed;
  final tail = body.endsWith('|') ? body.substring(0, body.length - 1) : body;
  return <String>[for (final cell in tail.split('|')) cell.trim()];
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

const TextStyle _kBase = TextStyle(fontSize: 14, height: 1.5);
const double _kBlockGap = 10.0;

Widget _buildBlock(_Block block, AssetResolver resolveAsset) {
  return switch (block) {
    _HeadingBlock() => _buildHeading(block, resolveAsset),
    _ListBlock() => _buildList(block, resolveAsset),
    _QuoteBlock() => _buildQuote(block, resolveAsset),
    _CodeBlock() => _buildCode(block),
    _DividerBlock() => const Divider(height: 20, thickness: 1),
    _TableBlock() => _buildTable(block, resolveAsset),
    _ParagraphBlock() => Padding(
        padding: const EdgeInsets.only(bottom: _kBlockGap),
        child: Text.rich(
          TextSpan(
            style: _kBase,
            children: _inlineSpans(block.text, _kBase, resolveAsset),
          ),
        ),
      ),
  };
}

Widget _buildHeading(_HeadingBlock block, AssetResolver resolveAsset) {
  final fontSize = switch (block.level) {
    1 => 20.0,
    2 => 17.0,
    _ => 15.0,
  };
  final style = _kBase.copyWith(
    fontSize: fontSize,
    fontWeight: FontWeight.bold,
    height: 1.3,
  );
  return Padding(
    padding: const EdgeInsets.only(bottom: _kBlockGap),
    child: Text.rich(
      TextSpan(
        style: style,
        // 行内 span 必须继承本块的 style（pushStyle 语义下同名字段会覆盖），
        // 否则标题会被重置成正文 14 号。
        children: _inlineSpans(block.text, style, resolveAsset),
      ),
    ),
  );
}

Widget _buildList(_ListBlock block, AssetResolver resolveAsset) {
  return Padding(
    padding: const EdgeInsets.only(bottom: _kBlockGap),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final item in block.items)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('${item.marker} ', style: _kBase),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: _kBase,
                      children: _inlineSpans(item.text, _kBase, resolveAsset),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

Widget _buildQuote(_QuoteBlock block, AssetResolver resolveAsset) {
  final style = _kBase.copyWith(color: Colors.grey.shade700);
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: _kBlockGap),
    padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
    decoration: BoxDecoration(
      color: Colors.grey.shade100,
      border: Border(left: BorderSide(color: Colors.grey.shade400, width: 3)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final line in block.lines)
          Text.rich(
            TextSpan(
              style: style,
              children: _inlineSpans(line, style, resolveAsset),
            ),
          ),
      ],
    ),
  );
}

Widget _buildCode(_CodeBlock block) {
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: _kBlockGap),
    padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
    decoration: BoxDecoration(
      color: Colors.grey.shade200,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      block.code,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
    ),
  );
}

/// 表格：**等宽**列（FlexColumnWidth），不支持对齐与合并单元格。
Widget _buildTable(_TableBlock block, AssetResolver resolveAsset) {
  final rows = block.rows;
  final columnCount = rows.fold<int>(
    1,
    (max, row) => row.length > max ? row.length : max,
  );

  return SizedBox(
    width: double.infinity,
    child: Table(
      border: TableBorder.all(color: Colors.grey.shade400, width: 0.5),
      defaultColumnWidth: const FlexColumnWidth(),
      columnWidths: <int, TableColumnWidth>{
        // FlexColumnWidth(1.0) == 均分，显式写出来的目的是让「等宽」意图可读。
        for (var i = 0; i < columnCount; i++) i: const FlexColumnWidth(1.0),
      },
      children: <TableRow>[
        for (var r = 0; r < rows.length; r++)
          TableRow(
            decoration: r == 0
                ? BoxDecoration(color: Colors.grey.shade200)
                : null,
            children: <Widget>[
              for (var c = 0; c < columnCount; c++)
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  child: Text.rich(
                    TextSpan(
                      style: _kBase.copyWith(
                        fontWeight: r == 0 ? FontWeight.bold : FontWeight.normal,
                        fontSize: 13,
                      ),
                      children: _inlineSpans(
                        c < rows[r].length ? rows[r][c] : '',
                        _kBase.copyWith(fontSize: 13),
                        resolveAsset,
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    ),
  );
}

/// 行内渲染：`**粗体**` / `*斜体*` / `` `代码` `` / 链接 / 图片。
List<InlineSpan> _inlineSpans(String src, TextStyle base,
    AssetResolver resolveAsset) {
  final result = <InlineSpan>[];
  var last = 0;

  for (final m in _kInline.allMatches(src)) {
    if (m.start > last) {
      result.add(TextSpan(text: src.substring(last, m.start), style: base));
    }
    final raw = m.group(0) ?? '';

    if (raw.startsWith('![')) {
      // 图片：![alt](url)
      final alt = m.group(1) ?? '';
      final url = m.group(2) ?? '';
      result.add(_buildImageSpan(alt, url, resolveAsset));
    } else if (raw.startsWith('[')) {
      // 链接：[label](url)
      final label = m.group(3) ?? '';
      final url = m.group(4) ?? '';
      result.add(TextSpan(
        text: label.isEmpty ? url : label,
        style: base.copyWith(
          color: Colors.blue.shade700,
          decoration: TextDecoration.underline,
        ),
      ));
    } else if (raw.startsWith('**')) {
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
    } else if (raw.startsWith('*')) {
      result.add(TextSpan(
        text: raw.substring(1, raw.length - 1),
        style: base.copyWith(fontStyle: FontStyle.italic),
      ));
    } else {
      result.add(TextSpan(text: raw, style: base));
    }
    last = m.end;
  }

  if (last < src.length) {
    result.add(TextSpan(text: src.substring(last), style: base));
  }
  return result;
}

/// 图片行内 WidgetSpan。
///
/// 只认识 `aimindtree-asset://<assetId>` 协议；其它地址按普通文本输出。
InlineSpan _buildImageSpan(String alt, String url, AssetResolver resolveAsset) {
  if (!url.startsWith(kAssetUrlPrefix)) {
    return TextSpan(text: '![${alt.isEmpty ? '图片' : alt}]($url)', style: _kBase);
  }
  final assetId = url.substring(kAssetUrlPrefix.length);
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: SizedBox(
      height: 160,
      child: FutureBuilder<Uint8List?>(
        future: resolveAsset(assetId),
        builder: (BuildContext context, AsyncSnapshot<Uint8List?> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _imageShell(const Center(child: Text('加载中…', style: TextStyle(fontSize: 12, color: Colors.grey))));
          }
          final bytes = snap.data;
          if (bytes == null || bytes.isEmpty) return _missingImageBox(alt);
          return Image.memory(
            bytes,
            height: 160,
            fit: BoxFit.contain,
            errorBuilder: (BuildContext _, Object __, StackTrace? ___) =>
                _missingImageBox(alt),
          );
        },
      ),
    ),
  );
}

/// 图片容器的统一外观（灰底 + 圆角 + 边框）。
Widget _imageShell(Widget child) => Container(
      width: 160,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.grey.shade300,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade400),
      ),
      alignment: Alignment.center,
      child: child,
    );

/// 缺失 / 未同步图片的占位块：**绝不让整篇笔记渲染失败**。
Widget _missingImageBox(String alt) => _imageShell(
      Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.broken_image, size: 22, color: Colors.grey.shade600),
          const SizedBox(height: 4),
          Text(
            alt.isEmpty ? '图片未同步' : '图片未同步：$alt',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

// ---------------------------------------------------------------------------
// 块数据模型
// ---------------------------------------------------------------------------

sealed class _Block {
  const _Block();
}

class _ParagraphBlock extends _Block {
  const _ParagraphBlock({required this.text});
  final String text;
}

class _HeadingBlock extends _Block {
  const _HeadingBlock({required this.level, required this.text});
  final int level;
  final String text;
}

class _ListItem {
  const _ListItem({required this.marker, required this.text});
  final String marker;
  final String text;
}

class _ListBlock extends _Block {
  const _ListBlock({required this.items});

  /// 每个条目的 marker 已经区分了有序（`1.`）与无序（`•`）。
  final List<_ListItem> items;
}

class _QuoteBlock extends _Block {
  const _QuoteBlock({required this.lines});
  final List<String> lines;
}

class _CodeBlock extends _Block {
  const _CodeBlock({required this.code});
  final String code;
}

class _TableBlock extends _Block {
  const _TableBlock({required this.rows});
  final List<List<String>> rows;
}

class _DividerBlock extends _Block {
  const _DividerBlock();
}
