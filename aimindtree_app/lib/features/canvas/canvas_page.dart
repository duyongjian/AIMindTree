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
library;

import 'package:flutter/material.dart';

import '../../ai/auto_graph_service.dart';
import '../../ai/extraction_service.dart';
import '../../ai/prereq_depth.dart';
import '../../canvas/render/tree_canvas.dart';
import '../../core/id.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/models/knowledge_tree.dart';
import '../../data/models/suggested_prerequisite.dart';
import '../../data/repositories/knowledge_repository.dart';
import '../../data/repositories/tree_repository.dart';

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

  /// 「重新布局」计数器，改变它会强制重建 [TreeCanvas] 让布局重跑。
  int _relayoutVersion = 0;
  bool _loading = false;

  KnowledgeRepository get _repo => widget.service.repo;
  TreeRepository get _treesRepo => widget.service.trees;

  /// 自动知识连线 / 自动补前置（DSL 优先 + 本地兜底）。
  late final AutoGraphService _auto;

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

  Future<void> _onCreateEdge(String fromKpId, String toKpId) async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    final res = await _repo.addManualPrerequisiteEdge(fromKpId, toKpId);
    if (!mounted) return;
    res.fold(
      (_) => _toast('已建立前置关系'),
      (e, _) => _toast('建立前置关系失败：$e'),
    );
    await _loadForTree(treeId);
  }

  Future<void> _onDeleteEdge(String edgeId) async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    final res = await _repo.deletePrerequisiteEdge(edgeId);
    if (!mounted) return;
    res.fold(
      (_) => _toast('已删除该关系'),
      (e, _) => _toast('删除失败：$e'),
    );
    await _loadForTree(treeId);
  }

  Future<void> _onMoveNode(String kpId, double x, double y) async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    await _repo.saveNodePosition(treeId, kpId, x, y);
  }

  Future<void> _onRelayout() async {
    final treeId = _selectedTree?.id;
    if (treeId == null) return;
    await _repo.clearNodePositions(treeId);
    setState(() => _relayoutVersion++);
    await _loadForTree(treeId);
    _toast('已重新布局');
  }

  // ================= 知识树管理 =================

  Future<void> _newTree() async {
    final name = await _askName('新建知识树', '给这棵树起个名字', '');
    if (name == null || name.trim().isEmpty) return;
    final res = await _treesRepo.createTree(name.trim());
    if (!mounted) return;
    final created = res.valueOrNull;
    if (created == null) {
      res.fold((_) => null, (e, _) => _toast('新建失败：$e'));
      return;
    }
    await _load();
    if (!mounted) return;
    // 新建后自动切过去
    final idx = _trees.indexWhere((t) => t.id == created.id);
    final target = idx == -1 ? created : _trees[idx];
    setState(() => _selectedTree = target);
    await _loadForTree(target.id);
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
    final res =
        await _treesRepo.addPoints(tree.id, kps.map((p) => p.id).toList());
    if (!mounted) return;
    res.fold(
      (added) =>
          _toast(added == 0 ? '这些知识点已经在树里了' : '已并入 $added 个知识点'),
      (e, _) => _toast('并入失败：$e'),
    );
    await _loadForTree(tree.id);
  }

  // ============ 自动图谱（DSL 优先 + 本地兜底） ============

  /// 自动连线：调用 [AutoGraphService] 推断前置关系并落库。
  Future<void> _autoLink() async {
    final tree = _selectedTree;
    if (tree == null) return;
    final res = await _auto.autoLink(tree.id);
    if (!mounted) return;
    res.fold(
      (r) {
        if (r.created > 0) {
          final how = r.usedFallback ? '（本地启发式）' : '（AI）';
          _toast('已自动建立$how ${r.created} 条前置关系');
          _loadForTree(tree.id);
        } else {
          _toast(r.note.isNotEmpty
              ? r.note
              : '没有可自动连接的新关系（可能已全部连好）');
        }
      },
      (e, _) => _toast('自动连线失败：$e'),
    );
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

  /// 跑深度补前置：Success → 弹建议 BottomSheet；Failure → toast。
  Future<void> _runPrereq(
    KnowledgePoint p,
    PrereqDepth depth,
    String? custom,
  ) async {
    final res = await _auto.autoPrerequisites(p, depth, customInstruction: custom);
    if (!mounted) return;
    res.fold(
      (r) => _showSuggestions(r),
      (e, _) => _toast('自动补前置失败：$e'),
    );
  }

  /// 工具栏「补前置」按钮：有选中点 → 对该点跑深度补前置；无选中点 → 提示先点选。
  Future<void> _autoPrereq() async {
    if (_selectedPoint != null) {
      _openDepthSheet(_selectedPoint!);
    } else {
      _toast('请先在画布上点选一个知识点，再补充它的前置知识');
    }
  }

  /// 建议结果 BottomSheet：顶部固定「仅为建议」提示，按 level 分组缩进展示。
  void _showSuggestions(AutoPrereqResult r) {
    if (!mounted) return;
    final byLevel = <int, List<SuggestedPrerequisite>>{};
    for (final s in r.suggestions) {
      byLevel.putIfAbsent(s.level, () => <SuggestedPrerequisite>[]).add(s);
    }
    final levels = byLevel.keys.toList()..sort();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.amber.shade50,
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '仅为建议，需自行新建笔记'
                      '${r.usedFallback ? '（本地启发式，建议以 AI 为准）' : ''}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
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
                        ListTile(
                          contentPadding: const EdgeInsets.only(left: 12),
                          leading: const Icon(Icons.add_circle_outline,
                              color: Colors.amber, size: 18),
                          title: Text(s.name),
                          subtitle: Text(
                            s.reason,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          dense: true,
                          trailing: TextButton(
                            onPressed: () => _createNoteFor(s),
                            child: const Text('去新建笔记'),
                          ),
                        ),
                    ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () => _createAllNotes(r.suggestions),
                    icon: const Icon(Icons.note_add_outlined),
                    label: const Text('全部新建为笔记'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('知道了'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
                      setState(() => _selectedTree = v);
                      await _loadForTree(v.id);
                    },
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                iconSize: 20,
                tooltip: '新建知识树',
                onPressed: _newTree,
              ),
              IconButton(
                icon: const Icon(Icons.drive_file_rename_outline),
                iconSize: 20,
                tooltip: '重命名',
                onPressed: tree == null ? null : _renameTree,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                iconSize: 20,
                tooltip: '删除知识树',
                onPressed: tree == null ? null : _deleteTree,
              ),
              IconButton(
                icon: const Icon(Icons.merge_type),
                iconSize: 20,
                tooltip: '把某篇笔记的知识点并入当前树',
                onPressed: tree == null ? null : _mergeFromNote,
              ),
              IconButton(
                icon: const Icon(Icons.auto_fix_high),
                iconSize: 20,
                tooltip: '自动连线：推断知识点之间的前置关系',
                onPressed: tree == null ? null : _autoLink,
              ),
              IconButton(
                icon: const Icon(Icons.lightbulb_outline),
                iconSize: 20,
                tooltip: '补充选中知识点的前置（先点选一个节点）',
                onPressed: tree == null ? null : _autoPrereq,
              ),
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
                        ),
        ),
      ],
    );
  }
}
