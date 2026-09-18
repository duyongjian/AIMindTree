/// SyncConfig：同步后端配置（T03）。
///
/// - `aimindtree.sync.base_url`：服务端 URL（明文存 prefs）；
/// - `aimindtree.sync.token_ref`：SecretStore 里的引用名；
/// - `aimindtree.sync.enabled`：是否开启自动同步。
///
/// token 本身不入 prefs，必须经 `SecretStore.resolveApiKey(token_ref)` 取。
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/secret_store.dart';

class SyncConfig {
  SyncConfig({required this.prefs, required this.secretStore});
  final SharedPreferences prefs;
  final SecretStore secretStore;

  static const _kBaseUrl = 'aimindtree.sync.base_url';
  static const _kTokenRef = 'aimindtree.sync.token_ref';
  static const _kEnabled = 'aimindtree.sync.enabled';

  String? get baseUrl => prefs.getString(_kBaseUrl);
  Future<void> setBaseUrl(String v) async => prefs.setString(_kBaseUrl, v);

  String? get tokenRef => prefs.getString(_kTokenRef);
  Future<void> setTokenRef(String? v) async {
    if (v == null) {
      await prefs.remove(_kTokenRef);
    } else {
      await prefs.setString(_kTokenRef, v);
    }
  }

  bool get enabled => prefs.getBool(_kEnabled) ?? false;
  Future<void> setEnabled(bool v) async => prefs.setBool(_kEnabled, v);

  /// 取出实际 token（仅供 HttpSyncApi 构造用）。
  Future<String?> resolveToken() async {
    final ref = tokenRef;
    if (ref == null) return null;
    return secretStore.get(ref);
  }

  bool get isConfigured => (baseUrl?.isNotEmpty ?? false) && (tokenRef?.isNotEmpty ?? false);

  Future<void> clear() async {
    await prefs.remove(_kBaseUrl);
    await prefs.remove(_kTokenRef);
    await prefs.remove(_kEnabled);
  }
}