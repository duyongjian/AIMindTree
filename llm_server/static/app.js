/* 应用壳：hash 路由 + 导航高亮 + 模块注册表 + 顶栏动作 + M9 占位。
   依赖 api.js（先加载）。
   导航分三大区（见 index.html）：① 配置 m2/m3/m4/m5/m8 ·
   ② 观测 m1/m7/m10/m6 · ③ 运维 m9/m11。 */

"use strict";

/** 模块注册表：key → {title, hint, render}。 */
var MODULES = {
  m1: { title: '概览', hint: '服务状态、后端可达性、近 1 小时调用统计', render: renderDashboard },
  m2: { title: 'LLM Provider', hint: '后端地址 / 协议 / 模型 / 密钥；保存即热重载', render: renderProviders },
  m3: { title: 'App 下发配置', hint: 'App 启动拉取的运行配置（GET /v1/app/config）', render: renderAppConfig },
  m4: { title: '任务路由', hint: '把单个任务固定到指定后端 / 模型', render: renderRoutes },
  m5: { title: '提示词管理', hint: '服务端 prompts/*.md 的在线编辑与热重载', render: renderPrompts },
  m6: { title: '任务调试台', hint: '按 inputs 逐个填值，跑一次真实任务看结果', render: renderPlayground },
  m7: { title: '运行日志', hint: '进程内日志环形缓冲：按级别 / 模块 / 关键字过滤，点击行看全文', render: renderLogs },
  m8: { title: '同步配置', hint: 'Supabase 同步地址 / 令牌 / 启用开关（settings.json · sync 段）', render: renderSync },
  m9: { title: '备份与系统信息', hint: 'P1：配置导出 / 导入', render: renderPlaceholder },
  m10: { title: '任务队列', hint: '批量型 AI 任务的实时队列：状态 / 进度 / 资源锁 / 取消（与 M7 日志互补）', render: renderJobs },
  m11: { title: '云端同步', hint: '云端账号与同步数据（用户/行数/重置/导出）', render: renderRelay },
};

var currentPage = 'm1';
var serverVersion = '';

/** 取当前 hash 里的模块 key（非法 → m1）。 */
function pageFromHash() {
  var m = /^#\/(\w+)/.exec(location.hash || '');
  var key = m ? m[1] : 'm1';
  return MODULES[key] ? key : 'm1';
}

/** 切换页面：去/加 hidden，改标题，调 render。 */
function route() {
  // 离开页面前清理视图挂上的自动刷新定时器（当前只有 M7 用）。
  if (window.__autoRefreshTimer) {
    clearInterval(window.__autoRefreshTimer);
    window.__autoRefreshTimer = null;
  }
  var key = pageFromHash();
  currentPage = key;
  var mod = MODULES[key];

  var sections = document.querySelectorAll('#view > .page');
  for (var i = 0; i < sections.length; i++) {
    sections[i].hidden = (sections[i].getAttribute('data-page') !== key);
  }
  var navs = document.querySelectorAll('.nav-item');
  for (var j = 0; j < navs.length; j++) {
    navs[j].classList.toggle('active', navs[j].getAttribute('data-page') === key);
  }

  document.getElementById('pageTitle').textContent = mod.title;
  document.getElementById('pageHint').textContent = mod.hint;

  var root = document.querySelector('#view > .page[data-page="' + key + '"]');
  root.innerHTML = '';
  mountInto(root, mod.render);
}

/** 重新渲染当前页（顶栏「刷新」）。 */
function refreshCurrent() { route(); }

/* ---------------- M9 占位 ---------------- */

function renderPlaceholder(root) {
  var key = root.getAttribute('data-page');
  var plans = {
    m9: 'P1（AC-23）：配置导出 / 导入。core/config.py 的 save_settings() 已支持任意段，'
      + '导出 settings.json + config.yaml 只读快照即可，不需要新的服务端接口。',
  };
  root.appendChild(makeEl('div', 'card',
    '<h2>本模块尚未实现（P1）</h2>' +
    '<p class="hint">' + esc(plans[key] || '') + '</p>' +
    '<p class="muted small">配置 / 观测 / 运维三大区的其余模块均已实现。</p>'));
}

/* ---------------- 顶栏动作 ---------------- */

function bindTopbar() {
  document.getElementById('btnRefresh').addEventListener('click', function () {
    refreshCurrent();
  });

  document.getElementById('btnReloadConfig').addEventListener('click', function () {
    var btn = this;
    btn.disabled = true;
    reloadConfig()
      .then(function () {
        refreshCurrent();
      })
      .catch(function (e) {
        var view = document.getElementById('view');
        toast(view, '重载配置失败：' + humanizeError(e), 'err');
      })
      .then(function () { btn.disabled = false; });
  });

  document.getElementById('btnReloadPrompts').addEventListener('click', function () {
    var btn = this;
    btn.disabled = true;
    reloadPrompts()
      .then(function (r) {
        var view = document.getElementById('view');
        toast(view, '提示词已重载：' + (r && r.loaded !== undefined ? r.loaded : '?') + ' 个', 'ok');
        refreshCurrent();
      })
      .catch(function (e) {
        toast(document.getElementById('view'), '重载提示词失败：' + humanizeError(e), 'err');
      })
      .then(function () { btn.disabled = false; });
  });
}

/** 顶栏版本号（来自 /health，失败不阻塞）。 */
function loadVersion() {
  health()
    .then(function (h) {
      serverVersion = 'v' + (h && h.version ? h.version : '?');
      document.getElementById('navVersion').textContent =
        serverVersion + ' · 提示词 ' + (h && h.prompts_loaded !== undefined ? h.prompts_loaded : '?') + ' 个';
    })
    .catch(function () {
      document.getElementById('navVersion').textContent = '服务未连接';
    });
}

/* ---------------- 启动 ---------------- */

window.addEventListener('hashchange', route);
document.addEventListener('DOMContentLoaded', function () {
  bindTopbar();
  loadVersion();
  if (!location.hash) location.hash = '#/m1';
  route();
});
