/// 图片选择（file_picker 的薄封装，T05 图片插入全链路）。
///
/// 约定：
/// - **返回 null = 用户取消**（编辑器静默返回，不弹 toast）；
/// - **抛出 = 选文件过程本身失败**（平台异常 / 读不出字节），编辑器 catch
///   后 toast——取消与失败必须能区分，否则用户点了取消也看到报错。
/// - 只选图片（`FileType.image`），且 `withData: true` 直接把字节读进内存
///   （本项目图片的唯一权威存储是 SQLite 里的 base64，不需要源文件路径）。
/// - 大小上限不在这里卡（调用方仓储层统一拒收并给出带数字的提示），
///   这里只负责「选到一张图并拿到字节」。
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// 选中的一张图片。
class PickedImage {
  const PickedImage({
    required this.name,
    required this.bytes,
    required this.mime,
  });

  /// 原始文件名（仅展示用，可为空）。
  final String name;

  /// 文件字节（调用方负责入库 / 上限校验）。
  final Uint8List bytes;

  /// 由扩展名推断的 MIME；推断不出时给 `application/octet-stream`
  /// （渲染层 `Image.memory` 自己会嗅探真实格式，不依赖这个值）。
  final String mime;
}

/// 扩展名 → MIME（覆盖常见图片格式；查不到回落 octet-stream）。
String _mimeFromExtension(String ext) {
  switch (ext.toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'bmp':
      return 'image/bmp';
    case 'heic':
      return 'image/heic';
    default:
      return 'application/octet-stream';
  }
}

/// 打开系统文件选择器选一张图片。
///
/// 返回 null = 取消；抛异常 = 失败（调用方 catch 后提示）。
Future<PickedImage?> pickImage() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.image,
    allowMultiple: false,
    withData: true,
  );
  // 用户取消：file_picker 的约定是返回 null。
  if (result == null) return null;
  final file = result.files.first;
  final bytes = file.bytes;
  if (bytes == null || bytes.isEmpty) {
    throw StateError('选中的图片读不出内容（${file.name}）');
  }
  return PickedImage(
    name: file.name,
    bytes: bytes,
    mime: _mimeFromExtension(file.extension ?? ''),
  );
}
