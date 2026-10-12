/// 知识点分组仓储（「分组」UI）。
///
/// 「组」= `kp_groups` 表：组名 + 组序 + 组级基础度 + 成员 JSON。
/// 组本身不是知识实体，成员只是已有知识点的 id（遵守锚点硬规则）。
library;

import 'package:drift/drift.dart';

import '../../core/id.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../db/drift_database.dart';
import '../models/kp_group.dart';

class GroupRepository {
  GroupRepository(this._db, {this.deviceId = ''});

  final AppDatabase _db;
  final String deviceId;

  static final AppLog _log = AppLog('group_repo');

  /// 某棵树的全部组，按组序升序（越基础越靠前）。
  Future<List<KpGroup>> listGroups(String canvasId) async {
    final rows = await (_db.select(_db.kpGroups)
          ..where((t) => t.canvasId.equals(canvasId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.orderIndex)]))
        .get();
    return rows.map(_fromRow).toList();
  }

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

  /// 保存（覆盖）一个组的名称 / 组序 / 基础度 / 成员。
  Future<Result<void>> saveGroup(KpGroup group) async {
    try {
      final existing = await (_db.select(_db.kpGroups)
            ..where((t) => t.id.equals(group.id)))
          .getSingleOrNull();
      await (_db.update(_db.kpGroups)..where((t) => t.id.equals(group.id)))
          .write(KpGroupsCompanion(
        name: Value(group.name),
        orderIndex: Value(group.orderIndex),
        foundationalLevel: Value(group.foundationalLevel),
        membersJson: Value(encodeGroupMembers(group.members)),
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value((existing?.version ?? 0) + 1),
      ));
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('保存分组失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  Future<Result<void>> deleteGroup(String id) async {
    try {
      await (_db.delete(_db.kpGroups)..where((t) => t.id.equals(id))).go();
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('删除分组失败', error: e, stackTrace: s);
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
