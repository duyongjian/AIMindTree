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
 * KV 绑定检查：Vercel 项目 → Storage 里创建 KV 数据库并 Bind 到本项目后，
 * 平台会自动注入 ``KV_REST_API_URL`` / ``KV_REST_API_TOKEN``。没绑定时这里直接
 * 返回 503 + 可读错误（而不是让 ``@vercel/kv`` 抛那句看不懂的 env 缺失异常），
 * 部署者 ``curl https://<域名>/`` 一眼就能看出来。
 *
 * 本文件只做「Web 标准 Request → core.js 的平台无关处理函数 → Response」适配，
 * 全部业务逻辑在 core.js，数据访问在 db.js。
 */

import { kv } from '@vercel/kv';

import { createHandler, SERVICE_NAME, CORS_HEADERS } from '../core.js';
import { createStore, isConfigured } from '../db.js';

/** 懒创建 + 缓存的业务处理函数（热启动复用，避免每次冷建 store）。 */
let cachedHandler = null;

async function getHandler() {
  if (!cachedHandler) {
    cachedHandler = createHandler(createStore(kv));
  }
  return cachedHandler;
}

/** KV 未绑定时统一的可读报错（部署者最容易踩的坑）。 */
function kvNotBoundResponse() {
  return new Response(
    JSON.stringify({
      ok: false,
      service: SERVICE_NAME,
      error:
        'KV 未绑定：请在 Vercel 项目 → Storage → 创建 KV 数据库并 Bind 到本项目，' +
        '然后 Redeploy；平台会自动注入 KV_REST_API_URL / KV_REST_API_TOKEN。',
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

  if (!isConfigured()) return kvNotBoundResponse();

  const handle = await getHandler();

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
 * 本地自测钩子：注入内存 mock store 驱动**真实入口**（不联网、不碰 KV）。
 * 生产路径不会调用它；见 test_protocol.mjs 的入口级用例。
 */
export function __setStoreForTesting(store) {
  cachedHandler = createHandler(store);
}
