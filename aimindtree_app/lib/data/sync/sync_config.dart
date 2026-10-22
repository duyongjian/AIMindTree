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

  // ---- Cloudflare 目标（方案 B：Worker + D1）----
  static const _kCfUrl = 'aimindtree.sync.cf_url';
  static const _kCfTokenRef = 'aimindtree.sync.cf_token_ref';
  // 开发期直存 token（不经 SecretStore；生产仍走 token_ref）。
  static const _kCfToken = 'aimindtree.sync.cf_token';

  /// 未单独配置时的 llm_server 默认地址（与 kLlmServerDefaultBaseUrl 同源）。
  static const String kSyncLlmServerDefaultBaseUrl = 'http://127.0.0.1:8787';

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

  // ---- Cloudflare 目标配置 ----

  String? get cfUrl => prefs.getString(_kCfUrl);
  Future<void> setCfUrl(String v) async => prefs.setString(_kCfUrl, v);

  String? get cfTokenRef => prefs.getString(_kCfTokenRef);
  Future<void> setCfTokenRef(String? v) async {
    if (v == null) {
      await prefs.remove(_kCfTokenRef);
    } else {
      await prefs.setString(_kCfTokenRef, v);
    }
  }

  /// 开发期直存 token（明文落 prefs，仅本机；生产请用 [cfTokenRef] + SecretStore）。
  String? get cfToken => prefs.getString(_kCfToken);
  Future<void> setCfToken(String? v) async {
    if (v == null) {
      await prefs.remove(_kCfToken);
    } else {
      await prefs.setString(_kCfToken, v);
    }
  }

  /// llm 目标 URL：用户未单独配时默认本机 llm_server（开发期免 token）。
  String get llmUrl =>
      (baseUrl?.isNotEmpty ?? false) ? baseUrl! : kSyncLlmServerDefaultBaseUrl;

  /// 原「单一目标」是否就绪（baseUrl + tokenRef 都非空）。
  bool get isConfigured => (baseUrl?.isNotEmpty ?? false) && (tokenRef?.isNotEmpty ?? false);

  /// llm 目标是否可用（默认指向 localhost，永远可用）。
  bool get isLlmConfigured => llmUrl.isNotEmpty;

  /// CF 目标是否可用（URL + token 至少其一就绪）。
  bool get isCfConfigured =>
      (cfUrl?.isNotEmpty ?? false) &&
      ((cfTokenRef?.isNotEmpty ?? false) || (cfToken?.isNotEmpty ?? false));

  /// 取出 CF token：优先 token_ref（SecretStore），回退开发期直存 token。
  Future<String?> resolveCfToken() async {
    final ref = cfTokenRef;
    if (ref != null) {
      final fromStore = await secretStore.get(ref);
      if (fromStore != null && fromStore.isNotEmpty) return fromStore;
    }
    final direct = cfToken;
    return (direct?.isNotEmpty ?? false) ? direct : null;
  }

  Future<void> clear() async {
    await prefs.remove(_kBaseUrl);
    await prefs.remove(_kTokenRef);
    await prefs.remove(_kEnabled);
    await prefs.remove(_kCfUrl);
    await prefs.remove(_kCfTokenRef);
    await prefs.remove(_kCfToken);
  }
}