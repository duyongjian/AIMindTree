/* M1 概览 / M2 LLM Provider / M3 App 下发配置。
   依赖 api.js（esc / badge / mountInto / cardError 等）。 */

"use strict";

/* ================================================================
   M1 概览：4 张卡（服务状态 / 后端可达性 / 近 1h 统计 / 最近错误）
   Promise.allSettled —— 单卡失败只在那张卡显示错误。
   ================================================================ */

function renderDashboard(root) {
  var grid = makeEl('div', 'grid-2');
  var c1 = makeEl('div', 'card', '<h2>服务状态</h2><p class="hint">GET /health</p>');
  var c2 = makeEl('div', 'card', '<h2>后端可达性</h2><p class="hint">各后端并发探测</p>');
  var c3 = makeEl('div', 'card', '<h2>近 1 小时调用</h2><p class="hint">GET /v1/admin/stats</p>');
  var c4 = makeEl('div', 'card', '<h2>最近错误</h2><p class="hint">窗口内最后一条失败</p>');
  c1.appendChild(makeEl('div', 'spinner', '加载中…'));
  c2.appendChild(makeEl('div', 'spinner', '加载中…'));
  c3.appendChild(makeEl('div', 'spinner', '加载中…'));
  c4.appendChild(makeEl('div', 'spinner', '加载中…'));
  grid.appendChild(c1);
  grid.appendChild(c3);
  grid.appendChild(c2);
  grid.appendChild(c4);
  root.appendChild(grid);

  Promise.allSettled([health(), adminStats(3600), prompts()]).then(function (res) {
    // 卡 1：服务状态
    if (res[0].status === 'fulfilled') {
      var h = res[0].value || {};
      c1.innerHTML = '<h2>服务状态</h2><p class="hint">GET /health</p>';
      var kv = makeEl('div', 'kv');
      kv.innerHTML =
        '<div><span class="k">服务</span>' +
        (h.status === 'ok' ? badge('ok', '正常') : badge('bad', String(h.status || '异常'))) +
        ' · v' + esc(h.version || '?') + ' · uptime ' + esc(h.uptime_s !== undefined ? h.uptime_s : '?') + 's</div>' +
        '<div><span class="k">默认后端</span>' + esc(h.default_backend || '—') + '</div>' +
        '<div><span class="k">按任务覆盖</span>' + esc(Object.keys(h.task_backends || {}).join('、') || '（无，全部跟随默认）') + '</div>';
      c1.appendChild(kv);
    } else {
      c1.innerHTML = '<h2>服务状态</h2><p class="hint">GET /health</p>';
      cardError(c1, res[0].reason, function () { refreshCurrent(); });
    }

    // 卡 2：后端可达性
    if (res[0].status === 'fulfilled') {
      var bs = (res[0].value || {}).backends || [];
      c2.innerHTML = '<h2>后端可达性</h2><p class="hint">各后端并发探测（health_s 超时）</p>';
      if (!bs.length) {
        c2.appendChild(makeEl('p', 'muted small', '（没有配置任何后端）'));
      } else {
        var html = '<table><thead><tr><th>后端</th><th>状态</th><th>Base URL</th><th>模型</th></tr></thead><tbody>';
        for (var i = 0; i < bs.length; i++) {
          var b = bs[i] || {};
          html += '<tr><td>' + esc(b.name) + '</td><td>' +
            (b.reachable ? badge('ok', '已连接') : badge('bad', '未连接')) +
            (b.error ? ' <span class="small muted">' + esc(String(b.error).slice(0, 60)) + '</span>' : '') +
            '</td><td class="mono">' + esc(b.base_url || '') + '</td><td class="mono">' +
            esc((b.models || []).join(', ')) + '</td></tr>';
        }
        html += '</tbody></table>';
        c2.appendChild(makeEl('div', '', html));
      }
    } else {
      c2.innerHTML = '<h2>后端可达性</h2><p class="hint">各后端并发探测</p>';
      c2.appendChild(makeEl('p', 'muted small', '（依赖 /health，上方失败时无数据）'));
    }

    // 卡 3：近 1h 统计
    if (res[1].status === 'fulfilled') {
      var s = res[1].value || {};
      c3.innerHTML = '<h2>近 1 小时调用</h2><p class="hint">GET /v1/admin/stats?window_s=3600</p>';
      var kv3 = makeEl('div', 'kv');
      kv3.innerHTML =
        '<div><span class="k">总调用</span>' + esc(s.total || 0) + ' 次</div>' +
        '<div><span class="k">成功 / 失败</span>' + badge('ok', String(s.ok || 0)) + ' ' +
        badge(s.error ? 'bad' : 'grey', String(s.error || 0)) + '</div>' +
        '<div><span class="k">平均延迟</span>' + esc(fmtMs(s.avg_latency_ms)) + '</div>' +
        '<div><span class="k">P95 延迟</span>' + esc(fmtMs(s.p95_latency_ms)) + '</div>' +
        '<div><span class="k">启动以来</span>' + esc(s.since_startup || 0) + ' 条（缓冲 ' + esc(s.buffer_size || 0) + '）</div>';
      c3.appendChild(kv3);
    } else {
      c3.innerHTML = '<h2>近 1 小时调用</h2><p class="hint">GET /v1/admin/stats</p>';
      cardError(c3, res[1].reason, function () { refreshCurrent(); });
    }

    // 卡 4：最近错误（顺带提示词数）
    c4.innerHTML = '<h2>最近错误</h2><p class="hint">窗口内最后一条失败</p>';
    var p = res[2].status === 'fulfilled' ? (res[2].value || {}) : null;
    if (p && p.count !== undefined) {
      c4.appendChild(makeEl('p', 'small muted',
        '提示词：已加载 ' + esc(p.count) + ' 个' +
        (p.errors && p.errors.length ? '（' + esc(p.errors.length) + ' 个错误）' : '')));
    }
    var le = (res[1].status === 'fulfilled' && res[1].value) ? res[1].value.last_error : null;
    if (!le) {
      c4.appendChild(makeEl('p', 'small muted', '近 1 小时没有失败调用 ✅'));
    } else {
      var box = makeEl('div', 'alert err');
      box.innerHTML = '<div><b>' + esc(ERROR_TEXT[le.code] || le.code || '未知错误') + '</b>' +
        badge('bad', esc(le.code || '?')) + '</div>' +
        '<div class="small">任务 ' + esc(le.task || '—') + ' · 后端 ' + esc(le.backend || '—') +
        ' · ' + esc(fmtAgo(le.ts)) + '</div>' +
        (le.message ? '<div class="small mono">' + esc(String(le.message).slice(0, 200)) + '</div>' : '');
      c4.appendChild(box);
    }
    if (res[2].status === 'rejected') {
      cardError(c4, res[2].reason, function () { refreshCurrent(); });
    }
  });
}

/* ================================================================
   M2 LLM Provider：每个后端一张卡
   ================================================================ */

function renderProviders(root) {
  var wrap = makeEl('div', '');
  wrap.appendChild(makeEl('div', 'spinner', '加载中…'));
  root.appendChild(wrap);

  adminConfig().then(function (cfg) {
    wrap.innerHTML = '';
    var backends = cfg.backends || [];
    var forms = [];

    for (var i = 0; i < backends.length; i++) {
      wrap.appendChild(buildBackendCard(backends[i], cfg.default_backend, forms));
    }

    // MiniMax 余额卡（外网卡，失败只降级自己）
    var balCard = makeEl('div', 'card',
      '<h2>MiniMax 余额 / 额度</h2><p class="hint">GET /v1/admin/balance（需要外网，失败不影响其它卡）</p>');
    var balBox = makeEl('div', 'spinner', '查询中…');
    balCard.appendChild(balBox);
    wrap.appendChild(balCard);
    adminBalance()
      .then(function (r) {
        balBox.className = '';
        var ok = !!(r && r.available);
        balBox.innerHTML =
          '<div class="kv"><div><span class="k">可用</span>' +
          (ok ? badge('ok', '是') : badge('bad', '否')) + '</div>' +
          '<div><span class="k">说明</span>' + esc((r && r.error) ? r.error : '无') + '</div></div>' +
          ((r && r.raw) ? '<pre>' + esc(JSON.stringify(r.raw, null, 2)) + '</pre>' : '');
      })
      .catch(function (e) {
        balBox.className = '';
        cardError(balBox, e, function () { refreshCurrent(); });
      });

    // 底部保存
    var actions = makeEl('div', 'card');
    var bar = makeEl('div', 'actions');
    var saveBtn = makeEl('button', 'btn', '保存并热重载');
    var msg = makeEl('span', 'msg');
    saveBtn.addEventListener('click', function () {
      saveBtn.disabled = true;
      msg.className = 'msg';
      msg.textContent = '保存中…';
      var body = { backends: {} };
      for (var k = 0; k < forms.length; k++) {
        body.backends[forms[k].name] = forms[k].collect();
      }
      saveAdminConfig(body)
        .then(function () {
          msg.textContent = '已保存，已热重载 ✅';
          msg.className = 'msg ok';
          refreshCurrent();
        })
        .catch(function (e) {
          msg.textContent = humanizeError(e);
          msg.className = 'msg err';
        })
        .then(function () { saveBtn.disabled = false; });
    });
    bar.appendChild(saveBtn);
    bar.appendChild(msg);
    var probeBtn = makeEl('button', 'btn ghost', '立即探活');
    probeBtn.addEventListener('click', function () {
      msg.className = 'msg';
      msg.textContent = '探活中…';
      health()
        .then(function (h) {
          var down = (h.backends || []).filter(function (b) { return !b.reachable; });
          msg.textContent = down.length
            ? '不可达：' + down.map(function (b) { return b.name; }).join('、')
            : '全部后端可达 ✅';
          msg.className = down.length ? 'msg err' : 'msg ok';
        })
        .catch(function (e) {
          msg.textContent = humanizeError(e);
          msg.className = 'msg err';
        });
    });
    bar.appendChild(probeBtn);
    actions.appendChild(bar);
    actions.appendChild(makeEl('p', 'field-help',
      '覆盖层语义：留空 / 不出现的键 = 不改；密钥框留空 = 不修改已保存的密钥；' +
      '地址清空 = 删除覆盖、回落 config.yaml 的基线值。保存只写 settings.json，config.yaml 永不被写入。'));
    wrap.appendChild(actions);
  }).catch(function (e) {
    wrap.innerHTML = '';
    cardError(wrap, e, function () { refreshCurrent(); });
  });
}

/** 单张后端卡。 */
function buildBackendCard(b, defaultBackend, forms) {
  var card = makeEl('div', 'card');
  var head = '<h2>' + esc(b.name) +
    (b.for_app ? ' ' + badge('info', 'App 默认') : '') +
    (b.key_set ? ' ' + badge('ok', '密钥已设置') : ' ' + badge('grey', '无密钥')) + '</h2>';
  card.innerHTML = head + '<p class="hint">' +
    (b.key_set ? '当前密钥：' + esc(b.key_masked || '') : '未设置密钥（本地后端如 Ollama 无需密钥）') +
    '</p>';

  // Base URL
  var urlLabel = makeEl('label', '', 'Base URL');
  urlLabel.setAttribute('for', 'bu_' + b.name);
  var urlInput = makeEl('input');
  urlInput.type = 'text';
  urlInput.id = 'bu_' + b.name;
  urlInput.value = b.base_url || '';
  card.appendChild(urlLabel);
  card.appendChild(urlInput);
  card.appendChild(makeEl('p', 'field-help', '清空 = 删除覆盖，回落 config.yaml 的基线值。'));

  // 协议
  var protoSelect = null;
  if (b.protocol) {
    var pLabel = makeEl('label', '', '协议 Protocol');
    pLabel.setAttribute('for', 'pt_' + b.name);
    protoSelect = makeEl('select');
    protoSelect.id = 'pt_' + b.name;
    var opts = [['openai_compat', 'openai_compat（/v1/chat/completions）'],
                ['anthropic_compat', 'anthropic_compat（/v1/messages）']];
    for (var i = 0; i < opts.length; i++) {
      var o = makeEl('option', '', esc(opts[i][1]));
      o.value = opts[i][0];
      if (opts[i][0] === b.protocol) o.selected = true;
      protoSelect.appendChild(o);
    }
    card.appendChild(pLabel);
    card.appendChild(protoSelect);
  }

  // 模型（下拉 + 自定义联动）
  var mLabel = makeEl('label', '', '默认模型');
  mLabel.setAttribute('for', 'ms_' + b.name);
  var mSelect = makeEl('select');
  mSelect.id = 'ms_' + b.name;
  var placeholder = makeEl('option', '', '— 从列表选择 —');
  placeholder.value = '';
  mSelect.appendChild(placeholder);
  for (var j = 0; j < (b.models || []).length; j++) {
    var mo = makeEl('option', '', esc(b.models[j]));
    mo.value = b.models[j];
    mSelect.appendChild(mo);
  }
  var mInput = makeEl('input');
  mInput.type = 'text';
  mInput.value = b.default_model || '';
  mInput.placeholder = '自定义模型 ID';
  mSelect.addEventListener('change', function () {
    if (mSelect.value) mInput.value = mSelect.value;
  });
  var mRow = makeEl('div', 'row');
  mRow.appendChild(mSelect);
  mRow.appendChild(mInput);
  card.appendChild(mLabel);
  card.appendChild(mRow);

  // 异步拉远端模型列表（失败只影响下拉）
  adminModels(b.name)
    .then(function (data) {
      var list = (data && data.models) || [];
      var seen = {};
      var existed = {};
      for (var q = 0; q < mSelect.options.length; q++) existed[mSelect.options[q].value] = true;
      for (var k = 0; k < list.length; k++) {
        if (existed[list[k]] || seen[list[k]]) continue;
        seen[list[k]] = true;
        var op = makeEl('option', '', esc(list[k]));
        op.value = list[k];
        mSelect.appendChild(op);
      }
    })
    .catch(function () { /* 下拉退化到配置列表，不影响保存 */ });

  // 密钥
  var kLabel = makeEl('label', '', 'API Key');
  kLabel.setAttribute('for', 'ak_' + b.name);
  var kInput = makeEl('input');
  kInput.type = 'password';
  kInput.id = 'ak_' + b.name;
  kInput.placeholder = '留空则不修改';
  kInput.autocomplete = 'off';
  card.appendChild(kLabel);
  card.appendChild(kInput);
  if (b.key_set) {
    card.appendChild(makeEl('p', 'field-help',
      '已保存：' + esc(b.key_masked || '') + '（只显示掩码，明文不可读回）'));
  }

  // 设为默认
  var defBtn = makeEl('button', 'btn ghost small', '设为默认后端');
  var defMsg = makeEl('span', 'msg');
  defBtn.addEventListener('click', function () {
    defBtn.disabled = true;
    saveAdminConfig({ default_backend: b.name })
      .then(function () {
        defMsg.textContent = '已设为默认 ✅';
        defMsg.className = 'msg ok';
        refreshCurrent();
      })
      .catch(function (e) {
        defMsg.textContent = humanizeError(e);
        defMsg.className = 'msg err';
      })
      .then(function () { defBtn.disabled = false; });
  });
  var bar = makeEl('div', 'actions');
  bar.appendChild(defBtn);
  bar.appendChild(defMsg);
  card.appendChild(bar);

  forms.push({
    name: b.name,
    collect: function () {
      var out = {};
      out.base_url = urlInput.value.trim();       // 空串 = 删除覆盖（服务端已定义）
      if (protoSelect) out.protocol = protoSelect.value;
      out.default_model = mInput.value.trim();
      out.api_key = kInput.value;                 // 空串 = 不改
      return out;
    },
  });
  return card;
}

/* ================================================================
   M3 App 下发配置：表单 + 真实 JSON 预览 + 5 项自检
   ================================================================ */

function renderAppConfig(root) {
  var formCard = makeEl('div', 'card',
    '<h2>下发配置</h2><p class="hint">写入 settings.json 的 app 段（无任何密钥；同步配置见「同步配置」页）</p>');
  formCard.appendChild(makeEl('div', 'spinner', '加载中…'));
  var previewCard = makeEl('div', 'card',
    '<h2>真实下发内容</h2><p class="hint">GET /v1/app/config —— App 启动时看到的就是这一段</p>');
  previewCard.appendChild(makeEl('div', 'spinner', '加载中…'));
  var checkCard = makeEl('div', 'card',
    '<h2>自检</h2><p class="hint">5 项：端点可达 / schema / base_url / 无密钥泄露 / 必需字段</p>');
  checkCard.appendChild(makeEl('div', 'spinner', '加载中…'));
  root.appendChild(formCard);
  root.appendChild(previewCard);
  root.appendChild(checkCard);

  Promise.all([adminConfig(), appConfig()]).then(function (res) {
    var cfg = res[0] || {};
    var pushed = res[1] || {};
    var app = cfg.app || {};
    var timeouts = app.timeouts || {};

    formCard.innerHTML = '<h2>下发配置</h2><p class="hint">写入 settings.json 的 app 段（无任何密钥；同步配置见「同步配置」页）</p>';

    var nameLabel = makeEl('label', '', '服务显示名');
    var nameInput = makeEl('input');
    nameInput.type = 'text';
    nameInput.value = app.service_name || '';
    nameInput.placeholder = 'AIMindTree AI 服务';
    formCard.appendChild(nameLabel);
    formCard.appendChild(nameInput);

    var urlLabel = makeEl('label', '', '管理后台地址 console_url');
    var urlInput = makeEl('input');
    urlInput.type = 'text';
    urlInput.value = app.console_url || '';
    urlInput.placeholder = '留空则自动用 base_url + /admin';
    formCard.appendChild(urlLabel);
    formCard.appendChild(urlInput);

    var tRow = makeEl('div', 'row');
    var tFields = [['structured_s', '结构化任务超时（秒）'],
                   ['chat_s', '会话超时（秒）'],
                   ['connect_s', '连接超时（秒）']];
    var tInputs = {};
    for (var i = 0; i < tFields.length; i++) {
      var col = makeEl('div', '');
      var lb = makeEl('label', '', esc(tFields[i][1]));
      var inp = makeEl('input');
      inp.type = 'number';
      inp.min = '1';
      inp.value = timeouts[tFields[i][0]] !== undefined ? timeouts[tFields[i][0]] : 120;
      col.appendChild(lb);
      col.appendChild(inp);
      tRow.appendChild(col);
      tInputs[tFields[i][0]] = inp;
    }
    formCard.appendChild(tRow);

    var bar = makeEl('div', 'actions');
    var saveBtn = makeEl('button', 'btn', '保存');
    var msg = makeEl('span', 'msg');
    saveBtn.addEventListener('click', function () {
      saveBtn.disabled = true;
      msg.className = 'msg';
      msg.textContent = '保存中…';
      var body = {
        app: {
          service_name: nameInput.value.trim(),
          console_url: urlInput.value.trim(),
          timeouts: {},
        },
      };
      for (var key in tInputs) {
        if (!Object.prototype.hasOwnProperty.call(tInputs, key)) continue;
        body.app.timeouts[key] = Number(tInputs[key].value);
      }
      saveAdminConfig(body)
        .then(function () {
          msg.textContent = '已保存 ✅';
          msg.className = 'msg ok';
          refreshCurrent();
        })
        .catch(function (e) {
          msg.textContent = humanizeError(e);
          msg.className = 'msg err';
        })
        .then(function () { saveBtn.disabled = false; });
    });
    bar.appendChild(saveBtn);
    bar.appendChild(msg);
    formCard.appendChild(bar);

    // ---- 真实下发预览 ----
    previewCard.innerHTML = '<h2>真实下发内容</h2><p class="hint">GET /v1/app/config —— App 启动时看到的就是这一段</p>';
    var text = JSON.stringify(pushed, null, 2);
    var pre = makeEl('pre', '', esc(text));
    previewCard.appendChild(pre);
    var pbar = makeEl('div', 'actions');
    var copyBtn = makeEl('button', 'btn ghost', '复制 JSON');
    var cmsg = makeEl('span', 'msg');
    copyBtn.addEventListener('click', function () {
      copyText(text)
        .then(function () { cmsg.textContent = '已复制 ✅'; cmsg.className = 'msg ok'; })
        .catch(function () { cmsg.textContent = '复制失败（请手动选中）'; cmsg.className = 'msg err'; });
    });
    pbar.appendChild(copyBtn);
    pbar.appendChild(cmsg);
    pbar.appendChild(makeEl('span', 'small muted', 'sha1 ' + esc(String(pushed.config_sha1 || '').slice(0, 12)) +
      ' · 更新于 ' + esc(pushed.updated_at || '—')));
    previewCard.appendChild(pbar);

    // ---- 5 项自检 ----
    renderSelfCheck(checkCard, pushed, text);
  }).catch(function (e) {
    formCard.innerHTML = '<h2>下发配置</h2>';
    cardError(formCard, e, function () { refreshCurrent(); });
    previewCard.innerHTML = '<h2>真实下发内容</h2>';
    cardError(previewCard, e, function () { refreshCurrent(); });
    checkCard.innerHTML = '<h2>自检</h2>';
    cardError(checkCard, e, function () { refreshCurrent(); });
  });
}

/** M3 的 5 项自检。 */
function renderSelfCheck(card, pushed, rawText) {
  card.innerHTML = '<h2>自检</h2><p class="hint">5 项：端点可达 / schema / base_url / 无密钥泄露 / 必需字段</p>';

  var lines = [];

  // ① 端点可达（本页能拿到数据即证明）
  lines.push({ state: 'pass', text: '端点可达：GET /v1/app/config 返回 200' });

  // ② schema
  lines.push(pushed.schema === 1
    ? { state: 'pass', text: 'schema = 1（App 只识别 1）' }
    : { state: 'fail', text: 'schema 不是 1（实际 ' + pushed.schema + '），App 会按「不支持下发」降级' });

  // ③ base_url 形如 http(s)://host:port
  var bu = String(pushed.base_url || '');
  lines.push(/^https?:\/\/[^\s/]+(:\d+)?$/.test(bu)
    ? { state: 'pass', text: 'base_url 合法：' + bu }
    : { state: 'fail', text: 'base_url 不合法：' + (bu || '(空)') });

  // ④ 无密钥泄露（可选：用户粘贴一段已知密钥片段做比对）
  var leakWrap = makeEl('div', 'mb');
  leakWrap.appendChild(makeEl('label', '', '已知密钥片段（可选，粘贴后做包含比对）'));
  var leakInput = makeEl('input');
  leakInput.type = 'password';
  leakInput.placeholder = '粘贴 .env 里的密钥片段；留空则显示「未校验」';
  leakInput.autocomplete = 'off';
  leakWrap.appendChild(leakInput);
  var leakLine = makeEl('div', 'check-line unknown');
  leakLine.innerHTML = '<span class="mark">?</span><span>响应体无密钥泄露 —— 未校验（未提供比对串）</span>';
  leakInput.addEventListener('input', function () {
    var v = leakInput.value.trim();
    if (!v) {
      leakLine.className = 'check-line unknown';
      leakLine.innerHTML = '<span class="mark">?</span><span>响应体无密钥泄露 —— 未校验（未提供比对串）</span>';
      return;
    }
    var hit = rawText.indexOf(v) >= 0;
    leakLine.className = 'check-line ' + (hit ? 'fail' : 'pass');
    leakLine.innerHTML = '<span class="mark">' + (hit ? '✗' : '✓') + '</span><span>' +
      (hit ? '⚠️ 密钥片段出现在下发体里（立即排查！）' : '响应体无密钥泄露（比对串 0 命中）') + '</span>';
  });
  leakWrap.appendChild(leakLine);

  // ⑤ 必需字段齐全
  var required = ['schema', 'server_version', 'service_name', 'protocol', 'base_url',
                  'backend', 'model', 'console_url', 'timeouts', 'task_backends',
                  'sync', 'config_sha1', 'updated_at'];
  var missing = required.filter(function (k) { return !(k in pushed); });
  lines.push(missing.length === 0
    ? { state: 'pass', text: '必需字段齐全（13/13）' }
    : { state: 'fail', text: '缺少字段：' + missing.join('、') });

  var box = makeEl('div', '');
  for (var i = 0; i < lines.length; i++) {
    var ln = makeEl('div', 'check-line ' + lines[i].state);
    ln.innerHTML = '<span class="mark">' + (lines[i].state === 'pass' ? '✓' : '✗') + '</span><span>' +
      esc(lines[i].text) + '</span>';
    box.appendChild(ln);
  }
  card.appendChild(box);
  card.appendChild(leakWrap);
}

/* ================================================================
   M8 同步配置（Supabase）：base_url / token / enabled
   GET/PUT /v1/admin/sync。语义：文本框留空 = 不修改已保存值；
   「清空令牌」= 删除已保存令牌（token_set 变 false）。
   ================================================================ */

function renderSync(root) {
  var formCard = makeEl('div', 'card',
    '<h2>同步配置</h2><p class="hint">GET/PUT /v1/admin/sync —— 写入 settings.json 的 sync 段（config.yaml 永不被写入）</p>');
  formCard.appendChild(makeEl('div', 'spinner', '加载中…'));
  var previewCard = makeEl('div', 'card',
    '<h2>App 实际收到的 sync 段</h2><p class="hint">GET /v1/app/config · sync —— App 启动时看到的就是这一段</p>');
  previewCard.appendChild(makeEl('div', 'spinner', '加载中…'));
  root.appendChild(formCard);
  root.appendChild(previewCard);

  Promise.all([adminSync(), appConfig()]).then(function (res) {
    var sync = res[0] || {};
    var pushed = (res[1] || {}).sync || {};

    formCard.innerHTML = '<h2>同步配置</h2><p class="hint">GET/PUT /v1/admin/sync —— 写入 settings.json 的 sync 段（config.yaml 永不被写入）</p>';

    var urlLabel = makeEl('label', '', '同步地址 base_url');
    var urlInput = makeEl('input');
    urlInput.type = 'text';
    urlInput.value = sync.base_url || '';
    urlInput.placeholder = 'https://<project>.supabase.co';
    formCard.appendChild(urlLabel);
    formCard.appendChild(urlInput);

    var enWrap = makeEl('div', 'mt');
    var enInput = makeEl('input');
    enInput.type = 'checkbox';
    enInput.id = 'syncEnabled';
    enInput.checked = sync.enabled !== false; // 缺省/未传按 true
    var enLabel = makeEl('label', 'small nowrap', '启用同步 enabled');
    enLabel.htmlFor = 'syncEnabled';
    enLabel.style.margin = '0';
    enWrap.appendChild(enInput);
    enWrap.appendChild(enLabel);
    formCard.appendChild(enWrap);

    var tokLabel = makeEl('label', '', '同步令牌 token');
    var tokInput = makeEl('input');
    tokInput.type = 'password';
    tokInput.autocomplete = 'off';
    tokInput.placeholder = sync.token_set
      ? '已设置（' + (sync.token_masked || '') + '），留空 = 不修改'
      : '（未设置）';
    formCard.appendChild(tokLabel);
    formCard.appendChild(tokInput);

    formCard.appendChild(makeEl('p', 'field-help',
      '语义：文本框留空 = 不修改已保存值；点「清空令牌」= 删除已保存令牌。' +
      '令牌只写不读：管理接口永不回显明文（只有 token_set / token_masked）。'));

    var bar = makeEl('div', 'actions');
    var saveBtn = makeEl('button', 'btn', '保存');
    var clearBtn = makeEl('button', 'btn ghost', '清空令牌');
    var msg = makeEl('span', 'msg');
    bar.appendChild(saveBtn);
    bar.appendChild(clearBtn);
    bar.appendChild(msg);
    formCard.appendChild(bar);

    saveBtn.addEventListener('click', function () {
      saveBtn.disabled = true;
      clearBtn.disabled = true;
      msg.className = 'msg';
      msg.textContent = '保存中…';
      var body = { base_url: urlInput.value.trim(), enabled: enInput.checked };
      if (tokInput.value) body.token = tokInput.value;
      saveSync(body)
        .then(function () {
          msg.textContent = '已保存 ✅';
          msg.className = 'msg ok';
          refreshCurrent();
        })
        .catch(function (e) {
          msg.textContent = humanizeError(e);
          msg.className = 'msg err';
        })
        .then(function () { saveBtn.disabled = false; clearBtn.disabled = false; });
    });

    clearBtn.addEventListener('click', function () {
      saveBtn.disabled = true;
      clearBtn.disabled = true;
      msg.className = 'msg';
      msg.textContent = '清空中…';
      saveSync({ token: '' })
        .then(function () {
          msg.textContent = '令牌已清空 ✅';
          msg.className = 'msg ok';
          refreshCurrent();
        })
        .catch(function (e) {
          msg.textContent = humanizeError(e);
          msg.className = 'msg err';
        })
        .then(function () { saveBtn.disabled = false; clearBtn.disabled = false; });
    });

    /* ---- App 实际收到的 sync 段（含 token 明文的真实下发内容） ---- */
    previewCard.innerHTML = '<h2>App 实际收到的 sync 段</h2><p class="hint">GET /v1/app/config · sync —— App 启动时看到的就是这一段</p>';
    var kv = makeEl('div', 'kv');
    kv.innerHTML =
      '<div><span class="k">base_url</span><span class="mono">' + esc(pushed.base_url || '（空）') + '</span></div>' +
      '<div><span class="k">enabled</span>' + (pushed.enabled ? badge('ok', 'true') : badge('grey', 'false')) + '</div>' +
      '<div><span class="k">token</span>' + (pushed.token
        ? badge('warn', '明文随配置下发') + ' <span class="mono">' + esc(pushed.token) + '</span>'
        : badge('grey', 'null（未设置）')) + '</div>' +
      '<div><span class="k">token_set</span>' + (pushed.token_set ? badge('ok', 'true') : badge('grey', 'false')) + '</div>';
    previewCard.appendChild(kv);
    previewCard.appendChild(makeEl('pre', '', esc(JSON.stringify(pushed, null, 2))));
    previewCard.appendChild(makeEl('p', 'field-help',
      '安全假设：llm_server 仅绑 127.0.0.1（localhost，无外网暴露），sync.token 随配置明文下发；' +
      '若服务端将来对非 localhost 暴露，需重评此处置（见 core/app_config.py 注释）。'));
  }).catch(function (e) {
    formCard.innerHTML = '<h2>同步配置</h2>';
    cardError(formCard, e, function () { refreshCurrent(); });
    previewCard.innerHTML = '<h2>App 实际收到的 sync 段</h2>';
    cardError(previewCard, e, function () { refreshCurrent(); });
  });
}
