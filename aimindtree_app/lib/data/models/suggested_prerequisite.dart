/// AI 推断出的「应补但当前缺失」的前置知识点建议。
///
/// 这类知识点**不入库**（PRD 锚点硬规则：没有可逐字定位的 source_quote 就是幻觉，
/// 禁止入库）。它们以「学习建议」形态呈现给用户，由用户决定是否新建笔记去补。
library;

class SuggestedPrerequisite {
  const SuggestedPrerequisite({
    required this.name,
    this.type = '',
    this.definition = '',
    required this.reason,
    this.level = 0, // 新增：在建议链中的层级（1=最接近选中点，越大越底层基础）
  });

  /// 建议补的知识点名称。
  final String name;

  /// 类型（概念/公式/定理/方法/事实/误区），可为空。
  final String type;

  /// AI 给出的定义（仅建议，未锚定原文）。
  final String definition;

  /// 为什么需要它（如：在哪些知识点的定义中被提及）。
  final String reason;

  /// 在建议链中的层级（1=最接近选中点，越大越底层基础）。默认 0 表示未分级。
  final int level;

  @override
  String toString() => 'SuggestedPrerequisite($name)';
}
