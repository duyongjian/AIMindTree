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
/// 知识树（新建 / 重命名 / 删除）、内容导入（笔记并入 / 已有知识点）、
/// 布局视图（自动布局 / 框选重排 / 局部重排 / 框选移动）、
/// AI 与作业（补前置 / 布置作业 / 作业历史 / 作业模式）。
library;

import 'package:flutter/material.dart';

import '../../ai/ai_job_service.dart' show kAiJobQueueEnabled, AiJob;
import '../../ai/ai_task.dart';
import '../../ai/auto_graph_service.dart';
import '../../ai/extract_into_tree_chain.dart';
import '../../ai/extraction_service.dart';
import '../../ai/prereq_depth.dart';
import '../../canvas/layout_autoplace.dart';
import '../../canvas/render/layout_engine.dart';
import '../../canvas/render/tree_canvas.dart';
import '../../core/id.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/homework.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/models/knowledge_tree.dart';
import '../../data/models/suggested_prerequisite.dart';
import '../../data/repositories/homework_repository.dart';
import '../../data/repositories/knowledge_repository.dart';
import '../../data/repositories/tree_repository.dart';
import '../../features/homework/homework_page.dart';

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

  /// 框选重排模式：开启后可在画布上框选若干知识点，再「局部重排」。
  bool _frameSelectMode = false;

  /// 框选移动模式：开启后框选若干知识点，拖动其中任意一个即整组一起移动。
  bool _frameMoveMode = false;

  /// 当前画布上框选 / 多选选中的知识点 id（作业模式与框选重排模式共用同一份状态）。
  final Set<String> _selectedKpIds = <String>{};

  /// 作业仓储（落库 + 历史）。
  late final HomeworkRepository _homeworks =
      HomeworkRepository(widget.db, deviceId: DeviceId.orEmpty);

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

    // 为每篇已提取知识点的笔记补建「笔记树」并归集成员（幂等，兼容历史数据）。
    for (final n in notes) {
      final kps = await _repo.pointsForNote(n.id);
      if (kps.isEmpty) continue;
      await _treesRepo.ensureNoteTree(noteId: n.id, noteTitle: _titleOf(n));
      await _treesRepo.addPoints(n.id, kps.map((p) => p.id).toList());
    }

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

    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('把哪篇笔记的知识点并入？'),
        children: [
          for (final n in _notes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, n.id),
              child: Text(_titleOf(n), overflow: TextOverflow.ellipsis),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
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
                  height: 360,
                  child: ListView.builder(
                    itemCount: candidates.length,
                    itemBuilder: (_, i) {
                      final kp = candidates[i];
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
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: selected.isEmpty ? null : () => Navigator.pop(ctx, true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
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

  /// 自动连线（B2：默认走队列，提交即返回；同步路径保留）。
  Future<void> _autoLink() async {
    final tree = _selectedTree;
    if (tree == null) return;
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

  /// 节点点选回调：记录选中态并弹出操作浮层（标记掌握 / 连接前置 / 补充前置知识）。
  void _onKpTap(KnowledgePoint p) {
    setState(() => _selectedPoint = p);
    _showNodeActions(p);
  }

  /// 操作浮层：选中节点后的三个动作。
  Future<void> _showNodeActions(KnowledgePoint p) async {
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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

  /// 工具栏「补前置」按钮：有选中点 → 对该点跑深度补前置；无选中点 → 提示先点选。
  Future<void> _autoPrereq() async {
    if (_selectedPoint != null) {
      _openDepthSheet(_selectedPoint!);
    } else {
      _toast('请先在画布上点选一个知识点，再补充它的前置知识');
    }
  }

  // ============ 作业模式（框选薄弱点 → 布置作业 / 历史）============

  void _toggleHomeworkMode() {
    setState(() {
      _homeworkMode = !_homeworkMode;
      // 三种框选模式互斥：开一个就关掉另外两个。
      if (_homeworkMode) {
        _frameSelectMode = false;
        _frameMoveMode = false;
      }
      if (!_homeworkMode) {
        _selectedKpIds.clear();
      }
    });
    if (_homeworkMode) {
      _toast('作业模式：在画布上拖拽框选薄弱点，再点「布置作业」');
    }
  }

  /// 切换「框选重排」模式：与作业模式 / 框选移动互斥，关闭时清空选中。
  void _toggleFrameSelectMode() {
    setState(() {
      _frameSelectMode = !_frameSelectMode;
      if (_frameSelectMode) {
        _homeworkMode = false;
        _frameMoveMode = false;
      }
      if (!_frameSelectMode) {
        _selectedKpIds.clear();
      }
    });
    if (_frameSelectMode) {
      _toast('框选重排：在画布上拖拽框选若干知识点，再点「局部重排」');
    }
  }

  /// 切换「框选移动」模式：与作业模式 / 框选重排互斥，关闭时清空选中。
  ///
  /// 开启后：先在画布上拖拽框选出一组知识点，再直接拖动其中任意一个，整组一起移动。
  void _toggleFrameMoveMode() {
    setState(() {
      _frameMoveMode = !_frameMoveMode;
      if (_frameMoveMode) {
        _homeworkMode = false;
        _frameSelectMode = false;
      }
      if (!_frameMoveMode) {
        _selectedKpIds.clear();
      }
    });
    if (_frameMoveMode) {
      _toast('框选移动：先拖拽框选若干知识点，再拖动其中任意一个，整组一起移动');
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
            label: const Text('布置作业'),
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

  /// 历史作业列表（BottomSheet）：打开可编辑，也可删除。
  Future<void> _showHomeworkHistory() async {
    final tree = _selectedTree;
    if (tree == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _homeworkHistorySheet(tree.id),
    );
  }

  Widget _homeworkHistorySheet(String canvasId) => FutureBuilder<List<Homework>>(
        future: _homeworks.listByCanvas(canvasId),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final list = snap.data!;
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.grey.shade100,
                  child: Row(
                    children: [
                      const Icon(Icons.history, size: 18),
                      const SizedBox(width: 8),
                      Text('作业历史（${list.length}）',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                Expanded(
                  child: list.isEmpty
                      ? const Center(
                          child: Text('还没有布置过作业。',
                              style: TextStyle(color: Colors.grey)))
                      : ListView(
                          children: [
                            for (final hw in list)
                              ListTile(
                                leading:
                                    const Icon(Icons.assignment_outlined),
                                title: Text(hw.title.isEmpty
                                    ? '(未命名)'
                                    : hw.title),
                                subtitle: Text(
                                  '${hw.itemCount} 题',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.red),
                                  tooltip: '删除作业',
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: ctx,
                                      builder: (d) => AlertDialog(
                                        title: const Text('删除作业'),
                                        content: const Text(
                                            '删除后将从历史中移除，确定？'),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(d, false),
                                            child: const Text('取消'),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(d, true),
                                            child: const Text('删除',
                                                style: TextStyle(
                                                    color: Colors.red)),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok == true) {
                                      await _homeworks.softDelete(hw.id);
                                      if (!mounted) return;
                                      Navigator.of(ctx).pop();
                                      _showHomeworkHistory();
                                    }
                                  },
                                ),
                onTap: () async {
                  // 用作业记录的 kpIds 重新取知识点作为出题上下文。
                  final pts =
                      await _repo.pointsByIds(hw.kpIds);
                  if (!mounted) return;
                  Navigator.of(ctx).pop();
                  // B4：同一作业的编辑会话已开着 → 挡（不静默失败）。
                  if (widget.service.jobs.isLocked('homework:${hw.id}')) {
                    _toast('该作业的编辑会话已打开，完成后再试');
                    widget.service.jobs.requestExpandTray();
                    return;
                  }
                  await Navigator.of(context)
                      .push<bool>(MaterialPageRoute(
                    builder: (_) => HomeworkPage(
                      ai: widget.service.ai,
                      db: widget.db,
                      canvasId: canvasId,
                      points: pts,
                      existingId: hw.id,
                      jobs: widget.service.jobs,
                    ),
                  ));
                                  if (!mounted) return;
                                  setState(() => _homeworkMode = false);
                                },
                              ),
                          ],
                        ),
                ),
              ],
            ),
          );
        },
      );


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
                      TextButton.icon(
                        onPressed: () => _createAllNotes(r.suggestions),
                        icon: const Icon(Icons.note_add_outlined),
                        label: const Text('全部新建为笔记'),
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

  /// 把勾选的补前置建议直接并入目标树（B2：默认走队列复合链，方案 §11.1）。
  ///
  /// 锚点铁律：建议本身没有可逐字锚定的原文，不能直接 `new KnowledgePoint` 入库。
  /// 把它们拼成一篇 Markdown 笔记 → T1 负责锚点校验、剔除无出处的幻觉点，
  /// 再把真正落库的知识点 addPoints 进树，最后同锁跑 T3 自动连线。
  /// 取消任一段回滚半成品（Q6）；T3 失败保留 T1 成果。
  Future<void> _supplementIntoTree(
    List<SuggestedPrerequisite> items,
    KnowledgeTree tree,
  ) async {
    if (items.isEmpty) return;

    // 1) 拼成一篇 Markdown 笔记：每条建议一个 `# 标题` + 定义段落。
    final buffer = StringBuffer();
    for (final s in items) {
      buffer
        ..writeln('# ${s.name}')
        ..writeln()
        ..writeln(s.definition)
        ..writeln();
    }
    final md = buffer.toString().trim();

    if (!kAiJobQueueEnabled) {
      await _supplementIntoTreeSync(items, tree, md);
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
    await _supplementIntoTreeSync(items, tree, md, existingNote: note);
  }

  /// 补充进树 · 同步路径（开关关闭 / 服务不可达兜底）：原阻塞流程。
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
          '可改用「新建笔记」手动收录。');
      return;
    }

    // 3) 把锚定后的知识点并入目标树，并立刻用布局引擎给新点铺开坐标。
    // 先取已有成员，避免「已在该树的点」被重新摆位（addPoints 幂等跳过，
    // 但布局引擎若覆盖其坐标会把它从用户摆好的位置拽走）。
    final existing = await _treesRepo.memberPointIds(tree.id);
    final newIds = ids.where((id) => !existing.contains(id)).toList();
    final addRes = await widget.service.trees.addPoints(tree.id, ids);
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    } else {
      return;
    }
    await loading.catchError((_) {});
    if (!mounted) return;
    await addRes.fold(
      (added) async {
        // 新并入的点默认 x/y=0，会被布局引擎当成「放在原点」→ 全挤在 (0,0) 且拖不动。
        // 这里用布局引擎给它们算不重叠坐标并写回（已手动摆过的旧节点不动）。
        await _autoPlaceNewPoints(tree.id, newIds);

        // 新点落位后，立刻为它们补上前置关系：复用 T3「自动连线」这条**仅 AI** 的路径
        // （无本地启发式兜底，符合决策 15）。连线失败不阻断「补充进树」——用户仍可稍后
        // 手动点「自动连线」重试。
        if (!mounted) return;
        final linkLoading = showDialog<void>(
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
        await linkLoading.catchError((_) {});
        if (!mounted) return;
        var linkNote = '';
        linkRes.fold(
          (r) {
            if (r.created > 0) {
              linkNote = '；已自动建立 ${r.created} 条前置关系';
            }
          },
          (e, _) {
            linkNote = '（自动连线未完成：$e，可稍后手动点「自动连线」）';
          },
        );
        if (!mounted) return;
        _toast('已补充进「${tree.name}」：$added 个知识点'
            '${res.rejectedCount > 0 ? '（${res.rejectedCount} 条无出处未入库）' : ''}'
            '$linkNote');
        // 刷新树列表（点数可能变了）；当前显示的树若不是目标树也一并更新。
        await _load();
      },
      (e, _) async => _toast('并入失败：$e'),
    );
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

  /// P2-1：把整批建议一次性落成多条笔记（同样不创建知识点，遵守锚点铁律）。
  Future<void> _createAllNotes(List<SuggestedPrerequisite> list) async {
    if (list.isEmpty) return;
    var ok = 0;
    for (final s in list) {
      final note = Note(
        title: s.name,
        contentMd: '# ${s.name}\n\n${s.definition}',
        deviceId: DeviceId.orEmpty,
      );
      final res = await _repo.saveNote(note);
      if (!mounted) return;
      if (res.isSuccess) ok++;
    }
    Navigator.of(context).pop(); // 关闭建议 BottomSheet
    _toast(ok == list.length
        ? '已新建 $ok 条笔记，去「提取」页跑一次 T1 即可收录对应知识点'
        : '已新建 $ok/${list.length} 条笔记（部分失败），去「提取」页跑一次 T1 即可收录知识点');
  }

  Future<String?> _askName(String title, String label, String initial) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
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
  /// 2. **内容导入**：从笔记并入知识点 / 加入已有知识点；
  /// 3. **布局视图**：自动布局 / 框选重排 / 局部重排 / 框选移动；
  /// 4. **AI 与作业**：补前置 / 布置作业 / 作业历史 / 作业模式。
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
      // ② 内容导入
      _toolbarGroupButton(
        icon: Icons.playlist_add,
        tooltip: '内容导入：并入笔记 / 已有知识点',
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
        ],
      ),
      // ③ 布局视图
      _toolbarGroupButton(
        icon: Icons.dashboard_outlined,
        tooltip: '布局视图：自动布局 / 框选重排 / 框选移动',
        itemBuilder: (_) => <PopupMenuEntry<int>>[
          _toolbarMenuItem(
            icon: Icons.auto_fix_high,
            label: '自动布局',
            enabled: hasTree,
            onTap: _autoLink,
          ),
          _toolbarMenuItem(
            icon: _frameSelectMode ? Icons.deselect : Icons.highlight_alt,
            label: _frameSelectMode ? '退出框选重排' : '框选重排',
            enabled: hasTree,
            onTap: _toggleFrameSelectMode,
          ),
          _toolbarMenuItem(
            icon: Icons.schema,
            label: '局部重排',
            enabled: hasTree && _frameSelectMode && _selectedKpIds.isNotEmpty,
            onTap: _relayoutSelected,
          ),
          _toolbarMenuItem(
            icon: _frameMoveMode ? Icons.deselect : Icons.open_with,
            label: _frameMoveMode ? '退出框选移动' : '框选移动',
            enabled: hasTree,
            onTap: _toggleFrameMoveMode,
          ),
        ],
      ),
      // ④ AI 与作业
      _toolbarGroupButton(
        icon: Icons.auto_awesome,
        tooltip: 'AI 与作业：补前置 / 布置作业 / 作业历史',
        itemBuilder: (_) => <PopupMenuEntry<int>>[
          _toolbarMenuItem(
            icon: Icons.lightbulb_outline,
            label: '补前置',
            enabled: hasTree,
            onTap: _autoPrereq,
          ),
          _toolbarMenuItem(
            icon: Icons.assignment,
            label: '布置作业',
            // 与作业模式条内的「布置作业」一致：未框选薄弱点时禁用。
            enabled: hasTree && _selectedKpIds.isNotEmpty,
            onTap: _openHomeworkPage,
          ),
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
                        _frameSelectMode = false;
                        _frameMoveMode = false;
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
                          onRelayout: _onRelayout,
                          selectionMode: _homeworkMode ||
                              _frameSelectMode ||
                              _frameMoveMode,
                          selectedKpIds: _selectedKpIds,
                          onSelectionChanged: (s) => setState(() {
                            _selectedKpIds
                              ..clear()
                              ..addAll(s);
                          }),
                          allowGroupDrag: _frameMoveMode,
                          onMoveNodes: _onMoveNodes,
                        ),
        ),
      ],
    );
  }
}
