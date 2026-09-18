/// 知识树（ARCHITECTURE T05「知识树」+ 画布）。
///
/// 持久化复用已有的 `canvases` 表（name / notebook_id / viewport）——它天然就是
/// 「一块可命名的画布」，不需要为新概念建表。
///
/// 两种来源：
/// - **笔记树**：从某篇笔记提取知识点时自动创建，`id` 与 `noteId` 相同
///   （这样老数据里 `canvas_nodes.canvas_id = noteId` 天然就是「笔记树」的成员，不用迁移）。
/// - **自建树**：用户新建的树，可以把任意笔记提取出的知识点并进来。
///
/// 成员关系存在 `canvas_nodes`（target_type='kp'），**同一条记录同时承载画布坐标**，
/// 即「被收进这棵树」和「在这棵树里的位置」是一份数据，不重复维护。
library;

import '../../core/id.dart';

class KnowledgeTree {
  KnowledgeTree({
    String? id,
    this.name = '',
    this.notebookId,
  }) : id = id ?? newUlid();

  final String id;
  String name;
  final String? notebookId;
}

/// 一批知识点对某棵知识树的「影响面」（删除笔记时用来提示用户）。
///
/// [pointCount] 是这批知识点中有多少个属于这棵树。
class TreeImpact {
  const TreeImpact({
    required this.treeId,
    required this.treeName,
    required this.pointCount,
  });

  final String treeId;
  final String treeName;
  final int pointCount;
}
