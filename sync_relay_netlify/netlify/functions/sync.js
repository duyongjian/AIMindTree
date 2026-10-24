/**
 * AIMindTree 同步中继 · Netlify 生产入口。
 *
 * Netlify Functions（Node.js）约定：默认导出 ``(request, context) => Response``。
 * 本文件只做三件事：
 *   1. 用 ``@netlify/blobs`` 的 ``getStore`` 拿到站点级 KV 存储（凭证在 Functions
 *      内自动注入，无需手动配置 token）；
 *   2. 把 Blobs 适配成 relay.js 需要的 ``{get, set, listKeys}`` 接口；
 *   3. 调 ``handleFetch(request, store)`` 跑核心逻辑。
 *
 * 路由由仓库根 ``netlify.toml`` 的 rewrite 把 ``/``、``/auth/*``、``/sync/*``
 * 全部转发到本函数（见 netlify.toml 注释）。
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

export default async (request, context) => {
  return handleFetch(request, store, context && context.env ? context.env : {});
};
