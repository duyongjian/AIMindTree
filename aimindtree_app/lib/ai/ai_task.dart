/// 15 类 AI 任务统一枚举（ARCHITECTURE §6）。
///
/// `structured = true` → 走 `AiProvider.runTask`（一次性 + 结构化 outputs，
/// 对应 Dify `/v1/workflows/run` blocking）；`false` → 走 `streamChat`
/// （多轮对话，对应 `/v1/chat-messages`）。
library;

enum AiTask {
  t1Extract('T1', '知识点提取', true),
  t2Normalize('T2', '知识点规范化', true),
  t3Prerequisite('T3', '前置知识推断', true),
  t4GapAnalysis('T4', '知识缺口分析', true),
  t5Ask('T5', '追问', false),
  t6Explain('T6', '讲解', false),
  t7Socratic('T7', '苏格拉底引导', false),
  t8Quiz('T8', '出题', false),
  t9Grade('T9', '批改与误区', true),
  t10Lecture('T10', '讲义生成', false),
  t11Summary('T11', '总结', false),
  t12TitleTags('T12', '标题与标签', true),
  t13Similarity('T13', '知识点相似度', true),
  t14KpDedup('T14', '知识点查重', true),
  t15KpFromSelection('T15', '划词提取知识点', true);

  const AiTask(this.code, this.label, this.structured);

  final String code;
  final String label;

  /// 是否为「一次性结构化执行」任务。
  final bool structured;

  /// 纯本地任务（不经过任何 AI Provider）。
  /// 当前 15 个任务均走 Provider（T4 亦走 DSL-first + 本地兜底），此字段预留。
  bool get isLocalOnly => false;

  /// 会话类任务（多轮、可流式）。
  bool get isConversational =>
      !structured && !isLocalOnly;

  /// 从代码名解析（路由表 / 配置存的是 code）。
  static AiTask parse(String? raw) {
    if (raw == null || raw.isEmpty) return AiTask.t1Extract;
    for (final t in AiTask.values) {
      if (t.name == raw || t.code == raw) return t;
    }
    return AiTask.t1Extract;
  }
}
