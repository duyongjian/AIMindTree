/* M10 任务队列面板的无浏览器验证（browserless-frontend-verify 工作流）。
 *
 * 三层：
 *  A. 夹具体检——.m10_fixture.json 由 gen_m10_fixture.py（进程内真队列）产出；
 *  B. 纯函数——jobActive / _jobProgress / _jobElapsed 状态机；
 *  C. 渲染与交互——最小 DOM 桩加载 api.js + views-d.js，打 renderJobs：
 *     表格行数、取消按钮仅活跃态、XSS 转义、行展开快照、取消请求、
 *     筛选联动、错误卡片 + 重试、自动刷新定时器管理。
 *
 * 用法（在 llm_server/ 下）：
 *     node verify_m10_panel.js
 * 前置：先跑 `./.venv/Scripts/python.exe gen_m10_fixture.py` 生成夹具。
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const ROOT = __dirname;
const FIXTURE = path.join(ROOT, '.m10_fixture.json');

let passed = 0;
let failed = 0;
function ok(cond, name, extra) {
  if (cond) {
    passed++;
    console.log('  ✓ ' + name);
  } else {
    failed++;
    console.log('  ✗ ' + name + (extra ? ' —— ' + extra : ''));
  }
}

/* ================= 最小 DOM 桩 ================= */

const byId = {};
const VOID_TAGS = new Set(['input', 'br', 'img', 'hr', 'meta', 'link']);

function parseAttrs(str) {
  const out = {};
  const re = /([\w-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
  let m;
  while ((m = re.exec(str))) {
    out[m[1]] = m[2] !== undefined ? m[2]
      : m[3] !== undefined ? m[3]
      : m[4] !== undefined ? m[4] : '';
  }
  return out;
}

function parseHTML(html) {
  const root = { nodeType: 1, tagName: 'ROOT', children: [], parentNode: null };
  const stack = [root];
  const re = /<(\/?)([a-zA-Z][\w-]*)((?:\s+[\w-]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)*)\s*(\/?)>/g;
  let last = 0;
  let m;
  while ((m = re.exec(html))) {
    const text = html.slice(last, m.index);
    if (text.length) {
      stack[stack.length - 1].children.push({
        nodeType: 3, textContent: text, parentNode: stack[stack.length - 1],
      });
    }
    last = re.lastIndex;
    const closing = m[1] === '/';
    const tag = m[2].toLowerCase();
    if (closing) {
      for (let i = stack.length - 1; i > 0; i--) {
        if (stack[i].tagName === tag) { stack.length = i; break; }
      }
      continue;
    }
    const el = new El(tag);
    const attrs = parseAttrs(m[3] || '');
    for (const k of Object.keys(attrs)) {
      el._attrs[k] = attrs[k];
      if (k === 'class') el.className = attrs[k];
      if (k === 'id') el.id = attrs[k];
    }
    const parent = stack[stack.length - 1];
    parent.children.push(el);
    el.parentNode = parent;
    if (m[4] !== '/' && !VOID_TAGS.has(tag)) stack.push(el);
  }
  return root.children;
}

class El {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.children = [];
    this.parentNode = null;
    this._attrs = {};
    this._handlers = {};
    this._id = '';
    this.className = '';
    this._html = '';
    this.textContent = '';
    this.disabled = false;
    this.checked = false;
    this.value = undefined;
    this.colSpan = 1;
    this.style = {};
    this.type = '';
  }
  set innerHTML(h) {
    this._html = String(h);
    this.children = parseHTML(this._html);
    for (const c of this.children) c.parentNode = this;
  }
  get innerHTML() { return this._html; }
  // 浏览器语义：<select> 的 value 默认取第一个 <option> 的 value（惰性）。
  get value() {
    if (this._value !== undefined) return this._value;
    if (this.tagName === 'SELECT') {
      const firstOpt = this.children.find((c) => c.tagName === 'OPTION');
      if (firstOpt) return firstOpt.value || '';
    }
    return undefined;
  }
  set value(v) { this._value = v; }
  set id(v) { this._id = String(v); byId[this._id] = this; }
  get id() { return this._id; }
  appendChild(c) { c.parentNode = this; this.children.push(c); return c; }
  insertBefore(c, ref) {
    c.parentNode = this;
    if (!ref) { this.children.push(c); return c; }
    const i = this.children.indexOf(ref);
    if (i < 0) this.children.push(c); else this.children.splice(i, 0, c);
    return c;
  }
  removeChild(c) {
    const i = this.children.indexOf(c);
    if (i >= 0) this.children.splice(i, 1);
    c.parentNode = null;
    return c;
  }
  get firstChild() { return this.children[0] || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const i = this.parentNode.children.indexOf(this);
    return this.parentNode.children[i + 1] || null;
  }
  get nextElementSibling() {
    let s = this.nextSibling;
    while (s && s.nodeType === 3) s = s.nextSibling;
    return s || null;
  }
  addEventListener(type, fn) {
    (this._handlers[type] = this._handlers[type] || []).push(fn);
  }
  _fire(type, ev) {
    (this._handlers[type] || []).forEach((fn) => fn(ev || { stopPropagation() {} }));
  }
  setAttribute(k, v) {
    this._attrs[k] = String(v);
    if (k === 'id') this.id = String(v);
  }
  getAttribute(k) { return this._attrs[k] !== undefined ? this._attrs[k] : null; }
  _desc() {
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.nodeType === 3) continue;
        out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
  querySelectorAll(sel) {
    const m = /^([a-zA-Z][\w-]*)(?:\[([\w-]+)\]|\.([\w-]+))?$/.exec(sel);
    if (!m) return [];
    const [, tag, attr, cls] = m;
    return this._desc().filter((el) => {
      if (el.tagName !== tag.toUpperCase()) return false;
      if (attr) return el.getAttribute(attr) !== null;
      if (cls) return String(el.className).split(/\s+/).includes(cls);
      return true;
    });
  }
}

function matches(el, sel) { return el.querySelectorAll(sel).length >= 0; } // 占位，未用

const documentStub = {
  createElement: (t) => new El(t),
  getElementById: (id) => byId[id] || null,
};

/* ================= 沙箱 ================= */

const fetchCalls = [];
let fetchImpl = null;

const sandbox = {
  console,
  setTimeout,
  clearTimeout,
  setInterval: (fn, ms) => { sandbox.__timers.push({ fn, ms }); return sandbox.__timers.length; },
  clearInterval: (id) => { sandbox.__cleared.push(id); },
  Date, JSON, Math, Number, String, Object, Array, isNaN, parseInt, parseFloat,
  Promise, Error, encodeURIComponent, decodeURIComponent,
  document: documentStub,
  navigator: { clipboard: { writeText: () => Promise.resolve() } },
  fetch: (p, init) => {
    fetchCalls.push({ path: p, init: init || {} });
    return fetchImpl(p, init);
  },
  __timers: [],
  __cleared: [],
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

const ctx = vm.createContext(sandbox);
for (const f of ['api.js', 'views-d.js']) {
  const code = fs.readFileSync(path.join(ROOT, 'static', f), 'utf8');
  vm.runInContext(code, ctx, { filename: f });
}

const flush = async () => {
  for (let i = 0; i < 8; i++) await new Promise((r) => setImmediate(r));
};
const jsonResp = (data, status = 200) => ({
  status,
  text: () => Promise.resolve(typeof data === 'string' ? data : JSON.stringify(data)),
});

/* ================= 主流程 ================= */

(async () => {
  console.log('== A. 夹具体检 ==');
  assert.ok(fs.existsSync(FIXTURE), '缺少 .m10_fixture.json，先跑 gen_m10_fixture.py');
  const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  const byStatus = {};
  for (const j of fixture.jobs) byStatus[j.status] = (byStatus[j.status] || 0) + 1;
  for (const s of ['queued', 'running', 'done', 'failed', 'canceled']) {
    ok((byStatus[s] || 0) >= 1, `夹具含 ${s} 样本`, JSON.stringify(byStatus));
  }
  ok(fixture.concurrency === 1, '夹具 concurrency=1（Q2 决策）');
  ok(typeof fixture.buffer_size === 'number', '夹具带 buffer_size');
  for (const j of fixture.jobs) {
    ok(typeof j.job_id === 'string' && j.job_id.length > 0, `快照 ${j.status} 有 job_id`);
    ok(j.submitted_at !== undefined, `快照 ${j.status} 有 submitted_at`);
  }

  console.log('== B. 纯函数：状态机与文案 ==');
  const active = fixture.jobs.filter((j) => ctx.jobActive(j));
  ok(active.length === fixture.jobs.filter((j) => ['queued', 'running'].includes(j.status)).length,
    'jobActive：仅 queued/running 可取消');
  ok(!fixture.jobs.filter((j) => ['done', 'failed', 'canceled'].includes(j.status)).some((j) => ctx.jobActive(j)),
    'jobActive：终态一律不可取消');
  const q = fixture.jobs.find((j) => j.status === 'queued');
  const r = fixture.jobs.find((j) => j.status === 'running');
  const d = fixture.jobs.find((j) => j.status === 'done');
  const f = fixture.jobs.find((j) => j.status === 'failed');
  const c = fixture.jobs.find((j) => j.status === 'canceled');
  ok(ctx._jobProgress(q) === '等待 worker…', 'queued 进度文案');
  ok(ctx._jobProgress(c) === '已取消' || (c.error && c.error.message), 'canceled 进度文案');
  ok(/失败|\[.*\]/.test(ctx._jobProgress(f)), 'failed 进度带错误信息', ctx._jobProgress(f));
  ok(/阶段|%|进行中/.test(ctx._jobProgress(r)), 'running 进度含阶段/百分比', ctx._jobProgress(r));
  ok(typeof ctx._jobElapsed(q) === 'string' && ctx._jobElapsed(q) !== '—', 'queued 已用时长');
  if (d && d.started_at && d.finished_at) {
    const expect = ctx.fmtMs(Math.round((d.finished_at - d.started_at) * 1000));
    ok(ctx._jobElapsed(d) === expect, 'done 已用时长取 finished-started');
  }

  console.log('== C. 渲染：首屏 ==');
  // 注入 XSS 探针（渲染前改标签，验证 esc 兜底）
  const xssJob = fixture.jobs.find((j) => j.status === 'running');
  xssJob.label = '补前置：导数<script>alert(1)</script>';
  xssJob.resource_key = 'kp:x"><img src=q onerror=alert(2)>';

  fetchImpl = () => Promise.resolve(jsonResp(fixture));
  const root = new El('div');
  ctx.renderJobs(root);
  await flush();

  ok(fetchCalls.length === 1, '首屏自动加载一次', String(fetchCalls.length));
  ok(fetchCalls[0].path === '/v1/jobs?limit=20', '默认 limit=20、无 status', fetchCalls[0].path);
  ok(byId['jobStatus'] && byId['jobLimit'], '筛选下拉已注册（getElementById 可达）');
  ok(byId['jobAuto'] && byId['jobAuto'].checked === true, '自动刷新默认开（队列监控语义）');
  ok(sandbox.__timers.length === 1 && sandbox.__timers[0].ms === 2000, '自动刷新定时器 2s 已挂');

  const rows = root.querySelectorAll('tr.job-row');
  ok(rows.length === fixture.jobs.length, '表格行数 = 夹具条数', String(rows.length));

  const cancelBtns = root.querySelectorAll('button[data-cancel]');
  ok(cancelBtns.length === 2, '取消按钮仅 queued+running 两条', String(cancelBtns.length));
  const cancelIds = cancelBtns.map((b) => b.getAttribute('data-cancel')).sort();
  ok(JSON.stringify(cancelIds) === JSON.stringify([q.job_id, r.job_id].sort()),
    '取消按钮 id 与活跃样本一一对应');

  const raw = root._desc().map((el) => el._html).join('\n');
  ok(!/<script>alert/.test(raw), 'XSS：label 里的 <script> 被转义');
  ok(raw.includes('&lt;script&gt;'), 'XSS：转义后的文本仍在 DOM 中可见');
  ok(!/onerror=alert/.test(raw.replace(/&quot;/g, '"')) || raw.includes('&lt;img'),
    'XSS：resource_key 里的标签同样被转义');

  const anyHtml = (el, re) => el._desc().some((d) => typeof d._html === 'string' && re.test(d._html));
  const runningRow = rows.find((tr) => tr.getAttribute('data-id') === r.job_id);
  ok(!!runningRow, 'running 样本行存在');
  ok(anyHtml(root, /取消已请求…/), 'running+cancel_requested 显示「取消已请求…」');
  ok(anyHtml(root, /badge bad/), 'failed 行显示失败态徽标');

  console.log('== D. 行展开快照 ==');
  runningRow._fire('click');
  const detail = runningRow.nextElementSibling;
  ok(detail && String(detail.className).includes('job-detail'), '点击行展开详情行');
  ok(detail && detail._desc().some((el) => el.tagName === 'PRE' &&
    el.textContent.includes(r.job_id)), '详情行含该 job 的 JSON 快照');
  runningRow._fire('click');
  ok(runningRow.nextElementSibling !== detail, '再点一次收起');

  console.log('== E. 取消请求 ==');
  const before = fetchCalls.length;
  cancelBtns[0]._fire('click', { stopPropagation() {} });
  await flush();
  const post = fetchCalls.find((c, i) => i >= before && c.init.method === 'POST');
  ok(!!post, '取消走 POST', post && post.path);
  ok(post && /^\/v1\/jobs\/.+\/cancel$/.test(post.path), '取消路径正确', post && post.path);
  ok(fetchCalls.length > before + 1, '取消后自动刷新列表');

  console.log('== F. 筛选联动 ==');
  byId['jobStatus'].value = 'failed';
  byId['jobStatus']._fire('change');
  await flush();
  const lastGet = fetchCalls.filter((c) => (c.init.method || 'GET') === 'GET').pop();
  ok(lastGet.path === '/v1/jobs?status=failed&limit=20', '状态筛选透传', lastGet.path);

  console.log('== G. 错误卡片 + 重试 ==');
  fetchImpl = () => Promise.reject(new ctx.ApiError('网络不通', 'upstream_error', 0, true));
  byId['jobLimit'].value = '50';
  byId['jobLimit']._fire('change');
  await flush();
  const alertBox = root.querySelectorAll('div.alert');
  ok(alertBox.length >= 1, '请求失败渲染 alert 卡片（卡片级隔离）');
  const retryBtn = alertBox[0].querySelectorAll('button.retry')[0];
  ok(!!retryBtn, '错误卡片带重试按钮');
  const failCount = fetchCalls.length;
  retryBtn._fire('click');
  await flush();
  ok(fetchCalls.length > failCount, '点重试重新发起请求');

  console.log('== H. 自动刷新管理 ==');
  // 定时器常挂是对的（load() 内有 state.loading 去重）；要防的是重复挂。
  ok(sandbox.__timers.length === 1, '定时器全程只挂一个（不随刷新重复挂）');
  byId['jobAuto'].checked = false;
  byId['jobAuto']._fire('change');
  ok(sandbox.window.__autoRefreshTimer === null || sandbox.window.__autoRefreshTimer === undefined,
    '取消勾选 → 定时器清理');
  byId['jobAuto'].checked = true;
  byId['jobAuto']._fire('change');
  ok(sandbox.window.__autoRefreshTimer, '重新勾选 → 定时器恢复');

  console.log('\n结果：' + passed + ' 过 / ' + failed + ' 挂');
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('测试 harness 自身崩溃：', e);
  process.exit(2);
});
