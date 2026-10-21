/* M7 运行日志：过滤条 + 摘要 + 明细表（点击行展开全文）+ 自动刷新。
   依赖 api.js（esc / badge / mountInto / cardError / fmtTime / fmtAgo）。
   约定：所有插入 innerHTML 的文本必须先过 esc()；自动刷新定时器挂在
   window.__autoRefreshTimer 上，由 app.js 的 route() 负责清理。 */

"use strict";

/* 级别 → 徽标配色。 */
var LOG_LEVEL_BADGE = {
  DEBUG: 'grey',
  INFO: 'info',
  WARNING: 'warn',
  ERROR: 'bad',
};

/* 自动刷新间隔（毫秒）。 */
var LOG_REFRESH_MS = 3000;

function renderLogs(root) {
  /* ---------- 过滤条（DOM 直建，刷新时保留用户输入） ---------- */
  var filterCard = makeEl('div', 'card');
  filterCard.innerHTML =
    '<h2>过滤</h2>' +
    '<p class="hint">GET /v1/admin/logs · 环形缓冲（进程内，不落盘，重启即清）</p>';
  var bar = makeEl('div', 'row');
  bar.appendChild(_logSelect('级别', 'logLevel', [
    ['', '全部'], ['INFO', 'INFO 及以上'], ['WARNING', 'WARNING 及以上'], ['ERROR', '仅 ERROR'],
  ]));
  bar.appendChild(_logInput('模块', 'logModule', '如 task / chat / config（留空=全部）'));
  bar.appendChild(_logInput('关键字', 'logQ', '消息子串，大小写不敏感'));
  bar.appendChild(_logSelect('条数', 'logLimit', [
    ['50', '50 条'], ['100', '100 条'], ['200', '200 条'], ['500', '500 条'],
  ]));
  filterCard.appendChild(bar);

  var actions = makeEl('div', 'actions');
  var btnRefresh = makeEl('button', 'btn', '刷新');
  var chkAuto = makeEl('input');
  chkAuto.type = 'checkbox';
  chkAuto.id = 'logAuto';
  var lblAuto = makeEl('label', 'small nowrap');
  lblAuto.style.margin = '0';
  lblAuto.htmlFor = 'logAuto';
  lblAuto.textContent = '自动刷新（3s）';
  actions.appendChild(btnRefresh);
  actions.appendChild(chkAuto);
  actions.appendChild(lblAuto);
  filterCard.appendChild(actions);
  root.appendChild(filterCard);

  /* ---------- 摘要 + 表格 ---------- */
  var body = makeEl('div', 'mt');
  root.appendChild(body);

  var state = { cursor: null, loading: false };

  function currentParams() {
    return {
      level: document.getElementById('logLevel').value,
      module: document.getElementById('logModule').value,
      q: document.getElementById('logQ').value,
      limit: document.getElementById('logLimit').value,
    };
  }

  function load(resetCursor) {
    if (state.loading) return;
    state.loading = true;
    if (resetCursor) state.cursor = null;
    var params = currentParams();
    if (state.cursor) params.before_seq = state.cursor;
    adminLogs(params)
      .then(function (data) { renderBody(body, data, load, state); })
      .catch(function (e) {
        body.innerHTML = '';
        cardError(body, e, function () { load(false); });
      })
      .then(function () { state.loading = false; });
  }

  btnRefresh.addEventListener('click', function () { load(true); });
  ['logLevel', 'logModule', 'logLimit'].forEach(function (id) {
    document.getElementById(id).addEventListener('change', function () { load(true); });
  });
  var qInput = document.getElementById('logQ');
  var qTimer = null;
  qInput.addEventListener('input', function () {
    if (qTimer) clearTimeout(qTimer);
    qTimer = setTimeout(function () { load(true); }, 300);
  });

  chkAuto.addEventListener('change', function () {
    if (window.__autoRefreshTimer) {
      clearInterval(window.__autoRefreshTimer);
      window.__autoRefreshTimer = null;
    }
    if (chkAuto.checked) {
      window.__autoRefreshTimer = setInterval(function () { load(true); }, LOG_REFRESH_MS);
    }
  });

  load(true);
}

/* ---------- 小控件 ---------- */

function _logSelect(label, id, options) {
  var wrap = makeEl('div');
  var lab = makeEl('label', '', label);
  lab.htmlFor = id;
  var sel = makeEl('select');
  sel.id = id;
  options.forEach(function (opt) {
    var o = document.createElement('option');
    o.value = opt[0];
    o.textContent = opt[1];
    sel.appendChild(o);
  });
  wrap.appendChild(lab);
  wrap.appendChild(sel);
  return wrap;
}

function _logInput(label, id, placeholder) {
  var wrap = makeEl('div');
  var lab = makeEl('label', '', label);
  lab.htmlFor = id;
  var inp = makeEl('input');
  inp.type = 'text';
  inp.id = id;
  inp.placeholder = placeholder || '';
  wrap.appendChild(lab);
  wrap.appendChild(inp);
  return wrap;
}

/* ---------- 主体渲染 ---------- */

function renderBody(body, data, load, state) {
  body.innerHTML = '';
  var items = (data && data.items) || [];

  /* 摘要 chips */
  var chips = makeEl('div', 'chips mb');
  chips.innerHTML =
    '<span class="small muted">命中 ' + esc(data.matched || 0) + ' 条 · 缓冲 ' +
    esc(data.buffer_size || 0) + '/1000 · 启动以来 ' + esc(data.since_startup || 0) +
    ' 条' + (data.dropped ? '（已挤出 ' + esc(data.dropped) + ' 条）' : '') + '</span>';
  var levels = data.levels || {};
  ['ERROR', 'WARNING', 'INFO', 'DEBUG'].forEach(function (lv) {
    if (!levels[lv]) return;
    chips.innerHTML += ' ' + badge(LOG_LEVEL_BADGE[lv] || 'grey', lv + ' ' + levels[lv]);
  });
  body.appendChild(chips);

  if (!items.length) {
    body.appendChild(makeEl('p', 'muted small',
      state.cursor ? '没有更早的日志了。' : '没有符合条件的日志（试试放宽过滤条件）。'));
    return;
  }

  /* 明细表 */
  var html = '<table><thead><tr>' +
    '<th style="width:150px">时间</th>' +
    '<th style="width:86px">级别</th>' +
    '<th style="width:130px">模块</th>' +
    '<th>消息（点击行展开全文）</th>' +
    '</tr></thead><tbody>';
  items.forEach(function (it) {
    var msg = String(it.message || '');
    var shortMsg = msg.length > 180 ? msg.slice(0, 180) + '…' : msg;
    html += '<tr class="log-row" data-seq="' + esc(it.seq) + '">' +
      '<td class="nowrap small" title="' + esc(fmtAgo(it.ts)) + '">' + esc(fmtTime(it.ts)) + '</td>' +
      '<td>' + badge(LOG_LEVEL_BADGE[it.level] || 'grey', esc(it.level || '?')) + '</td>' +
      '<td class="mono">' + esc(it.module || '—') + '</td>' +
      '<td class="log-msg">' + esc(shortMsg) + '</td>' +
      '</tr>';
  });
  html += '</tbody></table>';
  var tableBox = makeEl('div', '', html);
  body.appendChild(tableBox);

  /* 点击行 → 展开 / 收起全文（同一行只允许一条详情） */
  tableBox.querySelectorAll('tr.log-row').forEach(function (tr) {
    tr.addEventListener('click', function () {
      var next = tr.nextElementSibling;
      if (next && next.className === 'log-detail') {
        next.parentNode.removeChild(next);
        return;
      }
      var seq = Number(tr.getAttribute('data-seq'));
      var full = '';
      for (var i = 0; i < items.length; i++) {
        if (items[i].seq === seq) { full = items[i].message; break; }
      }
      var detail = document.createElement('tr');
      detail.className = 'log-detail';
      var td = document.createElement('td');
      td.colSpan = 4;
      var pre = document.createElement('pre');
      pre.textContent = full; // textContent 天然转义，无需 esc()
      td.appendChild(pre);
      detail.appendChild(td);
      tr.parentNode.insertBefore(detail, tr.nextSibling);
    });
  });

  /* 加载更早的一页（游标分页：替换为更旧的一页，非追加） */
  if (data.next_cursor) {
    var more = makeEl('button', 'btn ghost small mt',
      '加载更早的一页（共 ' + esc(data.matched || 0) + ' 条命中）');
    more.addEventListener('click', function () {
      state.cursor = data.next_cursor;
      adminLogs(mergeParams(state)).then(function (d) {
        renderBody(body, d, load, state);
      });
    });
    body.appendChild(more);
  }
}

/* 「加载更早」用的参数合并（与 renderLogs 里的 currentParams 同源）。 */
function mergeParams(state) {
  var params = {
    level: document.getElementById('logLevel').value,
    module: document.getElementById('logModule').value,
    q: document.getElementById('logQ').value,
    limit: document.getElementById('logLimit').value,
  };
  if (state.cursor) params.before_seq = state.cursor;
  return params;
}
