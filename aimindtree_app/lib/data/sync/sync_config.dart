/// SyncConfig：多后端同步配置（T03 演进：Cloudflare / CloudBase / Vercel）。
///
/// 三个同步中继的 HTTP 契约逐字一致（同样的 5 端点、同样字段、同样 Bearer
/// 鉴权），App 侧换后端只换地址；原 llm_server 同步目标已随「中继化」移除。
///
/// 存储口径：
/// - 每个后端三件套独立存放：地址 / 用户名（明文 prefs）+ 每用户令牌
///   （SecretStore，key 均带后端后缀，见 [SyncBackend.keySuffix]）；
/// - **cloudflare 刻意沿用旧 key**（`aimindtree.sync.cf_url` /
///   `cf_username` / `cf_user_token`），老用户升级后零迁移继续生效；
/// - [selectedBackend] 记住上次选中的后端（pref 存枚举 name）；
/// - HTTP 代理是全局设置（不随后端切换），key 沿用历史的
///   `aimindtree.sync.cf_proxy`（改名会丢老用户已存代理）。
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/secret_store.dart';

/// 同步后端枚举（设置页三选一）。
enum SyncBackend {
  cloudflare,
  cloudbase,
  vercel;

  /// UI 展示名（中文）。
  String get label => switch (this) {
        SyncBackend.cloudflare => 'Cloudflare',
        SyncBackend.cloudbase => '腾讯云 CloudBase',
        SyncBackend.vercel => 'Vercel',
      };

  /// pref / SecretStore key 的稳定后缀（不随枚举顺序变化）。
  ///
  /// cloudflare 用 `cf` 是为了兼容老用户已存的数据（见类文档）。
  String get keySuffix => switch (this) {
        SyncBackend.cloudflare => 'cf',
        SyncBackend.cloudbase => 'cb',
        SyncBackend.vercel => 'vc',
      };

  /// 内置默认地址（用户未覆盖时回落）。
  String get defaultBaseUrl => switch (this) {
        SyncBackend.cloudflare => SyncConfig.kSyncCfDefaultBaseUrl,
        SyncBackend.cloudbase => SyncConfig.kSyncCbDefaultBaseUrl,
        SyncBackend.vercel => SyncConfig.kSyncVercelDefaultBaseUrl,
      };
}

class SyncConfig {
  SyncConfig({required this.prefs, required this.secretStore});
  final SharedPreferences prefs;
  final SecretStore secretStore;

  /// 内置默认地址：Cloudflare Worker（sync_relay_cf，已部署）。
  static const String kSyncCfDefaultBaseUrl =
      'https://aimindtree-sync-relay.tuanx.workers.dev';

  /// 内置默认地址：腾讯云 CloudBase 同步中继（sync_relay_cn，已部署）。
  ///
  /// ⚠️ 必须带 `/sync-relay` 路径前缀：CloudBase 的 HTTP 访问服务是按「触发路径」
  /// 路由的，我们在网关建的路由是 `path=/sync-relay`（`upstreamResourceType=SCF`）。
  /// 少了这段前缀请求会落到静态托管的 404 上，看起来像「服务没起」。
  /// 也不要加结尾斜杠——App 是 `<base>/auth/register` 直接拼接的。
  static const String kSyncCbDefaultBaseUrl =
      'https://mindtree-d7glv6crkd8e9fba9-1409358097.ap-shanghai.app.tcloudbase.com/sync-relay';

  /// 内置默认地址：Vercel 同步中继（sync_relay_vercel）。
  ///
  /// ⚠️ 域名待 Vercel 部署完成后由主理人回填；空串表示「尚未配置」——
  /// [urlOf] 对 vercel 返回空串，UI 据此禁用上传/拉取并提示，不会静默失败。
  /// 用户手填的覆盖值不受影响（优先于内置默认）。
  static const String kSyncVercelDefaultBaseUrl = '';

  /// 当前选中后端（pref 存枚举 name；读不到 / 脏值 → cloudflare）。
  static const _kBackend = 'aimindtree.sync.backend';

  /// 用户手动指定的 HTTP 代理（`host:port`）。
  ///
  /// 与地址同理的「逃生舱」：本机线路把 Cloudflare IP 段整个封掉时，用户
  /// 可以在设置里配代理出国，无需重新编译 App。这是**全局**设置，不随后端
  /// 切换；key 名沿用历史 `cf_proxy`（改名会丢老用户已存代理）。
  static const _kProxy = 'aimindtree.sync.cf_proxy';

  /// 历史遗留 key（llm_server 同步目标 / CF 直存共享 token，均已废弃）。
  /// 仅在 [clear] 时顺带清理，避免「清空配置」后旧 key 残留造成困惑。
  static const _kLegacyBaseUrl = 'aimindtree.sync.base_url';
  static const _kLegacyTokenRef = 'aimindtree.sync.token_ref';
  static const _kLegacyEnabled = 'aimindtree.sync.enabled';
  static const _kLegacyCfToken = 'aimindtree.sync.cf_token';
  static const _kLegacyCfTokenRef = 'aimindtree.sync.cf_token_ref';

  // ---- 每后端 key 构造（形如 aimindtree.sync.<后缀>_url）----

  static String _kUrl(SyncBackend b) => 'aimindtree.sync.${b.keySuffix}_url';
  static String _kUsername(SyncBackend b) =>
      'aimindtree.sync.${b.keySuffix}_username';
  static String _kUserToken(SyncBackend b) =>
      'aimindtree.sync.${b.keySuffix}_user_token';

  // ---- 选中后端 ----

  SyncBackend get selectedBackend {
    final name = prefs.getString(_kBackend);
    for (final b in SyncBackend.values) {
      if (b.name == name) return b;
    }
    return SyncBackend.cloudflare;
  }

  Future<void> setSelectedBackend(SyncBackend b) async =>
      prefs.setString(_kBackend, b.name);

  // ---- 每后端：地址 ----

  /// 用户手填的地址覆盖（未填 → null）。
  ///
  /// 设置页回显用这个（而不是 [urlOf]），否则会把内置默认显示成「用户填过
  /// 的值」，让用户以为自己改过。
  String? urlOverrideOf(SyncBackend b) => prefs.getString(_kUrl(b));

  /// 后端实际地址：用户覆盖优先，未配置时回落到内置默认地址。
  /// 普通用户开箱即用，无需在设置里填 URL；Vercel 域名未回填时返回空串。
  String urlOf(SyncBackend b) {
    final v = urlOverrideOf(b)?.trim();
    return (v != null && v.isNotEmpty) ? v : b.defaultBaseUrl;
  }

  /// 设置 / 清除地址覆盖；空串（或纯空白）视为「清除覆盖」，回落到内置默认。
  Future<void> setUrl(SyncBackend b, String v) async {
    final trimmed = v.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(_kUrl(b));
    } else {
      await prefs.setString(_kUrl(b), trimmed);
    }
  }

  // ---- 每后端：账号（用户名 + 每用户令牌）----
  // 三个后端的账号体系互相独立（同一用户在 CF 与 CloudBase 上是不同账号），
  // 用户名 / 令牌按后端隔离存储，A 后端登录不影响 B。
  // 用户名明文落 prefs；每用户令牌经 SecretStore 保存（本机，不随 DB 上传）。

  String? usernameOf(SyncBackend b) => prefs.getString(_kUsername(b));

  /// 设置 / 清除用户名；null 或空白视为清除（pref 不留空串，避免歧义）。
  Future<void> setUsername(SyncBackend b, String? v) async {
    final trimmed = v?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await prefs.remove(_kUsername(b));
    } else {
      await prefs.setString(_kUsername(b), trimmed);
    }
  }

  /// 取出后端每用户令牌（登录/注册后由 [setUserToken] 写入 SecretStore）。
  Future<String?> resolveUserToken(SyncBackend b) async =>
      secretStore.get(_kUserToken(b));

  /// 登录/注册成功后保存每用户令牌；[token] 为 null/空串表示登出（清令牌）。
  Future<void> setUserToken(SyncBackend b, String? token) async {
    if (token == null || token.isEmpty) {
      await secretStore.delete(_kUserToken(b));
    } else {
      await secretStore.set(_kUserToken(b), token);
    }
  }

  /// 后端是否处于已登录状态（用户名非空且本地存有令牌）。
  Future<bool> isLoggedIn(SyncBackend b) async =>
      (usernameOf(b)?.isNotEmpty ?? false) && (await resolveUserToken(b)) != null;

  // ---- 全局：HTTP 代理（不随后端切换）----

  /// 用户手动指定的 HTTP 代理（`host:port`）；未设置（或只填了空白）→ null。
  String? get cfProxy {
    final v = prefs.getString(_kProxy)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 设置/清空手动代理；null 或空白表示「不走代理」（直接移除 pref，
  /// 避免留下空串让「是否设置过」产生歧义）。
  Future<void> setCfProxy(String? v) async {
    final trimmed = v?.trim() ?? '';
    if (trimmed.isEmpty) {
      await prefs.remove(_kProxy);
    } else {
      await prefs.setString(_kProxy, trimmed);
    }
  }

  /// 清空全部同步配置：所有后端的地址 / 用户名 / 每用户令牌、选中后端
  /// （回落 cloudflare）、手动代理，并顺带清理历史遗留 key。
  Future<void> clear() async {
    for (final b in SyncBackend.values) {
      await prefs.remove(_kUrl(b));
      await prefs.remove(_kUsername(b));
      await secretStore.delete(_kUserToken(b));
    }
    await prefs.remove(_kBackend);
    await prefs.remove(_kProxy);
    // 历史遗留 key（已废弃的 llm 目标 / CF 直存共享 token）。
    await prefs.remove(_kLegacyBaseUrl);
    await prefs.remove(_kLegacyTokenRef);
    await prefs.remove(_kLegacyEnabled);
    await prefs.remove(_kLegacyCfToken);
    await prefs.remove(_kLegacyCfTokenRef);
  }
}
