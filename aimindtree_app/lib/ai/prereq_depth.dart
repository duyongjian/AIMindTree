/// 补前置深度（T4 递归链层级契约）。
///
/// 与 T4 工作流 DSL、本地兜底共用同一套层级 / 学段语义：
/// - `depth` 量化为 `1/2/3` 层（绝对层级上限）；
/// - `level` 字段语义：在建议链中 `level=1` 表示最接近选中点（最直接前置），
///   `level` 越大越底层基础；
/// - 自定义档不量化成固定层数，而是把用户自由文本透传为 `depth_instruction`。
library;

/// 补前置链的深度档位（低 / 中 / 高 / 自定义）。
enum PrereqDepth {
  /// 低：最近一层直接相关前置（大学 / 高中入门即可）。
  low,

  /// 中：中等基础（初中 / 高中）。
  medium,

  /// 高：最基础（小学 / 常识）。
  high,

  /// 自定义：自然语言指令，由 [PrereqDepth.code] 外的 `depth_instruction` 承载。
  custom;

  /// 递归层数上限（绝对层级，从 1 开始）。
  int get maxLevels => switch (this) {
        PrereqDepth.low => 1,
        PrereqDepth.medium => 2,
        PrereqDepth.high => 3,
        PrereqDepth.custom => 3, // 自定义默认上限，可被 customInstruction 覆盖
      };

  /// 每节点广度上限（单次展开建议数），控制响应体积。
  int get maxBreadth => switch (this) {
        PrereqDepth.low => 3,
        PrereqDepth.medium => 4,
        PrereqDepth.high => 5,
        PrereqDepth.custom => 5,
      };

  /// 学段文案，T4 prompt 与本地兜底共用同一契约。
  String get schoolStage => switch (this) {
        PrereqDepth.low => '大学/高中入门级',
        PrereqDepth.medium => '初中/高中基础',
        PrereqDepth.high => '小学/常识级',
        PrereqDepth.custom => '由自定义指令决定',
      };

  /// 编码进 Dify 输入的标准字符串（'low' | 'medium' | 'high' | 'custom'）。
  String get code => name;

  /// 人类可读名称（UI 展示）。
  String get label => switch (this) {
        PrereqDepth.low => '低（最近一层直接相关前置）',
        PrereqDepth.medium => '中（初中/高中基础）',
        PrereqDepth.high => '高（小学/常识）',
        PrereqDepth.custom => '自定义',
      };
}
