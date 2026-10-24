/// 同步中继地址规范化（五后端共用）。
///
/// 背景（2026-10-24 用户实测）：Vercel 平台把 `api/` 目录下的函数挂在
/// `/api/*` 路径下，且 sync_relay_vercel 部署未加 rewrites 时，不带 `/api`
/// 的路径在平台层直接 404。用户在设置里手填
/// `https://aimindtree-syncrelayvercel.vercel.app` 极易漏掉 `/api`——
/// 实测现象是「注册失败：auth auth/register 返回 404」，而旧「测试连接」
/// 的宽判定又会把平台 404 显示成「已连通」，问题被掩盖到注册才爆。
///
/// 本函数在 [HttpSyncApi] / [SyncAccountApi] 构造时统一应用：检测到
/// `*.vercel.app` 域名且路径为空/根时补 `/api`；其余地址原样返回
/// （不猜用户显式的自定义挂载，如 CloudBase 的 `/sync-relay` 触发路径）。
library;

/// 规范化同步中继基地址：当前仅处理「Vercel 缺 /api 前缀」一种情况。
String normalizeSyncBaseUrl(String baseUrl) {
  final trimmed = baseUrl.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return baseUrl;
  if (!uri.host.endsWith('.vercel.app')) return baseUrl;
  // 空路径或根路径才补；已有子路径（含 /api 或用户显式的其它挂载）不猜。
  if (uri.path.isNotEmpty && uri.path != '/') return baseUrl;
  return uri.replace(path: '/api').toString();
}
