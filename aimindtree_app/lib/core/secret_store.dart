/// SecretStore（ARCHITECTURE §5.1 / §6 安全边界）。
///
/// - `api_providers.api_key_ref` 只存**引用名**，实际密钥**不入 DB**。
/// - [SecretStore] 是抽象；当前实现 [FileSecretStore] 用 JSON 文件落盘到应用
///   文档目录（path_provider），文件权限依赖 OS。
/// - 生产环境应替换为 flutter_secure_storage（Windows 走 credential manager）。
/// - 不做加密（避免引入原生加解密库）；威胁模型：本地设备级隔离，OS 用户之间不共享。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

abstract class SecretStore {
  Future<String?> get(String name);
  Future<void> set(String name, String value);
  Future<void> delete(String name);
  Future<Map<String, String>> all();
}

class FileSecretStore implements SecretStore {
  FileSecretStore(this._file);
  final File _file;
  final Map<String, String> _cache = <String, String>{};
  bool _loaded = false;

  static Future<FileSecretStore> defaultInstance() async {
    final dir = await getApplicationDocumentsDirectory();
    final target = Directory('${dir.path}${Platform.pathSeparator}.aimindtree');
    if (!await target.exists()) await target.create(recursive: true);
    return FileSecretStore(
      File('${target.path}${Platform.pathSeparator}secrets.json'),
    );
  }

  Future<void> _load() async {
    if (_loaded) return;
    if (await _file.exists()) {
      final txt = await _file.readAsString();
      if (txt.trim().isNotEmpty) {
        try {
          final m = jsonDecode(txt) as Map<String, dynamic>;
          for (final e in m.entries) {
            _cache[e.key] = e.value as String;
          }
        } on Object {
          // 损坏则忽略，下次 set 时覆盖
        }
      }
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final dir = _file.parent;
    if (!await dir.exists()) await dir.create(recursive: true);
    await _file.writeAsString(jsonEncode(_cache));
  }

  @override
  Future<String?> get(String name) async {
    await _load();
    return _cache[name];
  }

  @override
  Future<void> set(String name, String value) async {
    await _load();
    _cache[name] = value;
    await _persist();
  }

  @override
  Future<void> delete(String name) async {
    await _load();
    _cache.remove(name);
    await _persist();
  }

  @override
  Future<Map<String, String>> all() async {
    await _load();
    return Map<String, String>.from(_cache);
  }
}

/// 内存版（仅测试用 / 临时调试）。
class InMemorySecretStore implements SecretStore {
  final Map<String, String> _data = <String, String>{};
  @override
  Future<String?> get(String name) async => _data[name];
  @override
  Future<void> set(String name, String value) async => _data[name] = value;
  @override
  Future<void> delete(String name) async => _data.remove(name);
  @override
  Future<Map<String, String>> all() async => Map<String, String>.from(_data);
}
