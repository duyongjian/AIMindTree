/// 知识树页面（T05 画布 + 知识树）。
///
/// **知识树是一等公民**：一块可命名的画布，可以汇集多篇笔记提取出的知识点。
/// 顶部工具栏负责树的切换 / 新建 / 重命名 / 删除，以及「把某篇笔记的知识点并入当前树」。
///
/// 数据来源：树成员（`canvas_nodes`，target_type='kp'）→ 批量取知识点 → 取成员之间的
/// 前置边 → 渲染到 [TreeCanvas]。位置持久化复用同一批 `canvas_nodes` 记录的 x/y。
///
/// 兼容历史数据：笔记树的 id **等于 noteId**，所以早期按 noteId 存的位置记录天然
/// 就是「这篇笔记的树」的成员；加载时会为每篇已有知识点的笔记补建笔记树并归集成员。
///
/// 顶部工具栏：左侧切换知识树；右侧动作归组为 4 个图标菜单（见 [_buildToolbarGroups]）：
/// 知识树（新建 / 重命名 / 删除）、内容导入（笔记并入 / 新建 / 加入已有知识点）、
/// 布局与连线（重新布局 / 局部重排 / 自动连线 / 局部连线）、
/// AI 与作业（批量补前置 / 布置作业 / 作业历史 / 作业模式）。
library;

import 'package:flutter/material.dart';

import '../../ai/ai_job_service.dart' show kAiJobQueueEnabled, AiJob;
import '../settings/tree_behavior_settings.dart';
import '../../ai/ai_task.dart';
import '../../ai/auto_graph_service.dart';
import '../../ai/extract_into_tree_chain.dart';
import '../../ai/extraction_service.dart';
import '../../ai/prereq_depth.dart';
import '../../canvas/layout_autoplace.dart';
import '../../canvas/layout_transfer.dart';
import '../../canvas/render/layout_engine.dart';
import '../../canvas/render/tree_canvas.dart';
import '../../core/id.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/models/knowledge_tree.dart';
import '../../data/models/suggested_prerequisite.dart';
import '../../data/repositories/knowledge_repository.dart';
import '../../data/repositories/tree_repository.dart';
import '../notes/note_editor_page.dart';
import '../../features/homework/homework_history_page.dart';
import '../../features/homework/homework_page.dart';
import '../../features/knowledge/kp_dedup.dart' show kpDedupSchedule;
import '../../data/models/canvas_content.dart';

/// 补前置入库「笔记归属」四选项（默认 [manual]，见 [_pickSupplementMode]）。
enum _SupplementMode {
  /// 1. 不新建笔记：直接以手动知识点入库（user_manual 豁免，不做 T1 锚定）。
  manual,
  /// 2. 并入同一份新笔记：拼成一篇 Markdown 走 T1 锚定（现状路径）。
  newNote,
  /// 3. 每条建议单独新建笔记：每条各自成笔记并分别锚定。
  separateNotes,
  /// 4. 追加进现有笔记：选一篇笔记，把建议追加进它的内容再锚定。
  appendToNote,
}

class CanvasPage extends StatefulWidget {
  const CanvasPage({
    super.key,
    required this.service,
    required this.db,
    this.onKpTap,
  });
  final ExtractionService service;
  final AppDatabase db;
  final ValueChanged<KnowledgePoint>? onKpTap;

  @override
  State<CanvasPage> createState() => CanvasPageState();
}

class CanvasPageState extends State<CanvasPage> {
  List<KnowledgeTree> _trees = <KnowledgeTree>[];
  KnowledgeTree? _selectedTree;
  List<Note> _notes = <Note>[];

  List<KnowledgePoint> _points = <KnowledgePoint>[];
  List<PrerequisiteEdge> _edges = <PrerequisiteEdge>[];
  final Map<String, MasteryStatus> _mastery = <String, MasteryStatus>{};
  NodePositions _positions = const <String, ({double x, double y})>{};

  /// 当前在画布上点选的节点（T4 深度补前置的入口）。
  KnowledgePoint? _selectedPoint;

  /// 作业模式：开启后可在画布上框选薄弱点，再「布置作业」。
  bool _homeworkMode = false;

  /// 框选模式（常驻开关）：开启后画布可拖拽框选知识点；框选类功能
  /// （局部重排 / 局部连线 / 整组拖动）在此模式下才可用，再点一次退出。
  /// 与作业模式互斥。
  bool _frameMode = false;

  /// 当前画布上框选 / 多选选中的知识点 id（作业模式与框选模式共用同一份状态）。
  final Set<String> _selectedKpIds = <String>{};

  /// ★2.0.0：圆珠笔 / 橡皮模式（二者互斥，且与作业 / 框选模式互斥）。
  bool _penMode = false;
  bool _eraserMode = false;

  /// ★2.0.0：当前画布上的文本卡片与手写笔迹（由 [_loadForTree] 载入）。
  List<CanvasCardVm> _cards = <CanvasCardVm>[];
  List<CanvasStrokeVm> _strokes = <CanvasStrokeVm>[];

  /// ★2.0.0：画布视口中心对应的场景坐标（建卡时定位到可视区中央）。
  Offset _viewportCenter = Offset.zero;

  /// 「重新布局」计数器，改变它会强制重建 [TreeCanvas] 让布局重跑。
  int _relayoutVersion = 0;
  bool _loading = false;

  KnowledgeRepository get _repo => widget.service.repo;
  TreeRepository get _treesRepo => widget.service.trees;

  /// 自动知识连线 / 自动补前置（DSL 优先 + 本地兜底）。
  late final AutoGraphService _auto;

  /// Q4：拖节点放行提示已展示过的锁持有者（同一把锁只提示一次）。
  String? _warnedLockKey;

  /// 「提取 → 入树 → 自动连线」复合链（与 AI 助手页共用同一实现）。
  ExtractIntoTreeChain get _chain => ExtractIntoTreeChain(
        service: widget.service,
        auto: _auto,
        db: widget.db,
        onRefresh: (tree) => _loadForTree(tree.id),
        onMessage: _toast,
      );

  @override
  void initState() {
    super.initState();
    _auto = AutoGraphService(
      ai: widget.service.ai,
      repo: widget.service.repo,
      trees: widget.service.trees,
    );
    _load();
  }

  /// 供外部触发刷新（AppShell 切到知识树 Tab / 笔记页跳转过来时调用）。
  Future<void> refresh() => _load();

  Future<void> _load() async {
    setState(() => _loading = true);
    // 笔记是软删除的，已删除的笔记不该再复活出「笔记树」。
    final noteRows = await (widget.db.select(widget.db.notes)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    final notes = noteRows
        .map((r) => Note(
              id: r.id,
              contentMd: r.contentMd,
              title: r.title,
              updatedAt: r.updatedAt,
              deviceId: r.deviceId,
              version: r.version,
            ))
        .toList();

    // 注意：不再为「已提取知识点的笔记」自动补建「笔记树」并归集成员。
    // 用户需求（2026-10-25）：提取只产出知识点，不自动建知识树；知识树由用户
    // 在画布页显式创建 / 并入。保留 ensureNoteTree 以备显式建树路径复用。

    final trees = await _treesRepo.listTrees();
    if (!mounted) return;

    // 选中项要换成新列表里的实例（DropdownButton 用 identical 比较）。
    final prevId = _selectedTree?.id;
    final idx = prevId == null ? -1 : trees.indexWhere((t) => t.id == prevId);
    _selectedTree =
        idx == -1 ? (trees.isNotEmpty ? trees.first : null) : trees[idx];

    setState(() {
      _notes = notes;
      _trees = trees;
    });

    if (_selectedTree != null) {
      await _loadForTree(_selectedTree!.id);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadForTree(String treeId) async {
    setState(() => _selectedPoint = null); // 切树 / 刷新后清空选中态
    final kpIds = await _treesRepo.memberPointIds(treeId);
    final points = await _repo.pointsByIds(kpIds);

    final ids = points.map((p) => p.id).toSet();
    final allEdges = await widget.db.select(widget.db.prerequisiteEdges).get();
    final edges = allEdges
        .where((e) => ids.contains(e.fromKpId) && ids.contains(e.toKpId))
        .map((e) => PrerequisiteEdge(
              id: e.id,
              fromKpId: e.fromKpId,
              toKpId: e.toKpId,
              reason: e.reason,
              origin: e.origin,
              confidence: e.confidence,
            ))
        .toList();

    final positions = await _repo.loadNodePositions(treeId);
    if (!mounted) return;
    setState(() {
      _points = points;
      _edges = edges;
      _positions = positions;
      _selectedKpIds.clear();
      _mastery.clear();
      for (final p in points) {
        _mastery[p.id] = MasteryStatus.unknown;
      }
    });

    for (final p in points) {
      final m = await _repo.currentMastery(p.id);
      if (!mounted) return;
      setState(() => _mastery[p.id] = m);
    }

    // ★2.0.0：载入画布富组件（文本卡片 / 手写笔迹）。
    final cards = await _treesRepo.listCards(treeId);
    final strokes = await _treesRepo.listStrokes(treeId);
    if (!mounted) return;
    setState(() {
      _cards = cards;
      _strokes = strokes;
    });
  }

  MasteryStatus _masteryOf(String kpId) => _mastery[kpId] ?? MasteryStatus.unknown;

  // ================= 画布编辑回调 =================

  /// R4：当前树是否被 AI 任务占锁（互斥判定唯一入口在 AiJobService）。
  bool _treeLocked() {
    final tree = _selectedTree;
    if (tree == null) return false;
    return widget.service.jobs.isLocked('tree:${tree.id}');
  }

  /// R4：被挡时提示 + 展开托盘。返回 true = 调用方应放弃操作。
  bool _blockedByJob(String action) {
    if (!_treeLocked()) return false;
    _toast('$action：AI 任务正在处理这棵树，完成后再试');
    widget.service.jobs.requestExpandTray();
    return true;
  }

  /// Q4：拖节点在 AI 连线进行中**放行**（只改坐标不改边），但提示一次。
  void _warnDragIfLocked() {
    if (!_treeLocked()) {
      _warnedLockKey = null;
      return;
    }
    final key = 'tree:${_selectedTree?.id ?? ''}';
    if (_warnedLockKey == key) return;
    _warnedLockKey = key;
    _toast('AI 正在处理这棵树，拖动节点不影响其结果');
  }

  Future<void> _onCreateEdge(String fromKpId, String toKpId) async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    // R4：T3/T4 进行中手动加边会与其同表竞争，硬挡。
    if (_blockedByJob('手动建立前置关系')) return;
    final res = await _repo.addManualPrerequisiteEdge(fromKpId, toKpId);
    if (!mounted) return;
    res.fold(
      (_) => _toast('已建立前置关系'),
      (e, _) => _toast(e is StateError ? e.message : '建立前置关系失败：$e'),
    );
    // 连完新线不再自动重排（用户要求）：只刷新让新边显示，不挪动任何节点。
    await _loadForTree(treeId);
  }

  Future<void> _onDeleteEdge(String edgeId) async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    // R4：删边与 T3/T4 同表竞争，硬挡。
    if (_blockedByJob('删除前置关系')) return;
    final res = await _repo.deletePrerequisiteEdge(edgeId);
    if (!mounted) return;
    res.fold(
      (_) => _toast('已删除该关系'),
      (e, _) => _toast('删除失败：$e'),
    );
    // 删线不再自动重排（用户要求）：只刷新让删除生效，不挪动任何节点。
    await _loadForTree(treeId);
  }

  Future<void> _onMoveNode(String kpId, double x, double y) async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    // Q4：放行 + 提示。
    _warnDragIfLocked();
    await _repo.saveNodePosition(treeId, kpId, x, y);
  }

  /// 框选整组移动结束：批量写回各成员新坐标（松手一次性、pinned=true 锁定）。
  ///
  /// 画布内部的 `_pos` 已实时反映位移，所以这里**不**再 `_loadForTree`（避免整组
  /// 刚移动完就被「服务端真值」覆盖回原位而闪一下）。
  Future<void> _onMoveNodes(Map<String, Offset> positions) async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    // Q4：放行 + 提示。
    _warnDragIfLocked();
    for (final e in positions.entries) {
      await _repo.saveNodePosition(
        treeId,
        e.key,
        e.value.dx,
        e.value.dy,
        pinned: true,
      );
    }
  }

  // ================= ★2.0.0 画布富组件（卡片 / 笔迹）=================

  /// 圆珠笔模式开关（与橡皮 / 作业 / 框选模式互斥）。
  void _togglePenMode() {
    setState(() {
      _penMode = !_penMode;
      if (_penMode) {
        _eraserMode = false;
        _homeworkMode = false;
        _frameMode = false;
        _selectedKpIds.clear();
      }
    });
    if (_penMode) {
      _toast('圆珠笔：在画布上拖拽手写；用橡皮擦整笔擦除');
    }
  }

  /// 橡皮擦模式开关（与画笔 / 作业 / 框选模式互斥）。
  void _toggleEraserMode() {
    setState(() {
      _eraserMode = !_eraserMode;
      if (_eraserMode) {
        _penMode = false;
        _homeworkMode = false;
        _frameMode = false;
        _selectedKpIds.clear();
      }
    });
    if (_eraserMode) {
      _toast('橡皮擦：点 / 拖过手写字迹即整笔擦除');
    }
  }

  /// 在视口中心新建一张文本卡片，建好后立即打开编辑框。
  Future<void> _addCard({required String kind}) async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    final c = _viewportCenter;
    final res = await _treesRepo.createCard(treeId, c.dx, c.dy, kind);
    if (!mounted) return;
    res.fold((vm) {
      setState(() => _cards = [..._cards, vm]);
      _editCard(vm);
    }, (e, _) => _toast('创建卡片失败：$e'));
  }

  /// 卡片拖动结束（落点已吸附网格）：更新本地坐标并持久化。
  Future<void> _onMoveCard(String nodeId, double x, double y) async {
    final parts = nodeId.split(':');
    if (parts.length != 2) return;
    final res = await _treesRepo.moveCard(parts[0], parts[1], x, y);
    if (!mounted) return;
    res.fold(
      (_) => setState(() {
        _cards = [
          for (final card in _cards)
            if (card.nodeId == nodeId)
              CanvasCardVm(
                id: card.id,
                nodeId: card.nodeId,
                x: x,
                y: y,
                w: card.w,
                h: card.h,
                noteId: card.noteId,
                title: card.title,
                body: card.body,
                kind: card.kind,
              )
            else
              card,
        ];
      }),
      (e, _) => _toast('移动卡片失败：$e'),
    );
  }

  /// 画笔抬笔：持久化一笔（repo 生成真 id）。
  Future<void> _onAddStroke(CanvasStrokeVm stroke) async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    final res =
        await _treesRepo.addStroke(treeId, stroke.points, stroke.color, stroke.width);
    if (!mounted) return;
    res.fold(
      (vm) => setState(() => _strokes = [..._strokes, vm]),
      (e, _) => _toast('保存笔迹失败：$e'),
    );
  }

  /// 橡皮命中：删除整笔。
  Future<void> _onEraseStroke(String strokeId) async {
    final res = await _treesRepo.deleteStroke(strokeId);
    if (!mounted) return;
    res.fold(
      (_) => setState(
          () => _strokes = _strokes.where((s) => s.id != strokeId).toList()),
      (e, _) => _toast('擦除失败：$e'),
    );
  }

  /// 由画布点选卡片触发：打开编辑框（标题 / 正文 / 关联笔记 / 删除）。
  Future<void> _editCard(CanvasCardVm vm) async {
    final isNoteCard = vm.kind == 'note_card';
    String? linkedNoteId = vm.noteId;
    final titleCtl = TextEditingController(text: vm.title);
    final bodyCtl = TextEditingController(text: vm.body);
    final action = await showDialog<String?>(
      context: context,
      // 问题6：录入型弹框不让点外部误关，避免输入内容/流程被直接丢掉。
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(isNoteCard ? '编辑笔记卡片' : '编辑文本框'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (isNoteCard)
                  DropdownButton<String?>(
                    value: linkedNoteId,
                    hint: const Text('关联笔记（可选）'),
                    items: <DropdownMenuItem<String?>>[
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('不关联（纯手填）'),
                      ),
                      for (final n in _notes)
                        DropdownMenuItem<String?>(
                          value: n.id,
                          child: Text(_titleOf(n)),
                        ),
                    ],
                    onChanged: (id) {
                      setSt(() => linkedNoteId = id);
                      if (id != null) {
                        final n = _notes.firstWhere((x) => x.id == id);
                        titleCtl.text = _titleOf(n);
                        bodyCtl.text = _noteSummary(n);
                      }
                    },
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: titleCtl,
                  decoration: const InputDecoration(labelText: '标题'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: bodyCtl,
                  decoration: const InputDecoration(labelText: '内容 / 摘要'),
                  maxLines: 4,
                ),
                if (isNoteCard && linkedNoteId != null) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('打开笔记'),
                      onPressed: () => Navigator.of(ctx).pop('open_note'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('delete'),
              child: const Text('删除'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('save'),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'delete') {
      final r = await _treesRepo.deleteCard(vm.id);
      r.fold(
        (_) => setState(
            () => _cards = _cards.where((c) => c.id != vm.id).toList()),
        (e, _) => _toast('删除卡片失败：$e'),
      );
      return;
    }
    if (action == 'save') {
      final r = await _treesRepo.updateCard(
        vm.id,
        title: titleCtl.text,
        body: bodyCtl.text,
        noteId: linkedNoteId,
        kind: vm.kind,
      );
      r.fold(
        (_) => setState(() {
          _cards = [
            for (final card in _cards)
              if (card.id == vm.id)
                CanvasCardVm(
                  id: card.id,
                  nodeId: card.nodeId,
                  x: card.x,
                  y: card.y,
                  w: card.w,
                  h: card.h,
                  noteId: linkedNoteId,
                  title: titleCtl.text,
                  body: bodyCtl.text,
                  kind: card.kind,
                )
              else
                card,
          ];
        }),
        (e, _) => _toast('保存卡片失败：$e'),
      );
    }
    if (action == 'open_note') {
      final id = linkedNoteId;
      titleCtl.dispose();
      bodyCtl.dispose();
      if (id != null && mounted) {
        // 覆盖式 push：CanvasPage 在 IndexedStack 常驻，pop 后自动回到知识树
        // （Tab3）且画布状态保留，不会跳去笔记 Tab。
        await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => NoteEditorPage(
            service: widget.service,
            db: widget.db,
            noteId: id,
          ),
        ));
      }
      return;
    }
    titleCtl.dispose();
    bodyCtl.dispose();
  }

  /// 由关联笔记派生「摘要」：取正文首个非空段落，超 120 字截断。
  String _noteSummary(Note n) {
    final paras = n.contentMd
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => l.trim())
        .toList();
    final first = paras.isNotEmpty ? paras.first : '';
    return first.length > 120 ? '${first.substring(0, 120)}…' : first;
  }

  Future<void> _onRelayout() async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    // 手动「重新布局」= 用布局引擎重算所有成员坐标并写回，绝不删除 canvas_nodes 行
    // （那一行同时是「树成员关系」，删除会把知识点从树里移除，见已修 bug）。
    // 全量重排后所有节点一并「锁定」（pinned=true）：之后结构变化不再自动挪动它们，
    // 直到用户再次手动重排或拖动某个节点（拖动会单独锁定那个节点）。
    final layout = layoutForest(_points, _edges, config: const LayoutConfig());
    for (final n in layout.nodes) {
      await _repo.saveNodePosition(treeId, n.kpId, n.x, n.y, pinned: true);
    }
    setState(() => _relayoutVersion++);
    await _loadForTree(treeId);
    _toast('已重新布局（全部锁定）');
  }

  /// 局部重排：只对当前框选（[_selectedKpIds]）的知识点重跑布局，其余节点不动。
  ///
  /// 与全量 [_onRelayout] 的区别：先把**未选中**成员的真实矩形当作占位，再只对子集
  /// 内部跑 [layoutForest]，最后用 [findFreeBlockTopLeft] 把子集整体放到一个不与
  /// 未选中节点相交的位置——避免「子集重排后叠到别人身上」。
  Future<void> _relayoutSelected() async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    final idSet = <String>{..._selectedKpIds};
    final subsetPts = _points.where((p) => idSet.contains(p.id)).toList();
    if (idSet.isEmpty || subsetPts.isEmpty) {
      _toast('请先框选要重排的知识点');
      return;
    }
    final subsetEdges = _edges
        .where((e) => idSet.contains(e.fromKpId) && idSet.contains(e.toKpId))
        .toList();

    const config = LayoutConfig();
    // 只算子集：子集内部边决定它们的相对层级 / 顺序。
    final layout = layoutForest(subsetPts, subsetEdges, config: config);

    // 未选中成员的真实坐标 → 占位矩形（子集必须避开）。
    final layoutById = await _repo.loadNodeLayout(treeId);
    final occupied = <LayoutBox>[];
    for (final p in _points) {
      if (idSet.contains(p.id)) continue;
      final pos = layoutById[p.id];
      if (pos == null) continue; // 未固化位置的点不占位
      occupied.add(LayoutBox(pos.x, pos.y, config.nodeWidth, config.nodeHeight));
    }

    // 首选：尽量把子集整体留在它当前所在处（取选中点当前左上角的最小 x / y）。
    var preferredLeft = 0.0;
    var preferredTop = 0.0;
    var hasSel = false;
    for (final p in subsetPts) {
      final pos = layoutById[p.id];
      if (pos == null) continue;
      if (!hasSel) {
        preferredLeft = pos.x;
        preferredTop = pos.y;
        hasSel = true;
      } else {
        if (pos.x < preferredLeft) preferredLeft = pos.x;
        if (pos.y < preferredTop) preferredTop = pos.y;
      }
    }

    // 子集整体块尺寸（以子布局 (0,0) 为基准）。
    var blockWidth = config.nodeWidth;
    var blockHeight = config.nodeHeight;
    for (final n in layout.nodes) {
      final w = n.x + config.nodeWidth;
      final h = n.y + config.nodeHeight;
      if (w > blockWidth) blockWidth = w;
      if (h > blockHeight) blockHeight = h;
    }

    final free = findFreeBlockTopLeft(
      blockWidth: blockWidth,
      blockHeight: blockHeight,
      occupied: occupied,
      preferredLeft: preferredLeft,
      preferredTop: preferredTop,
      step: config.gridSize > 0 ? config.gridSize : 20,
    );

    for (final n in layout.nodes) {
      await _repo.saveNodePosition(
        treeId,
        n.kpId,
        snapToGrid(free.left + n.x, config.gridSize),
        snapToGrid(free.top + n.y, config.gridSize),
        pinned: true,
      );
    }
    setState(() => _relayoutVersion++);
    await _loadForTree(treeId);
    _toast('已局部重排 ${layout.nodes.length} 个知识点');
  }

  /// 给一批「刚并入树、还没摆位置」的知识点算不重叠的布局坐标并写回 DB。
  ///
  /// 根因：TreeRepository.addPoints 写出的 canvas_nodes 行 x/y 默认 0，而布局引擎
  /// 把「库里有位置 (0,0)」当成「已放在原点」，导致新点全挤在 (0,0)、也拖不动。
  /// 具体算坐标的逻辑抽到 [autoPlaceNewPointsInTree]（canvas 与 Agent 共用）。
  Future<void> _autoPlaceNewPoints(String treeId, List<String> newIds) =>
      autoPlaceNewPointsInTree(
        db: widget.db,
        trees: _treesRepo,
        repo: _repo,
        treeId: treeId,
        newIds: newIds,
      );

  // ================= 知识树管理 =================

  /// 新建一棵树并刷新页面状态，返回新建的树（失败 / 取消返回 null）。
  ///
  /// 工具栏「＋ 新建知识树」与建议 sheet 的「＋ 新建知识树」共用同一逻辑。
  Future<KnowledgeTree?> _createTreeInline() async {
    final name = await _askName('新建知识树', '给这棵树起个名字', '');
    if (name == null || name.trim().isEmpty) return null;
    final res = await _treesRepo.createTree(name.trim());
    if (!mounted) return null;
    final created = res.valueOrNull;
    if (created == null) {
      res.fold((_) => null, (e, _) => _toast('新建失败：$e'));
      return null;
    }
    await _load();
    if (!mounted) return created;
    // 新建后自动切过去
    final idx = _trees.indexWhere((t) => t.id == created.id);
    final target = idx == -1 ? created : _trees[idx];
    setState(() => _selectedTree = target);
    await _loadForTree(target.id);
    return created;
  }

  Future<void> _newTree() async {
    await _createTreeInline();
  }

  Future<void> _renameTree() async {
    final tree = _selectedTree;
    if (tree == null) return;
    final name = await _askName('重命名知识树', '新的名字', tree.name);
    if (name == null || name.trim().isEmpty) return;
    await _treesRepo.renameTree(tree.id, name.trim());
    await _load();
  }

  Future<void> _deleteTree() async {
    final tree = _selectedTree;
    if (tree == null) return;
    // R4：AI 任务在写这棵树时删树，硬挡。
    if (_blockedByJob('删除知识树')) return;
    final kpIds = await _treesRepo.memberPointIds(tree.id);

    if (!mounted) return;
    // 只删树（解除关系）还是连知识点一起删——由用户在弹窗里决定。
    final also = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除知识树'),
        content: Text(
          '「${tree.name}」里有 ${kpIds.length} 个知识点。\n\n'
          '仅删除这棵树：知识点会保留为独立资产，之后仍可并入别的树。\n'
          '连同知识点一起删除：不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('仅删除树'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '连同知识点删除',
              style: TextStyle(color: Colors.red),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (also == null) return;

    final res = await _treesRepo.deleteTree(tree.id, deletePoints: also);
    if (!mounted) return;
    res.fold(
      (_) => _toast(also ? '已删除树和知识点' : '已删除树（知识点保留）'),
      (e, _) => _toast('删除失败：$e'),
    );
    setState(() => _selectedTree = null);
    await _load();
  }

  /// 把某篇笔记的知识点并入当前树（一篇文章可以喂给多棵树）。
  Future<void> _mergeFromNote() async {
    final tree = _selectedTree;
    if (tree == null) return;

    final notes = _notes;
    final query = TextEditingController();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) {
        var keyword = '';
        return StatefulBuilder(
          builder: (ctx, setSt) {
            final filtered = notes
                .where((n) =>
                    _titleOf(n).toLowerCase().contains(keyword.toLowerCase()))
                .toList();
            return AlertDialog(
            title: const Text('把哪篇笔记的知识点并入？'),
            content: SizedBox(
              width: 420,
              height: 360,
              child: Column(
                children: [
                  TextField(
                    controller: query,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索笔记标题',
                      isDense: true,
                    ),
                    onChanged: (v) => setSt(() => keyword = v.trim()),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(
                            child: Text('没有匹配的笔记',
                                style: TextStyle(color: Colors.grey)),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final n = filtered[i];
                              return ListTile(
                                dense: true,
                                title: Text(_titleOf(n),
                                    overflow: TextOverflow.ellipsis),
                                onTap: () => Navigator.pop(ctx, n.id),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
            ],
          );
        },
      );
    },
    );
    query.dispose();
    if (picked == null) return;

    final kps = await _repo.pointsForNote(picked);
    if (kps.isEmpty) {
      _toast('这篇笔记还没有知识点，先去「提取」页跑一次 T1');
      return;
    }
    final existing = await _treesRepo.memberPointIds(tree.id);
    final newIds =
        kps.where((p) => !existing.contains(p.id)).map((p) => p.id).toList();
    final res =
        await _treesRepo.addPoints(tree.id, kps.map((p) => p.id).toList());
    if (!mounted) return;
    await res.fold(
      (added) async {
        // 新并入的点用布局引擎铺开，避免全挤在 (0,0)。
        await _autoPlaceNewPoints(tree.id, newIds);
        _toast(added == 0 && newIds.isEmpty
            ? '这些知识点已经在树里了'
            : '已并入 $added 个知识点');
      },
      (e, _) async => _toast('并入失败：$e'),
    );
    await _loadForTree(tree.id);
  }

  /// P1-4：把已有知识点（不在当前树里的）加入当前树。
  ///
  /// 弹窗多选；提交后 `addPoints` 幂等跳过已在树的，新点用布局引擎铺位避免全挤在 (0,0)。
  Future<void> _addKnowledgePoints() async {
    final tree = _selectedTree;
    if (tree == null) return;
    final existing = await _treesRepo.memberPointIds(tree.id);
    final all = await _repo.allKnowledgePoints();
    final candidates =
        all.where((p) => !existing.contains(p.id)).toList();
    if (!mounted) return;
    final selected = <String>{};
    final query = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      // 问题6：多选加入树是录入流程，禁止点外部误关（有显式「取消」）。
      barrierDismissible: false,
      builder: (ctx) {
        var keyword = '';
        return StatefulBuilder(
          builder: (ctx, setSt) {
            final filtered = candidates.where((p) {
              final k = keyword.toLowerCase();
              return p.name.toLowerCase().contains(k) ||
                  p.type.label.toLowerCase().contains(k);
            }).toList();
            return AlertDialog(
            title: Text('向「${tree.name}」添加知识点'),
            content: candidates.isEmpty
                ? const SizedBox(
                    height: 120,
                    child: Center(
                      child: Text('没有可添加的知识点（都已经在树里了）',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  )
                : SizedBox(
                    width: 420,
                    height: 420,
                    child: Column(
                      children: [
                        TextField(
                          controller: query,
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            hintText: '搜索知识点名称 / 类型',
                            isDense: true,
                          ),
                          onChanged: (v) => setSt(() => keyword = v.trim()),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: filtered.isEmpty
                              ? const Center(
                                  child: Text('没有匹配的知识点',
                                      style: TextStyle(color: Colors.grey)),
                                )
                              : ListView.builder(
                                  itemCount: filtered.length,
                                  itemBuilder: (_, i) {
                                    final kp = filtered[i];
                                    return CheckboxListTile(
                                      dense: true,
                                      value: selected.contains(kp.id),
                                      onChanged: (v) => setSt(() {
                                        if (v == true) {
                                          selected.add(kp.id);
                                        } else {
                                          selected.remove(kp.id);
                                        }
                                      }),
                                      title: Text(kp.name),
                                      subtitle: Text(kp.type.label),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed:
                    selected.isEmpty ? null : () => Navigator.pop(ctx, true),
                child: const Text('添加'),
              ),
            ],
            );
          }
        );
      },
    );
    query.dispose();
    if (ok != true || selected.isEmpty) return;
    final ids = selected.toList();
    final res = await _treesRepo.addPoints(tree.id, ids);
    if (!mounted) return;
    await _autoPlaceNewPoints(tree.id, ids);
    res.fold(
      (added) =>
          _toast(added == 0 ? '都在树里了' : '已添加 $added 个知识点'),
      (e, _) => _toast('添加失败：$e'),
    );
    await _loadForTree(tree.id);
  }

  /// 在知识树界面「就地」新建知识点：填名称 / 类型 / 定义 → 落库 → 收进当前树
  /// → 自动落位 → 触发一轮查重。
  ///
  /// 与「知识点管理」页手动新建的差别只有一处：**不做「关联笔记」下拉**——
  /// 树上快速建点的场景里，用户想要的只是一个能立刻摆到画布上的节点；来源笔记
  /// 留空即可，之后仍可在管理页补。其余口径完全对齐：同样走
  /// [KnowledgeRepository.createManualKnowledgePoint]（origin=user_manual，
  /// 豁免 T1 锚点铁律），同样在**新建**后调 [kpDedupSchedule] 跑 T14 查重
  /// （跨树加入那种「没创建新知识点」的场景才故意不查重）。
  ///
  /// 落位交给 [_autoPlaceNewPoints]：只在「已有内容下方」找一个不重叠空位，
  /// 不挤占现有节点、不触发全树重排（详见 [autoPlaceNewPointsInTree]）。
  Future<void> _newKnowledgePoint() async {
    final tree = _selectedTree;
    if (tree == null) return;

    final nameCtrl = TextEditingController();
    final defCtrl = TextEditingController();
    var type = KnowledgePointType.concept;

    final created = await showDialog<KnowledgePoint>(
      context: context,
      // 问题6：新增知识点是录入流程，禁止点外部误关（有显式「取消」）。
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('新建知识点'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '名称（必填）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<KnowledgePointType>(
                    initialValue: type,
                    decoration: const InputDecoration(
                      labelText: '类型',
                      isDense: true,
                    ),
                    items: <DropdownMenuItem<KnowledgePointType>>[
                      for (final t in KnowledgePointType.values)
                        DropdownMenuItem<KnowledgePointType>(
                          value: t,
                          child: Text(t.label),
                        ),
                    ],
                    onChanged: (v) => setSt(() => type = v ?? type),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: defCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '定义',
                      isDense: true,
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) {
                  _toast('名称不能为空');
                  return;
                }
                final res = await _repo.createManualKnowledgePoint(
                  name: name,
                  type: type,
                  definition: defCtrl.text,
                );
                if (!mounted) return;
                final kp = res.valueOrNull;
                if (kp == null) {
                  final msg = res is Failure<KnowledgePoint>
                      ? res.message
                      : '未知错误';
                  _toast('新建失败：$msg');
                  return;
                }
                Navigator.pop(ctx, kp);
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    // 注意：**不要**在这里 dispose 两个 controller。`showDialog` 的 future 在路由
    // pop 的瞬间就已完成，此时弹窗还在退场动画里、TextField 仍会随动画重建，
    // 立即 dispose 会撞上「A TextEditingController was used after being disposed」。
    // 与同文件 [_askName]、管理页 `_showEditDialog` 的口径一致：弹窗局部
    // controller 交给 GC。
    if (created == null || !mounted) return;

    // 1) 收进当前树（addPoints 幂等写 canvas_nodes 成员行）。
    final addRes = await _treesRepo.addPoints(tree.id, <String>[created.id]);
    if (!mounted) return;
    if (addRes is Failure<int>) {
      _toast('加入知识树失败：${addRes.message}');
      return;
    }
    // 2) 落位：已有内容下方第一个不重叠空位（不挤占节点、不触发全树重排）。
    await _autoPlaceNewPoints(tree.id, <String>[created.id]);
    if (!mounted) return;
    // 3) 手动新建 → 后台异步跑一轮知识点查重（T14），与管理页手动新建同口径。
    kpDedupSchedule(repo: _repo, jobs: widget.service.jobs);
    await _loadForTree(tree.id);
    _toast('已新建并加入知识树');
  }

  /// 在知识树界面「就地」编辑某个已存在的知识点：名称 / 类型 / 定义。
  ///
  /// 入口是 [_showNodeActions] 浮层的「编辑知识点」——用户不必跳去「知识点管理」
  /// 页就能改掉画布上刚发现的问题点。
  ///
  /// **可改字段刻意只有三个**（与「知识点管理」页的编辑弹窗同口径）：
  /// - 名称 / 类型 / 定义是展示性字段，用户可自由改；
  /// - 锚点四件套（`sourceNoteId` / `sourceStart` / `sourceEnd` / `sourceQuote`）
  ///   是「这个点从哪来」的硬证据，`origin` / `confidence` 是抽取时的元信息，
  ///   全部**原样带回**——[KnowledgePoint.copyWith] 本就会保留它们，落库侧
  ///   [KnowledgeRepository.updateKpMeta] 也只写 name/type/definition/sourceNoteId
  ///   四列，并自带 `version + 1` 与 sync outbox 入队，锚点不会被这次编辑破坏。
  /// - 树成员关系、节点坐标存在 `canvas_nodes`，本方法**完全不碰**，所以存完
  ///   位置不变、连线不变。
  ///
  /// 与 [_newKnowledgePoint] 的差别只有一处：**不做「关联笔记」下拉**（树上快速
  /// 编辑的场景里用户要的是「把名字/定义改对」），来源笔记沿用原值。其余形态完全
  /// 对齐：SingleChildScrollView 承载（小屏/横屏不溢出）、名称为空就地 toast 且
  /// **不关窗**、弹窗局部 TextEditingController 交给 GC。
  Future<void> _showEditKpDialog(KnowledgePoint kp) async {
    final nameCtrl = TextEditingController(text: kp.name);
    final defCtrl = TextEditingController(text: kp.definition);
    var type = kp.type;

    final saved = await showDialog<bool>(
      context: context,
      // 问题6：编辑知识点是录入流程，禁止点外部误关（有显式「取消」）。
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('编辑知识点'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '名称（必填）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<KnowledgePointType>(
                    initialValue: type,
                    decoration: const InputDecoration(
                      labelText: '类型',
                      isDense: true,
                    ),
                    items: <DropdownMenuItem<KnowledgePointType>>[
                      for (final t in KnowledgePointType.values)
                        DropdownMenuItem<KnowledgePointType>(
                          value: t,
                          child: Text(t.label),
                        ),
                    ],
                    onChanged: (v) => setSt(() => type = v ?? type),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: defCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '定义',
                      isDense: true,
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) {
                  _toast('名称不能为空');
                  return;
                }
                // 只改三项；锚点 / origin / confidence / version 由 copyWith 原样保留。
                final updated = kp.copyWith(
                  name: name,
                  type: type,
                  definition: defCtrl.text,
                );
                final res = await _repo.updateKpMeta(updated);
                if (!mounted) return;
                if (res is Failure<KnowledgePoint>) {
                  _toast('保存失败：${res.message}');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    // 同 [_newKnowledgePoint]：**不要**在这里 dispose 两个 controller。
    // `showDialog` 的 future 在路由 pop 的瞬间就已完成，此时弹窗还在退场动画里、
    // TextField 仍会随动画重建，立即 dispose 会撞上
    // 「A TextEditingController was used after being disposed」。交给 GC。
    if (saved != true || !mounted) return;

    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    // 刷新整棵树（名称/类型/定义都参与渲染），顺带让这条改动落到画布上。
    await _loadForTree(treeId);
    if (!mounted) return;
    // [_loadForTree] 首行会清空选中态；这里按 id 从刷新后的列表里找回**新实例**
    // 重新选中——否则用户刚编辑完的点会自己「掉选」，得再点一次。
    // （不用 collection 的 firstWhereOrNull：本项目未声明该直接依赖。）
    KnowledgePoint? fresh;
    for (final q in _points) {
      if (q.id == kp.id) {
        fresh = q;
        break;
      }
    }
    setState(() => _selectedPoint = fresh);
    _toast('已更新');
  }

  /// 从其他知识树加入知识点：选源树 → 勾选该树的成员（已在当前树的置灰）→
  /// 加入当前选中的树。
  ///
  /// 落位保留**源树里的相对坐标**（[placeTransferredPointsInTree]），不重新布局；
  /// 源树内部的连线也无需搬运——画布按全局 `prerequisite_edges` 过滤当前树成员
  /// 之间的边，两端点进了同一棵树，线会自动出现。
  Future<void> _copyFromOtherTree() async {
    final tree = _selectedTree;
    if (tree == null) return;

    final allTrees = await _treesRepo.listTrees();
    final sources = allTrees.where((t) => t.id != tree.id).toList();
    if (!mounted) return;
    if (sources.isEmpty) {
      _toast('还没有其他知识树');
      return;
    }

    // 1) 选源树。
    final sourceTree = await showDialog<KnowledgeTree>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('从哪棵树加入？'),
        children: [
          for (final t in sources)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, t),
              child: Text(
                t.name.isEmpty ? '(未命名)' : t.name,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
    if (sourceTree == null || !mounted) return;

    // 2) 读源树成员 + 当前树已有成员（用于置灰「已在当前树」）。
    final sourceIds = await _treesRepo.memberPointIds(sourceTree.id);
    final existing = (await _treesRepo.memberPointIds(tree.id)).toSet();
    final points = await _repo.pointsByIds(sourceIds);
    if (!mounted) return;
    if (points.isEmpty) {
      _toast('「${sourceTree.name}」里还没有知识点');
      return;
    }

    // 3) 多选对话框（结构参照 [_addKnowledgePoints]）。
    final selected = <String>{};
    final query = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        var keyword = '';
        return StatefulBuilder(
          builder: (ctx, setSt) {
            final filtered = points.where((p) {
              final k = keyword.toLowerCase();
              return p.name.toLowerCase().contains(k) ||
                  p.type.label.toLowerCase().contains(k);
            }).toList();
            return AlertDialog(
              title: Text('从《${sourceTree.name}》加入知识点'),
              content: SizedBox(
                width: 420,
                height: 420,
                child: Column(
                  children: [
                    TextField(
                      controller: query,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: '搜索知识点名称 / 类型',
                        isDense: true,
                      ),
                      onChanged: (v) => setSt(() => keyword = v.trim()),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(
                              child: Text('没有匹配的知识点',
                                  style: TextStyle(color: Colors.grey)),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (_, i) {
                                final kp = filtered[i];
                                final already = existing.contains(kp.id);
                                return CheckboxListTile(
                                  dense: true,
                                  value: already || selected.contains(kp.id),
                                  // 已在当前树的置灰不可勾选。
                                  onChanged: already
                                      ? null
                                      : (v) => setSt(() {
                                            if (v == true) {
                                              selected.add(kp.id);
                                            } else {
                                              selected.remove(kp.id);
                                            }
                                          }),
                                  title: Text(kp.name),
                                  subtitle: Text(
                                      already ? '已在当前树' : kp.type.label),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(ctx, true),
                  child: const Text('加入'),
                ),
              ],
            );
          },
        );
      },
    );
    query.dispose();
    if (ok != true || selected.isEmpty || !mounted) return;

    // 4) 先落成员行（幂等），再只对**真正新增**的点按源树相对坐标整块落位。
    final ids = selected.toList();
    final newIds = ids.where((id) => !existing.contains(id)).toList();
    final addRes = await _treesRepo.addPoints(tree.id, ids);
    if (!mounted) return;
    if (addRes is Failure<int>) {
      _toast('加入失败：${addRes.error}');
      return;
    }
    final added = addRes.valueOrNull ?? 0;
    if (newIds.isNotEmpty) {
      await placeTransferredPointsInTree(
        trees: _treesRepo,
        repo: _repo,
        sourceTreeId: sourceTree.id,
        targetTreeId: tree.id,
        kpIds: newIds,
      );
    }
    if (!mounted) return;
    _toast('已从「${sourceTree.name}」加入 $added 个知识点');
    // 跨树加入只新增成员行、不创建知识点：跑 T14 查重纯浪费 LLM 调用，故意不调
    // kpDedupSchedule（别「补全」）。
    await _loadForTree(tree.id);
  }

  /// 从当前知识树移除知识点（只解除成员关系，知识点仍保留为独立资产）。
  ///
  /// 弹窗多选当前树成员；提交后 [TreeRepository.removePoints] 删除 canvas_nodes
  /// 行（硬删、同步对账），不触碰知识点本体，也不动全局前置关系（边按当前树成员
  /// 过滤渲染，移除后自然不再显示）。
  Future<void> _removeFromTree() async {
    final tree = _selectedTree;
    if (tree == null) return;
    final members = _points;
    if (members.isEmpty) {
      _toast('这棵树还没有知识点');
      return;
    }
    final selected = <String>{};
    final query = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      // 问题6：跨树多选加入是录入流程，禁止点外部误关（有显式「取消」）。
      barrierDismissible: false,
      builder: (ctx) {
        var keyword = '';
        return StatefulBuilder(
          builder: (ctx, setSt) {
            final filtered = members.where((p) {
              final k = keyword.toLowerCase();
              return p.name.toLowerCase().contains(k);
            }).toList();
            return AlertDialog(
              title: Text('从「${tree.name}」移除知识点'),
              content: SizedBox(
                width: 420,
                height: 420,
                child: Column(
                  children: [
                    TextField(
                      controller: query,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: '搜索知识点名称',
                        isDense: true,
                      ),
                      onChanged: (v) => setSt(() => keyword = v.trim()),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(
                              child: Text('没有匹配的知识点',
                                  style: TextStyle(color: Colors.grey)),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (_, i) {
                                final kp = filtered[i];
                                return CheckboxListTile(
                                  dense: true,
                                  value: selected.contains(kp.id),
                                  onChanged: (v) => setSt(() {
                                    if (v == true) {
                                      selected.add(kp.id);
                                    } else {
                                      selected.remove(kp.id);
                                    }
                                  }),
                                  title: Text(kp.name),
                                  subtitle: Text(kp.type.label),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed:
                      selected.isEmpty ? null : () => Navigator.pop(ctx, true),
                  child: const Text('移除'),
                ),
              ],
            );
          }
        );
      },
    );
    query.dispose();
    if (ok != true || selected.isEmpty) return;
    final ids = selected.toList();
    final res = await _treesRepo.removePoints(tree.id, ids);
    if (!mounted) return;
    res.fold(
      (_) {
        _toast('已从树中移除 ${ids.length} 个知识点（知识点仍保留为资产）');
        _selectedKpIds.removeAll(ids);
      },
      (e, _) => _toast('移除失败：$e'),
    );
    await _loadForTree(tree.id);
  }

  /// 框选模式下，把当前框选（[_selectedKpIds]）的知识点从树中批量移除。
  Future<void> _removeSelectedFromTree() async {
    final tree = _selectedTree;
    if (tree == null) return;
    final ids = <String>{..._selectedKpIds};
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从知识树移除选中的知识点？'),
        content: Text(
            '将移除 $ids.length 个框选知识点（知识点仍保留为资产，其全局前置关系不动）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await _treesRepo.removePoints(tree.id, ids.toList());
    if (!mounted) return;
    res.fold(
      (_) {
        _toast('已移除 ${ids.length} 个知识点');
        _selectedKpIds.clear();
      },
      (e, _) => _toast('移除失败：$e'),
    );
    await _loadForTree(tree.id);
  }

  /// 自动连线（B2：默认走队列，提交即返回；同步路径保留）。
  ///
  /// [force] = true 表示用户在画布上手动点「自动连线」：手动操作不受
  /// 「自动连线」开关约束（该开关只管 AI 链式自动连线）。
  Future<void> _autoLink({bool force = false}) async {
    final tree = _selectedTree;
    if (tree == null) return;
    // 受「自动连线」开关控制（E）：关 → AI 链式路径不自动建立边。
    if (!force && !TreeBehaviorSettings.instance.autoLinkEnabled) return;
    if (!kAiJobQueueEnabled) {
      await _autoLinkSync(tree);
      return;
    }
    if (_blockedByJob('自动连线')) return;
    final inputs = await _auto.linkInputsFor(tree.id);
    if (inputs == null) {
      _toast('知识点不足 2 个，无法自动连线');
      return;
    }
    try {
      final job = await widget.service.jobs.submit(
        task: AiTask.t3Prerequisite.code,
        resourceKey: 'tree:${tree.id}',
        label: '自动连线《${tree.name}》',
        inputs: inputs,
        onDone: (j) async {
          final res = await _auto.linkFromParsed(tree.id, j.result?['parsed']);
          if (!mounted) return;
          res.fold(
            (r) {
              j.doneMessage = r.created > 0
                  ? '已自动建立 ${r.created} 条前置关系（AI）'
                  : (r.note.isNotEmpty
                      ? r.note
                      : '没有可自动连接的新关系（可能已全部连好）');
              // 连完新线不再自动重排（用户要求）：只刷新让新边显示。
              _loadForTree(tree.id);
            },
            (e, _) => _toast('自动连线失败：$e'),
          );
        },
      );
      if (job == null) {
        _toast('这棵树有 AI 任务正在进行，完成后再试');
        widget.service.jobs.requestExpandTray();
      }
    } on Object {
      _toast('AI 服务连接失败，改用同步处理');
      await _autoLinkSync(tree);
    }
  }

  /// 自动连线 · 同步路径（开关关闭 / 服务不可达兜底）。
  Future<void> _autoLinkSync(KnowledgeTree tree) async {
    final loading = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('正在分析知识点之间的前置关系…')),
          ],
        ),
      ),
    );
    final res = await _auto.autoLink(tree.id);
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    } else {
      return;
    }
    res.fold(
      (r) {
        if (r.created > 0) {
          // 仅 AI（T3 失败即 Failure，无本地启发式兜底，见决策 15）。
          _toast('已自动建立 ${r.created} 条前置关系（AI）');
          // 连完新线不再自动重排（用户要求）：只刷新让新边显示。
          _loadForTree(tree.id);
        } else {
          _toast(r.note.isNotEmpty
              ? r.note
              : '没有可自动连接的新关系（可能已全部连好）');
        }
      },
      (e, _) => _toast('自动连线失败：$e'),
    );
    await loading.catchError((_) {});
  }

  /// 局部连线（B2 局部版「自动连线」）：只对当前框选（[_selectedKpIds]）的知识点推断
  /// 前置关系，其余知识点视为不存在——过滤只发生在**应用侧**（[AutoGraphService.linkFromParsed]
  /// 的 restrictToIds 参数），不在 [AutoGraphService.linkInputsFor] 的输入里裁剪。
  ///
  /// 决策：T3 的 inputs 仍用**全树**上下文（[AutoGraphService.linkInputsFor]），因为模型
  /// 需要全树信息才推断得准；只在落库时过滤两端都在集合内的边（需求 ②）。
  Future<void> _autoLinkSelected({bool force = false}) async {
    final tree = _selectedTree;
    if (tree == null) return;
    // 受「自动连线」开关控制（E）：关 → AI 链式路径不自动建立边。
    // [force] = true 为用户手动点选，不受开关约束。
    if (!force && !TreeBehaviorSettings.instance.autoLinkEnabled) return;
    if (_selectedKpIds.length < 2) {
      _toast('请先框选至少 2 个知识点（先开「框选模式」）再局部连线');
      return;
    }
    final ids = <String>{..._selectedKpIds};
    if (!kAiJobQueueEnabled) {
      await _autoLinkSelectedSync(tree, ids);
      return;
    }
    if (_blockedByJob('局部连线')) return;
    // 队列提交的 inputs 用全树上下文（模型需要全树信息），过滤在 onDone 应用侧做。
    final inputs = await _auto.linkInputsFor(tree.id);
    if (inputs == null) {
      _toast('知识点不足 2 个，无法自动连线');
      return;
    }
    try {
      final job = await widget.service.jobs.submit(
        task: AiTask.t3Prerequisite.code,
        resourceKey: 'tree:${tree.id}',
        label: '局部连线《${tree.name}》',
        inputs: inputs,
        onDone: (j) async {
          final res = await _auto.linkFromParsed(
            tree.id,
            j.result?['parsed'],
            restrictToIds: ids,
          );
          if (!mounted) return;
          res.fold(
            (r) {
              j.doneMessage = r.created > 0
                  ? '已局部建立 ${r.created} 条前置关系（AI）'
                  : (r.note.isNotEmpty
                      ? r.note
                      : '没有可自动连接的新关系（可能已全部连好）');
              // 连完新线不再自动重排（用户要求）：只刷新让新边显示。
              _loadForTree(tree.id);
            },
            (e, _) => _toast('局部连线失败：$e'),
          );
        },
      );
      if (job == null) {
        _toast('这棵树有 AI 任务正在进行，完成后再试');
        widget.service.jobs.requestExpandTray();
      }
    } on Object {
      _toast('AI 服务连接失败，改用同步处理');
      await _autoLinkSelectedSync(tree, ids);
    }
  }

  /// 局部连线 · 同步路径（开关关闭 / 服务不可达兜底）。
  ///
  /// 改动最小的方案：复用 [_auto.autoLink]（已加 restrictToIds 透传），由它内部走
  /// 「全树 inputs → LLM → 应用侧过滤」的组合。
  Future<void> _autoLinkSelectedSync(KnowledgeTree tree, Set<String> ids) async {
    final loading = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('正在分析选中知识点的前置关系…')),
          ],
        ),
      ),
    );
    final res = await _auto.autoLink(tree.id, restrictToIds: ids);
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    } else {
      return;
    }
    res.fold(
      (r) {
        if (r.created > 0) {
          // 仅 AI（T3 失败即 Failure，无本地启发式兜底，见决策 15）。
          _toast('已局部建立 ${r.created} 条前置关系（AI）');
          // 连完新线不再自动重排（用户要求）：只刷新让新边显示。
          _loadForTree(tree.id);
        } else {
          _toast(r.note.isNotEmpty
              ? r.note
              : '没有可自动连接的新关系（可能已全部连好）');
        }
      },
      (e, _) => _toast('局部连线失败：$e'),
    );
    await loading.catchError((_) {});
  }

  /// 节点点选回调：记录选中态并弹出操作浮层（标记掌握 / 连接前置 / 补充前置知识）。
  void _onKpTap(KnowledgePoint p) {
    setState(() => _selectedPoint = p);
    _showNodeActions(p);
  }

  /// 操作浮层：选中节点后的动作（编辑 / 讲解 / 掌握度 / 连线 / 补前置）。
  ///
  /// 这是**单点操作的唯一入口**：想改某个知识点不必跳去「知识点管理」页，
  /// 在这里点「编辑知识点」即可就地改名称 / 类型 / 定义（见 [_showEditKpDialog]）。
  Future<void> _showNodeActions(KnowledgePoint p) async {
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑知识点'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.school),
              title: const Text('AI 讲解 / 追问'),
              onTap: () => Navigator.pop(ctx, 'teach'),
            ),
            ListTile(
              leading: const Icon(Icons.star),
              title: const Text('标记为已掌握'),
              onTap: () => Navigator.pop(ctx, 'master'),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('连接前置'),
              subtitle: const Text('在节点卡片右上角的连接按钮上点一下即可建立前置关系'),
              onTap: () => Navigator.pop(ctx, 'link'),
            ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('补充前置知识'),
              onTap: () => Navigator.pop(ctx, 'prereq'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'edit':
        await _showEditKpDialog(p);
      case 'teach':
        widget.onKpTap?.call(p);
      case 'master':
        await _markMastered(p);
      case 'link':
        _toast('在节点卡片右上角的连接按钮上点一下即可建立前置关系');
      case 'prereq':
        _openDepthSheet(p);
    }
  }

  /// 标记掌握度：列出五种状态供选择，写库后刷新该点掌握度。
  Future<void> _markMastered(KnowledgePoint p) async {
    if (!mounted) return;
    final status = await showModalBottomSheet<MasteryStatus>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in MasteryStatus.values)
              ListTile(
                leading: const Icon(Icons.circle, size: 14),
                title: Text(s.label),
                onTap: () => Navigator.pop(ctx, s),
              ),
          ],
        ),
      ),
    );
    if (status == null) return;
    final res = await _repo.setMastery(p.id, status);
    if (!mounted) return;
    final treeId = _selectedTree?.id;
    res.fold(
      (_) {
        _toast('已标记为「${status.label}」');
        if (treeId != null) _loadForTree(treeId);
      },
      (e, _) => _toast('标记失败：$e'),
    );
  }

  /// 深度选择器 BottomSheet：低 / 中 / 高 / 自定义（+ 自定义输入框）。
  void _openDepthSheet(KnowledgePoint p) {
    PrereqDepth depth = PrereqDepth.medium;
    final customController = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('补充前置知识到什么深度？',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                SegmentedButton<PrereqDepth>(
                  selected: {depth},
                  onSelectionChanged: (s) => setSt(() => depth = s.first),
                  segments: const [
                    ButtonSegment(value: PrereqDepth.low, label: Text('低')),
                    ButtonSegment(value: PrereqDepth.medium, label: Text('中')),
                    ButtonSegment(value: PrereqDepth.high, label: Text('高')),
                    ButtonSegment(
                        value: PrereqDepth.custom, label: Text('自定义')),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    depth == PrereqDepth.low
                        ? '低：最近一层直接相关前置'
                        : depth == PrereqDepth.medium
                            ? '中：中等基础（初中/高中）'
                            : depth == PrereqDepth.high
                                ? '高：最基础（小学/常识）'
                                : '自定义：用自然语言描述你想要的深度',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                if (depth == PrereqDepth.custom)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: TextField(
                      controller: customController,
                      decoration: const InputDecoration(
                        labelText: '自定义深度指令（如：补到大学水平即可）',
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          final custom = customController.text;
                          Navigator.pop(ctx);
                          _runPrereq(
                            p,
                            depth,
                            depth == PrereqDepth.custom ? custom : null,
                          );
                        },
                        child: const Text('生成'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 跑深度补前置（B2：默认走队列——递归驱动权已在服务端，Q1）。
  ///
  /// 提交后立即释放界面；进度（第 X/Y 层，本层 a/b）经 job.stage.message
  /// 在托盘实时可见，与原先页面内文案同一套。
  Future<void> _runPrereq(
    KnowledgePoint p,
    PrereqDepth depth,
    String? custom,
  ) async {
    if (!mounted) return;
    if (!kAiJobQueueEnabled) {
      await _runPrereqSync(p, depth, custom);
      return;
    }
    if (_blockedByJob('补前置')) return;
    final tree = _selectedTree;
    final resourceKey = tree != null ? 'tree:${tree.id}' : 'kp:${p.id}';
    try {
      final job = await widget.service.jobs.submit(
        task: AiTask.t4GapAnalysis.code,
        resourceKey: resourceKey,
        label: '补前置：${p.name}',
        inputs: <String, dynamic>{
          'target': {
            'name': p.name,
            'type': p.type.label,
            'definition': p.definition,
          },
          'depth': depth.code,
          if (depth == PrereqDepth.custom && (custom?.trim().isNotEmpty ?? false))
            'custom_instruction': custom!.trim(),
        },
        onDone: (j) => _onPrereqDone(j),
      );
      if (job == null) {
        _toast('这棵树有 AI 任务正在进行，完成后再试');
        widget.service.jobs.requestExpandTray();
      }
    } on Object {
      _toast('AI 服务连接失败，改用同步处理');
      await _runPrereqSync(p, depth, custom);
    }
  }

  /// T4 job 完成：suggestions → 建议 BottomSheet（与同步路径同一收尾）。
  void _onPrereqDone(AiJob j) {
    if (!mounted) return;
    final list = (j.result?['suggestions'] as List?) ?? const <dynamic>[];
    final suggestions = <SuggestedPrerequisite>[
      for (final raw in list)
        if (raw is Map)
          SuggestedPrerequisite(
            name: (raw['name'] as String?) ?? '',
            type: (raw['type'] as String?) ?? '',
            definition: (raw['definition'] as String?) ?? '',
            reason: (raw['reason'] as String?) ?? '',
            level: (raw['level'] as num?)?.toInt() ?? 1,
          ),
    ].where((s) => s.name.isNotEmpty).toList();
    if (suggestions.isEmpty) {
      _toast('AI 未返回前置建议（该知识点可能已是最基础，或结果被过滤）。');
    } else {
      _showSuggestions(AutoPrereqResult(
        suggestions: suggestions,
        usedFallback: false,
      ));
    }
  }

  /// 补前置 · 同步路径（开关关闭 / 服务不可达兜底）。
  Future<void> _runPrereqSync(
    KnowledgePoint p,
    PrereqDepth depth,
    String? custom,
  ) async {
    if (!mounted) return;
    final progress = ValueNotifier<String>('正在向 AI 请求前置知识点…');
    final loading = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, msg, __) => Text(msg),
              ),
            ),
          ],
        ),
      ),
    );
    final res = await _auto.autoPrerequisites(
      p,
      depth,
      customInstruction: custom,
      onProgress: (pr) => progress.value = pr.label,
    );
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    } else {
      return;
    }
    res.fold(
      (r) {
        if (r.suggestions.isEmpty) {
          _toast('AI 未返回前置建议（该知识点可能已是最基础，或结果被过滤）。'
              '${r.usedFallback ? '已改用本地启发式，建议以 AI 结果为准。' : ''}');
        } else {
          _showSuggestions(r);
        }
      },
      (e, _) => _toast('自动补前置失败：$e'),
    );
    // 显式消费 loading Future，避免「未使用变量」提示。
    await loading.catchError((_) {});
  }

  /// 工具栏「批量补前置」按钮。
  ///
  /// - 有框选（[_selectedKpIds] 非空）→ 对每个选中点**依次**提交 T4 job
  ///   （资源键 `kp:{id}` 互不相同不会互锁；队列 concurrency=1 会顺序执行）。
  ///   某次提交返回 null（资源被占）→ toast「有 AI 任务正在进行，已提交前 N 个」
  ///   + 展开托盘并停止提交剩余。
  /// - 无框选但有单点选中（[_selectedPoint]）→ 保持现行为（弹深度选择器对该点跑）。
  /// - 都为空 → 提示先框选若干知识点，或点选一个知识点。
  ///
  /// 偏离规格说明：批量提交的深度统一用 [PrereqDepth.medium]（规格未指定逐点深度 UI），
  /// 单点路径仍走 [_openDepthSheet] 由用户自选。
  Future<void> _autoPrereq() async {
    final tree = _selectedTree;
    if (tree == null) return;

    // 1) 有框选 → 批量依次提交 T4（每个 kp 独立资源键，互不互锁）。
    if (_selectedKpIds.isNotEmpty) {
      var submitted = 0;
      for (final id in _selectedKpIds) {
        KnowledgePoint? kp;
        for (final p in _points) {
          if (p.id == id) {
            kp = p;
            break;
          }
        }
        if (kp == null) continue;

        // 队列关闭 → 同步兜底：逐个串行跑单点 T4。
        if (!kAiJobQueueEnabled) {
          await _runPrereqSync(kp, PrereqDepth.medium, null);
          submitted++;
          continue;
        }
        try {
          final job = await widget.service.jobs.submit(
            task: AiTask.t4GapAnalysis.code,
            resourceKey: 'kp:$id', // 与整树锁区分：互不互锁，队列顺序执行
            label: '补前置：${kp.name}',
            inputs: <String, dynamic>{
              'target': {
                'name': kp.name,
                'type': kp.type.label,
                'definition': kp.definition,
              },
              'depth': PrereqDepth.medium.code,
            },
            onDone: (j) => _onPrereqDone(j),
          );
          if (job == null) {
            // 资源被占（该 kp 已有进行中的任务）→ 停剩余。
            _toast('有 AI 任务正在进行，已提交前 $submitted 个');
            widget.service.jobs.requestExpandTray();
            return;
          }
          submitted++;
        } on Object {
          _toast('AI 服务连接失败，已提交前 $submitted 个');
          widget.service.jobs.requestExpandTray();
          return;
        }
      }
      if (submitted > 0) {
        _toast('已提交 $submitted 个知识点的「补前置」任务');
        widget.service.jobs.requestExpandTray();
      }
      return;
    }

    // 2) 无框选但有单点 → 保持现行为。
    if (_selectedPoint != null) {
      _openDepthSheet(_selectedPoint!);
      return;
    }

    // 3) 都为空 → 提示。
    _toast('请先框选若干知识点（先开「框选模式」），或点选一个知识点');
  }

  // ============ 作业模式（框选薄弱点 → 布置作业 / 历史）============

  void _toggleHomeworkMode() {
    setState(() {
      _homeworkMode = !_homeworkMode;
      // 作业模式与框选模式互斥。
      if (_homeworkMode) {
        _frameMode = false;
      }
      if (!_homeworkMode) {
        _selectedKpIds.clear();
      }
    });
    if (_homeworkMode) {
      _toast('作业模式：在画布上拖拽框选薄弱点，再点「布置作业」');
    }
  }

  /// 切换「框选模式」（常驻开关，与作业模式互斥）：
  /// 开启后画布进入框选态——拖拽框选知识点，选好后可「局部重排 / 局部连线」，
  /// 拖动选中组内任意一个即整组一起移动；关闭时清空选中。
  void _toggleFrameMode() {
    setState(() {
      _frameMode = !_frameMode;
      if (_frameMode) {
        _homeworkMode = false;
      }
      if (!_frameMode) {
        _selectedKpIds.clear();
      }
    });
    if (_frameMode) {
      _toast('框选模式：拖拽框选知识点；选好后可局部重排 / 局部连线，'
          '拖动其中一个整组移动；再点一次退出');
    }
  }

  Widget _buildHomeworkBar() {
    final n = _selectedKpIds.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.green.shade50,
      child: Row(
        children: [
          const Icon(Icons.assignment_outlined, size: 18, color: Colors.green),
          const SizedBox(width: 8),
          Text('作业模式 · 已选 $n 个薄弱点',
              style: const TextStyle(fontSize: 13)),
          const Spacer(),
          TextButton.icon(
            onPressed: _selectWeakPoints,
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('全选薄弱点'),
          ),
          TextButton.icon(
            onPressed: n == 0 ? null : _openHomeworkPage,
            icon: const Icon(Icons.assignment, size: 16),
            // Q7：一次选 N 个点 = N 份独立作业，按钮文案说清楚。
            label: Text(n > 1 ? '批量布置作业（$n 份）' : '布置作业'),
          ),
          TextButton.icon(
            onPressed: _showHomeworkHistory,
            icon: const Icon(Icons.history, size: 16),
            label: const Text('历史'),
          ),
          TextButton(
            onPressed: _toggleHomeworkMode,
            child: const Text('退出'),
          ),
        ],
      ),
    );
  }

  /// 薄弱 = 掌握状态为「未掌握」或「学习中」。
  bool _isWeak(String kpId) {
    final m = _masteryOf(kpId);
    return m == MasteryStatus.notMastered || m == MasteryStatus.learning;
  }

  /// 一键选中当前树上所有薄弱点（空则给提示）。
  void _selectWeakPoints() {
    final weak = <String>{
      for (final p in _points)
        if (_isWeak(p.id)) p.id,
    };
    setState(() => _selectedKpIds
      ..clear()
      ..addAll(weak));
    if (weak.isEmpty) {
      _toast('当前没有标记为「未掌握 / 学习中」的薄弱点。'
          '可手动框选任意知识点作为作业对象。');
    }
  }

  /// 把框选的薄弱点交给作业页出题。
  Future<void> _openHomeworkPage() async {
    final tree = _selectedTree;
    if (tree == null) return;
    final sel =
        _points.where((p) => _selectedKpIds.contains(p.id)).toList();
    if (sel.isEmpty) {
      _toast('请先框选薄弱点，或点「全选薄弱点」');
      return;
    }
    // B4：同一棵树的「布置作业」会话已开着 → 挡（不静默失败）。
    if (widget.service.jobs.isLocked('homework:new:${tree.id}')) {
      _toast('该树的「布置作业」会话已打开，完成后再试');
      widget.service.jobs.requestExpandTray();
      return;
    }
    await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => HomeworkPage(
        ai: widget.service.ai,
        db: widget.db,
        canvasId: tree.id,
        points: sel,
        jobs: widget.service.jobs,
      ),
    ));
    if (!mounted) return;
    // 布置完退出作业模式，回到正常浏览。
    setState(() => _homeworkMode = false);
  }

  /// 作业历史：改为独立页面（可搜索 / 筛选 / 按知识点分类），见 [HomeworkHistoryPage]。
  ///
  /// 旧实现是画布内的 BottomSheet，只能平铺列表、不能搜不能筛，已下线。
  Future<void> _showHomeworkHistory() async {
    final tree = _selectedTree;
    if (tree == null) return;
    await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => HomeworkHistoryPage(
        ai: widget.service.ai,
        db: widget.db,
        jobs: widget.service.jobs,
        canvasId: tree.id,
        title: "${tree.name} · 作业历史",
      ),
    ));
  }

  /// 建议结果 BottomSheet（改版）：
  /// - 每条建议可勾选，用户决定「补充多少进去树」；
  /// - 顶部选择目标知识树（或当场「＋ 新建知识树」）；
  /// - 点「补充进树」把勾选的建议经 T1 锚定后并入所选树，全程遵守锚点铁律。
  void _showSuggestions(AutoPrereqResult r) {
    if (!mounted) return;
    final byLevel = <int, List<SuggestedPrerequisite>>{};
    for (final s in r.suggestions) {
      byLevel.putIfAbsent(s.level, () => <SuggestedPrerequisite>[]).add(s);
    }
    final levels = byLevel.keys.toList()..sort();

    // 默认全选，用户可取消勾选来减少补充数量。
    final selected = <SuggestedPrerequisite>{...r.suggestions};
    final trees = <KnowledgeTree>[..._trees];
    var targetTree = _selectedTree;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final selectedCount = selected.length;
          final allSelected =
              r.suggestions.isNotEmpty && selectedCount == r.suggestions.length;
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.8,
            child: Column(
              children: [
                // 顶部提示条
                Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.amber.shade50,
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.amber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '仅为建议。勾选后「补充进树」会经 T1 锚定'
                          '（无原文出处的不入库）'
                          '${r.usedFallback ? '（本地启发式，建议以 AI 为准）' : ''}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                // 目标树选择
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.account_tree_outlined,
                          size: 18, color: Colors.grey),
                      const SizedBox(width: 8),
                      const Text('并入：', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<KnowledgeTree?>(
                            isExpanded: true,
                            hint: const Text('选择知识树'),
                            value: targetTree,
                            items: [
                              for (final t in trees)
                                DropdownMenuItem(
                                  value: t,
                                  child: Text(
                                    t.name.isEmpty ? '(未命名)' : t.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              const DropdownMenuItem<KnowledgeTree?>(
                                value: null,
                                child: Row(
                                  children: [
                                    Icon(Icons.add, size: 18),
                                    SizedBox(width: 4),
                                    Text('＋ 新建知识树'),
                                  ],
                                ),
                              ),
                            ],
                            onChanged: (v) async {
                              if (v == null) {
                                final created = await _createTreeInline();
                                if (created != null) {
                                  setSt(() {
                                    trees.add(created);
                                    targetTree = created;
                                  });
                                }
                              } else {
                                setSt(() => targetTree = v);
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 全选 / 计数
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: allSelected,
                        onChanged: (v) {
                          setSt(() {
                            if (v == true) {
                              selected.addAll(r.suggestions);
                            } else {
                              selected.clear();
                            }
                          });
                        },
                      ),
                      const Text('全选', style: TextStyle(fontSize: 13)),
                      const Spacer(),
                      Text(
                        '已选 $selectedCount / ${r.suggestions.length}',
                        style: const TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // 建议列表（可勾选）
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(8),
                    children: [
                      for (final lv in levels)
                        ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
                            child: Text(
                              '第 $lv 层（${lv == 1 ? '最接近该点' : '更基础'}）',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          for (final s in byLevel[lv]!)
                            CheckboxListTile(
                              contentPadding:
                                  const EdgeInsets.only(left: 12, right: 8),
                              controlAffinity: ListTileControlAffinity.leading,
                              value: selected.contains(s),
                              onChanged: (v) {
                                setSt(() {
                                  if (v == true) {
                                    selected.add(s);
                                  } else {
                                    selected.remove(s);
                                  }
                                });
                              },
                              secondary: IconButton(
                                icon: const Icon(Icons.note_add_outlined, size: 18),
                                tooltip: '仅新建为笔记（不并入树）',
                                onPressed: () => _createNoteFor(s),
                              ),
                              title: Text(s.name),
                              subtitle: Text(
                                s.reason,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              dense: true,
                            ),
                        ],
                    ],
                  ),
                ),
                // 底部动作
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.add),
                        onPressed: selectedCount == 0 || targetTree == null
                            ? null
                            : () {
                                Navigator.pop(ctx);
                                _supplementIntoTree(selected.toList(), targetTree!);
                              },
                        label: Text('补充进树（$selectedCount）'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 把勾选的补前置建议并入目标树。
  ///
  /// 入口先弹「笔记归属」选项（默认 1：不新建笔记），四种路径见下方各 `_supplement*`
  /// 方法。锚点铁律仍贯穿：除选项 1（用户勾选=人工担保，§4.2 user_manual 豁免）外，
  /// 其余路径都经过 T1 锚定校验，绝不凭空 `new KnowledgePoint` 入库。
  Future<void> _supplementIntoTree(
    List<SuggestedPrerequisite> items,
    KnowledgeTree tree,
  ) async {
    if (items.isEmpty) return;

    // 拼成一篇 Markdown 笔记：每条建议一个 `# 标题` + 定义段落。
    // 路径 2（并入同一份新笔记）直接用；路径 4（追加现有笔记）复用此 md。
    final buffer = StringBuffer();
    for (final s in items) {
      buffer
        ..writeln('# ${s.name}')
        ..writeln()
        ..writeln(s.definition)
        ..writeln();
    }
    final md = buffer.toString().trim();

    // 先让用户选「笔记归属」方式（默认 1：不新建笔记，直接以手动知识点入库）。
    final mode = await _pickSupplementMode();
    if (mode == null) return; // 取消

    switch (mode) {
      case _SupplementMode.manual:
        await _supplementManual(tree, items);
        break;
      case _SupplementMode.newNote:
        await _supplementViaNewNote(tree, md);
        break;
      case _SupplementMode.separateNotes:
        await _supplementViaSeparateNotes(tree, items);
        break;
      case _SupplementMode.appendToNote:
        await _supplementViaAppend(tree, md);
        break;
    }
  }

  /// 补前置入库 · 选「1. 不新建笔记」：逐条以手动知识点入库（origin=user_manual，
  /// 豁免锚点铁律），再并入树、自动落位、走 [_autoLink] 队列/同步双路径连线。
  ///
  /// 锚点铁律 §4.2 user_manual 豁免：用户已在建议面板勾选这些知识点，等于人工担保
  /// 其正确性，故直接落库为手动知识点、不做 T1 原文锚定校验（也无需可锚定的原文）。
  Future<void> _supplementManual(
    KnowledgeTree tree,
    List<SuggestedPrerequisite> items,
  ) async {
    final ids = <String>[];
    for (final s in items) {
      final res = await _repo.createManualKnowledgePoint(
        name: s.name,
        definition: s.definition,
      );
      if (res is Success<KnowledgePoint>) ids.add(res.value.id);
    }
    if (ids.isEmpty) {
      _toast('没有可入库的知识点');
      return;
    }
    // 公共尾：addPoints → 自动落位 → T3 连线（走 [_autoLink] 双路径）→ toast → 刷新。
    await _finalizeSupplement(tree, ids, () async {
      await _autoLink();
      return null;
    });
  }

  /// 补前置入库 · 选「2. 并入同一份新笔记」（现状路径，完全不动）。
  ///
  /// 默认走队列复合链（T1 建笔记 → 锚定校验 → 入树 → T3 连线）；队列不可达时落到
  /// [_supplementIntoTreeSync] 的同步阻塞流程。
  Future<void> _supplementViaNewNote(KnowledgeTree tree, String md) async {
    if (!kAiJobQueueEnabled) {
      await _supplementIntoTreeSync(<SuggestedPrerequisite>[], tree, md);
      return;
    }

    final Note note;
    try {
      final (outcome, saved) = await _chain.submit(
        tree: tree,
        md: md,
        label: '补前置入库《${tree.name}》',
      );
      note = saved;
      switch (outcome) {
        case ChainOutcome.queued:
          // 关建议 BottomSheet：提交即返回，不钉界面（R1）。
          // 后台异步查重：队列路径的知识点由后台 T1 任务随后落库，查重任务
          // 排在其后执行；若执行时新点尚未落库则本轮静默无结果（不影响
          // 正确性，手动去重按钮可随时兜底）。
          kpDedupSchedule(repo: _repo, jobs: widget.service.jobs);
          Navigator.of(context).pop();
          return;
        case ChainOutcome.locked:
          _toast('「${tree.name}」有 AI 任务正在进行，完成后再试');
          widget.service.jobs.requestExpandTray();
          return;
        case ChainOutcome.serviceDown:
          _toast('AI 服务连接失败，改用同步处理');
      }
    } on Object catch (e) {
      _toast('保存笔记失败：$e');
      return;
    }
    await _supplementIntoTreeSync(<SuggestedPrerequisite>[], tree, md,
        existingNote: note);
  }

  /// 补前置入库 · 选「3. 每条建议单独新建笔记」：每条建议各自存一篇笔记 →
  /// 同步 T1 锚定 → 收集落库 id，最后统一并入树 + 自动落位 + T3 连线。
  Future<void> _supplementViaSeparateNotes(
    KnowledgeTree tree,
    List<SuggestedPrerequisite> items,
  ) async {
    final ids = <String>[];
    if (!mounted) return;
    final progress = ValueNotifier<String>('正在逐条通过 T1 锚定知识点…');
    final loading = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, msg, __) => Text(msg),
              ),
            ),
          ],
        ),
      ),
    );
    for (final s in items) {
      // extract 内部即 stageSaveNote + T1，等价于「逐篇 saveNote → 同步 T1」。
      final singleMd = '# ${s.name}\n\n${s.definition}';
      final ext = await widget.service.extract(singleMd);
      if (!mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        await loading.catchError((_) {});
        return;
      }
      if (ext is Success<ExtractionSaveResult>) {
        ids.addAll(ext.value.saved.map((k) => k.id));
      }
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await loading.catchError((_) {});
    if (!mounted) return;
    if (ids.isEmpty) {
      _toast('没有可锚定的知识点被收录（建议缺少原文出处）。'
          '可改用「不新建笔记」手动收录。');
      return;
    }
    await _finalizeSupplement(tree, ids, _syncLinkConnect(tree));
  }

  /// 补前置入库 · 选「4. 追加进现有笔记」：选一篇现有笔记 → 把建议 md 追加到其正文 →
  /// 同步 T1 锚定 → 收集落库 id，最后统一并入树 + 落位 + T3 连线。
  Future<void> _supplementViaAppend(KnowledgeTree tree, String md) async {
    final notes = await _repo.listNotes();
    if (!mounted) return;
    if (notes.isEmpty) {
      _toast('还没有笔记可追加');
      return;
    }
    final picked = await showDialog<Note>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('追加进哪篇笔记？'),
        children: [
          for (final n in notes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, n),
              child: Text(
                n.title.isEmpty ? '(无标题)' : n.title,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
    if (picked == null) return;

    if (!mounted) return;
    final updated = picked.copyWith(
      contentMd: '${picked.contentMd}\n\n$md',
      updatedAt: DateTime.now().toUtc(),
    );
    final saveRes = await _repo.saveNote(updated);
    if (!mounted) return;
    if (saveRes is Failure<Note>) {
      _toast('更新笔记失败：${saveRes.error}');
      return;
    }

    if (!mounted) return;
    final progress = ValueNotifier<String>('正在通过 T1 锚定知识点…');
    final loading = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, msg, __) => Text('$msg\n并入「${tree.name}」'),
              ),
            ),
          ],
        ),
      ),
    );
    // 与 1572-1578 行用法一致：content 用拼好的 md，T1 仅分析新增建议部分；
    // 知识点归属到更新后的笔记（已含原文 + 追加建议）。
    final ext = await ExtractIntoTreeChain.extractWithExistingNote(
      widget.service,
      updated,
      md,
    );
    if (!mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      await loading.catchError((_) {});
      return;
    }
    if (ext is Failure<ExtractionSaveResult>) {
      Navigator.of(context, rootNavigator: true).pop();
      await loading.catchError((_) {});
      _toast('T1 锚定失败：${ext.error}');
      return;
    }
    final ids = (ext as Success<ExtractionSaveResult>)
        .value
        .saved
        .map((k) => k.id)
        .toList();
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await loading.catchError((_) {});
    if (!mounted) return;
    if (ids.isEmpty) {
      _toast('没有可锚定的知识点被收录（建议缺少原文出处）。'
          '可改用「不新建笔记」手动收录。');
      return;
    }
    await _finalizeSupplement(tree, ids, _syncLinkConnect(tree));
  }

  /// 四条补前置入库路径的公共收尾：把已落库知识点并入树、自动落位，再跑 T3 连线、
  /// toast、刷新。
  ///
  /// [connect] 封装「T3 连线」这一步并返回连线结果文案（null = 无额外信息）：
  /// - 路径 1：走 [_autoLink] 队列/同步双路径；
  /// - 路径 3/4：走 [_syncLinkConnect] 同步阻塞（带进度对话框）。
  Future<void> _finalizeSupplement(
    KnowledgeTree tree,
    List<String> ids,
    Future<String?> Function() connect,
  ) async {
    if (ids.isEmpty) {
      _toast('没有可入库的知识点');
      return;
    }
    final existing = await _treesRepo.memberPointIds(tree.id);
    final newIds = ids.where((id) => !existing.contains(id)).toList();
    final addRes = await _treesRepo.addPoints(tree.id, ids);
    if (!mounted) return;
    final added = addRes.valueOrNull ?? 0;
    if (addRes is Failure<int>) {
      _toast('并入失败：${addRes.error}');
      return;
    }
    // 新并入的点默认 x/y=0，会被布局引擎当成「放在原点」→ 用布局引擎铺开坐标。
    await _autoPlaceNewPoints(tree.id, newIds);
    final linkMsg = await connect();
    if (!mounted) return;
    _toast('已补充进「${tree.name}」：$added 个知识点${linkMsg ?? ''}');
    await _load();
    // 后台异步查重：补前置是知识点创建环节之一（用户要求全覆盖）。
    kpDedupSchedule(repo: _repo, jobs: widget.service.jobs);
  }

  /// 同步阻塞路径的「T3 连线」封装：带进度对话框跑 [_auto.autoLink]，返回连线文案。
  Future<String?> Function() _syncLinkConnect(KnowledgeTree tree) {
    return () async {
      // 受「自动连线」开关控制（E）：关 → 不自动连线（补前置路径 3/4）。
      if (!TreeBehaviorSettings.instance.autoLinkEnabled) return '';
      final loading = showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Expanded(child: Text('正在自动连线（T3）…')),
            ],
          ),
        ),
      );
      final linkRes = await _auto.autoLink(tree.id);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      await loading.catchError((_) {});
      if (!mounted) return null;
      var linkNote = '';
      linkRes.fold(
        (r) {
          if (r.created > 0) linkNote = '；已自动建立 ${r.created} 条前置关系';
        },
        (e, _) {
          linkNote = '（自动连线未完成：$e，可稍后手动点「自动连线」）';
        },
      );
      return linkNote;
    };
  }

  /// 补前置入库「笔记归属」选项对话框（默认 1：不新建笔记）。
  Future<_SupplementMode?> _pickSupplementMode() async {
    var selected = _SupplementMode.manual; // 默认 1：不新建笔记
    return showDialog<_SupplementMode>(
      context: context,
      // 问题6：补前置的入库方式是多步流程，禁止点外部误关（有显式「取消」）。
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('补前置入库：笔记归属'),
          content: SingleChildScrollView(
            child: RadioGroup<_SupplementMode>(
              groupValue: selected,
              onChanged: (v) => setSt(() => selected = v ?? selected),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<_SupplementMode>(
                    title: const Text('不新建笔记'),
                    subtitle: const Text('直接以手动知识点入库，不做 T1 锚定校验'),
                    value: _SupplementMode.manual,
                  ),
                  RadioListTile<_SupplementMode>(
                    title: const Text('并入同一份新笔记'),
                    subtitle: const Text('拼成一篇 Markdown 走 T1 锚定（现状）'),
                    value: _SupplementMode.newNote,
                  ),
                  RadioListTile<_SupplementMode>(
                    title: const Text('每条建议单独新建笔记'),
                    subtitle: const Text('每条各自成笔记并分别锚定'),
                    value: _SupplementMode.separateNotes,
                  ),
                  RadioListTile<_SupplementMode>(
                    title: const Text('追加进现有笔记'),
                    subtitle: const Text('选一篇笔记，把建议追加进它的内容再锚定'),
                    value: _SupplementMode.appendToNote,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, selected),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  /// 补充进树 · 同步路径（开关关闭 / 服务不可达兜底）：原阻塞流程。
  ///
  /// 现状路径（选项 2）走这里：T1 锚定 → 收集落库 id → 公共尾 [_finalizeSupplement]。
  Future<void> _supplementIntoTreeSync(
    List<SuggestedPrerequisite> items,
    KnowledgeTree tree,
    String md, {
    Note? existingNote,
  }) async {
    if (!mounted) return;
    final progress = ValueNotifier<String>('正在通过 T1 锚定知识点…');
    final loading = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, msg, __) => Text('$msg\n并入「${tree.name}」'),
              ),
            ),
          ],
        ),
      ),
    );

    final ext = existingNote == null
        ? await widget.service.extract(md)
        : await ExtractIntoTreeChain.extractWithExistingNote(
            widget.service,
            existingNote,
            md,
          );
    if (!mounted) return;
    if (ext is Failure<ExtractionSaveResult>) {
      Navigator.of(context, rootNavigator: true).pop();
      await loading.catchError((_) {});
      _toast('T1 锚定失败：${ext.error}');
      return;
    }
    final res = (ext as Success<ExtractionSaveResult>).value;
    final ids = res.saved.map((k) => k.id).toList();

    if (ids.isEmpty) {
      // 建议全被锚点校验剔除：不落库任何无出处的点。
      Navigator.of(context, rootNavigator: true).pop();
      await loading.catchError((_) {});
      _toast('没有可锚定的知识点被收录（${res.rejectedCount} 条因缺少原文出处被剔除）。'
          '可改用「不新建笔记」手动收录。');
      return;
    }

    // T1 进度框关闭，落库/连线交给公共尾（它内部会再弹 T3 进度框）。
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await loading.catchError((_) {});
    if (!mounted) return;
    await _finalizeSupplement(tree, ids, _syncLinkConnect(tree));
  }

  /// P2-1：把单条补前置建议直接落成一条笔记（**不是**知识点）。
  ///
  /// 锚点铁律：无 `source_quote` 逐字匹配的知识点禁止入库，所以这里只新建笔记，
  /// 预填建议的标题/定义；用户随后去「提取」页跑一次 T1 即可把知识点正式收录。
  Future<void> _createNoteFor(SuggestedPrerequisite s) async {
    final note = Note(
      title: s.name,
      contentMd: '# ${s.name}\n\n${s.definition}',
      deviceId: DeviceId.orEmpty,
    );
    final res = await _repo.saveNote(note);
    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭建议 BottomSheet
    res.fold(
      (_) => _toast('已新建笔记「${s.name}」，去「提取」页跑一次 T1 即可收录知识点'),
      (e, _) => _toast('新建笔记失败：$e'),
    );
  }

  Future<String?> _askName(String title, String label, String initial) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      // 问题6：命名弹框有输入内容，禁止点外部误关（有显式「取消」）。
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ));
  }

  String _titleOf(Note n) =>
      n.title.isEmpty ? n.contentMd.split('\n').first : n.title;

  // ================= 工具栏分组 =================

  /// 一个工具栏分组按钮：分组图标 + tooltip，点开弹出该组动作菜单。
  ///
  /// 分组按钮本身**不禁用**：「知识树」组的「新建知识树」在无树时也必须可用；
  /// 各动作的禁用态由菜单项各自的 `enabled` 保留（与原平铺 IconButton 一致）。
  Widget _toolbarGroupButton({
    required IconData icon,
    required String tooltip,
    required List<PopupMenuEntry<int>> Function(BuildContext) itemBuilder,
  }) {
    return PopupMenuButton<int>(
      icon: Icon(icon),
      iconSize: 20,
      tooltip: tooltip,
      itemBuilder: itemBuilder,
    );
  }

  /// 分组菜单里的一项：图标 + 文字。[enabled] 为 false 时保留禁用态。
  PopupMenuItem<int> _toolbarMenuItem({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return PopupMenuItem<int>(
      enabled: enabled,
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }

  /// 工具栏右侧的 4 个分组按钮（由原来一排平铺图标归类而来）：
  ///
  /// 1. **知识树**（实体 CRUD）：新建知识树 / 重命名 / 删除知识树；
  /// 2. **内容导入（树成员管理）**：从笔记并入知识点 / 加入已有知识点 /
  ///    新建知识点 / 从其他知识树加入 / 从知识树移除知识点；
  /// 3. **布局与连线**（布局系列 + 连线系列，用分隔线分开）：
  ///    - 布局系列：重新布局（全量重排）/ 局部重排；
  ///    - 连线系列：自动连线（原「自动布局」，实为 T3 前置连线）/ 局部连线（仅对框选子集连线）；
  /// 4. **AI 与作业**：批量补前置 / 布置作业 / 作业历史 / 作业模式。
  ///
  /// 全部复用既有 handler；`tree == null` 时的禁用态与原实现逐项对应。
  List<Widget> _buildToolbarGroups(KnowledgeTree? tree) {
    final hasTree = tree != null;
    return <Widget>[
      // ① 知识树（实体 CRUD）
      _toolbarGroupButton(
        icon: Icons.account_tree,
        tooltip: '知识树：新建 / 重命名 / 删除',
        itemBuilder: (_) => <PopupMenuEntry<int>>[
          _toolbarMenuItem(
            icon: Icons.add,
            label: '新建知识树',
            enabled: true,
            onTap: _newTree,
          ),
          _toolbarMenuItem(
            icon: Icons.drive_file_rename_outline,
            label: '重命名',
            enabled: hasTree,
            onTap: _renameTree,
          ),
          _toolbarMenuItem(
            icon: Icons.delete_outline,
            label: '删除知识树',
            enabled: hasTree,
            onTap: _deleteTree,
          ),
        ],
      ),
      // ② 内容导入（树成员管理：并入 / 新建 / 添加 / 移除）
      _toolbarGroupButton(
        icon: Icons.playlist_add,
        tooltip: '内容导入：并入笔记 / 新建知识点 / 已有知识点 / 移除',
        itemBuilder: (_) => <PopupMenuEntry<int>>[
          _toolbarMenuItem(
            icon: Icons.merge_type,
            label: '从笔记并入知识点',
            enabled: hasTree,
            onTap: _mergeFromNote,
          ),
          _toolbarMenuItem(
            icon: Icons.playlist_add,
            label: '加入已有知识点',
            enabled: hasTree,
            onTap: _addKnowledgePoints,
          ),
          _toolbarMenuItem(
            icon: Icons.add_circle_outline,
            label: '新建知识点',
            enabled: hasTree,
            onTap: _newKnowledgePoint,
          ),
          _toolbarMenuItem(
            icon: Icons.move_down,
            label: '从其他知识树加入',
            enabled: hasTree,
            onTap: _copyFromOtherTree,
          ),
          const PopupMenuDivider(),
          _toolbarMenuItem(
            icon: Icons.remove_circle_outline,
            label: '从知识树移除知识点',
            enabled: hasTree && _points.isNotEmpty,
            onTap: _removeFromTree,
          ),
          _toolbarMenuItem(
            icon: Icons.delete_outline,
            label: '移除框选的知识点',
            enabled: hasTree && _frameMode && _selectedKpIds.isNotEmpty,
            onTap: _removeSelectedFromTree,
          ),
        ],
      ),
      // ③ 布局与连线（布局系列 + 连线系列，PopupMenuDivider 分隔）
      _toolbarGroupButton(
        icon: Icons.dashboard_outlined,
        tooltip: '布局与连线：重新布局 / 局部重排 / 自动连线 / 局部连线',
        itemBuilder: (_) => <PopupMenuEntry<int>>[
          // —— 布局系列 ——
          _toolbarMenuItem(
            icon: Icons.grid_view,
            label: '重新布局',
            enabled: hasTree,
            onTap: _onRelayout,
          ),
          _toolbarMenuItem(
            icon: Icons.schema,
            label: '局部重排',
            enabled: hasTree && _frameMode && _selectedKpIds.isNotEmpty,
            onTap: _relayoutSelected,
          ),
          // —— 连线系列（与布局系列分隔）——
          const PopupMenuDivider(),
          _toolbarMenuItem(
            icon: Icons.auto_fix_high,
            // 原「自动布局」仅改 label；其 onTap 实为 _autoLink（T3 前置连线）。
            // 手动点选不受「自动连线」开关约束（开关只管 AI 链式）。
            label: '自动连线',
            enabled: hasTree,
            onTap: () => _autoLink(force: true),
          ),
          _toolbarMenuItem(
            icon: Icons.hub_outlined,
            label: '局部连线',
            // 少于 2 个点无从连线（需至少 2 个框选知识点）。
            enabled: hasTree && _selectedKpIds.length >= 2,
            onTap: () => _autoLinkSelected(force: true),
          ),
        ],
      ),
      // ④ AI 与作业
      _toolbarGroupButton(
        icon: Icons.auto_awesome,
        tooltip: 'AI 与作业：补前置 / 作业历史 / 作业模式',
        itemBuilder: (_) => <PopupMenuEntry<int>>[
          _toolbarMenuItem(
            icon: Icons.lightbulb_outline,
            label: '批量补前置',
            enabled: hasTree &&
                (_selectedKpIds.isNotEmpty || _selectedPoint != null),
            onTap: _autoPrereq,
          ),
          // 「布置作业」不在这里重复：作业模式（下方菜单项）打开后，框选薄弱点
          // 即在模式条里出现「布置作业 / 批量布置作业」（见 2160-2180 行），
          // 两处并存会让用户以为有两套入口，且这里的入口未框选时恒为禁用。
          _toolbarMenuItem(
            icon: Icons.history,
            label: '作业历史',
            enabled: hasTree,
            onTap: _showHomeworkHistory,
          ),
          _toolbarMenuItem(
            icon: _homeworkMode ? Icons.deselect : Icons.assignment_outlined,
            label: _homeworkMode ? '退出作业模式' : '作业模式',
            enabled: hasTree,
            onTap: _toggleHomeworkMode,
          ),
        ],
      ),
      // ⑤ ★2.0.0 画布组件（笔记卡片 / 透明文本框 / 圆珠笔 / 橡皮）
      _toolbarGroupButton(
        icon: Icons.add_box_outlined,
        tooltip: '画布组件：笔记卡片 / 透明文本框 / 圆珠笔 / 橡皮',
        itemBuilder: (_) => <PopupMenuEntry<int>>[
          _toolbarMenuItem(
            icon: Icons.sticky_note_2_outlined,
            label: '添加笔记卡片',
            enabled: hasTree,
            onTap: () => _addCard(kind: 'note_card'),
          ),
          _toolbarMenuItem(
            icon: Icons.text_fields,
            label: '添加透明文本框',
            enabled: hasTree,
            onTap: () => _addCard(kind: 'text_box'),
          ),
          const PopupMenuDivider(),
          _toolbarMenuItem(
            icon: _penMode ? Icons.check_box : Icons.edit,
            label: _penMode ? '退出圆珠笔' : '圆珠笔',
            enabled: hasTree,
            onTap: _togglePenMode,
          ),
          _toolbarMenuItem(
            icon: _eraserMode ? Icons.check_box : Icons.auto_fix_off,
            label: _eraserMode ? '退出橡皮擦' : '橡皮擦',
            enabled: hasTree,
            onTap: _toggleEraserMode,
          ),
        ],
      ),
    ];
  }

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    final tree = _selectedTree;
    return Column(
      children: [
        // ── 知识树工具栏 ──
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              const Text('知识树：',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<KnowledgeTree>(
                    isExpanded: true,
                    value: tree,
                    items: [
                      for (final t in _trees)
                        DropdownMenuItem(
                          value: t,
                          child: Text(
                            t.name.isEmpty ? '(未命名)' : t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) async {
                      if (v == null) return;
                      setState(() {
                        _selectedTree = v;
                        _homeworkMode = false;
                        _frameMode = false;
                        _selectedKpIds.clear();
                      });
                      await _loadForTree(v.id);
                    },
                  ),
                ),
              ),
              // 工具栏动作归组为 4 个分组图标菜单（详见 [_buildToolbarGroups]）。
              ..._buildToolbarGroups(tree),
            ],
          ),
        ),
        // ── 统计 ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text(
                '${_points.length} 个知识点 / ${_edges.length} 条边',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (_loading) ...[
                const SizedBox(width: 10),
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        if (_homeworkMode) _buildHomeworkBar(),
        // ── 画布 ──
        Expanded(
          child: _trees.isEmpty
              ? const Center(
                  child: Text(
                    '还没有知识树。\n去「提取」页跑一次 T1，会自动为那篇笔记生成一棵树。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ))
              : tree == null
                  ? const Center(
                      child: Text('请选择一棵知识树',
                          style: TextStyle(color: Colors.grey)))
                  : _points.isEmpty
                      ? const Center(
                          child: Text(
                            '这棵树还是空的。\n用上方「并入」按钮把笔记的知识点加进来。',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ))
                      : TreeCanvas(
                          key: ValueKey<String>('${tree.id}#$_relayoutVersion'),
                          points: _points,
                          edges: _edges,
                          currentMastery: _masteryOf,
                          onKpTap: _onKpTap,
                          selectedKpId: _selectedPoint?.id,
                          savedPositions: _positions,
                          onMoveNode: _onMoveNode,
                          onCreateEdge: _onCreateEdge,
                          onDeleteEdge: _onDeleteEdge,
                          selectionMode: _homeworkMode || _frameMode,
                          selectedKpIds: _selectedKpIds,
                          onSelectionChanged: (s) => setState(() {
                            _selectedKpIds
                              ..clear()
                              ..addAll(s);
                          }),
                          allowGroupDrag: _frameMode,
                          frameMode: _frameMode,
                          onToggleFrameMode: _toggleFrameMode,
                          onMoveNodes: _onMoveNodes,
                          // ★2.0.0：画布富组件
                          cards: _cards,
                          strokes: _strokes,
                          penMode: _penMode,
                          eraserMode: _eraserMode,
                          onEditCard: _editCard,
                          onMoveCard: _onMoveCard,
                          onAddStroke: _onAddStroke,
                          onEraseStroke: _onEraseStroke,
                          onViewportCenter: (c) => _viewportCenter = c,
                        ),
        ),
      ],
    );
  }
}
