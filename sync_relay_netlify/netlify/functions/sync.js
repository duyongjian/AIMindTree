/**
 * AIMindTree 同步中继 · Netlify 生产入口。
 *
 * Netlify Functions（Node.js）约定：默认导出 ``(request, context) => Response``。
 * 本文件只做三件事：
 *   1. 用 ``@netlify/blobs`` 的 ``getStore`` 拿到站点级 KV 存储（凭证在 Functions
 *      内自动注入，无需手动配置 token）；
 *   2. 把 Blobs 适配成 relay.js 需要的 ``{get, set, listKeys}`` 接口；
 *   3. 把 Netlify 的「函数挂载前缀」还原成逻辑路径，再调 ``handleFetch``。
 *
 * 路由由仓库根 ``netlify.toml`` 的 rewrite（200）把 ``/``、``/auth/*``、``/sync/*``
 * 全部转发到本函数；转发时带 ``:splat`` 保留原始子路径，故本函数收到的 URL 可能是
 * ``/.netlify/functions/sync/auth/register``（rewrite 改写后）或 ``/auth/register``
 * （Netlify 保留原始 URL 时）。无论哪种，[toLogicalRequest] 都按 ``FN_PREFIX``
 * 还原出逻辑路径，保证 relay.js 的契约匹配（endsWith('/auth/register') 等）稳定生效。
 */

import { getStore } from '@netlify/blobs';
import { handleFetch } from '../../relay.js';

// 站点级 store，跨所有 deploy 上下文共享（与生产数据一致）。开启强一致：写入立即可读，
// 不依赖 60s 最终一致窗口（Blobs 比 EdgeOne KV 更稳的一点）。
const blobs = getStore({ name: 'aimindtree-sync', consistency: 'strong' });

// Blobs → relay 接口适配层。
const store = {
  async get(key) {
    // get 默认返 string；Blobs 对不存在键返 null，与 relay 约定一致。
    return blobs.get(key);
  },
  async set(key, value) {
    await blobs.set(key, value);
  },
  async listKeys(prefix) {
    // Blobs list 默认自动翻页（无需 cursor），返回全部 blobs。
    const { blobs: items } = await blobs.list({ prefix });
    return (items || []).map((b) => b.key);
  },
};

// Netlify Functions 的挂载前缀（见 netlify.toml 的 rewrite）。
const FN_PREFIX = '/.netlify/functions/sync';

/**
 * 把请求还原成「逻辑 URL」：剥掉函数挂载前缀，保留原始子路径
 * （``/auth/register``、``/sync/push`` …）。
 */
function toLogicalRequest(request) {
  const url = new URL(request.url);
  let pathname = url.pathname;
  if (pathname.startsWith(FN_PREFIX)) {
    pathname = pathname.slice(FN_PREFIX.length) || '/';
  }
  const logicalUrl = `${url.origin}${pathname}${url.search}`;
  return new Request(logicalUrl, request);
}

export default async (request, context) => {
  return handleFetch(
    toLogicalRequest(request),
    store,
    context && context.env ? context.env : {},
  );
};
