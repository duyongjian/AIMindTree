/// 知识点管理页的排序规则（纯函数，无 Flutter 依赖，便于单测）。
///
/// 排序优先级（架构定稿，2026-10-22）：
/// 1. **置顶优先**：`pinned` 的知识点恒在列表最前，与排序字段、方向无关
///    （用户诉求：「控制哪些知识点排在上面方便看」）。
/// 2. **选定时间字段**：`updatedAt` 或 `createdAt`，按用户选的升 / 降序。
///    创建时间一律走 [KnowledgePoint.effectiveCreatedAt]（历史行
///    `created_at` 为 null 时回落到 `updatedAt`，v5 迁移已回填但仍兜底）。
/// 3. **名称**：时间相同按名称升序，保证顺序稳定可复现（同秒创建的点
///    不会因数据库返回顺序漂移而「跳位」）。
library;

import '../../data/models/knowledge_point.dart';

/// 排序字段（时间二选一）。
enum KpSortField {
  /// 按更新时间（内容改动时间）。
  updatedAt('更新时间'),

  /// 按创建时间（入库时间；历史行回落 updatedAt）。
  createdAt('创建时间');

  const KpSortField(this.label);

  /// 中文标签（下拉框 / tooltip 展示）。
  final String label;
}

/// 知识点列表比较器：置顶 > 选定时间字段（asc 控制方向）> 名称。
///
/// 用法：`list..sort((a, b) => compareKp(a, b, field: f, asc: asc))`
int compareKp(
  KnowledgePoint a,
  KnowledgePoint b, {
  required KpSortField field,
  required bool asc,
}) {
  // 1. 置顶恒在最前（true 排前面），与字段、方向无关。
  if (a.pinned != b.pinned) return a.pinned ? -1 : 1;

  // 2. 选定时间字段；asc = 最早在上，false = 最新在上。
  final timeCmp = switch (field) {
    KpSortField.updatedAt => a.updatedAt.compareTo(b.updatedAt),
    KpSortField.createdAt =>
      a.effectiveCreatedAt.compareTo(b.effectiveCreatedAt),
  };
  if (timeCmp != 0) return asc ? timeCmp : -timeCmp;

  // 3. 兜底按名称升序（稳定、可复现）。
  return a.name.compareTo(b.name);
}
