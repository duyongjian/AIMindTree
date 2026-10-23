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
  /// 开发期直存 token（不经 SecretStore；生产仍走 token_ref）。
  static const _kCfToken = 'aimindtree.sync.cf_token';
  /// 用户手动指定的 HTTP 代理（`host:port`）。
  ///
  /// 与地址同理的「逃生舱」：本机线路把 Cloudflare IP 段整个封掉时，用户
  /// 可以在设置里配代理出国，无需重新编译 App。
  static const _kCfProxy = 'aimindtree.sync.cf_proxy';

  /// 未单独配置时的 llm_server 默认地址（与 kLlmServerDefaultBaseUrl 同源）。
  static const String kSyncLlmServerDefaultBaseUrl = 'http://127.0.0.1:8787';

  /// 内置 Cloudflare Worker 默认地址（方案 B 已部署）。
  /// App 自带该地址，普通用户**无需填写**；若更换 Worker 域名，改这里即可
  /// （用户仍可在设置里自定义覆盖，存到 [_kCfUrl]）。
  static const String kSyncCfDefaultBaseUrl =
      'https://aimindtree-sync-relay.tuanx.workers.dev';

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

  /// CF 目标实际地址：用户自定义优先，未配置时回落到内置默认地址。
  /// 普通用户开箱即用，无需在设置里填 URL。
  String get cfUrlResolved {
    final v = cfUrl?.trim();
    return (v != null && v.isNotEmpty) ? v : kSyncCfDefaultBaseUrl;
  }

  /// 用户手动指定的 HTTP 代理（`host:port`）；未设置（或只填了空白）→ null。
  String? get cfProxy {
    final v = prefs.getString(_kCfProxy)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 设置/清空手动代理；null 或空白表示「不走代理」（直接移除 pref，
  /// 避免留下空串让「是否设置过」产生歧义）。
  Future<void> setCfProxy(String? v) async {
    final trimmed = v?.trim() ?? '';
    if (trimmed.isEmpty) {
      await prefs.remove(_kCfProxy);
    } else {
      await prefs.setString(_kCfProxy, trimmed);
    }
  }

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

  // ---- Cloudflare 账号（方案 B，自助注册/登录，多租户隔离）----
  // 普通用户用用户名+密码登录即可，无需填写任何共享 token。
  // 用户名明文落 prefs；每用户令牌经 SecretStore 保存（本机，不随 DB 上传）。
  static const _kCfUsername = 'aimindtree.sync.cf_username';
  static const _kCfUserToken = 'aimindtree.sync.cf_user_token';

  String? get cfUsername => prefs.getString(_kCfUsername);
  Future<void> setCfUsername(String? v) async =>
      v == null ? prefs.remove(_kCfUsername) : prefs.setString(_kCfUsername, v);

  /// 取出 CF 每用户令牌（登录/注册后由 [setCfUserToken] 写入 SecretStore）。
  Future<String?> resolveCfUserToken() async => secretStore.get(_kCfUserToken);

  /// 登录/注册成功后保存每用户令牌；[token] 为 null 表示登出（清本地令牌）。
  Future<void> setCfUserToken(String? token) async {
    if (token == null) {
      await secretStore.delete(_kCfUserToken);
    } else {
      await secretStore.set(_kCfUserToken, token);
    }
  }

  /// CF 是否处于已登录状态（用户名非空且本地存有令牌）。
  Future<bool> isCfLoggedIn() async =>
      (cfUsername?.isNotEmpty ?? false) && (await resolveCfUserToken()) != null;

  /// llm 目标 URL：用户未单独配时默认本机 llm_server（开发期免 token）。
  String get llmUrl =>
      (baseUrl?.isNotEmpty ?? false) ? baseUrl! : kSyncLlmServerDefaultBaseUrl;

  /// 原「单一目标」是否就绪（baseUrl + tokenRef 都非空）。
  bool get isConfigured => (baseUrl?.isNotEmpty ?? false) && (tokenRef?.isNotEmpty ?? false);

  /// llm 目标是否可用（默认指向 localhost，永远可用）。
  bool get isLlmConfigured => llmUrl.isNotEmpty;

  /// CF 目标是否可用（地址恒有内置默认，故只看 token 是否就绪）。
  bool get isCfConfigured =>
      cfUrlResolved.isNotEmpty &&
      ((cfTokenRef?.isNotEmpty ?? false) || (cfToken?.isNotEmpty ?? false));

  /// 取出 CF token：优先 token_ref（SecretStore），回退开发期直存 token。
  /// 两端都未设置时返回空串——对应 Worker 的「开放部署」（SYNC_TOKEN 留空放行），
  /// 因此普通用户无需填写 token 也能与官方/个人开放中继互通。
  Future<String?> resolveCfToken() async {
    final ref = cfTokenRef;
    if (ref != null) {
      final fromStore = await secretStore.get(ref);
      if (fromStore != null && fromStore.isNotEmpty) return fromStore;
    }
    final direct = cfToken;
    if (direct != null && direct.isNotEmpty) return direct;
    return '';
  }

  Future<void> clear() async {
    await prefs.remove(_kBaseUrl);
    await prefs.remove(_kTokenRef);
    await prefs.remove(_kEnabled);
    await prefs.remove(_kCfUrl);
    await prefs.remove(_kCfTokenRef);
    await prefs.remove(_kCfToken);
    await prefs.remove(_kCfProxy);
  }
}