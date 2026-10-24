/// 会话相关的共享 UI 工具（AI 助手 / 老师模式等会话型页面共用）。
///
/// 抽取自 `lib/features/agent/agent_page.dart`，**等价搬迁**：除
/// [deriveSessionTitle] 按裁决 13 增加可选参数 [fallbackTitle] 外，
/// 函数体逐字未改；`fallbackTitle` 默认 `'新对话'`，**默认参数下行为与
/// 搬迁前逐字等价**（既有断言一行都不用改）。
///
/// 约束：
/// - 本文件**不反向 import** `agent_page.dart`，只依赖数据层的 [ChatMessage]；
/// - 不掺入任何页面专属语义（文案、阈值等一律由调用方传入）；
/// - Agent 侧 `import '.../agent_page.dart'` 的调用方（含既有测试）**仍可用**
///   —— 由 `agent_page.dart` 的 `export` 承接，import 路径保持不变。
library;

import 'package:flutter/material.dart';

import '../../data/repositories/ai_session_repository.dart';

/// 会话标题：优先用户在 title 列里的重命名覆盖；否则**运行时派生**——
/// 首条 user 消息首行（截 24 字），没有再退 [fallbackTitle]。
///
/// ai_sessions 本就带 title 列（tables.dart），重命名直接写该列即可，
/// **不需要改表结构**；未重命名时该列为空，退回派生标题。
///
/// [fallbackTitle]：既无重命名标题、也无首条 user 消息时的回落文案，
/// 默认 `'新对话'`（**默认值不得改动**）；需要其它回落文案时由调用方传入。
String deriveSessionTitle({
  required String storedTitle,
  required List<ChatMessage> messages,
  String fallbackTitle = '新对话',
}) {
  final override = storedTitle.trim();
  if (override.isNotEmpty) return override;
  for (final m in messages) {
    if (m.role != 'user') continue;
    final first = m.content.trim().split('\n').first.trim();
    if (first.isEmpty) continue;
    return first.length <= 24 ? first : '${first.substring(0, 24)}…';
  }
  return fallbackTitle;
}

/// 会话列表时间戳（本地时区，MM-dd HH:mm）。
String fmtSessionTime(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

/// 弹一个单行输入框（命名类场景共用，如建树 / 重命名）。
Future<String?> askNameDialog(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
}) async {
  final c = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(hintText: hint, isDense: true),
        onSubmitted: (_) => Navigator.pop(ctx, c.text.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, c.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  return name;
}

/// 通用确认框（清空 / 删除等破坏性操作前的二次确认）。
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定')),
      ],
    ),
  );
  return ok ?? false;
}
