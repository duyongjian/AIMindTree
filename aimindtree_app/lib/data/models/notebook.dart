/// 笔记文件夹（笔记本）。
///
/// 与 [Note] 同级：一篇笔记通过 [Note.notebookId] 归属一个文件夹；文件夹通过
/// [parentId] 可构成多层层级（[Notebooks] 表已留该列，详见 tables.dart）。
///
/// 同步：文件夹是带 SyncMeta 的表，随笔记一起上行 / 下行（见 [kSyncTableAllowlist]）。
import '../../core/id.dart';

class Notebook {
  Notebook({
    String? id,
    required this.name,
    this.parentId,
    this.sortOrder = 0,
    this.pinned = false,
    DateTime? updatedAt,
    this.version = 1,
    this.deviceId = '',
    this.deletedAt,
  })  : id = id ?? newUlid(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String id;
  final String name;
  final String? parentId;
  final int sortOrder;
  final bool pinned;
  final DateTime updatedAt;
  final int version;
  final String deviceId;
  final DateTime? deletedAt;

  Notebook copyWith({
    String? name,
    String? parentId,
    int? sortOrder,
    bool? pinned,
    DateTime? updatedAt,
    int? version,
  }) =>
      Notebook(
        id: id,
        name: name ?? this.name,
        parentId: parentId ?? this.parentId,
        sortOrder: sortOrder ?? this.sortOrder,
        pinned: pinned ?? this.pinned,
        updatedAt: updatedAt ?? this.updatedAt,
        version: version ?? this.version,
        deviceId: deviceId,
        deletedAt: deletedAt,
      );
}
