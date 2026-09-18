/// ID 生成与设备标识（ARCHITECTURE §11：主键一律 ULID，不用自增、不用 uuid）。
library;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:ulid/ulid.dart';

/// 生成一个新的 ULID（时间有序、无中心化依赖）。
String newUlid() => Ulid().toString();

/// 设备标识：首次启动生成并持久化。
///
/// 用途：同步自回声过滤（自己推的不回灌）+ 未来 CRDT 扩展位（§5.5）。
class DeviceId {
  DeviceId._();
  static const _key = 'aimindtree.device_id';

  static String? _cached;

  /// 获取（并缓存）本机 device_id。
  static Future<String> get() async {
    final cached = _cached;
    if (cached != null && cached.isNotEmpty) return cached;
    final prefs = await SharedPreferences.getInstance();
    var v = prefs.getString(_key);
    if (v == null || v.isEmpty) {
      v = newUlid();
      await prefs.setString(_key, v);
    }
    _cached = v;
    return v;
  }

  /// 同步读取缓存值（启动后已 [get] 过才有值），否则返回空串。
  static String get orEmpty => _cached ?? '';

  /// 测试用：注入固定值。
  static void overrideForTest(String v) => _cached = v;
}
