/// 组装「本会话前文」上下文块（L2）。
///
/// **纯函数**：输入相同 → 输出逐字相同（可单测、可被 AI 助手与老师模式共用）。
///
/// 存在理由：后端 `llm_server` 的 `/v1/chat/completions` **是无状态的**
/// （`routers/chat.py` 的 `_build_messages` 只渲染单条 query，`conversation_id`
/// 仅回显透传、四个后端适配器都不消费它）→ 多轮记忆**只能**由 App 侧把
/// 历史拼进 query 来实现。
library;

/// 把一段会话此前的问答拼成「本会话前文」块。
///
/// [turns] 当前会话此前的 user / assistant 消息（**不含本轮问题**）。
///        每条是一个具名记录：`role`（`'user'` / `'assistant'`）、`content`（正文）。
///        其它 role 一律忽略。
///
///        ⚠️ **函数内部绝不重排**：严格按调用方传入的顺序输出。
///        排序权威在数据层 `listMessages`（纯 `id ASC`）；而 `updated_at` 跨端
///        会被同步覆盖（推送时用 outbox 创建时间覆盖、pull 时 `_hydrate` 再覆盖）
///        → 不可信。若在这里再按时间排一次，就会出现「第二个排序权威」，
///        把列表顺序与上下文顺序搞成两套。
///
/// [maxMessages] 最多取最近多少条；超限时**从最老**开始丢。
///               默认 12 —— 这是 AI 助手侧的历史条数口径（保持其输出逐字不变）。
/// [maxChars]    注入块总长度上限（字符）；`0` = 不限长。
///               超限时**从最老的一条**开始丢；**至少保留最新一条**
///               （若最新一条单独就超限 → **截断它的内容**，不是整条丢弃）。
/// [header]      前文块标题行。
///
/// 返回值 = `[header, ...保留的各行].join('\n').trimRight()`；
/// 没有可用内容时返回**空字符串**（不是只有 header）。
String buildSessionContext(
  List<({String role, String content})> turns, {
  int maxMessages = 12,
  int maxChars = 0,
  String header = '【本会话前文】（同一会话内此前的问答，请参考上下文）',
}) {
  // ① 只取 user / assistant。
  final picked = <({String role, String content})>[];
  for (final t in turns) {
    if (t.role == 'user' || t.role == 'assistant') picked.add(t);
  }
  if (picked.isEmpty) return '';

  // ② 条数超限 → 从最老开始丢，保留最近 N 条。
  final limited = picked.length > maxMessages
      ? picked.sublist(picked.length - maxMessages)
      : picked;
  if (limited.isEmpty) return '';

  // ③ 逐行成文（中文冒号，逐字固定）。
  final lines = <String>[
    for (final m in limited) '${m.role == 'user' ? '用户' : 'AI'}：${m.content}'
  ];

  var kept = lines;
  if (maxChars > 0) {
    // 预算 = 总上限 - 标题行 - 标题后的换行符。
    final budget = maxChars - header.length - 1;
    final keptRev = <String>[];
    var used = 0;
    // 从最新往最老收：先收到的就是最新的，收满即止。
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      final cost = line.length + 1;
      if (used + cost <= budget) {
        keptRev.insert(0, line);
        used += cost;
      } else if (keptRev.isEmpty) {
        // 最新一条单独就超预算 → 截断它的内容（**不是**整条丢弃）。
        final room = budget > 0 ? budget : 0;
        keptRev.insert(0, line.length <= room ? line : line.substring(0, room));
        used = room;
      } else {
        break; // 更老的一律丢弃。
      }
    }
    kept = keptRev;
  }

  return ([header] + kept).join('\n').trimRight();
}
