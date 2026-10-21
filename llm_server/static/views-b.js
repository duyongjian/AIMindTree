/* M4 任务路由 / M5 提示词管理 / M6 任务调试台。
   依赖 api.js（esc / badge / mountInto / cardError 等）。 */

"use strict";

/* ================================================================
   M4 任务路由
   ================================================================ */

function renderRoutes(root) {
  var card = makeEl('div', 'card',
    '<h2>任务路由</h2><p class="hint">GET/PUT /v1/admin/routes —— 把单个任务固定到指定后端 / 模型</p>');
  card.appendChild(makeEl('div', 'spinner', '加载中…'));
  root.appendChild(card);

  adminRoutes().then(function (data) {
    card.innerHTML = '<h2>任务路由</h2><p class="hint">GET/PUT /v1/admin/routes —— 把单个任务固定到指定后端 / 模型</p>';
    var backends = [];
    var byTask = {};

    var html = '<table><thead><tr>' +
      '<th>任务</th><th>形态</th><th>后端</th><th>模型（空=跟随全局）</th><th>建议后端</th>' +
      '</tr></thead><tbody>';
    var tasks = data.tasks || [];
    for (var i = 0; i < tasks.length; i++) {
      var t = tasks[i];
      var label = t.task + (t.variant ? ' · ' + t.variant : '');
      html += '<tr>' +
        '<td><b>' + esc(label) + '</b><div class="small muted mono">' +
        esc((t.inputs || []).join(', ')) + '</div></td>' +
        '<td>' + (t.structured ? badge('info', '结构化') : badge('grey', '会话')) + '</td>' +
        '<td><select class="r-backend" data-task="' + esc(t.task) + '"></select></td>' +
        '<td><input type="text" class="r-model" data-task="' + esc(t.task) + '" value="' +
        esc(t.model || '') + '" placeholder="留空 = 跟随全局" /></td>' +
        '<td class="mono small">' + esc(t.preferred_backend || '—') + '</td>' +
        '</tr>';
      byTask[t.task] = t;
    }
    html += '</tbody></table>';
    var tableWrap = makeEl('div', '', html);
    card.appendChild(tableWrap);

    // 后端下拉选项（先从 /v1/admin/config 拿名字，失败退化为空）
    adminConfig().then(function (cfg) {
      backends = (cfg.backends || []).map(function (b) { return b.name; });
      var sels = card.querySelectorAll('select.r-backend');
      for (var i = 0; i < sels.length; i++) {
        var sel = sels[i];
        var task = sel.getAttribute('data-task');
        var cur = (byTask[task] && byTask[task].backend) || '';
        var opt = makeEl('option', '', '跟随全局');
        opt.value = '';
        sel.appendChild(opt);
        for (var j = 0; j < backends.length; j++) {
          var o = makeEl('option', '', esc(backends[j]));
          o.value = backends[j];
          if (backends[j] === cur) o.selected = true;
          sel.appendChild(o);
        }
      }
    }).catch(function () { /* 下拉为空时前端不允许提交 */ });

    var bar = makeEl('div', 'actions');
    var saveBtn = makeEl('button', 'btn', '保存');
    var resetBtn = makeEl('button', 'btn ghost', '全部跟随全局');
    var msg = makeEl('span', 'msg');
    bar.appendChild(saveBtn);
    bar.appendChild(resetBtn);
    bar.appendChild(msg);
    card.appendChild(bar);
    card.appendChild(makeEl('p', 'field-help',
      '说明：App 侧不做本地路由（ai_task_routes / AiTaskRouter.resolve 未改动），' +
      '这里配的是**服务端**的 per-task 后端与模型，对所有客户端生效。'));

    function collect() {
      var out = {};
      var sels = card.querySelectorAll('select.r-backend');
      for (var i = 0; i < sels.length; i++) {
        var task = sels[i].getAttribute('data-task');
        var modelInput = card.querySelector('input.r-model[data-task="' + task + '"]');
        var model = modelInput ? modelInput.value.trim() : '';
        var backend = sels[i].value;
        out[task] = { backend: backend, model: model };
      }
      return out;
    }

    saveBtn.addEventListener('click', function () {
      // 前端先拦：下拉里没有的选项不允许提交
      var sels = card.querySelectorAll('select.r-backend');
      for (var i = 0; i < sels.length; i++) {
        var v = sels[i].value;
        if (v && backends.indexOf(v) < 0) {
          msg.className = 'msg err';
          msg.textContent = '未知后端：' + v + '（请从下拉里选）';
          return;
        }
      }
      saveBtn.disabled = true;
      msg.className = 'msg';
      msg.textContent = '保存中…';
      saveRoutes(collect())
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

    resetBtn.addEventListener('click', function () {
      var out = {};
      var sels = card.querySelectorAll('select.r-backend');
      for (var i = 0; i < sels.length; i++) {
        out[sels[i].getAttribute('data-task')] = null;
      }
      resetBtn.disabled = true;
      saveRoutes(out)
        .then(function () {
          msg.textContent = '已全部改为跟随全局 ✅';
          msg.className = 'msg ok';
          refreshCurrent();
        })
        .catch(function (e) {
          msg.textContent = humanizeError(e);
          msg.className = 'msg err';
        })
        .then(function () { resetBtn.disabled = false; });
    });
  }).catch(function (e) {
    card.innerHTML = '<h2>任务路由</h2>';
    cardError(card, e, function () { refreshCurrent(); });
  });
}

/* ================================================================
   M5 提示词管理：左列表 + 右编辑（保存后显示 sha1 变化）
   ================================================================ */

function renderPrompts(root) {
  var card = makeEl('div', 'card',
    '<h2>提示词管理</h2><p class="hint">服务端 prompts/*.md —— 改完点「保存（含重载）」立即生效</p>');
  card.appendChild(makeEl('div', 'spinner', '加载中…'));
  root.appendChild(card);

  prompts().then(function (data) {
    card.innerHTML = '<h2>提示词管理</h2><p class="hint">服务端 prompts/*.md —— 改完点「保存（含重载）」立即生效</p>';
    var list = data.prompts || [];
    if (!list.length) {
      card.appendChild(makeEl('p', 'muted', '（没有加载到提示词）'));
      return;
    }

    var split = makeEl('div', 'split');
    var left = makeEl('div', 'card');
    left.innerHTML = '<h2>提示词</h2><p class="hint">共 ' + esc(list.length) + ' 个</p>';
    var right = makeEl('div', 'card');
    right.innerHTML = '<h2>编辑</h2><p class="hint">从左侧选一个</p>';
    split.appendChild(left);
    split.appendChild(right);
    card.appendChild(split);

    if (data.errors && data.errors.length) {
      var eb = makeEl('div', 'alert warn');
      eb.innerHTML = '<b>加载错误 ' + esc(data.errors.length) + ' 条：</b><br />' +
        esc(data.errors.join('<br />')).replace(/&lt;br \/&gt;/g, '<br />');
      card.appendChild(eb);
    }

    var textarea = null;
    var current = null;
    var originalSha1 = '';
    var originalContent = '';

    function select(meta) {
      current = meta;
      originalSha1 = meta.sha1 || '';
      right.innerHTML = '<h2>' + esc(meta.file) + '</h2><p class="hint">' +
        (meta.structured ? badge('info', '结构化') : badge('grey', '会话')) + ' ' +
        (meta.json_output ? badge('ok', 'JSON 输出') : '') +
        ' · inputs: <span class="mono">' + esc((meta.inputs || []).join(', ')) + '</span>' +
        (meta.placeholders_mismatch ? ' ' + badge('warn', '占位符与 inputs 不一致') : '') +
        '</p>';

      var kv = makeEl('div', 'kv small');
      kv.innerHTML =
        '<div><span class="k">sha1</span><span class="mono">' + esc(String(meta.sha1 || '').slice(0, 12)) + '</span></div>' +
        '<div><span class="k">修改时间</span>' + esc(fmtTime(meta.mtime)) + '</div>' +
        '<div><span class="k">大小</span>' + esc(meta.size) + ' 字节</div>' +
        '<div><span class="k">output_key</span>' + esc(meta.output_key || '—') + '</div>';
      right.appendChild(kv);

      textarea = makeEl('textarea');
      textarea.rows = 22;
      textarea.value = '加载中…';
      right.appendChild(textarea);

      var bar = makeEl('div', 'actions');
      var saveBtn = makeEl('button', 'btn', '保存（含重载）');
      var giveUpBtn = makeEl('button', 'btn ghost', '放弃修改');
      var reloadAllBtn = makeEl('button', 'btn ghost', '重载全部');
      var msg = makeEl('span', 'msg');
      bar.appendChild(saveBtn);
      bar.appendChild(giveUpBtn);
      bar.appendChild(reloadAllBtn);
      bar.appendChild(msg);
      right.appendChild(bar);

      prompt(meta.task, meta.variant).then(function (p) {
        originalContent = p.content || '';
        textarea.value = originalContent;
      }).catch(function (e) {
        textarea.value = '';
        cardError(right, e, function () { select(meta); });
      });

      saveBtn.addEventListener('click', function () {
        saveBtn.disabled = true;
        msg.className = 'msg';
        msg.textContent = '保存中…';
        savePrompt(meta.task, meta.variant, textarea.value)
          .then(function () {
            return prompts().then(function (fresh) {
              var now = (fresh.prompts || []).filter(function (m) {
                return m.task === meta.task && m.variant === meta.variant;
              })[0];
              var nowSha = now ? String(now.sha1 || '').slice(0, 8) : '?';
              msg.className = 'msg ok';
              msg.innerHTML = '已保存并重载：sha1 已由 ' +
                esc(String(originalSha1).slice(0, 8)) + ' 变为 ' + esc(nowSha) + ' ✅';
              originalSha1 = now ? now.sha1 : originalSha1;
              originalContent = textarea.value;
              renderPrompts(root);
            });
          })
          .catch(function (e) {
            msg.textContent = humanizeError(e);
            msg.className = 'msg err';
          })
          .then(function () { saveBtn.disabled = false; });
      });

      giveUpBtn.addEventListener('click', function () {
        textarea.value = originalContent;
        msg.textContent = '已放弃修改';
        msg.className = 'msg';
      });

      reloadAllBtn.addEventListener('click', function () {
        reloadPrompts().then(function (r) {
          msg.textContent = '已重载：' + (r.loaded !== undefined ? r.loaded : '?') + ' 个';
          msg.className = 'msg ok';
          renderPrompts(root);
        }).catch(function (e) {
          msg.textContent = humanizeError(e);
          msg.className = 'msg err';
        });
      });

      var items = left.querySelectorAll('.list-item');
      for (var i = 0; i < items.length; i++) {
        items[i].classList.toggle('active', items[i].getAttribute('data-key') === keyOf(meta));
      }
    }

    function keyOf(m) { return m.task + (m.variant ? '.' + m.variant : ''); }

    for (var i = 0; i < list.length; i++) {
      var m = list[i];
      var item = makeEl('div', 'list-item');
      item.setAttribute('data-key', keyOf(m));
      item.innerHTML = '<b>' + esc(m.task + (m.variant ? ' · ' + m.variant : '')) + '</b>' +
        '<span class="sub mono">' + esc(m.file) + ' · ' + esc(String(m.sha1 || '').slice(0, 8)) +
        ' · ' + esc(fmtAgo(m.mtime)) + '</span>';
      (function (meta) {
        item.addEventListener('click', function () { select(meta); });
      })(m);
      left.appendChild(item);
    }

    select(list[0]);
  }).catch(function (e) {
    card.innerHTML = '<h2>提示词管理</h2>';
    cardError(card, e, function () { refreshCurrent(); });
  });
}

/* ================================================================
   M6 任务调试台：按 inputs[] 逐个生成输入框 + 三标签结果区
   ================================================================ */

function renderPlayground(root) {
  var card = makeEl('div', 'card',
    '<h2>任务调试台</h2><p class="hint">选任务 → 按 inputs 逐个填值 → 运行 → 看原始输出 / 解析后 JSON / 调用信息</p>');
  card.appendChild(makeEl('div', 'spinner', '加载中…'));
  root.appendChild(card);

  adminRoutes().then(function (data) {
    card.innerHTML = '<h2>任务调试台</h2><p class="hint">选任务 → 按 inputs 逐个填值 → 运行 → 看原始输出 / 解析后 JSON / 调用信息</p>';
    var tasks = data.tasks || [];

    var selWrap = makeEl('div', 'row');
    var tCol = makeEl('div', '');
    tCol.appendChild(makeEl('label', '', '任务'));
    var tSelect = makeEl('select');
    for (var i = 0; i < tasks.length; i++) {
      var o = makeEl('option', '', esc(tasks[i].task + (tasks[i].variant ? ' · ' + tasks[i].variant : '')) +
        (tasks[i].structured ? '（结构化）' : '（会话）'));
      o.value = i;
      tSelect.appendChild(o);
    }
    tCol.appendChild(tSelect);
    selWrap.appendChild(tCol);
    card.appendChild(selWrap);

    var inputsBox = makeEl('div', 'mt');
    card.appendChild(inputsBox);

    var advToggle = makeEl('p', 'field-help', '▸ 高级：覆盖后端 / 模型');
    advToggle.style.cursor = 'pointer';
    var advBox = makeEl('div', 'row hidden');
    var bCol = makeEl('div', '');
    bCol.appendChild(makeEl('label', '', '后端覆盖（空 = 跟随路由）'));
    var bInput = makeEl('input');
    bInput.type = 'text';
    bInput.placeholder = 'ollama / minimax / openai_compat';
    bCol.appendChild(bInput);
    var mCol = makeEl('div', '');
    mCol.appendChild(makeEl('label', '', '模型覆盖（空 = 后端默认）'));
    var mInput = makeEl('input');
    mInput.type = 'text';
    mInput.placeholder = 'qwen3:8b-8k';
    mCol.appendChild(mInput);
    advBox.appendChild(bCol);
    advBox.appendChild(mCol);
    card.appendChild(advToggle);
    card.appendChild(advBox);
    advToggle.addEventListener('click', function () {
      advBox.classList.toggle('hidden');
      advToggle.textContent = advBox.classList.contains('hidden')
        ? '▸ 高级：覆盖后端 / 模型' : '▾ 高级：覆盖后端 / 模型';
    });

    var bar = makeEl('div', 'actions');
    var runBtn = makeEl('button', 'btn', '运行');
    var msg = makeEl('span', 'msg');
    bar.appendChild(runBtn);
    bar.appendChild(msg);
    card.appendChild(bar);

    var resultBox = makeEl('div', 'mt');
    card.appendChild(resultBox);

    function buildInputs() {
      inputsBox.innerHTML = '';
      var t = tasks[Number(tSelect.value) || 0];
      var names = t.inputs || [];
      for (var i = 0; i < names.length; i++) {
        var wrap = makeEl('div', '');
        var lb = makeEl('label', '', '输入 ' + esc(names[i]));
        wrap.appendChild(lb);
        var field;
        if (/text|json|content|note|points|pairs|answer|question/.test(names[i])) {
          field = makeEl('textarea');
          field.rows = 5;
        } else {
          field = makeEl('input');
          field.type = 'text';
        }
        field.setAttribute('data-input', names[i]);
        field.placeholder = '{{' + names[i] + '}}';
        wrap.appendChild(field);
        inputsBox.appendChild(wrap);
      }
      if (!names.length) {
        inputsBox.appendChild(makeEl('p', 'muted small', '该任务不需要输入。'));
      }
    }

    tSelect.addEventListener('change', buildInputs);
    buildInputs();

    runBtn.addEventListener('click', function () {
      var t = tasks[Number(tSelect.value) || 0];
      var values = {};
      var fields = inputsBox.querySelectorAll('[data-input]');
      for (var i = 0; i < fields.length; i++) {
        values[fields[i].getAttribute('data-input')] = fields[i].value;
      }
      runBtn.disabled = true;
      msg.className = 'msg';
      msg.textContent = '运行中（结构化任务约 20s，会话任务可能更久）…';
      resultBox.innerHTML = '';

      var backend = bInput.value.trim();
      var model = mInput.value.trim();

      var call;
      if (t.structured) {
        var body = { inputs: values };
        if (backend) body.backend = backend;
        if (model) body.model = model;
        call = runTask(t.task, body);
      } else {
        var chatBody = {
          query: values.query || values.content || values.note_text || '',
          task: t.task,
        };
        if (t.variant) chatBody.variant = t.variant;
        if (backend) chatBody.backend = backend;
        if (model) chatBody.model = model;
        // 其余 inputs 作为附加变量透传
        for (var key in values) {
          if (!Object.prototype.hasOwnProperty.call(values, key)) continue;
          if (key === 'query') continue;
          chatBody[key] = values[key];
        }
        if (!chatBody.query) {
          var extraKeys = Object.keys(values);
          if (extraKeys.length) chatBody.query = String(values[extraKeys[0]] || '');
        }
        call = runChat(chatBody);
      }

      call.then(function (res) {
        msg.textContent = '完成 ✅';
        msg.className = 'msg ok';
        renderResult(resultBox, res || {});
      }).catch(function (e) {
        msg.textContent = '失败';
        msg.className = 'msg err';
        var box = makeEl('div', 'alert err');
        box.innerHTML = '<div><b>' + esc(ERROR_TEXT[e.code] || '运行失败') + '</b> ' +
          badge('bad', esc(e.code || '?')) + ' ' +
          badge(e.retryable ? 'warn' : 'grey', e.retryable ? '可重试' : '不可重试') + '</div>' +
          '<div class="small">' + esc(e.message || '') + '</div>';
        resultBox.appendChild(box);
      }).then(function () { runBtn.disabled = false; });
    });
  }).catch(function (e) {
    card.innerHTML = '<h2>任务调试台</h2>';
    cardError(card, e, function () { refreshCurrent(); });
  });
}

/** 结果三标签：原始输出 / 解析后 JSON / 调用信息。 */
function renderResult(box, res) {
  box.innerHTML = '';
  var tabs = makeEl('div', 'tabs');
  var names = [['raw', '原始输出'], ['json', '解析后 JSON'], ['meta', '调用信息']];
  var panes = {};
  for (var i = 0; i < names.length; i++) {
    var btn = makeEl('button', 'tab' + (i === 0 ? ' active' : ''), esc(names[i][1]));
    btn.setAttribute('data-tab', names[i][0]);
    tabs.appendChild(btn);
    var pane = makeEl('div', 'pane' + (i === 0 ? '' : ' hidden'));
    if (names[i][0] === 'raw') {
      pane.appendChild(makeEl('pre', '', esc(res.content || '(空)')));
    } else if (names[i][0] === 'json') {
      pane.appendChild(makeEl('pre', '', esc(JSON.stringify(res.parsed === undefined ? null : res.parsed, null, 2))));
    } else {
      var kv = makeEl('div', 'kv');
      kv.innerHTML =
        '<div><span class="k">后端</span>' + esc(res.backend || '—') + '</div>' +
        '<div><span class="k">模型</span>' + esc(res.model_id || '—') + '</div>' +
        '<div><span class="k">延迟</span>' + esc(fmtMs(res.latency_ms)) + '</div>' +
        '<div><span class="k">尝试次数</span>' + esc(res.attempts !== undefined ? res.attempts : '—') + '</div>' +
        '<div><span class="k">output_key</span>' + esc(res.output_key || '—') + '</div>' +
        '<div><span class="k">prompt_sha1</span><span class="mono">' +
        esc(String(res.prompt_sha1 || '—').slice(0, 12)) + '</span></div>' +
        '<div><span class="k">usage</span><span class="mono">' +
        esc(res.usage ? JSON.stringify(res.usage) : '—') + '</span></div>';
      pane.appendChild(kv);
    }
    panes[names[i][0]] = pane;
    box.appendChild(pane);
  }
  box.insertBefore(tabs, box.firstChild);

  var btns = tabs.querySelectorAll('.tab');
  for (var j = 0; j < btns.length; j++) {
    btns[j].addEventListener('click', function () {
      var key = this.getAttribute('data-tab');
      for (var k = 0; k < btns.length; k++) btns[k].classList.toggle('active', btns[k] === this);
      for (var name in panes) {
        if (!Object.prototype.hasOwnProperty.call(panes, name)) continue;
        panes[name].classList.toggle('hidden', name !== key);
      }
    });
  }
}
