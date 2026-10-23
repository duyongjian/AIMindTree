/**
 * Vercel Serverless Function 入口（catch-all：``api/[[...path]].js``）。
 *
 * 为什么是单个 catch-all 函数而不是拆成 6 个：Vercel Hobby 版对「函数数量」有限制，
 * 一个 catch-all 全部搞定；路径匹配在 core.js 里用 ``endsWith`` 后缀匹配完成
 * （与 CF 版写法一致），绑到 ``/`` 根路径即可命中所有业务路由。
 *
 * 运行时选 **nodejs**（默认，勿切 edge）：密码散列 PBKDF2 10 万次迭代是 CPU 密集
 * 同步计算，edge runtime 有 CPU 时间上限，可能超时；Node 运行时下约几十毫秒。
 *
 * 数据库：**Vercel KV 产品已下线**（`@vercel/kv` 弃用，2026 年官方确认产品不存在），
 * 迁移路径是 `@upstash/redis`——Redis 命令 API 与前者完全一致（`@vercel/kv` 本来
 * 就是它的薄封装），只是换 import、换客户端构造、换环境变量名。
 * 这里同时兼容两套变量名：走 Vercel Marketplace 装 Upstash 集成会注入
 * ``KV_REST_API_URL`` / ``KV_REST_API_TOKEN``（旧名，保持兼容），手动填则是
 * ``UPSTASH_REDIS_REST_URL`` / ``UPSTASH_REDIS_REST_TOKEN``。
 * 两者都没有时返回 503 + 可读指引，``curl https://<域名>/`` 一眼能看出来。
 *
 * 本文件只做「Web 标准 Request → core.js 的平台无关处理函数 → Response」适配，
 * 全部业务逻辑在 core.js，数据访问在 db.js。
 */

import { Redis } from '@upstash/redis';

import { createHandler, SERVICE_NAME, CORS_HEADERS } from '../core.js';
import { createStore, isConfigured } from '../db.js';

/**
 * 从环境变量构造 Upstash Redis 客户端；没配全时返回 null。
 *
 * 变量名两套都认（原因见文件头）：Marketplace 集成注入旧名 KV_REST_API_*，
 * 手动配置 / upstash.com 直建用的是 UPSTASH_REDIS_REST_*。
 */
function createRedisClient() {
  const url =
    process.env.UPSTASH_REDIS_REST_URL ||
    process.env.KV_REST_API_URL ||
    process.env.KV_URL;
  const token =
    process.env.UPSTASH_REDIS_REST_TOKEN ||
    process.env.KV_REST_API_TOKEN ||
    process.env.KV_API_TOKEN;
  if (!url || !token) return null;
  return new Redis({ url, token });
}

/** 懒创建 + 缓存的业务处理函数（热启动复用，避免每次冷建 store）。 */
let cachedHandler = null;

async function getHandler() {
  if (!cachedHandler) {
    const client = createRedisClient();
    if (!client) return null;
    cachedHandler = createHandler(createStore(client));
  }
  return cachedHandler;
}

/** Redis 未配置时统一的可读报错（部署者最容易踩的坑）。 */
function redisNotConfiguredResponse() {
  return new Response(
    JSON.stringify({
      ok: false,
      service: SERVICE_NAME,
      error:
        'Redis 未配置：Vercel KV 产品已下线，请在 Vercel 项目 → Integrations → ' +
        'Marketplace 添加 Upstash Redis（或到 upstash.com 建库），把 ' +
        'UPSTASH_REDIS_REST_URL / UPSTASH_REDIS_REST_TOKEN 配成项目环境变量后 Redeploy。',
    }),
    { status: 503, headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS } }
  );
}

export default async function handler(request) {
  const url = new URL(request.url);

  // CORS 预检不过库、不看配置，部署成功就该放行（浏览器手动调试用；App 走 dart:io）。
  if (request.method.toUpperCase() === 'OPTIONS') {
    return new Response(null, { status: 204, headers: { ...CORS_HEADERS } });
  }

  if (!isConfigured()) return redisNotConfiguredResponse();

  const handle = await getHandler();
  if (!handle) return redisNotConfiguredResponse();

  // 请求头键统一转小写后交给 core；请求体以原始字符串传入，由 core 自己 JSON.parse
  // （非法 JSON 在 core 里统一回 400 invalid json，与 CF 版行为一致）。
  const headers = {};
  request.headers.forEach((value, key) => {
    headers[key.toLowerCase()] = value;
  });
  const bodyText = await request.text();

  const { status, headers: outHeaders, body } = await handle({
    method: request.method,
    path: url.pathname,
    headers,
    body: bodyText,
  });

  // 204 不允许带 body（Web 标准会抛 TypeError）；其余路径原样回 JSON 字符串。
  return new Response(status === 204 ? null : body, { status, headers: outHeaders });
}

/**
 * 本地自测钩子：注入内存 mock store 驱动**真实入口**（不联网、不碰 Redis）。
 * 生产路径不会调用它；见 test_protocol.mjs 的入口级用例。
 */
export function __setStoreForTesting(store) {
  cachedHandler = createHandler(store);
}
