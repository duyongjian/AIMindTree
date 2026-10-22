/* 管理后台 API 封装 —— 全部端点走这里，views 里禁止裸 fetch。
   无框架、无 CDN 外链（C2）。 */

"use strict";

/* ---------------- 错误归一化 ---------------- */

/** 12 个归一化错误码 → 中文文案 + 是否可重试（绝不把英文 traceback 甩给用户）。 */
var ERROR_TEXT = {
  unknown_task: '任务不存在',
  missing_input: '缺少必填输入',
  prompt_not_found: '提示词加载失败',
  backend_unknown: '后端未配置',
  backend_unreachable: '后端连不上',
  backend_timeout: '后端超时',
  auth_failed: '密钥鉴权失败',
  rate_limited: '触发限流',
  bad_json: '模型输出不是合法 JSON',
  upstream_error: '上游返回异常',
  invalid_request: '请求不合法',
  internal: '服务端内部错误',
};

/** 可重试的错误码（超时/限流/不可达/上游错误/bad_json）。 */
var RETRYABLE_CODES = {
  backend_unreachable: true,
  backend_timeout: true,
  rate_limited: true,
  bad_json: true,
  upstream_error: true,
};

/** 统一错误对象。 */
function ApiError(message, code, status, retryable) {
  this.name = 'ApiError';
  this.message = message || '未知错误';
  this.code = code || 'internal';
  this.status = typeof status === 'number' ? status : 0;
  this.retryable = retryable === true ||
    (retryable === undefined && RETRYABLE_CODES[this.code] === true);
}
ApiError.prototype = Object.create(Error.prototype);
ApiError.prototype.constructor = ApiError;

/** 把任意异常转成用户能看懂的一句话（绝不出现英文 traceback）。 */
function humanizeError(err) {
  if (err && err.code && ERROR_TEXT[err.code]) {
    return ERROR_TEXT[err.code] + (err.message ? '：' + err.message : '');
  }
  if (err && err.code) {
    return '服务返回未知错误（code=' + err.code + '）';
  }
  if (err && err.message) {
    return '请求失败：' + err.message;
  }
  return '请求失败：未知原因';
}

/* ---------------- HTTP ---------------- */

function _request(method, path, body) {
  var init = { method: method, cache: 'no-store', headers: {} };
  if (body !== undefined && body !== null) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  return fetch(path, init).then(function (resp) {
    return resp.text().then(function (text) {
      var data = null;
      try {
        data = text ? JSON.parse(text) : null;
      } catch (e) {
        data = null;
      }
      if (resp.status >= 200 && resp.status < 300) {
        return data;
      }
      var err = (data && data.error) || {};
      throw new ApiError(
        err.message || ('HTTP ' + resp.status),
        err.code || (resp.status === 404 ? 'unknown_task' : 'internal'),
        resp.status,
        err.retryable
      );
    });
  });
}

function apiGet(path) { return _request('GET', path, null); }
function apiPost(path, body) { return _request('POST', path, body || {}); }
function apiPut(path, body) { return _request('PUT', path, body || {}); }

/* ---------------- 端点 ---------------- */

function health() { return apiGet('/health'); }
function adminConfig() { return apiGet('/v1/admin/config'); }
function saveAdminConfig(body) { return apiPost('/v1/admin/config', body); }
/* 同步配置（Supabase）：GET 只回 token_set / token_masked，无明文；
   PUT 语义：文本框留空 = 不修改，token 空串 = 清空。 */
function adminSync() { return apiGet('/v1/admin/sync'); }
function saveSync(body) { return apiPut('/v1/admin/sync', body); }
function adminModels(backend) {
  return apiGet('/v1/admin/models?backend=' + encodeURIComponent(backend || ''));
}
function adminBalance() { return apiGet('/v1/admin/balance'); }
function adminStats(windowS) {
  var q = (windowS === undefined || windowS === null) ? '' : '?window_s=' + encodeURIComponent(windowS);
  return apiGet('/v1/admin/stats' + q);
}
function adminLogs(params) {
  var p = params || {};
  var qs = [];
  if (p.level) qs.push('level=' + encodeURIComponent(p.level));
  if (p.module) qs.push('module=' + encodeURIComponent(p.module));
  if (p.q) qs.push('q=' + encodeURIComponent(p.q));
  if (p.limit) qs.push('limit=' + encodeURIComponent(p.limit));
  if (p.before_seq) qs.push('before_seq=' + encodeURIComponent(p.before_seq));
  return apiGet('/v1/admin/logs' + (qs.length ? '?' + qs.join('&') : ''));
}
function adminRoutes() { return apiGet('/v1/admin/routes'); }
function saveRoutes(taskBackends) { return apiPut('/v1/admin/routes', { task_backends: taskBackends }); }
function adminJobs(params) {
  var p = params || {};
  var qs = [];
  if (p.status) qs.push('status=' + encodeURIComponent(p.status));
  if (p.limit) qs.push('limit=' + encodeURIComponent(p.limit));
  return apiGet('/v1/jobs' + (qs.length ? '?' + qs.join('&') : ''));
}
function cancelJob(jobId) {
  return apiPost('/v1/jobs/' + encodeURIComponent(jobId) + '/cancel', {});
}
function appConfig() { return apiGet('/v1/app/config'); }
function prompts() { return apiGet('/v1/prompts'); }
function prompt(task, variant) {
  var q = variant ? '?variant=' + encodeURIComponent(variant) : '';
  return apiGet('/v1/prompts/' + encodeURIComponent(task) + q);
}
function savePrompt(task, variant, content) {
  var q = '?reload=true' + (variant ? '&variant=' + encodeURIComponent(variant) : '');
  return apiPut('/v1/prompts/' + encodeURIComponent(task) + q, { content: content });
}
function reloadPrompts() { return apiPost('/v1/prompts/reload', {}); }
function runTask(code, body) {
  return apiPost('/v1/task/' + encodeURIComponent(code), body || {});
}
function runChat(body) {
  var payload = body || {};
  payload.stream = false; // 调试台固定一次性返回，不接 SSE
  return apiPost('/v1/chat', payload);
}
function reloadConfig() { return apiPost('/v1/admin/reload', {}); }

/* ---------------- 渲染工具 ---------------- */

/** HTML 转义：所有插入 innerHTML 的文本必须先过这里。 */
function esc(s) {
  return String(s === null || s === undefined ? '' : s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}

/** 状态徽标。kind: ok / bad / warn / info / grey。 */
function badge(kind, text) {
  return '<span class="badge ' + esc(kind) + '">' + esc(text) + '</span>';
}

/** epoch 秒 → 本地时间字符串。 */
function fmtTime(ts) {
  if (!ts && ts !== 0) return '—';
  var d = new Date(typeof ts === 'number' && ts < 1e12 ? ts * 1000 : ts);
  if (isNaN(d.getTime())) return '—';
  var p = function (n) { return String(n).padStart(2, '0'); };
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
    ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

/** epoch 秒 → 「3 分钟前」。 */
function fmtAgo(ts) {
  if (!ts) return '—';
  var now = Date.now() / 1000;
  var t = typeof ts === 'number' && ts < 1e12 ? ts : ts / 1000;
  var diff = Math.floor(now - t);
  if (isNaN(diff)) return '—';
  if (diff < 0) return '刚刚';
  if (diff < 60) return diff + ' 秒前';
  if (diff < 3600) return Math.floor(diff / 60) + ' 分钟前';
  if (diff < 86400) return Math.floor(diff / 3600) + ' 小时前';
  return Math.floor(diff / 86400) + ' 天前';
}

/** 毫秒 → 「1.2s」/「820ms」。 */
function fmtMs(ms) {
  if (ms === null || ms === undefined) return '—';
  var n = Number(ms);
  if (isNaN(n)) return '—';
  return n >= 1000 ? (n / 1000).toFixed(1) + 's' : n + 'ms';
}

/** 创建一个元素（带 class / html）。 */
function makeEl(tag, className, html) {
  var el = document.createElement(tag);
  if (className) el.className = className;
  if (html !== undefined && html !== null) el.innerHTML = html;
  return el;
}

/** 把错误渲染成红色条 + 重试按钮（**卡片级隔离**：只影响本卡）。 */
function cardError(container, err, onRetry) {
  var box = makeEl('div', 'alert err');
  box.innerHTML = '<span>' + esc(humanizeError(err)) + '</span>';
  if (typeof onRetry === 'function') {
    var btn = makeEl('button', 'btn small retry', '重试');
    btn.addEventListener('click', function () { onRetry(); });
    box.appendChild(btn);
  }
  container.appendChild(box);
}

/** 卡片渲染包装：try/catch 后把错误收敛到本卡（前端渲染铁律 ②）。 */
function mountInto(container, fn) {
  return Promise.resolve()
    .then(function () { return fn(container); })
    .catch(function (e) {
      cardError(container, e, function () {
        container.innerHTML = '';
        mountInto(container, fn);
      });
    });
}

/** 顶部轻量提示（成功绿色 / 失败红色）。 */
function toast(container, text, kind) {
  if (!container) return;
  var box = makeEl('div', 'alert ' + (kind || 'ok'), esc(text));
  container.insertBefore(box, container.firstChild);
  setTimeout(function () { if (box.parentNode) box.parentNode.removeChild(box); }, 4000);
}

/** 复制到剪贴板（带降级：execCommand）。 */
function copyText(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    return navigator.clipboard.writeText(text);
  }
  return new Promise(function (resolve, reject) {
    try {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      var ok = document.execCommand('copy');
      document.body.removeChild(ta);
      ok ? resolve() : reject(new Error('copy failed'));
    } catch (e) {
      reject(e);
    }
  });
}
