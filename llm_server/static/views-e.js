/* M11 云端同步：云端中继（Cloudflare / Netlify …）上的账号与同步数据。
   依赖 api.js（adminRelayConfig / relayStats / relayUsers / relayReset /
   relayDeleteUser / relayExport / esc / badge / toast / fmtTime …）。

   为什么要这个面板：App 的「账号 + 用户数据同步」在云端（Workers+D1 /
   Netlify Blobs …），只能去云控制台看，Netlify Blobs 甚至没有图形界面。
   这里经本地 llm_server 代理中继的管理 API（/v1/admin/relay/*），
   在一个页面里看概览、看用户表、导出、以及做危险清理。

   约定：
   - 令牌只写不读：placeholder 只显示「已配置 abc…xyz」；
   - 失败时把上游原文显示出来（relayErrText：HTTP 状态 + rawBody），不吞错；
   - 危险操作必须弹输入框手输 RESET（relayPrompt：取原生 prompt 的引用，
     详见该函数注释），删除用户必须 window.confirm()。 */

"use strict";

/* 后端名 → 一行说明（云控制台各自叫什么，方便对照排查）。 */
var RELAY_BACKEND_LABEL = {
  cloudflare: 'Cloudflare Workers + D1',
  netlify: 'Netlify Functions + Blobs',
  vercel: 'Vercel + KV',
  edgeone: '腾讯 EdgeOne + KV',
  cloudbase: '腾讯 CloudBase + 文档数据库',
};

var RELAY_HEAD_CFG = '<h2>中继连接</h2><p class="hint">GET/PUT /v1/admin/relay/config'
  + ' —— 写入 settings.json 的 relay_admin 段；令牌只写不读（只回 token_masked），'
  + '代理地址明文回显</p>';
var RELAY_HEAD_STAT = '<h2>数据概览</h2><p class="hint">GET /v1/admin/relay/stats'
  + ' —— 云端中继实时统计（用户 / 令牌 / 同步行数）</p>';
var RELAY_HEAD_USERS = '<h2>用户与同步数据</h2><p class="hint">GET /v1/admin/relay/users'
  + ' —— 点击某行选中，再在下方「危险操作」里重置该用户</p>';
var RELAY_HEAD_DANGER = '<h2>危险操作</h2><p class="hint">不可撤销 · 每次都要在弹窗里手输'
  + ' RESET 才会真正发请求</p>';

/** 上游错误原文（HTTP 状态 + body），解析不出结构就整段显示。 */
function relayErrText(e) {
  if (!e || !e.rawBody) return humanizeError(e);
  var text = String(e.rawBody).trim();
  try {
    var j = JSON.parse(text);
    if (j && typeof j === 'object') {
      if (typeof j.error === 'string') {
        text = j.error;
      } else if (j.error && typeof j.error === 'object') {
        text = (j.error.message || '') + (j.error.code ? '（' + j.error.code + '）' : '');
      }
    }
  } catch (err) {
    // 非 JSON（HTML 错误页 / 纯文本）→ 保留原文
  }
  var status = e.status ? 'HTTP ' + e.status + ' · ' : '';
  return status + (text.length > 600 ? text.slice(0, 600) + '…' : text);
}

/** 错误卡片下方的「上游原文」小字：只在透传错误（非本服务归一化错误）时补一行。 */
function relayRawLine(box, e) {
  if (!e || !e.rawBody) return;
  if (e.code !== 'upstream_error' && e.code !== 'internal') return;
  box.appendChild(makeEl('p', 'small mono', esc(relayErrText(e))));
}

/** 取浏览器**原生** prompt 的返回值（取消 / 无原生对话框都返回 null）。
 *
 * ⚠️ 不能用 ``window.prompt``：api.js 顶层的全局 ``function prompt(task, variant)``
 * 会把浏览器的 ``window.prompt`` 覆盖掉（同名全局函数声明），直接调会拿到一个
 * Promise。index.html 在加载 api.js **之前**把原生 prompt 存进了
 * ``window.__nativePrompt``；万一没有（单独嵌页面），退化成 confirm 兜底。
 */
function relayPrompt(message) {
  if (typeof window.__nativePrompt === 'function') return window.__nativePrompt(message, '');
  if (typeof window.confirm === 'function') {
    return window.confirm(message + '\n\n（当前环境没有输入框：点「确定」= 输入 RESET）')
      ? 'RESET'
      : null;
  }
  return null;
}

function renderRelay(root) {
  var state = {
    configs: [],      // [{name, base_url, token_set, token_masked, configured}]
    backend: '',      // 当前选中的后端名
    users: [],        // 当前后端的用户列表
    selectedUser: '', // 表格里选中的 user_id（危险区「重置选中用户」用）
  };
  var dangerMsg; // 危险区结果行（先声明：renderUsers 选中行时也会写它）

  /* ---------- 卡 1：中继连接 ---------- */
  var cfgCard = makeEl('div', 'card');
  cfgCard.innerHTML = RELAY_HEAD_CFG;
  var cfgBody = makeEl('div', '');
  cfgBody.appendChild(makeEl('div', 'spinner', '加载中…'));
  cfgCard.appendChild(cfgBody);
  root.appendChild(cfgCard);

  /* ---------- 卡 2：概览 ---------- */
  var statCard = makeEl('div', 'card');
  statCard.innerHTML = RELAY_HEAD_STAT;
  var statBody = makeEl('div', '');
  statBody.appendChild(makeEl('div', 'spinner', '等待选择中继后端…'));
  statCard.appendChild(statBody);
  root.appendChild(statCard);

  /* ---------- 卡 3：用户表 ---------- */
  var userCard = makeEl('div', 'card');
  userCard.innerHTML = RELAY_HEAD_USERS;
  var userBody = makeEl('div', '');
  userBody.appendChild(makeEl('div', 'spinner', '等待选择中继后端…'));
  userCard.appendChild(userBody);
  root.appendChild(userCard);

  /* ---------- 卡 4：危险区 ---------- */
  var dangerCard = makeEl('div', 'card danger-zone');
  dangerCard.innerHTML = RELAY_HEAD_DANGER;
  root.appendChild(dangerCard);

  /* ---------- 配置表单（结构只建一次，切换后端只改值） ---------- */
  var row = makeEl('div', 'row');
  var colSel = makeEl('div', '');
  var lbSel = makeEl('label', '', '中继后端');
  var sel = makeEl('select');
  colSel.appendChild(lbSel);
  colSel.appendChild(sel);
  var colUrl = makeEl('div', '');
  var lbUrl = makeEl('label', '', '管理 API 地址 base_url');
  var urlInput = makeEl('input');
  urlInput.type = 'text';
  urlInput.placeholder = 'https://<中继域名>（管理接口前缀 /admin）';
  colUrl.appendChild(lbUrl);
  colUrl.appendChild(urlInput);
  row.appendChild(colSel);
  row.appendChild(colUrl);

  var lbTok = makeEl('label', '', '管理令牌 ADMIN_TOKEN');
  var tokInput = makeEl('input');
  tokInput.type = 'password';
  tokInput.autocomplete = 'off';

  var lbProxy = makeEl('label', '', '出站代理（可选，留空 = 直连）');
  var proxyInput = makeEl('input');
  proxyInput.type = 'text';
  proxyInput.autocomplete = 'off';
  proxyInput.placeholder = 'http://127.0.0.1:7890';

  var bar = makeEl('div', 'actions');
  var saveBtn = makeEl('button', 'btn', '保存');
  var testBtn = makeEl('button', 'btn ghost', '测试连接');
  var clearBtn = makeEl('button', 'btn ghost', '清空令牌');
  var clearProxyBtn = makeEl('button', 'btn ghost', '清空代理');
  var cfgMsg = makeEl('span', 'msg');
  bar.appendChild(saveBtn);
  bar.appendChild(testBtn);
  bar.appendChild(clearBtn);
  bar.appendChild(clearProxyBtn);
  bar.appendChild(cfgMsg);

  cfgBody.innerHTML = '';
  cfgBody.appendChild(row);
  cfgBody.appendChild(lbProxy);
  cfgBody.appendChild(proxyInput);
  cfgBody.appendChild(lbTok);
  cfgBody.appendChild(tokInput);
  cfgBody.appendChild(makeEl('p', 'field-help',
    '令牌只写不读：管理接口永不回显明文（只有 token_set / token_masked）。'
    + '文本框留空 = 不修改已保存值；点「清空令牌」= 删除。'
    + '中继侧未配置 ADMIN_TOKEN 时，其 /admin/* 一律 404。'));
  cfgBody.appendChild(makeEl('p', 'field-help',
    '出站代理：本服务转发时**不吃环境变量里的代理**（trust_env=False），'
    + '所以访问 *.workers.dev 需要走代理的机器必须在这里显式填（例如 '
    + 'http://127.0.0.1:7890）；留空 = 直连。代理地址会明文回显，便于修改。'));
  cfgBody.appendChild(bar);

  /* ---------- 工具 ---------- */

  function cfgOf(name) {
    for (var i = 0; i < state.configs.length; i++) {
      if (state.configs[i].name === name) return state.configs[i];
    }
    return null;
  }

  function fillForm() {
    var c = cfgOf(state.backend) || {};
    urlInput.value = c.base_url || '';
    proxyInput.value = c.proxy || '';
    tokInput.value = '';
    tokInput.placeholder = c.token_set
      ? '已配置 ' + (c.token_masked || '') + '，留空 = 不修改'
      : '（未配置，粘贴中继的 ADMIN_TOKEN）';
  }

  /** 概览卡：5 个数据块（用户 / 令牌 / 行数 / 存储 / 服务器时间）。 */
  function renderStats(s) {
    statBody.innerHTML = '';
    if (!s) {
      statBody.appendChild(makeEl('p', 'muted small', '（没有统计数据）'));
      return;
    }
    var grid = makeEl('div', 'stat-grid');
    var tiles = [
      ['用户数', s.users],
      ['令牌数', s.tokens],
      ['数据行数', s.envelopes],
      ['存储类型', s.storage || '—'],
    ];
    tiles.forEach(function (t) {
      var tile = makeEl('div', 'stat');
      tile.innerHTML = '<div class="n">' +
        esc(t[1] === undefined || t[1] === null ? '—' : t[1]) +
        '</div><div class="l">' + esc(t[0]) + '</div>';
      grid.appendChild(tile);
    });
    var time = makeEl('div', 'stat');
    time.innerHTML = '<div class="n small">' + esc(s.server_time || '—') +
      '</div><div class="l">服务器时间</div>';
    grid.appendChild(time);
    statBody.appendChild(grid);

    var c = cfgOf(state.backend) || {};
    statBody.appendChild(makeEl('p', 'small muted',
      esc('出站代理：' + (c.proxy ? c.proxy : '直连（trust_env=False，不吃环境变量代理）'))));

    var per = s.per_user || [];
    if (per.length) {
      var chips = makeEl('div', 'chips mt');
      per.forEach(function (u) {
        chips.innerHTML += badge('grey', (u.username || u.user_id || '?') +
          ' · ' + (u.envelopes || 0) + ' 行 / ' + (u.tokens || 0) + ' 令牌');
      });
      statBody.appendChild(chips);
    }
  }

  function renderUsers(data) {
    state.users = (data && data.users) || [];
    state.selectedUser = '';
    userBody.innerHTML = '';
    if (!state.users.length) {
      userBody.appendChild(makeEl('p', 'muted small',
        '云端还没有任何账号（App 首次推送后才会出现）。'));
      return;
    }
    var html = '<table><thead><tr>'
      + '<th>用户名</th>'
      + '<th>user_id（可复制）</th>'
      + '<th style="width:78px">令牌数</th>'
      + '<th style="width:78px">行数</th>'
      + '<th style="width:158px">创建时间</th>'
      + '<th style="width:132px">操作</th>'
      + '</tr></thead><tbody>';
    state.users.forEach(function (u) {
      html += '<tr class="relay-row" data-uid="' + esc(u.user_id || '') + '">'
        + '<td>' + esc(u.username || '—') + '</td>'
        + '<td class="mono" title="点击复制">' + esc(u.user_id || '—') + '</td>'
        + '<td>' + esc(u.tokens || 0) + '</td>'
        + '<td>' + esc(u.envelopes || 0) + '</td>'
        + '<td class="small nowrap">' + esc(fmtTime(u.created_at)) + '</td>'
        + '<td class="nowrap">'
        + '<button class="btn small ghost" data-export="' + esc(u.user_id || '') + '">导出</button> '
        + '<button class="btn small danger" data-del="' + esc(u.user_id || '') + '">删除</button>'
        + '</td></tr>';
    });
    html += '</tbody></table>';
    var box = makeEl('div', '', html);
    userBody.appendChild(box);
    userBody.appendChild(makeEl('p', 'field-help',
      '点击行 = 选中（用于「重置选中用户」）；点 user_id 可复制；删除会连令牌与全部同步数据一起删。'));

    box.querySelectorAll('tr.relay-row').forEach(function (tr) {
      tr.addEventListener('click', function (ev) {
        if (ev.target && ev.target.tagName === 'BUTTON') return;
        var uid = tr.getAttribute('data-uid') || '';
        state.selectedUser = (state.selectedUser === uid) ? '' : uid;
        box.querySelectorAll('tr.relay-row').forEach(function (other) {
          other.classList.toggle('selected',
            other.getAttribute('data-uid') === state.selectedUser);
        });
        dangerMsg.className = 'msg';
        dangerMsg.textContent = state.selectedUser
          ? '已选中用户 ' + state.selectedUser
          : '';
      });
    });

    box.querySelectorAll('td.mono[title]').forEach(function (td) {
      td.addEventListener('click', function (ev) {
        ev.stopPropagation();
        copyText(td.textContent.trim())
          .then(function () { toast(root, 'user_id 已复制', 'ok'); })
          .catch(function () { toast(root, '复制失败（请手动选中）', 'err'); });
      });
    });

    box.querySelectorAll('button[data-export]').forEach(function (btn) {
      btn.addEventListener('click', function (ev) {
        ev.stopPropagation();
        doExport(btn.getAttribute('data-export') || '');
      });
    });

    box.querySelectorAll('button[data-del]').forEach(function (btn) {
      btn.addEventListener('click', function (ev) {
        ev.stopPropagation();
        doDelete(btn.getAttribute('data-del') || '');
      });
    });
  }

  /* ---------- 数据加载 ---------- */

  function loadConfig() {
    return adminRelayConfig().then(function (data) {
      state.configs = (data && data.backends) || [];
      sel.innerHTML = '';
      state.configs.forEach(function (b) {
        var o = document.createElement('option');
        o.value = b.name;
        o.textContent = b.name
          + (RELAY_BACKEND_LABEL[b.name] ? '（' + RELAY_BACKEND_LABEL[b.name] + '）' : '')
          + (b.configured ? ' · 已配置' : ' · 未配置');
        sel.appendChild(o);
      });
      var want = state.backend;
      if (!want || !cfgOf(want)) {
        want = '';
        for (var i = 0; i < state.configs.length; i++) {
          if (state.configs[i].configured) { want = state.configs[i].name; break; }
        }
        if (!want) want = state.configs.length ? state.configs[0].name : '';
      }
      state.backend = want;
      sel.value = want;
      fillForm();
    });
  }

  function loadStats() {
    var be = state.backend;
    statBody.innerHTML = '';
    statBody.appendChild(makeEl('div', 'spinner', '加载中…'));
    if (!be) {
      statBody.innerHTML = '';
      statBody.appendChild(makeEl('p', 'muted small', '（没有可用的中继后端）'));
      return;
    }
    relayStats(be)
      .then(function (s) { if (be === state.backend) renderStats(s); })
      .catch(function (e) {
        if (be !== state.backend) return;
        statBody.innerHTML = '';
        cardError(statBody, e, function () { loadStats(); });
        relayRawLine(statBody, e);
      });
  }

  function loadUsers() {
    var be = state.backend;
    userBody.innerHTML = '';
    userBody.appendChild(makeEl('div', 'spinner', '加载中…'));
    if (!be) {
      userBody.innerHTML = '';
      userBody.appendChild(makeEl('p', 'muted small', '（没有可用的中继后端）'));
      return;
    }
    relayUsers(be)
      .then(function (d) { if (be === state.backend) renderUsers(d); })
      .catch(function (e) {
        if (be !== state.backend) return;
        userBody.innerHTML = '';
        cardError(userBody, e, function () { loadUsers(); });
        relayRawLine(userBody, e);
      });
  }

  function reloadData() {
    loadStats();
    loadUsers();
  }

  /* ---------- 配置动作 ---------- */

  sel.addEventListener('change', function () {
    state.backend = sel.value;
    state.selectedUser = '';
    fillForm();
    cfgMsg.className = 'msg';
    cfgMsg.textContent = '';
    reloadData();
  });

  saveBtn.addEventListener('click', function () {
    saveBtn.disabled = true;
    testBtn.disabled = true;
    clearBtn.disabled = true;
    clearProxyBtn.disabled = true;
    cfgMsg.className = 'msg';
    cfgMsg.textContent = '保存中…';
    // proxy 是明文普通配置 → 每次都提交（清空输入框 = 直连）；
    // token 只写不读 → 留空 = 不修改。
    var body = {
      backend: state.backend,
      base_url: urlInput.value.trim(),
      proxy: proxyInput.value.trim(),
    };
    if (tokInput.value) body.token = tokInput.value;
    saveRelayConfig(body)
      .then(function (data) {
        state.configs = (data && data.backends) || state.configs;
        // 重建下拉文案（「已配置 / 未配置」会变），并保持当前后端选中
        var keep = state.backend;
        return loadConfig().then(function () {
          state.backend = keep;
          sel.value = keep;
          fillForm();
          cfgMsg.textContent = '已保存 ✅';
          cfgMsg.className = 'msg ok';
          reloadData();
        });
      })
      .catch(function (e) {
        cfgMsg.textContent = '保存失败：' + relayErrText(e);
        cfgMsg.className = 'msg err';
      })
      .then(function () {
        saveBtn.disabled = false;
        testBtn.disabled = false;
        clearBtn.disabled = false;
        clearProxyBtn.disabled = false;
      });
  });

  clearBtn.addEventListener('click', function () {
    if (!window.confirm('确认清空 ' + state.backend + ' 的管理令牌？清空后不能再拉云端数据。')) return;
    saveBtn.disabled = true;
    testBtn.disabled = true;
    clearBtn.disabled = true;
    clearProxyBtn.disabled = true;
    cfgMsg.className = 'msg';
    cfgMsg.textContent = '清空中…';
    saveRelayConfig({ backend: state.backend, token: '' })
      .then(function () {
        return loadConfig().then(function () {
          state.backend = sel.value;
          fillForm();
          cfgMsg.textContent = '令牌已清空 ✅';
          cfgMsg.className = 'msg ok';
          reloadData();
        });
      })
      .catch(function (e) {
        cfgMsg.textContent = '清空失败：' + relayErrText(e);
        cfgMsg.className = 'msg err';
      })
      .then(function () {
        saveBtn.disabled = false;
        testBtn.disabled = false;
        clearBtn.disabled = false;
        clearProxyBtn.disabled = false;
      });
  });

  clearProxyBtn.addEventListener('click', function () {
    cfgMsg.className = 'msg';
    cfgMsg.textContent = '清空代理中…';
    saveBtn.disabled = true;
    clearProxyBtn.disabled = true;
    saveRelayConfig({ backend: state.backend, proxy: '' })
      .then(function (data) {
        state.configs = (data && data.backends) || state.configs;
        var keep = state.backend;
        return loadConfig().then(function () {
          state.backend = keep;
          sel.value = keep;
          fillForm();
          cfgMsg.textContent = '代理已清空（回到直连）✅';
          cfgMsg.className = 'msg ok';
          reloadData();
        });
      })
      .catch(function (e) {
        cfgMsg.textContent = '清空代理失败：' + relayErrText(e);
        cfgMsg.className = 'msg err';
      })
      .then(function () {
        saveBtn.disabled = false;
        clearProxyBtn.disabled = false;
      });
  });

  testBtn.addEventListener('click', function () {
    var c = cfgOf(state.backend);
    if (!c || !c.configured) {
      cfgMsg.className = 'msg err';
      cfgMsg.textContent = '还没保存 base_url + 令牌：先点「保存」再测试连接。';
      return;
    }
    // 测试用**已保存**的配置（输入框里未保存的改动不参与）
    var dirty = (urlInput.value.trim() !== (c.base_url || ''))
      || (proxyInput.value.trim() !== (c.proxy || ''))
      || !!tokInput.value;
    testBtn.disabled = true;
    cfgMsg.className = 'msg';
    cfgMsg.textContent = '连接中…';
    relayPing(state.backend)
      .then(function (r) {
        var info = r || {};
        cfgMsg.className = 'msg ok';
        cfgMsg.textContent = '连接正常 ✅ 存储 ' + (info.storage || '?')
          + ' · 服务器时间 ' + (info.server_time || '—')
          + (dirty ? '（用的是已保存配置，输入框里的改动尚未保存）' : '');
      })
      .catch(function (e) {
        cfgMsg.className = 'msg err';
        cfgMsg.textContent = '连接失败：' + relayErrText(e);
      })
      .then(function () { testBtn.disabled = false; });
  });

  /* ---------- 单用户动作 ---------- */

  function doExport(uid) {
    relayExport(state.backend, uid)
      .then(function (data) {
        var text = JSON.stringify(data, null, 2);
        var blob = new Blob([text], { type: 'application/json' });
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = 'relay-export-' + (uid || 'all') + '.json';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        setTimeout(function () { URL.revokeObjectURL(url); }, 2000);
        var n = (data && data.envelopes) ? data.envelopes.length : 0;
        toast(root, '已导出 ' + n + ' 条'
          + (data && data.truncated ? '（上游标记 truncated，可能被截断）' : ''), 'ok');
      })
      .catch(function (e) {
        toast(root, '导出失败：' + relayErrText(e), 'err');
      });
  }

  function doDelete(uid) {
    if (!uid) return;
    if (!window.confirm('确认删除云端用户 ' + uid + '？\n\n'
      + '该账号的令牌与全部同步数据都会被删除，不可撤销。')) return;
    relayDeleteUser(uid, state.backend)
      .then(function (r) {
        var d = (r && r.deleted) || {};
        toast(root, '已删除：用户 ' + (d.users || 0) + ' · 令牌 ' + (d.tokens || 0)
          + ' · 数据 ' + (d.envelopes || 0), 'ok');
        reloadData();
      })
      .catch(function (e) {
        toast(root, '删除失败：' + relayErrText(e), 'err');
      });
  }

  /* ---------- 危险区 ---------- */

  dangerCard.appendChild(makeEl('p', 'small muted',
    'scope=all 会删「用户 + 令牌 + 同步数据」；scope=envelopes 只删同步数据（账号保留）；'
    + 'scope=user 只删表格里选中的那一个用户。执行结果会显示 deleted 计数。'));

  dangerMsg = makeEl('span', 'msg');
  var dBtn1 = makeEl('button', 'btn danger', '只清同步数据（envelopes）');
  var dBtn2 = makeEl('button', 'btn danger', '连账号一起清（all）');
  var dBtn3 = makeEl('button', 'btn ghost', '重置选中用户（user）');
  var dangerBar = makeEl('div', 'actions');
  dangerBar.appendChild(dBtn1);
  dangerBar.appendChild(dBtn2);
  dangerBar.appendChild(dBtn3);
  dangerBar.appendChild(dangerMsg);
  dangerCard.appendChild(dangerBar);

  function setDangerDisabled(flag) {
    dBtn1.disabled = flag;
    dBtn2.disabled = flag;
    dBtn3.disabled = flag;
  }

  /** 手输 RESET 才放行；返回输入的确认串 / null。 */
  function askReset(tip) {
    var typed = relayPrompt('危险操作：' + tip + '\n\n'
      + '请手输 RESET（全大写）确认，取消则不发请求：');
    if (typed === null || typed === undefined) {
      dangerMsg.className = 'msg';
      dangerMsg.textContent = '已取消';
      return null;
    }
    if (String(typed).trim() !== 'RESET') {
      dangerMsg.className = 'msg err';
      dangerMsg.textContent = '输入不是 RESET，已取消（没有发出请求）';
      return null;
    }
    return 'RESET';
  }

  function doReset(scope, userId, tip) {
    if (!state.backend) {
      dangerMsg.className = 'msg err';
      dangerMsg.textContent = '请先选择中继后端';
      return;
    }
    var confirmText = askReset(tip);
    if (!confirmText) return;
    var body = { backend: state.backend, scope: scope, confirm: confirmText };
    if (userId) body.user_id = userId;
    setDangerDisabled(true);
    dangerMsg.className = 'msg';
    dangerMsg.textContent = '执行中…（scope=' + scope + '）';
    relayReset(body)
      .then(function (r) {
        var d = (r && r.deleted) || {};
        dangerMsg.className = 'msg ok';
        dangerMsg.textContent = '已完成（scope=' + (r && r.scope ? r.scope : scope) + '）'
          + ' · 删除：用户 ' + (d.users || 0)
          + ' · 令牌 ' + (d.tokens || 0)
          + ' · 数据 ' + (d.envelopes || 0);
        toast(root, '云端数据已重置（' + scope + '）', 'ok');
        reloadData();
      })
      .catch(function (e) {
        dangerMsg.className = 'msg err';
        dangerMsg.textContent = '重置失败：' + relayErrText(e);
      })
      .then(function () { setDangerDisabled(false); });
  }

  dBtn1.addEventListener('click', function () {
    doReset('envelopes', '', '清空 ' + state.backend + ' 上**全部用户的同步数据**（账号与令牌保留）');
  });
  dBtn2.addEventListener('click', function () {
    doReset('all', '', '清空 ' + state.backend + ' 上**全部用户 + 令牌 + 同步数据**');
  });
  dBtn3.addEventListener('click', function () {
    if (!state.selectedUser) {
      dangerMsg.className = 'msg err';
      dangerMsg.textContent = '请先在上方用户表里点一行选中用户';
      return;
    }
    doReset('user', state.selectedUser,
      '删除用户 ' + state.selectedUser + ' 及其令牌 / 同步数据');
  });

  /* ---------- 启动 ---------- */

  loadConfig()
    .then(function () {
      reloadData();
    })
    .catch(function (e) {
      cfgBody.innerHTML = '';
      cfgBody.appendChild(makeEl('h2', '', '中继连接'));
      cardError(cfgBody, e, function () { refreshCurrent(); });
      cfgBody.appendChild(makeEl('p', 'small mono', esc(relayErrText(e))));
    });
}
