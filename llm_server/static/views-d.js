/* M10 任务队列：当前任务 + concurrency + 取消 + 自动刷新（Q5）。
   依赖 api.js（esc / badge / mountInto / cardError / fmtTime / fmtAgo / fmtMs）。
   约定：所有插入 innerHTML 的文本必须先过 esc()；自动刷新定时器挂在
   window.__autoRefreshTimer 上，由 app.js 的 route() 负责清理。
   与 M7 日志互补：日志看历史事件流，本面板看「此刻队列里有什么」。 */

"use strict";

/* 状态 → 徽标配色 / 文案。 */
var JOB_STATUS = {
  queued: { badge: 'grey', text: '排队中' },
  running: { badge: 'info', text: '进行中' },
  done: { badge: 'ok', text: '完成' },
  failed: { badge: 'bad', text: '失败' },
  canceled: { badge: 'warn', text: '已取消' },
};

/* 自动刷新间隔（毫秒）：队列是活的状态，默认开、2s 一拍。 */
var JOB_REFRESH_MS = 2000;

function renderJobs(root) {
  /* ---------- 过滤条（DOM 直建，刷新时保留用户输入） ---------- */
  var filterCard = makeEl('div', 'card');
  filterCard.innerHTML =
    '<h2>任务队列</h2>' +
    '<p class="hint">GET /v1/jobs · 批量型 AI 任务（T1 提取 / T3 连线 / T4 补前置 / T5 检测）'
    + '走此队列；交互流式（T5 问答 / T6 / T7 / T8）不经过这里</p>';
  var bar = makeEl('div', 'row');
  bar.appendChild(_jobSelect('状态', 'jobStatus', [
    ['', '全部'], ['queued', '排队中'], ['running', '进行中'],
    ['done', '完成'], ['failed', '失败'], ['canceled', '已取消'],
  ]));
  bar.appendChild(_jobSelect('条数', 'jobLimit', [
    ['20', '20 条'], ['50', '50 条'], ['100', '100 条'], ['200', '200 条'],
  ]));
  filterCard.appendChild(bar);

  var actions = makeEl('div', 'actions');
  var btnRefresh = makeEl('button', 'btn', '刷新');
  var chkAuto = makeEl('input');
  chkAuto.type = 'checkbox';
  chkAuto.id = 'jobAuto';
  chkAuto.checked = true; // 队列监控默认自动刷新
  var lblAuto = makeEl('label', 'small nowrap');
  lblAuto.style.margin = '0';
  lblAuto.htmlFor = 'jobAuto';
  lblAuto.textContent = '自动刷新（2s）';
  actions.appendChild(btnRefresh);
  actions.appendChild(chkAuto);
  actions.appendChild(lblAuto);
  filterCard.appendChild(actions);
  root.appendChild(filterCard);

  /* ---------- 摘要 + 表格 ---------- */
  var body = makeEl('div', 'mt');
  root.appendChild(body);

  var state = { loading: false };

  function currentParams() {
    return {
      status: document.getElementById('jobStatus').value,
      limit: document.getElementById('jobLimit').value,
    };
  }

  function load() {
    if (state.loading) return;
    state.loading = true;
    adminJobs(currentParams())
      .then(function (data) { renderBody(body, data, load); })
      .catch(function (e) {
        body.innerHTML = '';
        cardError(body, e, function () { load(); });
      })
      .then(function () { state.loading = false; });
  }

  btnRefresh.addEventListener('click', function () { load(); });
  ['jobStatus', 'jobLimit'].forEach(function (id) {
    document.getElementById(id).addEventListener('change', function () { load(); });
  });

  chkAuto.addEventListener('change', function () {
    if (window.__autoRefreshTimer) {
      clearInterval(window.__autoRefreshTimer);
      window.__autoRefreshTimer = null;
    }
    if (chkAuto.checked) {
      window.__autoRefreshTimer = setInterval(load, JOB_REFRESH_MS);
    }
  });
  if (chkAuto.checked) {
    window.__autoRefreshTimer = setInterval(load, JOB_REFRESH_MS);
  }

  load();
}

/* ---------- 小控件 ---------- */

function _jobSelect(label, id, options) {
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

/* ---------- 主体渲染 ---------- */

function renderBody(body, data, load) {
  body.innerHTML = '';
  var items = (data && data.jobs) || [];

  /* 摘要 chips：活跃数 / 并发 / 缓冲占用 + 各状态计数。 */
  var counts = { queued: 0, running: 0, done: 0, failed: 0, canceled: 0 };
  items.forEach(function (j) {
    if (counts[j.status] !== undefined) counts[j.status]++;
  });
  var chips = makeEl('div', 'chips mb');
  chips.innerHTML =
    '<span class="small muted">并发 ' + esc(data.concurrency || 0) +
    ' · 缓冲 ' + esc(data.buffer_size || 0) + ' 条</span>' +
    ' ' + badge('grey', '排队 ' + counts.queued) +
    ' ' + badge('info', '进行中 ' + counts.running) +
    ' ' + badge('ok', '完成 ' + counts.done) +
    (counts.failed ? ' ' + badge('bad', '失败 ' + counts.failed) : '') +
    (counts.canceled ? ' ' + badge('warn', '已取消 ' + counts.canceled) : '');
  body.appendChild(chips);

  if (!items.length) {
    body.appendChild(makeEl('p', 'muted small', '队列是空的（没有未终态任务，也没有近期终态任务）。'));
    return;
  }

  /* 明细表 */
  var html = '<table><thead><tr>' +
    '<th style="width:132px">提交时间</th>' +
    '<th style="width:64px">任务</th>' +
    '<th>标签 / 资源锁</th>' +
    '<th style="width:96px">状态</th>' +
    '<th style="width:220px">进度</th>' +
    '<th style="width:88px">已用</th>' +
    '<th style="width:64px">操作</th>' +
    '</tr></thead><tbody>';
  items.forEach(function (j) {
    var st = JOB_STATUS[j.status] || { badge: 'grey', text: j.status || '?' };
    var progress = _jobProgress(j);
    html += '<tr class="job-row" data-id="' + esc(j.job_id || '') + '">' +
      '<td class="nowrap small" title="' + esc(fmtAgo(j.submitted_at)) + '">' +
        esc(fmtTime(j.submitted_at)) + '</td>' +
      '<td class="mono">' + esc(j.task || '—') + '</td>' +
      '<td>' + esc(j.label || '—') +
        (j.resource_key ? '<div class="small muted">🔒 ' + esc(j.resource_key) + '</div>' : '') +
        '</td>' +
      '<td>' + badge(st.badge, esc(st.text)) +
        (j.cancel_requested && j.status === 'running'
          ? '<div class="small muted">取消已请求…</div>' : '') +
        '</td>' +
      '<td class="small">' + esc(progress) + '</td>' +
      '<td class="nowrap small">' + esc(_jobElapsed(j)) + '</td>' +
      '<td>' + (jobActive(j)
        ? '<button class="btn small" data-cancel="' + esc(j.job_id || '') + '">取消</button>'
        : '') + '</td>' +
      '</tr>';
  });
  html += '</tbody></table>';
  var tableBox = makeEl('div', '', html);
  body.appendChild(tableBox);

  /* 取消按钮（事件委托，避免每行单独绑）。 */
  tableBox.querySelectorAll('button[data-cancel]').forEach(function (btn) {
    btn.addEventListener('click', function (ev) {
      ev.stopPropagation(); // 别触发行展开
      var id = btn.getAttribute('data-cancel');
      btn.disabled = true;
      cancelJob(id)
        .then(function () { load(); })
        .catch(function (e) {
          toast(body, '取消失败：' + humanizeError(e), 'err');
          btn.disabled = false;
        });
    });
  });

  /* 点击行 → 展开 / 收起完整快照。 */
  tableBox.querySelectorAll('tr.job-row').forEach(function (tr) {
    tr.addEventListener('click', function () {
      var next = tr.nextElementSibling;
      if (next && next.className === 'job-detail') {
        next.parentNode.removeChild(next);
        return;
      }
      var id = tr.getAttribute('data-id');
      var snap = null;
      for (var i = 0; i < items.length; i++) {
        if (items[i].job_id === id) { snap = items[i]; break; }
      }
      var detail = document.createElement('tr');
      detail.className = 'job-detail';
      var td = document.createElement('td');
      td.colSpan = 7;
      var pre = document.createElement('pre');
      pre.textContent = snap ? JSON.stringify(snap, null, 2) : '(快照缺失)';
      td.appendChild(pre);
      detail.appendChild(td);
      tr.parentNode.insertBefore(detail, tr.nextSibling);
    });
  });
}

/** 未终态（queued / running）= 可取消。 */
function jobActive(j) {
  return j.status === 'queued' || j.status === 'running';
}

/** 进度列文案：阶段 x/y · percent% · message（失败带 error code）。 */
function _jobProgress(j) {
  if (j.status === 'queued') return '等待 worker…';
  if (j.status === 'canceled') return j.error && j.error.message ? j.error.message : '已取消';
  if (j.status === 'failed') {
    var code = j.error && j.error.code ? '[' + j.error.code + '] ' : '';
    return code + (j.error && j.error.message ? j.error.message : '失败');
  }
  var stage = j.stage || {};
  var parts = [];
  if (stage.total && stage.total > 1) {
    parts.push('阶段 ' + (stage.index || 1) + '/' + stage.total);
  }
  if (typeof stage.percent === 'number') {
    parts.push(stage.percent + '%');
  }
  if (stage.message) parts.push(stage.message);
  return parts.length ? parts.join(' · ') : '进行中';
}

/** 已用时长：running/queued 用 elapsed_ms，终态用 finished-started（缺则 elapsed）。 */
function _jobElapsed(j) {
  var ms = j.elapsed_ms;
  if (j.status === 'running' || j.status === 'queued') return fmtMs(ms);
  if (j.finished_at && j.started_at) {
    return fmtMs(Math.round((j.finished_at - j.started_at) * 1000));
  }
  return fmtMs(ms);
}
