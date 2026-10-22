/// 知识点分组（「分组」UI 的领域模型）。
///
/// 一条 [KpGroup] = 一棵知识树里的一个组：组名 + 组序（越小越基础）+
/// 组级基础度，以及成员列表（每个成员可选地覆盖自己的基础度）。
///
/// 设计要点：
/// - 「组」是**编排用的顺序容器**，不是新的知识实体——成员只是 canvas_nodes 里
///   已有知识点的 id，组本身不产生新知识点（遵守锚点硬规则）。
/// - 基础度**组级 + 点级**双轨：组的 [foundationalLevel] 给默认值，
///   成员 [KpGroupMember.level] 非空时覆盖它。连线时用 [levelOf] 取有效值。
library;

import 'dart:convert';

/// 全局作用域：知识点管理页的分组统一用 '' 作 canvasId
///（kp_groups.canvas_id NOT NULL，用空串哨兵绕开，**零 schema 变更**）。
///
/// 知识点管理页的「分组」不属于某棵知识树（它跨树统筹所有知识点），但
/// `canvas_id` 是非空列且改动代价高；约定 '' = 全局作用域，与 UI 层的
/// `sourceNoteId = ''` 哨兵（手动知识点无来源笔记）是同一套手法。
const String kGlobalGroupScope = '';

/// 一个分组。
class KpGroup {
  const KpGroup({
    required this.id,
    required this.canvasId,
    required this.name,
    required this.orderIndex,
    required this.foundationalLevel,
    required this.members,
  });

  final String id;

  /// 所属知识树（canvases.id）。
  final String canvasId;

  final String name;

  /// 组序（0 起，越小越基础 / 越先掌握）。
  final int orderIndex;

  /// 组级基础度（0 = 最基础）。
  final int foundationalLevel;

  final List<KpGroupMember> members;

  KpGroup copyWith({
    String? name,
    int? orderIndex,
    int? foundationalLevel,
    List<KpGroupMember>? members,
  }) =>
      KpGroup(
        id: id,
        canvasId: canvasId,
        name: name ?? this.name,
        orderIndex: orderIndex ?? this.orderIndex,
        foundationalLevel: foundationalLevel ?? this.foundationalLevel,
        members: members ?? this.members,
      );

  List<String> get memberIds => <String>[for (final m in members) m.kpId];

  /// 某成员的有效基础度：点级覆盖优先，否则用组级。
  int levelOf(String kpId) {
    for (final m in members) {
      if (m.kpId == kpId && m.level != null) return m.level!;
    }
    return foundationalLevel;
  }
}

/// 分组的一个成员（知识点 id + 可选的点级基础度覆盖）。
class KpGroupMember {
  const KpGroupMember({required this.kpId, this.level});

  final String kpId;

  /// 点级基础度覆盖；`null` = 用组级。
  final int? level;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kpId': kpId,
        if (level != null) 'level': level,
      };

  static KpGroupMember fromJson(Map<String, dynamic> j) => KpGroupMember(
        kpId: (j['kpId'] as String?) ?? '',
        level: (j['level'] as num?)?.toInt(),
      );
}

/// 把成员列表编码成 `kp_groups.members_json` 的字符串。
String encodeGroupMembers(List<KpGroupMember> members) =>
    jsonEncode(<Map<String, dynamic>>[for (final m in members) m.toJson()]);

/// 解析 `kp_groups.members_json`；坏数据一律返回空列表，不抛异常。
List<KpGroupMember> decodeGroupMembers(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <KpGroupMember>[];
    return <KpGroupMember>[
      for (final e in decoded)
        if (e is Map<String, dynamic>) KpGroupMember.fromJson(e),
    ];
  } on Object {
    return const <KpGroupMember>[];
  }
}
