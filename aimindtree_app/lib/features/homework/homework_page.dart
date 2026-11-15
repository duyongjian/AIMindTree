/// 作业页面（「作业模式」的落点）。
///
/// 进入方式：在知识树里点「作业模式」→ 框选薄弱点 →「布置作业」，把选中的
/// [KnowledgePoint] 连同（若有）已存在的作业 id 传进来。
///
/// 能力：
/// - **AI 按点出题（Q7）**：一次选 N 个知识点 = **N 份独立作业**（同一
///   `batch_id` 聚合）。出题逐点串行，每点出自己的题、落自己的 `homeworks`
///   行（`kp_id` 指该点），进度显示「正在出题 2/5：xxx」。
/// - **后台执行（D）**：出题跑在 [AiJobService.runDetached] 的执行体里，
///   页面退出不中断、托盘可见可取消；每点完成即落草稿（`status='draft'`），
///   页面关掉也不会丢结果，命中的话回来还能看到题目。
/// - **逐题编辑**：题型 / 难度 / 题干 / 参考答案均可改，也支持删题、手动加题。
/// - **导出 Markdown**：可切换「含答案 / 仅题目」，一键复制到剪贴板。
/// - **落库**：新建按知识点逐行保存（`assigned`），或覆盖保存已有作业
///   （[HomeworkRepository]），历史在作业历史页里查看。
/// - **草稿（可增删改查）**：AppBar 的「存草稿」把当前内容落成 `status='draft'`，
///   **允许零题目**（先占位、回头在历史页点开继续填）；草稿在「作业历史」的
///   「草稿」筛选里可见、可编辑、可删、可再存草稿。普通「保存」才转 `assigned`。
///
/// 设计要点：作业**不产生知识点**，题目本身也不是知识实体，所以出题不受「锚点铁律」
/// 约束；但 prompt 会把知识点的 `sourceQuote` 一并喂给模型，作为「不脱离原文」的唯一防线。
///
/// B4 互斥：会话打开期间持 `homework:{id}` 锁（编辑）或 `homework:new:{canvasId}`
/// 锁（新建，入口处挡「同树再开一个布置作业」），托盘同步显示一行计时；
/// 出题另有独立的 `homework:gen:{batchId}` 锁（D 的后台任务行）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ai/ai_job_service.dart';
import '../../ai/ai_service.dart';
import '../../ai/ai_task.dart';
import '../../core/id.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/homework.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/repositories/homework_repository.dart';

class HomeworkPage extends StatefulWidget {
  const HomeworkPage({
    super.key,
    required this.ai,
    required this.db,
    required this.canvasId,
    required this.points,
    required this.jobs,
    this.existingId,
  });

  /// AI 服务（用于 T8 流式出题）。
  final AiService ai;

  final AppDatabase db;

  /// 所属知识树（canvases.id）。
  final String canvasId;

  /// 出题上下文：被选中的薄弱点（名称 / 定义 / 原文出处）。
  final List<KnowledgePoint> points;

  /// 任务队列服务（B4：会话持 `homework:{id}` 锁 + 托盘计时）。
  final AiJobService jobs;

  /// 非空 → 编辑已有作业（从库里载入题目）。
  final String? existingId;

  @override
  State<HomeworkPage> createState() => _HomeworkPageState();
}

class _HomeworkPageState extends State<HomeworkPage> {
  late final HomeworkRepository _repo =
      HomeworkRepository(widget.db, deviceId: DeviceId.orEmpty);

  static final AppLog _log = AppLog('homework_page');

  final TextEditingController _titleCtrl = TextEditingController();
  List<HomeworkItem> _items = const <HomeworkItem>[];

  /// 流式出题时的实时原文（展示「正在生成」进度）。
  String _streaming = '';
  bool _busy = false;
  String? _error;
  bool _withAnswer = true;

  /// Q7：本次批量作业的聚合键。新建时首次生成才生成（一知识点一行作业，
  /// 同 `batch_id` 视为同一批）；编辑已有作业时沿用该作业的 batchId。
  String? _batchId;

  /// 逐点进度文案（「正在出题 2/5：xxx」；空 = 未在出题）。
  String _progressText = '';

  /// 出题失败/跳过的知识点（点名字 + 原因），页面内红条展示，不阻断其他点。
  List<String> _failed = const <String>[];

  /// D：当前后台出题任务（取消按钮用）。
  DetachedTask? _task;

  /// B4：交互会话 id（持 `homework:{id}` 锁；dispose 时释放）。
  ///
  /// 编辑已有作业锁作业本身；新作业还没 id，退而锁「该树的新作业会话」，
  /// 防止同一棵树同时开两个「布置作业」。
  String _sessionTicket = '';

  @override
  void initState() {
    super.initState();
    final names = widget.points.map((p) => p.name).take(2).join('、');
    _sessionTicket = widget.jobs.holdInteractive(
      widget.existingId != null
          ? 'homework:${widget.existingId}'
          : 'homework:new:${widget.canvasId}',
      // 这一行代表「**这个页面开着**」（交互会话，锁随页面生命周期），不是
      // 「正在生成题目」—— 后者是下面 `runDetached` 登记的那一行。所以 label
      // 里必须带「编辑中」，否则出题时两行都以「布置作业」开头，用户分不清。
      label: widget.existingId != null
          ? '编辑作业（$names）'
          : '布置作业 · 编辑中（$names）',
    );
    if (widget.existingId != null) _loadExisting();
  }

  @override
  void dispose() {
    widget.jobs.releaseInteractive(_sessionTicket);
    _titleCtrl.dispose();
    super.dispose();
  }

  /// 托盘文案联动：出题中 ↔ 会话进行中。
  void _ticket(String message) {
    if (_sessionTicket.isEmpty) return;
    widget.jobs.setInteractiveMessage(_sessionTicket, message);
  }

  Future<void> _loadExisting() async {
    final hw = await _repo.byId(widget.existingId!);
    if (!mounted) return;
    if (hw == null) {
      setState(() => _error = '找不到该作业（可能已被删除）。');
      return;
    }
    setState(() {
      _titleCtrl.text = hw.title;
      _items = hw.items;
      // 编辑已有作业：沿用它的批次键（批量里的一份也走同一条）。
      _batchId = hw.batchId;
    });
  }

  // ===================== 出题（Q7：一知识点一份） =====================

  /// 单知识点出题 prompt（Q7：每次只喂一个点，模型不会把题串到别的点上）。
  String _buildPromptFor(KnowledgePoint p) {
    final sb = StringBuffer();
    sb.writeln('你是出题老师。下面是一个学生掌握得不好的知识点（薄弱点），'
        '请围绕它出练习题，帮助学生巩固。');
    sb.writeln('该知识点附有「原文出处」，请以原文为依据出题，'
        '不要编造原文里没有的概念或数据。');
    sb.writeln();
    sb.writeln('【薄弱点】${p.name}');
    if (p.definition.isNotEmpty) sb.writeln('定义：${p.definition}');
    if (p.sourceQuote.isNotEmpty) sb.writeln('原文：${p.sourceQuote}');
    sb.writeln();
    sb.writeln('要求：');
    sb.writeln('- 为该知识点出 1~3 道题；');
    sb.writeln('- 题型从 choice（选择）/ fill（填空）/ short（简答）/ '
        'calc（计算）/ proof（证明或推导）中选择最合适的；');
    sb.writeln('- difficulty 为 1（易）/ 2（中）/ 3（难）。');
    sb.writeln('只输出一个 JSON 数组，不要任何解释、不要 markdown 代码块标记。'
        '每个元素格式：');
    sb.writeln('{"kpName":"${p.name}","type":"short","question":"题目",'
        '"answer":"参考答案或评分要点","difficulty":2}');
    return sb.toString();
  }

  /// 把模型输出解析成题目列表；兼容「裸数组」或「包了一层对象的数组」。
  ///
  /// Q7 下每份作业只面对一个知识点，所以 `kpId/kpName` 一律**强制**写成
  /// [point]（模型漏字段、写错名字都不影响归属）。
  List<HomeworkItem> _parseQuestions(String raw, KnowledgePoint point) {
    var s = raw.trim();
    if (s.isEmpty) return const <HomeworkItem>[];
    // 去掉 ```json ... ``` 围栏。
    if (s.startsWith('```')) {
      final nl = s.indexOf('\n');
      if (nl >= 0) s = s.substring(nl + 1);
      if (s.endsWith('```')) s = s.substring(0, s.length - 3);
      s = s.trim();
    }
    // 优先找数组；找不到再找对象里的列表字段。
    Object? decoded;
    try {
      final arrStart = s.indexOf('[');
      final arrEnd = s.lastIndexOf(']');
      if (arrStart >= 0 && arrEnd > arrStart) {
        decoded = jsonDecode(s.substring(arrStart, arrEnd + 1));
      } else {
        final objStart = s.indexOf('{');
        final objEnd = s.lastIndexOf('}');
        if (objStart >= 0 && objEnd > objStart) {
          final map =
              jsonDecode(s.substring(objStart, objEnd + 1)) as Map<String, dynamic>;
          for (final key in const <String>['questions', 'items', 'data', 'list']) {
            if (map[key] is List) {
              decoded = map[key];
              break;
            }
          }
        }
      }
    } on Object {
      return const <HomeworkItem>[];
    }
    if (decoded is! List) return const <HomeworkItem>[];
    final out = <HomeworkItem>[];
    for (final e in decoded) {
      final it = HomeworkItem.fromJson(e).copyWith(kpId: point.id, kpName: point.name);
      // 题干空的题目没有布置意义，直接丢。
      if (it.question.trim().isEmpty) continue;
      out.add(it);
    }
    return out;
  }

  /// 一份作业的标题：用户填了主标题就拼上知识点名，没填就用「点名 · 练习」。
  ///
  /// [base] 由调用方快照传入（后台任务的 body 可能在页面 dispose 之后才执行，
  /// 那时不能再读 `_titleCtrl`）；不传则现读（页面存活路径）。
  String _titleForPoint(KnowledgePoint p, [String? base]) {
    final head = (base ?? _titleCtrl.text).trim();
    return head.isEmpty ? '${p.name} · 练习（${_fmtNow()}）' : '$head · ${p.name}';
  }

  /// 逐点出题并逐点落库（草稿）。
  ///
  /// ★ D 的核心：整段跑在 [AiJobService.runDetached] 的执行体里，**不依赖页面
  ///   生命周期** —— 用户退出页面后任务继续，每点完成即写 `homeworks` 行
  ///   （`status='draft'`），所以结果不会因为「页面没了」而丢；`setState` 一律
  ///   先判 `mounted`，DB 写一律无条件。
  Future<void> _generate() async {
    if (widget.points.isEmpty) {
      _toast('没有可用的知识点内容，无法自动出题。可手动「添加题目」。');
      return;
    }
    if (_busy) return;

    final points = List<KnowledgePoint>.of(widget.points);

    /// 编辑已有作业：只重出这一行的题（**不落草稿行**），否则会多出一批孤儿作业。
    final editing = widget.existingId != null;

    /// 每轮生成都用**新批次**：既不会「先删旧草稿、生成失败后两头空」，
    /// 也不会「每点一次重新生成就成倍堆行」——旧批次在**本轮至少成功一份后**
    /// 才清理（见 body 收尾）。
    final batch = newUlid();
    final staleBatch = editing ? null : _batchId;
    if (!editing) _batchId = batch;

    // 标题在登记任务前快照：body 可能跑在页面销毁之后，那时 `_titleCtrl`
    // 已经 dispose，读它会把「AI 已出好题」变成 failed。
    final titleBase = _titleCtrl.text.trim();

    final collected = <HomeworkItem>[];
    final failed = <String>[];

    setState(() {
      _busy = true;
      _error = null;
      _streaming = '';
      _progressText = '准备出题…';
      _failed = const <String>[];
    });
    _ticket('出题中…');

    _task = widget.jobs.runDetached(
      // 这一行才是「正在生成题目」（后台执行体，页面关了也跑完）。与上面那条
      // 交互行区分开：一个说页面开着，一个说进度到哪儿了。
      label: editing
          ? '重新出题（${points.first.name}）'
          : '出题中（${points.length} 个知识点）',
      resourceKey: 'homework:gen:$batch',
      doneMessage: editing ? '题目已重新生成' : '作业已生成（${points.length} 份）',
      body: (task) async {
        var okCount = 0;
        for (var i = 0; i < points.length; i++) {
          if (task.isCanceled) break;
          final p = points[i];
          final step = '正在出题 ${i + 1}/${points.length}：${p.name}';
          task.progress(step,
              percent: i / points.length,
              stageIndex: i + 1,
              stageTotal: points.length);
          if (mounted) {
            setState(() {
              _progressText = step;
              _streaming = '';
            });
          }

          final buf = StringBuffer();
          try {
            await for (final c in widget.ai.chat(AiTask.t8Quiz, _buildPromptFor(p))) {
              if (task.isCanceled) break;
              final delta = c.delta;
              if (delta == null) continue;
              buf.write(delta);
              // 节流：每积够 ~120 字才刷一次，避免每块都 setState。
              if (mounted && buf.length % 120 < delta.length) {
                setState(() => _streaming = buf.toString());
              }
            }
          } on Object catch (e) {
            failed.add('${p.name}：${_friendlyError(e)}');
            continue;
          }
          if (task.isCanceled) break;

          final items = _parseQuestions(buf.toString(), p);
          if (items.isEmpty) {
            failed.add('${p.name}：AI 返回的内容无法解析为题目');
            continue;
          }
          collected.addAll(items);
          okCount++;

          // 逐点落草稿：页面关了也留得下（保存时再置为 assigned）。
          // 编辑模式不落草稿 —— 结果由 `_save` 覆盖进原行。
          if (!editing) {
            try {
              await _repo.createHomework(
                canvasId: widget.canvasId,
                kpId: p.id,
                batchId: batch,
                title: _titleForPoint(p, titleBase),
                itemsJson: encodeHomeworkItems(items),
                status: 'draft',
              );
            } on Object catch (e) {
              failed.add('${p.name}：落库失败（$e）');
            }
          }

          if (mounted) {
            setState(() {
              _items = List<HomeworkItem>.of(collected);
              _progressText = '已完成 ${i + 1}/${points.length}';
              _streaming = '';
            });
          }
        }

        // ---- 清理上一批的**草稿**（本轮至少成功一份才清，避免两头空） ----
        //
        // ⚠️ 只清 `status == 'draft'`：作业一旦保存过（assigned）就是用户的正式
        //    数据，重新生成不该把它删掉。这条在作业纳入同步后更要紧 —— 同步层
        //    对墓碑是「无条件硬删」（`sync_engine.dart` 的 `_merge`，不看版本），
        //    一条误清的墓碑就能把另一台设备上刚编辑好的作业静默抹掉。
        if (!editing && okCount > 0 && staleBatch != null && staleBatch != batch) {
          try {
            for (final row in await _repo.listByBatch(staleBatch)) {
              if (row.status != 'draft') continue;
              await _repo.softDelete(row.id);
            }
          } on Object catch (e) {
            _log.w('清理上一批草稿失败：$e');
          }
        }

        // ---- 收尾（页面已销毁也必须走完：日志与终态文案靠它） ----
        if (failed.isNotEmpty) {
          task.setDoneMessage(
              '作业已生成 $okCount 份，${failed.length} 个知识点没出出来');
        }
        if (mounted) {
          setState(() {
            _busy = false;
            _progressText = '';
            _streaming = '';
            _failed = List<String>.of(failed);
            if (collected.isEmpty && !task.isCanceled) {
              _error = 'AI 没出出任何题目。可手动「添加题目」，或点「重新生成」。';
            }
          });
          _ticket('会话进行中');
        }
      },
    );
  }

  /// 取消正在进行的后台出题（托盘取消之外，页面内也留一个入口）。
  Future<void> _cancelGenerate() async {
    final task = _task;
    if (task == null) return;
    await widget.jobs.cancel(task.id);
    if (!mounted) return;
    setState(() => _progressText = '正在取消…');
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('没有任何可用的 AI Provider')) {
      return '还没有配置 AI Provider，无法自动出题。'
          '你可以先去「设置」配置，或直接点「添加题目」手动布置。';
    }
    return '出题失败：$msg';
  }

  // ===================== 保存 / 导出 =====================

  /// 保存。[asDraft] = true 时落到 `status='draft'`（草稿，历史页仍可见、可再编辑）。
  ///
  /// 草稿**允许零题目**：用户可以先建个空壳占位（比如「第三章错题」还没想好出
  /// 哪些题），回头在历史页点开继续填。正式保存仍要求至少一题。
  Future<void> _save({bool asDraft = false}) async {
    if (_items.isEmpty && !asDraft) {
      _toast('还没有题目，先生成或手动添加。');
      return;
    }
    // 还在生成里就点保存：先取消并等它收尾，否则会把「半批题目」存成正式作业，
    // 而且批次行可能与随后生成的草稿打架。等的是任务本身，不是页面。
    final running = _busy ? _task : null;
    if (running != null) {
      await widget.jobs.cancel(running.id);
      try {
        await running.done;
      } on Object {
        // done 不抛，这里只是防御。
      }
      if (!mounted) return;
    }
    final title = _titleCtrl.text.trim().isEmpty
        ? '作业（${_fmtNow()}）'
        : _titleCtrl.text.trim();
    final kpIds = widget.points.map((p) => p.id).toList();

    /// 本轮要落的状态：草稿 or 正式布置。
    final String targetStatus = asDraft ? 'draft' : 'assigned';

    // ① 编辑已有作业：单行覆盖（保持原语义，不碰别的行）。
    if (widget.existingId != null) {
      await _saveExisting(title: title, kpIds: kpIds, asDraft: asDraft);
      return;
    }

    // ② 批量（Q7）：生成时已按知识点落草稿，这里把每行的题目换成最新编辑内容
    //    并置为 assigned；编辑期间新增的、库里还没有的知识点再补建。
    final batch = _batchId;
    if (batch != null) {
      final rows = await _repo.listByBatch(batch);
      if (rows.isNotEmpty) {
        final byKp = <String, List<HomeworkItem>>{};
        for (final it in _items) {
          byKp.putIfAbsent(it.kpId, () => <HomeworkItem>[]).add(it);
        }
        // 手动「添加题目」造的题没有 kpId —— 不能就这样丢掉（浏览器里看得见、
        // 保存后消失）。全并到第一个知识点的行里。
        final orphans = byKp.remove('') ?? const <HomeworkItem>[];
        if (orphans.isNotEmpty) {
          final fallback = widget.points.isNotEmpty
              ? widget.points.first.id
              : (rows.first.kpId ?? '');
          if (fallback.isNotEmpty) {
            byKp.putIfAbsent(fallback, () => <HomeworkItem>[]).addAll(orphans);
          }
        }
        for (final row in rows) {
          final own = byKp[row.kpId ?? ''] ?? const <HomeworkItem>[];
          if (own.isEmpty) {
            // 存草稿：**不删**空组。用户可能只想先存一部分，其它知识点留着
            // 空壳下次继续填；删掉就变成「我明明存过却没记录」。
            if (asDraft) continue;
            // 正式保存：用户把这个知识点的题全删了 → 该行作废（否则会留下一条
            // 空草稿继续混在历史里，还虚增「已保存 N 份」的计数）。
            await _repo.softDelete(row.id);
            continue;
          }
          final r = await _repo.save(row.copyWith(items: own, status: targetStatus));
          final err = r.fold<Object?>((_) => null, (e, _) => e);
          if (err != null) {
            _toast('保存失败：$err');
            return;
          }
        }
        final known = rows.map((r) => r.kpId).whereType<String>().toSet();
        for (final entry in byKp.entries) {
          if (entry.key.isEmpty || known.contains(entry.key)) continue;
          KnowledgePoint? p;
          for (final cand in widget.points) {
            if (cand.id == entry.key) {
              p = cand;
              break;
            }
          }
          try {
            await _repo.createHomework(
              canvasId: widget.canvasId,
              kpId: entry.key,
              batchId: batch,
              title: p == null ? title : _titleForPoint(p),
              itemsJson: encodeHomeworkItems(entry.value),
              status: targetStatus,
            );
          } on Object catch (e) {
            _toast('保存失败：$e');
            return;
          }
        }
        if (!mounted) return;
        // 计数口径：真正落下题的份数（删空的点已作废，不算）。
        final saved = byKp.entries.where((e) => e.value.isNotEmpty).length;
        // 存草稿时把题全删光 → 不写空行（避免覆盖掉原有内容），如实告知。
        if (asDraft && saved == 0) {
          _toast('没有题目，原有草稿保持不变');
        } else {
          _toast(asDraft ? '已存 $saved 份草稿' : '已保存 $saved 份作业');
        }
        Navigator.of(context).pop(true);
        return;
      }
    }

    // ③ 手动出题（没走 AI，没有批次）：按知识点逐行落库，仍守「一知识点一份」。
    if (widget.points.length <= 1) {
      final r = await _repo.create(
        canvasId: widget.canvasId,
        title: title,
        kpIds: kpIds,
        items: _items,
        kpId: widget.points.isEmpty ? null : widget.points.first.id,
        batchId: batch,
        status: targetStatus,
      );
      if (!mounted) return;
      final err = r.fold<Object?>((_) => null, (e, _) => e);
      if (err != null) {
        _toast('保存失败：$err');
        return;
      }
      _toast(asDraft ? '已存为草稿' : '已保存作业');
      Navigator.of(context).pop(true);
      return;
    }

    final newBatch = batch ?? newUlid();
    _batchId = newBatch;
    var created = 0;
    for (final p in widget.points) {
      final own = _items.where((it) => it.kpId == p.id).toList();
      // 手动加题没有 kpId → 归到第一个知识点，不让它成为孤儿题。
      final items = own.isNotEmpty
          ? own
          : (p.id == widget.points.first.id
              ? _items.where((it) => it.kpId.isEmpty).toList()
              : const <HomeworkItem>[]);
      // 草稿允许零题目：每个点都留一个空壳占位，回头在历史页继续填。
      if (items.isEmpty && !asDraft) continue;
      try {
        await _repo.createHomework(
          canvasId: widget.canvasId,
          kpId: p.id,
          batchId: newBatch,
          title: _titleForPoint(p),
          itemsJson: encodeHomeworkItems(items),
          status: targetStatus,
        );
        created++;
      } on Object catch (e) {
        _toast('保存失败：$e');
        return;
      }
    }
    if (!mounted) return;
    _toast(asDraft ? '已存 $created 份草稿' : '已保存 $created 份作业');
    Navigator.of(context).pop(true);
  }

  Future<void> _saveExisting({
    required String title,
    required List<String> kpIds,
    required bool asDraft,
  }) async {
    final existing = await _repo.byId(widget.existingId!);
    if (!mounted) return;
    if (existing == null) {
      final r = await _repo.create(
        canvasId: widget.canvasId,
        title: title,
        kpIds: kpIds,
        items: _items,
        // 兜底补建也要留住「作业→知识点」的主外键，否则这条作业在知识点页面上
        // 永远查不到（`listByKp` 靠 `kp_id`）。
        kpId: widget.points.isEmpty ? null : widget.points.first.id,
        batchId: _batchId,
        status: asDraft ? 'draft' : 'assigned',
      );
      if (!mounted) return;
      final err = r.fold<Object?>((_) => null, (e, _) => e);
      if (err != null) {
        _toast('保存失败：$err');
        return;
      }
      _toast(asDraft ? '已存为草稿' : '已保存作业');
      Navigator.of(context).pop(true);
      return;
    }
    final r = await _repo.save(existing.copyWith(
      title: title,
      kpIds: kpIds,
      items: _items,
      // 显式「存草稿」→ 保持草稿；普通保存 → 早前生成的草稿在这里正式生效。
      status: asDraft
          ? 'draft'
          : (existing.status == 'draft' ? 'assigned' : existing.status),
    ));
    if (!mounted) return;
    final err = r.fold<Object?>((_) => null, (e, _) => e);
    if (err != null) {
      _toast('保存失败：$err');
      return;
    }
    _toast(asDraft ? '已存为草稿' : '已保存作业');
    Navigator.of(context).pop(true);
  }

  String _toMarkdown({required bool withAnswer}) {
    final sb = StringBuffer();
    final title = _titleCtrl.text.trim().isEmpty
        ? '作业'
        : _titleCtrl.text.trim();
    sb.writeln('# $title');
    sb.writeln();
    sb.writeln('共 ${_items.length} 题'
        '${widget.points.isNotEmpty ? '（覆盖 ${widget.points.length} 个薄弱点）' : ''}');
    sb.writeln();
    for (var i = 0; i < _items.length; i++) {
      final it = _items[i];
      sb.writeln('## 第 ${i + 1} 题（${it.typeLabel} · 难度 ${it.difficulty}）');
      if (it.kpName.isNotEmpty) sb.writeln('知识点：${it.kpName}');
      sb.writeln();
      sb.writeln(it.question.trim());
      if (withAnswer) {
        sb.writeln();
        sb.writeln('**参考答案：**');
        sb.writeln(it.answer.trim());
      }
      sb.writeln();
    }
    return sb.toString();
  }

  Future<void> _export() async {
    if (_items.isEmpty) {
      _toast('还没有题目可导出。');
      return;
    }
    final md = _toMarkdown(withAnswer: _withAnswer);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('导出 Markdown'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(md),
            ),
          ),
          actions: [
            Row(
              children: [
                Checkbox(
                  value: _withAnswer,
                  onChanged: (v) => setD(() => _withAnswer = v ?? true),
                ),
                const Text('包含答案'),
              ],
            ),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: md));
                if (!ctx.mounted) return;
                Navigator.of(ctx).pop();
                _toast('已复制到剪贴板');
              },
              child: const Text('复制'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  static String _fmtNow() {
    final l = DateTime.now().toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, "0")}-'
        '${l.day.toString().padLeft(2, "0")} '
        '${l.hour.toString().padLeft(2, "0")}:'
        '${l.minute.toString().padLeft(2, "0")}';
  }

  // ===================== 构建 =====================

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.existingId != null ? '编辑作业' : '布置作业'),
          actions: [
            TextButton.icon(
              onPressed: _export,
              icon: const Icon(Icons.download_outlined),
              label: const Text('导出'),
            ),
            // 草稿：允许零题目、保持 status='draft'，在历史页「草稿」里可再打开。
            TextButton.icon(
              onPressed: () => _save(asDraft: true),
              icon: const Icon(Icons.save_as_outlined),
              label: const Text('存草稿'),
            ),
            TextButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _titleCtrl,
                decoration: const InputDecoration(
                  labelText: '作业标题',
                  hintText: '例如：第三章薄弱点专项练习',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _generate,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome),
                    label: Text(_items.isEmpty
                        ? (widget.points.length > 1
                            ? 'AI 生成（${widget.points.length} 份）'
                            : 'AI 生成')
                        : '重新生成'),
                  ),
                  if (_busy) ...[
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _cancelGenerate,
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      label: const Text('取消'),
                    ),
                  ],
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    // 只有一个知识点时，手动加的题直接归属该点（多知识点时
                    // 留空，保存阶段再并进第一个点的行，不会丢）。
                    onPressed: () => setState(() => _items = [
                      ..._items,
                      HomeworkItem(
                        kpId: widget.points.length == 1
                            ? widget.points.first.id
                            : '',
                        kpName: widget.points.length == 1
                            ? widget.points.first.name
                            : '',
                        type: 'short',
                        question: '',
                        answer: '',
                      ),
                    ]),
                    icon: const Icon(Icons.add),
                    label: const Text('添加题目'),
                  ),
                ],
              ),
              if (_busy)
                _StreamBanner(text: _progressText, stream: _streaming),
              if (_failed.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final f in _failed)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text('· $f',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.deepOrange)),
                        ),
                    ],
                  ),
                ),
              if (_error != null)
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_error!,
                            style: const TextStyle(fontSize: 13, color: Colors.red)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Text('题目（${_items.length}）',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (_items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                        '还没有题目。点「AI 生成」自动出题，或「添加题目」手动录入；'
                        '也可以先「存草稿」占位，回头在「作业历史」里继续填。',
                        style: TextStyle(color: Colors.grey)),
                  ),
                )
              else
                for (var i = 0; i < _items.length; i++)
                  _ItemEditor(
                    index: i + 1,
                    item: _items[i],
                    onChanged: (it) => setState(() => _items[i] = it),
                    onDelete: () => setState(() => _items.removeAt(i)),
                  ),
            ],
          ),
        ),
      );
}

/// 单题编辑器：自带 TextEditingController，题型 / 难度可改，可删除。
class _ItemEditor extends StatefulWidget {
  const _ItemEditor({
    required this.index,
    required this.item,
    required this.onChanged,
    required this.onDelete,
  });

  final int index;
  final HomeworkItem item;
  final ValueChanged<HomeworkItem> onChanged;
  final VoidCallback onDelete;

  @override
  State<_ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<_ItemEditor> {
  late final TextEditingController _kp =
      TextEditingController(text: widget.item.kpName);
  late final TextEditingController _q =
      TextEditingController(text: widget.item.question);
  late final TextEditingController _a =
      TextEditingController(text: widget.item.answer);

  /// 列表按 index 复用 State：删掉中间一题后，第 N 个 `_ItemEditor` 会拿到
  /// 「原来第 N+1 题」的数据，而内部 controller 还留着旧题文本 —— 不同步的话
  /// 界面上是甲题、`onChanged` 交出去的是乙题（改题改错对象）。
  /// 只在「外部数据与当前文本不一致」时同步，所以正在输入时不会被光标记重置。
  @override
  void didUpdateWidget(covariant _ItemEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.kpName != _kp.text) _kp.text = widget.item.kpName;
    if (widget.item.question != _q.text) _q.text = widget.item.question;
    if (widget.item.answer != _a.text) _a.text = widget.item.answer;
  }

  @override
  void dispose() {
    _kp.dispose();
    _q.dispose();
    _a.dispose();
    super.dispose();
  }

  HomeworkItem _current() => widget.item.copyWith(
        kpName: _kp.text,
        question: _q.text,
        answer: _a.text,
      );

  void _emit() => widget.onChanged(_current());

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    child: Text('${widget.index}', style: const TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: widget.item.type,
                      items: const [
                        DropdownMenuItem(value: 'choice', child: Text('选择')),
                        DropdownMenuItem(value: 'fill', child: Text('填空')),
                        DropdownMenuItem(value: 'short', child: Text('简答')),
                        DropdownMenuItem(value: 'calc', child: Text('计算')),
                        DropdownMenuItem(value: 'proof', child: Text('证明/推导')),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          widget.onChanged(_current().copyWith(type: v));
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 1, label: Text('易')),
                      ButtonSegment(value: 2, label: Text('中')),
                      ButtonSegment(value: 3, label: Text('难')),
                    ],
                    selected: {widget.item.difficulty},
                    onSelectionChanged: (s) =>
                        widget.onChanged(_current().copyWith(difficulty: s.first)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    tooltip: '删除该题',
                    onPressed: widget.onDelete,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _kp,
                decoration: const InputDecoration(
                  labelText: '关联知识点',
                  isDense: true,
                ),
                onChanged: (_) => _emit(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _q,
                minLines: 1,
                maxLines: null,
                decoration: const InputDecoration(
                  labelText: '题目',
                  isDense: true,
                ),
                onChanged: (_) => _emit(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _a,
                minLines: 1,
                maxLines: null,
                decoration: const InputDecoration(
                  labelText: '参考答案 / 评分要点',
                  isDense: true,
                ),
                onChanged: (_) => _emit(),
              ),
            ],
          ),
        ),
      );
}

/// 出题时的进度条（Q7 逐点进度 + 模型实时输出，不阻塞编辑）。
class _StreamBanner extends StatelessWidget {
  const _StreamBanner({required this.text, this.stream = ''});

  /// 逐点进度文案（「正在出题 2/5：xxx」）。
  final String text;

  /// 当前知识点的流式原文预览。
  final String stream;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.amber.shade50,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text.isEmpty ? 'AI 正在出题…' : text,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            if (stream.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                stream.length > 240 ? '${stream.substring(stream.length - 240)}' : stream,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      );
}
