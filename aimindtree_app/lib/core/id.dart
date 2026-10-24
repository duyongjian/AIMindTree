/// ID 生成与设备标识（ARCHITECTURE §11：主键一律 ULID，不用自增、不用 uuid）。
library;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:ulid/ulid.dart';

/// 生成一个新的 ULID（时间有序、无中心化依赖）。
String newUlid() => Ulid().toString();

/// 由源 id **确定性**派生一个新 id：源 id 的 16 个字节逐字节 +1（mod 256）。
///
/// 用途：老师模式把 `explain` 老会话的消息迁入 `chat` 主会话时，新行的主键
/// 必须由源 id 推导而**不能随机生成**——否则跨端各自合并会产生两条不同的行。
///
/// 三条性质（缺一不可）：
/// - **双射（全局单射）**：逐字节 +1 是 `Z_256^16` 上的平移 → 不同的源 id
///   必然派生出不同的新 id。
///   ⚠️ **必须取模**（`& 0xFF`），否则 `0xFF + 1 = 0x100` 溢出、破坏单射性。
/// - **保序**：ULID 前 48 位是毫秒时间戳，整体 +1 后毫秒 +1 → 消息之间的
///   相对顺序不变（迁移后仍在原位，不会被排到流末尾）。
/// - **幂等**：同一源 id 恒得同一派生 id → 重复合并/跨端重复合并天然收敛
///   （主键冲突即跳过）。
///
/// ⚠️ 这与「保持原毫秒、只把随机尾巴 +1」**不同**——后者不是全局双射
/// （随机尾巴恰好相差 1 的两个源 id 会撞）。
String newDerivedUlid(String srcId) {
  final Ulid src;
  try {
    src = Ulid.parse(srcId);
  } on Object catch (e) {
    throw ArgumentError.value(srcId, 'srcId', '不是合法的 ULID：$e');
  }
  final bytes = src.toBytes();
  final out = List<int>.filled(16, 0);
  for (var i = 0; i < 16; i++) {
    out[i] = (bytes[i] + 1) & 0xFF;
  }
  return Ulid.fromBytes(out).toString();
}

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
