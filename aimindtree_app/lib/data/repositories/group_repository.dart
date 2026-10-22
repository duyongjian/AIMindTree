/// 知识点分组仓储（「分组」UI）。
///
/// 「组」= `kp_groups` 表：组名 + 组序 + 组级基础度 + 成员 JSON。
/// 组本身不是知识实体，成员只是已有知识点的 id（遵守锚点硬规则）。
///
/// 两条铁律：
/// 1. **软删铁律**：所有列表 / 读取查询必须带 `deletedAt.isNull()`；删除只写
///   墓碑（`deleted_at`）+ 入队 `tombstoneKpGroup`，绝不物理删行。
/// 2. **删组不解散成员**：删掉一个组，组里的知识点只是回到「未分组」，
///   绝不能连知识点一起删（组是编排容器，不是知识实体的所有者）。
///
/// 同步：每个写操作后经 [SyncOutboxWriter] 入队；`SyncOutboxRepo.current`
/// 为 null（单测）时自动跳过。分组成员整段存在 `members_json` 里，
/// 同步层原样搬运、不解析（见 `sync_row_map.dart` 的 `kpGroupRowToMap`）。
library;

import 'package:drift/drift.dart';

import '../../core/id.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../db/drift_database.dart';
import '../models/kp_group.dart';
import '../sync/sync_outbox_writer.dart';

class GroupRepository {
  GroupRepository(this._db, {this.deviceId = ''});

  final AppDatabase _db;
  final String deviceId;

  /// 上行同步接线（`SyncOutboxRepo.current == null` 时全部静默跳过）。
  late final SyncOutboxWriter _sync = SyncOutboxWriter(_db);

  static final AppLog _log = AppLog('group_repo');

  // ============ 读 ============

  /// 某棵树的全部组，按组序升序（越基础越靠前）。
  Future<List<KpGroup>> listGroups(String canvasId) async {
    final rows = await (_db.select(_db.kpGroups)
          ..where((t) => t.canvasId.equals(canvasId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
    return rows.map(_fromRow).toList();
  }

  /// 全局作用域（知识点管理页）的全部组，按组序升序。
  ///
  /// 全局组统一用 [kGlobalGroupScope]（空串）作 canvasId，
  /// 与某棵知识树下的组互不干扰。
  Future<List<KpGroup>> listGlobalGroups() => listGroups(kGlobalGroupScope);

  // ============ 写 ============

  /// 新建一个组（组序默认接在末尾）。
  Future<Result<KpGroup>> createGroup({
    required String canvasId,
    String name = '',
    required int orderIndex,
    int foundationalLevel = 0,
    List<String> memberIds = const <String>[],
  }) async {
    try {
      final id = newUlid();
      final members = <KpGroupMember>[
        for (final k in memberIds) KpGroupMember(kpId: k),
      ];
      await _db.into(_db.kpGroups).insert(KpGroupsCompanion(
            id: Value(id),
            canvasId: Value(canvasId),
            name: Value(name),
            orderIndex: Value(orderIndex),
            foundationalLevel: Value(foundationalLevel),
            membersJson: Value(encodeGroupMembers(members)),
            updatedAt: Value(DateTime.now().toUtc()),
            version: const Value(1),
            deviceId: Value(deviceId),
          ));
      await _sync.upsertKpGroup(id);
      return Success(KpGroup(
        id: id,
        canvasId: canvasId,
        name: name,
        orderIndex: orderIndex,
        foundationalLevel: foundationalLevel,
        members: members,
      ));
    } on Object catch (e, s) {
      _log.e('新建分组失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 新建一个**全局组**（知识点管理页，组序自动接在末尾）。
  Future<Result<KpGroup>> createGlobalGroup({
    required String name,
    List<String> memberIds = const <String>[],
  }) async {
    try {
      final existing = await listGlobalGroups();
      // 组序取「当前最大 + 1」；空表时为 0。
      var nextOrder = 0;
      for (final g in existing) {
        if (g.orderIndex >= nextOrder) nextOrder = g.orderIndex + 1;
      }
      return await createGroup(
        canvasId: kGlobalGroupScope,
        name: name,
        orderIndex: nextOrder,
        memberIds: memberIds,
      );
    } on Object catch (e, s) {
      _log.e('新建全局分组失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 保存（覆盖）一个组的名称 / 组序 / 基础度 / 成员。
  Future<Result<void>> saveGroup(KpGroup group) async {
    try {
      final existing = await _loadGroupRow(group.id);
      await (_db.update(_db.kpGroups)..where((t) => t.id.equals(group.id)))
          .write(KpGroupsCompanion(
        name: Value(group.name),
        orderIndex: Value(group.orderIndex),
        foundationalLevel: Value(group.foundationalLevel),
        membersJson: Value(encodeGroupMembers(group.members)),
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value((existing?.version ?? 0) + 1),
      ));
      await _sync.upsertKpGroup(group.id);
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('保存分组失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 往组里加成员（已存在的成员不会重复添加，保持原有顺序）。
  Future<Result<void>> addMembers(String groupId, List<String> kpIds) =>
      _mutateMembers(groupId, add: kpIds, remove: const <String>[]);

  /// 从组里移除成员（只解除归属关系，不动知识点本身）。
  Future<Result<void>> removeMembers(String groupId, List<String> kpIds) =>
      _mutateMembers(groupId, add: const <String>[], remove: kpIds);

  /// 重命名一个组（只改 `name`，其余字段不动）。
  Future<Result<void>> renameGroup(String id, String name) async {
    try {
      final existing = await _loadGroupRow(id);
      if (existing == null) {
        return Failure<void>(StateError('分组不存在或已被删除：$id'));
      }
      await (_db.update(_db.kpGroups)..where((t) => t.id.equals(id)))
          .write(KpGroupsCompanion(
        name: Value(name),
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value(existing.version + 1),
      ));
      await _sync.upsertKpGroup(id);
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('重命名分组失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 按 [orderedIds] 的顺序重排分组（第 i 个 id 的组序记为 i）。
  ///
  /// 未出现在列表里的组保持原组序不变；不存在的 id 静默跳过。
  Future<Result<void>> reorderGroups(List<String> orderedIds) async {
    try {
      for (var i = 0; i < orderedIds.length; i++) {
        final id = orderedIds[i];
        final existing = await _loadGroupRow(id);
        if (existing == null) continue;
        if (existing.orderIndex == i) continue; // 无变化则不写、不入队
        await (_db.update(_db.kpGroups)..where((t) => t.id.equals(id)))
            .write(KpGroupsCompanion(
          orderIndex: Value(i),
          updatedAt: Value(DateTime.now().toUtc()),
          version: Value(existing.version + 1),
        ));
        await _sync.upsertKpGroup(id);
      }
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('重排分组失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 删除一个组：**软删**（写墓碑 + 入队墓碑），**且不解散成员**。
  ///
  /// 组内知识点只是回到「未分组」状态——删的是容器，不是内容。
  Future<Result<void>> deleteGroup(String id) async {
    try {
      final existing = await _loadGroupRow(id);
      if (existing == null) {
        // 已删除或不存在：幂等返回成功（UI 连点两次不应报错）。
        return const Success<void>(null);
      }
      final now = DateTime.now().toUtc();
      await (_db.update(_db.kpGroups)..where((t) => t.id.equals(id)))
          .write(KpGroupsCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        version: Value(existing.version + 1),
      ));
      await _sync.tombstoneKpGroup(id);
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('删除分组失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  // ============ 内部实现 ============

  /// 读一行未删除的组；不存在 / 已软删返回 null（软删铁律）。
  Future<KpGroupRow?> _loadGroupRow(String id) =>
      (_db.select(_db.kpGroups)
            ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
          .getSingleOrNull();

  /// 增减成员：先合并出新的成员列表，再整段覆写 `members_json`。
  Future<Result<void>> _mutateMembers(
    String groupId, {
    required List<String> add,
    required List<String> remove,
  }) async {
    try {
      final row = await _loadGroupRow(groupId);
      if (row == null) {
        return Failure<void>(StateError('分组不存在或已被删除：$groupId'));
      }
      final removeSet = remove.toSet();
      final merged = <KpGroupMember>[
        // 保留原有成员及其点级基础度覆盖，过滤掉要移除的。
        for (final m in decodeGroupMembers(row.membersJson))
          if (!removeSet.contains(m.kpId)) m,
      ];
      final seen = <String>{for (final m in merged) m.kpId};
      // 新增成员追加到末尾，已在组里的不重复添加。
      for (final id in add) {
        if (seen.contains(id)) continue;
        seen.add(id);
        merged.add(KpGroupMember(kpId: id));
      }

      await (_db.update(_db.kpGroups)..where((t) => t.id.equals(groupId)))
          .write(KpGroupsCompanion(
        membersJson: Value(encodeGroupMembers(merged)),
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value(row.version + 1),
      ));
      await _sync.upsertKpGroup(groupId);
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('修改分组成员失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  KpGroup _fromRow(KpGroupRow r) => KpGroup(
        id: r.id,
        canvasId: r.canvasId,
        name: r.name,
        orderIndex: r.orderIndex,
        foundationalLevel: r.foundationalLevel,
        members: decodeGroupMembers(r.membersJson),
      );
}
