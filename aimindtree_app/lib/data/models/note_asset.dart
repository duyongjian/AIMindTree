/// 笔记附件（图片）领域模型。
///
/// 为什么**单独一张表**而不是塞进 `notes.content_md`：
/// 图片正文是 base64，直接内联会把笔记 payload 撑到几 MB 级，上行同步
///（outbox 存的是实体最终态 JSON）会被这一张图拖垮。分开成 [NoteAsset] 后：
/// - 笔记正文里只放极短的引用 `aimindtree-asset://<id>`（见 [assetUri]）；
/// - 附件单独走自己的同步通道，可断点续传 / 单独重试；
/// - 同一笔记内可用 [sha1] 去重（重复粘贴同一张图不会多存一份）。
///
/// `data_base64` 是**唯一权威存储**：磁盘里的文件只是可选缓存，可随时重建。
library;

import '../../core/id.dart';

/// 附件 URI 的自定义 scheme（Markdown 正文里用它引用附件）。
const String kAssetUriScheme = 'aimindtree-asset';

/// 把附件 id 变成 Markdown 正文里可嵌入的 URI：`aimindtree-asset://<id>`。
///
/// 渲染层识别这个 scheme 后走本地字节解码；非本 App 环境里它就是个普通
/// 链接，不会炸。
String assetUri(String id) => '$kAssetUriScheme://$id';

/// 匹配正文里的附件引用，`group(1)` 是附件 id。
final RegExp kAssetUriPattern = RegExp('$kAssetUriScheme://([A-Za-z0-9_-]+)');

/// 解析 Markdown 正文里**所有**引用的附件 id（去重）。
///
/// 用途：
/// - 渲染前预热（提前把要用的字节取出来）；
/// - 清理孤儿附件：正文里没出现的 id 说明图片已被删，附件可以跟着回收。
///
/// 纯函数，不碰 IO，方便单测。
Set<String> extractAssetIds(String md) {
  final out = <String>{};
  for (final m in kAssetUriPattern.allMatches(md)) {
    final id = m.group(1);
    if (id != null && id.isNotEmpty) out.add(id);
  }
  return out;
}

/// 一条笔记附件（图片）。
class NoteAsset {
  NoteAsset({
    String? id,
    required this.noteId,
    this.name = '',
    this.mime = 'image/png',
    this.sha1 = '',
    this.bytes = 0,
    this.dataBase64 = '',
    DateTime? updatedAt,
    this.version = 1,
    this.deviceId = '',
  })  : id = id ?? newUlid(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String id;

  /// 所属笔记（notes.id）。
  final String noteId;

  /// 原始文件名（仅展示用，可为 ''）。
  final String name;

  /// MIME，默认 `image/png`。
  final String mime;

  /// 原图字节的 SHA-1，**同一笔记内**去重用。
  final String sha1;

  /// 原图字节数（插入前做上限校验）。
  final int bytes;

  /// base64 正文（唯一权威存储）。
  final String dataBase64;

  final DateTime updatedAt;
  final int version;
  final String deviceId;

  NoteAsset copyWith({
    String? name,
    String? dataBase64,
    DateTime? updatedAt,
    int? version,
  }) =>
      NoteAsset(
        id: id,
        noteId: noteId,
        name: name ?? this.name,
        mime: mime,
        sha1: sha1,
        bytes: bytes,
        dataBase64: dataBase64 ?? this.dataBase64,
        updatedAt: updatedAt ?? this.updatedAt,
        version: version ?? this.version,
        deviceId: deviceId,
      );
}
