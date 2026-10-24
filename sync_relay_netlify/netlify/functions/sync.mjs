/**
 * AIMindTree 同步中继 · Netlify 生产入口。
 *
 * Netlify Functions（v2，默认导出签名）约定：``(request, context) => Response``。
 * 本文件只做三件事：
 *   1. 用 ``@netlify/blobs`` 的 ``getStore`` 拿到站点级 KV 存储；
 *   2. 把 Blobs 适配成 relay.js 需要的 ``{get, set, listKeys}`` 接口；
 *   3. 把 Netlify 的「函数挂载前缀」还原成逻辑路径，再调 ``handleFetch``。
 *
 * 路由由仓库根 ``netlify.toml`` 的 rewrite（200）把 ``/``、``/auth/*``、``/sync/*``
 * 全部转发到本函数；转发时带 ``:splat`` 保留原始子路径，故本函数收到的 URL 可能是
 * ``/.netlify/functions/sync/auth/register``（rewrite 改写后）或 ``/auth/register``
 * （Netlify 保留原始 URL 时）。无论哪种，[toLogicalRequest] 都按 ``FN_PREFIX``
 * 还原出逻辑路径，保证 relay.js 的契约匹配（endsWith('/auth/register') 等）稳定生效。
 *
 * 存储初始化策略（2026-10-24 实测定稿，改动前必读）：
 *   1. **不能依赖平台自动注入 Blobs 上下文**：实测 v2 默认导出 + 惰性建 store +
 *      ``.mjs`` 扩展名均无法让平台注入 ``netlifyBlobsContext`` /
 *      ``NETLIFY_BLOBS_CONTEXT``（每次请求 ``MissingBlobsEnvironmentError``）；
 *      Netlify 支持论坛有同期活跃缺陷帖（注入失效影响多站点，含官方 Next.js
 *      运行时）。故走官方文档明确的 **API 访问模式**：显式传 siteID + token。
 *   2. **siteID 运行时取**：``context.site.id``（v2 Context 字段），回退请求头
 *      ``x-nf-site-id``，不硬编码。
 *   3. **token 走站点环境变量** ``NETLIFY_BLOBS_TOKEN``（``netlify env:set`` 注入，
 *      **绝不写进仓库**）。API 模式不经 edgeURL，没有 ``uncachedEdgeURL`` 要求，
 *      读写直达 API 源站 = 强一致（官方推荐的强一致用法）。
 *   4. **惰性建 store**：函数模块可能在无请求上下文时被加载，模块顶层建 store 会把
 *      启动错误带进冷初始化（线上表现为 502）。推迟到首个请求再建。
 */
import { getStore } from '@netlify/blobs';
import { handleFetch } from '../../relay.js';

// 站点级 store 名，跨所有 deploy 上下文共享（与生产数据一致）。
const STORE_NAME = 'aimindtree-sync';

let cachedStore = null;

function resolveStore(siteId) {
  if (!cachedStore) {
    const token = process.env.NETLIFY_BLOBS_TOKEN;
    if (!token) {
      throw new Error(
        'NETLIFY_BLOBS_TOKEN 未配置：请在 Netlify 控制台或 CLI（netlify env:set ' +
          'NETLIFY_BLOBS_TOKEN <token> --context production）设置后重新部署',
      );
    }
    cachedStore = getStore({ name: STORE_NAME, siteID: siteId, token });
  }
  return cachedStore;
}

// Blobs → relay 接口适配层（siteId 来自运行时 context，见 [resolveStore]）。
function makeStore(siteId) {
  return {
    get(key) {
      // get 默认返 string；Blobs 对不存在键返 null，与 relay 约定一致。
      return resolveStore(siteId).get(key);
    },
    set(key, value) {
      return resolveStore(siteId).set(key, value);
    },
    listKeys(prefix) {
      // Blobs list 默认自动翻页（无需 cursor），返回全部 blobs。
      return resolveStore(siteId)
        .list({ prefix })
        .then(({ blobs }) => (blobs || []).map((b) => b.key));
    },
  };
}

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
  const logical = toLogicalRequest(request);
  const siteId =
    (context && context.site && context.site.id) ||
    request.headers.get('x-nf-site-id');
  return handleFetch(logical, makeStore(siteId), context && context.env ? context.env : {});
};
