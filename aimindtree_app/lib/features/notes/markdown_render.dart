/// 块级 Markdown 渲染器 —— **兼容 shim**（T3 瘦身后只剩入口）。
///
/// 改造前这里是 554 行「解析 + 渲染」一体的实现；改造后：
/// - 解析交给 `markdown_block_parser.dart`（`parseMarkdownDoc`）；
/// - 渲染交给 `block_view.dart`（`buildReadOnlyDoc`），与编辑器**共用同一套视觉语言**
///   （标题 20/17/15、表格等宽、代码块灰底…），因此不会出现「预览一套、编辑另一套」。
///
/// **为什么保留这个符号**
/// 1. `test/markdown_render_test.dart` 的 10 条断言原样继续跑；
/// 2. 未来任何「只读展示 Markdown」的地方（知识卡片、AI 回答气泡）可直接复用；
/// 3. 万一 WYSIWYG 出意外，需要一个只读兜底开关时成本为零。
///
/// **语义与旧实现保持一致**
/// - 空正文（全空白）→ 返回空列表（旧测试「空正文不产生任何块」依赖此行为）；
/// - 只读，不可编辑；
/// - 图片缺失 → 「图片未同步」占位块，绝不让整篇渲染失败。
///
/// 本文件**不再包含任何解析 / 渲染逻辑**，请勿在此新增代码。
library;

import 'package:flutter/widgets.dart';

import 'block_model.dart';
import 'block_view.dart';
import 'markdown_block_parser.dart';

/// [AssetResolver] 定义在 `block_model.dart`；这里再导出，保证老的
/// `import 'markdown_render.dart'` 写法继续可用（设计 §6.5）。
export 'block_model.dart' show AssetResolver;

/// 把 [md] 渲染成一列块级 Widget（供 `Column(children: ...)` 直接使用）。
///
/// [resolveAsset] 用于解析笔记内嵌图片，缺失时返回 `null` → 渲染占位块。
List<Widget> renderMarkdownBlocks(
  String md, {
  required AssetResolver resolveAsset,
}) {
  if (md.trim().isEmpty) return const <Widget>[];
  return buildReadOnlyDoc(
    parseMarkdownDoc(md),
    resolveAsset: resolveAsset,
  );
}
