/// 同步 JSON 编码工具（DateTime 安全）。
///
/// 同步 payload 里含 DateTime 列（`updated_at` / `deleted_at`）。Dart 的
/// `jsonEncode` **默认不支持 DateTime**（会抛 `JsonUnsupportedObjectError`），
/// 所以这里统一提供 `toEncodable`：DateTime → ISO 8601 字符串。
///
/// 代价是：JSON 往返后 DateTime 列变成字符串，读回来时必须**宽容解析**
/// （见 `sync_engine.dart` 的 `_dt`）。写入侧（enqueue / 传输）与读取侧
/// （fromMap）必须成对使用，否则「一旦 payload 变成真实数据就会崩」。
library;

import 'dart:convert';

/// JSON 编码兜底转换：
/// - `DateTime` → ISO 8601 字符串（可被 `DateTime.tryParse` 还原）；
/// - 基础类型原样返回；
/// - 其他未知类型 → `toString()`（宁可降级成字符串，也不让整批同步失败）。
Object? syncJsonEncodable(Object? value) {
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  return value.toString();
}

/// 同步专用 JSON 编码（DateTime 安全）。
String encodeSyncJson(Object? value) =>
    jsonEncode(value, toEncodable: syncJsonEncodable);

/// 把任意值转成 **JSON 安全** 的形式（递归）。
///
/// DateTime → ISO 8601 字符串；Map / List 递归处理；其余走
/// [syncJsonEncodable]。用于「内存对象 → 传输层 Map」这条路径
/// （`SyncEnvelope.toJson` 的 payload），避免 `jsonEncode` 遇到 DateTime
/// 直接抛 `JsonUnsupportedObjectError`。
Object? toJsonSafe(Object? value) {
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries) '${entry.key}': toJsonSafe(entry.value),
    };
  }
  if (value is Iterable) {
    return value.map(toJsonSafe).toList();
  }
  return syncJsonEncodable(value);
}
