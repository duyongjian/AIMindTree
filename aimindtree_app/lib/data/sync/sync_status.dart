/// SyncStatus：同步状态持久化（T03）。
///
/// 用 `shared_preferences` 存三个 key：
/// - `aimindtree.sync.last_pulled_at`：上次成功 pull 的服务端时间
/// - `aimindtree.sync.last_push_at`：上次成功 push 的本地时间
/// - `aimindtree.sync.last_status`：'idle' | 'syncing' | 'ok' | 'error:...'
library;

import 'package:shared_preferences/shared_preferences.dart';

class SyncStatusStore {
  SyncStatusStore(this._prefs);
  final SharedPreferences _prefs;

  static const _kLastPulled = 'aimindtree.sync.last_pulled_at';
  static const _kLastPush = 'aimindtree.sync.last_push_at';
  static const _kStatus = 'aimindtree.sync.last_status';

  static Future<SyncStatusStore> defaultInstance() async =>
      SyncStatusStore(await SharedPreferences.getInstance());

  DateTime? get lastPulledAt {
    final s = _prefs.getString(_kLastPulled);
    return s == null ? null : DateTime.parse(s);
  }

  Future<void> setLastPulledAt(DateTime t) async {
    await _prefs.setString(_kLastPulled, t.toUtc().toIso8601String());
  }

  DateTime? get lastPushAt {
    final s = _prefs.getString(_kLastPush);
    return s == null ? null : DateTime.parse(s);
  }

  Future<void> setLastPushAt(DateTime t) async {
    await _prefs.setString(_kLastPush, t.toUtc().toIso8601String());
  }

  String get status => _prefs.getString(_kStatus) ?? 'idle';

  Future<void> setStatus(String s) async {
    await _prefs.setString(_kStatus, s);
  }

  Future<void> clear() async {
    await _prefs.remove(_kLastPulled);
    await _prefs.remove(_kLastPush);
    await _prefs.remove(_kStatus);
  }
}