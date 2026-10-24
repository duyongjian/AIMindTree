/// Markdown 快捷插入 / 切换动作的**纯函数**集合（供 `markdown_toolbar.dart` 调用）。
///
/// 设计约束（便于 100% 单测）：
/// - 入参只有正文字符串 + `TextSelection`，出参是新正文 + 新选区，**不碰任何 Widget /
///   IO / 数据库**；
/// - 选区统一按 `baseOffset/extentOffset` 归一化，**支持反向选区**（extent < base），
///   并把越界偏移夹取到 `[0, text.length]`；
/// - 每个动作都尽量做到「再按一次回到原状」（toggle），符合富文本工具栏直觉。
///
/// 行级动作（`toggleLinePrefix`）对多行选区**逐行**处理。
library;

import 'package:flutter/services.dart';

/// 笔记内嵌图片的自定义协议前缀：`![alt](aimindtree-asset://<assetId>)`。
const String kAssetUrlPrefix = 'aimindtree-asset://';

/// 一次编辑动作的结果：新正文 + 新光标选区。
typedef MarkdownEditResult = ({String text, TextSelection selection});

/// `wrapInline` 无选区时使用的占位文案（按标记区分）。
const Map<String, String> kInlinePlaceholders = <String, String>{
  '**': '粗体文字',
  '*': '斜体文字',
  '`': '代码',
  '~~': '删除线',
};

/// `insertFence` 无选区时代码块里的占位代码。
const String kCodePlaceholder = '在此输入代码';

/// `insertLink` 无选区时的默认链接文案 / URL。
const String kDefaultLinkLabel = '链接文字';
const String kDefaultLinkUrl = 'https://';

/// `insertImage` 未提供 alt 时的默认替代文本。
const String kDefaultImageAlt = '图片';

/// `insertTable` 插入的 2×2 占位表格。
const String kTablePlaceholder = '| 列1 | 列2 |\n'
    '| --- | --- |\n'
    '| 内容1 | 内容2 |';

/// 行内包裹：`**加粗**` / `*斜体*` / `` `代码` ``。
///
/// - 有选区 → 用 `marker` 包住选区，并保持选中（连选中 `marker`，便于再次点击取消）；
/// - 选区自身已被同一 `marker` 包住（或紧贴外侧就有一对）→ 去掉标记（取消）；
/// - 无选区 → 插入 `marker + 占位 + marker` 并选中占位文案。
MarkdownEditResult wrapInline(
    String text, TextSelection sel, String marker) {
  final range = _resolveRange(sel, text.length);
  final selected = text.substring(range.start, range.end);

  // 1) 选区自身含一对 marker（用户把 **abc** 整段选中了）→ 去掉。
  if (selected.length >= marker.length * 2 &&
      selected.startsWith(marker) &&
      selected.endsWith(marker)) {
    final body =
        selected.substring(marker.length, selected.length - marker.length);
    return (
      text: text.replaceRange(range.start, range.end, body),
      selection: TextSelection(
        baseOffset: range.start,
        extentOffset: range.start + body.length,
      ),
    );
  }

  // 2) 选区外侧紧贴一对 marker（上一次 wrap 的结果还在选中态）→ 连外侧一起去掉。
  final outerStart = range.start - marker.length;
  final outerEnd = range.end + marker.length;
  if (outerStart >= 0 &&
      outerEnd <= text.length &&
      text.startsWith(marker, outerStart) &&
      text.startsWith(marker, range.end)) {
    final newText = text
        .replaceRange(range.end, outerEnd, '')
        .replaceRange(outerStart, range.start, '');
    return (
      text: newText,
      selection: TextSelection(
        baseOffset: outerStart,
        extentOffset: outerStart + (range.end - range.start),
      ),
    );
  }

  // 3) 空选区 → 占位文案，并选中占位便于直接改写。
  if (range.start == range.end) {
    final placeholder = kInlinePlaceholders[marker] ?? marker;
    final phStart = range.start + marker.length;
    return (
      text: text.replaceRange(range.start, range.end, '$marker$placeholder$marker'),
      selection: TextSelection(
        baseOffset: phStart,
        extentOffset: phStart + placeholder.length,
      ),
    );
  }

  // 4) 普通包裹。
  final insert = '$marker$selected$marker';
  return (
    text: text.replaceRange(range.start, range.end, insert),
    selection: TextSelection(
      baseOffset: range.start,
      extentOffset: range.start + insert.length,
    ),
  );
}

/// 行前缀切换：`# ` / `## ` / `### ` / `- ` / `1. ` / `> `。
///
/// 规则：
/// - 多行选区 → 对**每一行**单独处理；
/// - 所有受影响行都已经是该前缀 → 全部移除（取消）；否则给缺失的行加上；
/// - 同一「家族」的旧前缀会先被剥掉（如 `## 标题` 点 H1 → `# 标题`，
///   `1. 项` 点有序列表 → 取消，`- 项` 点引用 → `> 项`）；
/// - 保留原有缩进。
/// 返回的新选区覆盖全部受影响行（便于连点切换）。
MarkdownEditResult toggleLinePrefix(
    String text, TextSelection sel, String prefix) {
  final range = _resolveRange(sel, text.length);
  final regionStart = _lineStartOf(text, range.start);
  final regionEnd = _lineEndOf(text, range.end);
  final lines = text.substring(regionStart, regionEnd).split('\n');

  final parsed = <_StrippedLine>[for (final line in lines) _stripPrefixFamily(line, prefix)];
  final allPrefixed = parsed.every((p) => p.hadExactPrefix);

  final rebuilt = <String>[
    for (final p in parsed)
      allPrefixed ? '${p.indent}${p.body}' : '${p.indent}$prefix${p.body}',
  ];
  final region = rebuilt.join('\n');

  return (
    text: text.replaceRange(regionStart, regionEnd, region),
    selection: TextSelection(
      baseOffset: regionStart,
      extentOffset: regionStart + region.length,
    ),
  );
}

/// 插入围栏代码块（```` ``` ```` 开头与结尾各占一行）。
///
/// 有选区时把选区放进代码块并选中，无选区时选中占位代码。
MarkdownEditResult insertFence(String text, TextSelection sel) {
  final range = _resolveRange(sel, text.length);
  final before = text.substring(0, range.start);
  final after = text.substring(range.end);
  final selected = range.start == range.end ? '' : text.substring(range.start, range.end);
  final body = selected.isEmpty ? kCodePlaceholder : selected;

  final lead = _gapBefore(before);
  final trail = _gapAfter(after);
  final insert = '${lead}```\n$body\n```$trail';

  final bodyStart = range.start + lead.length + '```\n'.length;
  return (
    text: '$before$insert$after',
    selection: TextSelection(
      baseOffset: bodyStart,
      extentOffset: bodyStart + body.length,
    ),
  );
}

/// 插入链接 `[文案](url)`。
///
/// - 选区看起来是 URL（http/https 开头）→ 作为 url；
/// - 其它选区 → 作为文案；
/// - 无选区 → 用默认文案 + 默认 URL。
/// 插入后选中 url 部分，便于直接改写地址。
MarkdownEditResult insertLink(String text, TextSelection sel) {
  final range = _resolveRange(sel, text.length);
  final selected = range.start == range.end ? '' : text.substring(range.start, range.end);

  final looksLikeUrl =
      selected.startsWith('http://') || selected.startsWith('https://');
  final label = selected.isEmpty || looksLikeUrl ? kDefaultLinkLabel : selected;
  final url = looksLikeUrl ? selected : kDefaultLinkUrl;

  final insert = '[$label]($url)';
  final urlStart = range.start + label.length + '[]('.length;
  return (
    text: text.replaceRange(range.start, range.end, insert),
    selection: TextSelection(
      baseOffset: urlStart,
      extentOffset: urlStart + url.length,
    ),
  );
}

/// 插入 2×2 占位表格，并选中第一个表头单元格文案（`列1`），便于直接改写列名。
MarkdownEditResult insertTable(String text, TextSelection sel) {
  final range = _resolveRange(sel, text.length);
  final before = text.substring(0, range.start);
  final after = text.substring(range.end);
  final lead = _gapBefore(before);
  final trail = _gapAfter(after);
  final insert = '$lead$kTablePlaceholder$trail';

  final firstCellStart = range.start + lead.length + '| '.length;
  return (
    text: '$before$insert$after',
    selection: TextSelection(
      baseOffset: firstCellStart,
      extentOffset: firstCellStart + '列1'.length,
    ),
  );
}

/// 插入图片引用 `![alt](aimindtree-asset://<assetId>)`。
///
/// [assetId] 允许带或不带协议前缀（带前缀时原样使用）。
/// 插入后光标停在这行末尾（assetId 由调用方决定，不需要用户手改）。
MarkdownEditResult insertImage(
    String text, TextSelection sel, String assetId, String alt) {
  final range = _resolveRange(sel, text.length);
  final before = text.substring(0, range.start);
  final after = text.substring(range.end);
  final lead = _gapBefore(before);
  final trail = _gapAfter(after);

  final label = alt.trim().isEmpty ? kDefaultImageAlt : alt.trim();
  final url = assetId.startsWith(kAssetUrlPrefix) ? assetId : '$kAssetUrlPrefix$assetId';
  final line = '![$label]($url)';
  final cursor = range.start + lead.length + line.length;

  return (
    text: '$before$lead$line$trail$after',
    selection: TextSelection.collapsed(offset: cursor),
  );
}

/// 插入水平分割线 `---`，并把光标移到分割线下一行行首。
MarkdownEditResult insertDivider(String text, TextSelection sel) {
  final range = _resolveRange(sel, text.length);
  final before = text.substring(0, range.start);
  final after = text.substring(range.end);
  final lead = _gapBefore(before);
  final trail = _gapAfter(after).isEmpty ? '\n' : _gapAfter(after);

  const line = '---';
  final cursor = range.start + lead.length + line.length + 1;
  return (
    text: '$before$lead$line$trail$after',
    selection: TextSelection.collapsed(offset: cursor),
  );
}

/// 归一化选区：支持反向选区（extent < base），并把越界值夹取到正文范围内。
({int start, int end}) _resolveRange(TextSelection sel, int length) {
  int clampToOne(int v) => v < 0 ? 0 : (v > length ? length : v);
  final base = clampToOne(sel.baseOffset);
  final extent = clampToOne(sel.extentOffset);
  return (start: base <= extent ? base : extent, end: base <= extent ? extent : base);
}

/// [offset] 所在行的行首下标。
int _lineStartOf(String text, int offset) {
  if (offset <= 0) return 0;
  final idx = text.lastIndexOf('\n', offset - 1);
  return idx < 0 ? 0 : idx + 1;
}

/// [offset] 所在行的行尾下标（不含 `\n`）。
int _lineEndOf(String text, int offset) {
  final idx = text.indexOf('\n', offset);
  return idx < 0 ? text.length : idx;
}

/// 「块级」语法需要被空行隔开：返回插入点前面应补的分隔。
String _gapBefore(String before) {
  if (before.isEmpty) return '';
  if (before.endsWith('\n\n')) return '';
  if (before.endsWith('\n')) return '\n';
  return '\n\n';
}

/// 同 [_gapBefore]，作用于插入点之后的正文。
String _gapAfter(String after) {
  if (after.isEmpty) return '';
  if (after.startsWith('\n\n')) return '';
  if (after.startsWith('\n')) return '\n';
  return '\n\n';
}

/// 一行被剥掉「同族行前缀」后的三段信息。
class _StrippedLine {
  const _StrippedLine({
    required this.indent,
    required this.body,
    required this.hadExactPrefix,
  });

  /// 行首缩进（处理嵌套列表/缩进时要保留）。
  final String indent;

  /// 去掉前缀后剩下的正文。
  final String body;

  /// 是否恰好带着 [prefix]（决定连点时是「加」还是「取消」）。
  final bool hadExactPrefix;
}

/// 剥掉 [prefix] 所属家族的行前缀；该家族不存在时原样返回。
///
/// 「家族」决定哪些旧前缀会被先剥掉（避免叠加成 `1. - 项`）；
/// 「是否已有」决定这次点击是「加」还是「取消」。
_StrippedLine _stripPrefixFamily(String line, String prefix) {
  final indentMatch = RegExp(r'^[ \t]*').firstMatch(line);
  final indent = indentMatch?.group(0) ?? '';
  final rest = line.substring(indent.length);

  // 「家族」= 加新前缀前要先剥掉的旧前缀（避免叠加成 `1. - 项`）。
  // 列表标记后面**必须有空白**，否则会把 `**粗体**` 误判成列表项。
  final strip = switch (prefix) {
    // 列表家族（有序 / 无序 / 任务列表）共用同一套「先剥旧前缀」正则。
    // **任务列表 `- [ ] ` 必须排在 `[-*+]\s+` 之前**：否则 `[-*+]\s+`
    // 会先匹配 `- `，把 `- [ ] 项` 剥成 `[ ] 项`（半残），任务列表永远剥不干净。
    '1. ' => RegExp(r'^(?:[-*+]\s+\[\s?\]\s+|\d+\.\s+|[-*+]\s+)'),
    '- ' => RegExp(r'^(?:[-*+]\s+\[\s?\]\s+|\d+\.\s+|[-*+]\s+)'),
    '- [ ] ' => RegExp(r'^(?:[-*+]\s+\[\s?\]\s+|\d+\.\s+|[-*+]\s+)'),
    '> ' => RegExp(r'^(?:>\s?)+'),
    '# ' || '## ' || '### ' || '#### ' || '##### ' || '###### ' =>
      RegExp(r'^#{1,6}\s?'),
    _ => RegExp('^${RegExp.escape(prefix)}\\s?'),
  };

  final m = strip.firstMatch(rest);
  if (m == null) {
    return _StrippedLine(indent: indent, body: rest, hadExactPrefix: false);
  }

  final hadExactPrefix = switch (prefix) {
    '1. ' => RegExp(r'^\d+\.\s+').hasMatch(rest), // 任意编号都算「已是有序列表」
    '- ' => RegExp(r'^[-*+]\s+').hasMatch(rest), // - * + 都算「已是无序列表」
    // 标题与引用：只有同一级别才算「已是该前缀」（多层引用一次降一级）。
    _ => rest.startsWith(prefix),
  };

  return _StrippedLine(
    indent: indent,
    body: rest.substring(m.end),
    hadExactPrefix: hadExactPrefix,
  );
}

/// 一个 Markdown 标题（由 [extractHeadings] 抽取，供「目录 / 大纲」使用）。
class MarkdownHeading {
  const MarkdownHeading({
    required this.level,
    required this.title,
    required this.offset,
  });

  /// 标题级别：1 = `#`，6 = `######`。
  final int level;

  /// 去掉前导 `#` 后的纯文本。
  final String title;

  /// 该标题行在原文中的字符起始偏移（指向行首的 `#`），
  /// 点击目录项可直接把光标跳到源码对应位置。
  final int offset;
}

/// 从 Markdown 正文中抽取标题，供「目录 / 大纲」功能使用。
///
/// 规则：
/// - 仅匹配**行首**的 `#`~`######`，且 `#` 后必须跟空白（避免误伤行内的 `#`）；
/// - 处于围栏代码块（``` 或 ~~~ 包围）内的行忽略；
/// - 返回的 [MarkdownHeading.offset] 指向该行行首，便于点击跳转。
List<MarkdownHeading> extractHeadings(String text) {
  final headings = <MarkdownHeading>[];
  final lines = text.split('\n');
  var inFence = false;
  var offset = 0;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      offset += line.length + 1; // +1 为被 split 掉的 '\n'
      continue;
    }
    if (!inFence) {
      final m = RegExp(r'^(#{1,6})\s+(.*\S)\s*$').firstMatch(trimmed);
      if (m != null) {
        headings.add(MarkdownHeading(
          level: m.group(1)!.length,
          title: m.group(2)!,
          offset: offset,
        ));
      }
    }
    offset += line.length + 1;
  }
  return headings;
}
