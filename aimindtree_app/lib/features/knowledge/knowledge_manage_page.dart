/// 知识点管理页（P1-1）。
///
/// 全量列表（默认更新时间倒序）+ 搜索 + 筛选（类型 / 来源 / 掌握状态）。
/// 点条目 → 进入该知识点的老师模式页（讲解 + 追问，复用 [TeacherPage]）。
/// 顶部「+」手动新建（名称必填；类型、定义、可选关联笔记）。
/// 条目菜单：编辑 / 加入知识树 / 追问 / 删除（影响面预览）。
/// 多选批量删除：AppBar 图标或长按条目进入多选态，全选 +「删除(N)」批量
/// 软删（墓碑，进回收站可恢复）。
///
/// 数据铁律：列表只读 `allKnowledgePoints()`（已过滤软删）；删除走
/// [KnowledgeRepository.softDeleteKnowledgePoint]（墓碑，见 PRD §4.1）。
library;

import 'package:flutter/material.dart';

import '../../ai/extraction_service.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/models/knowledge_tree.dart';
import '../../data/repositories/knowledge_repository.dart';
import '../../data/repositories/tree_repository.dart';
import 'knowledge_recycle_bin_page.dart';

class KnowledgeManagePage extends StatefulWidget {
  const KnowledgeManagePage({
    super.key,
    required this.service,
    required this.db,
    this.onOpenTeacher,
  });

  final ExtractionService service;
  final AppDatabase db;

  /// 进入老师模式页的回调（由 AppShell 提供，统一持 `kp:{id}` 锁）。
  final ValueChanged<KnowledgePoint>? onOpenTeacher;

  @override
  State<KnowledgeManagePage> createState() => _KnowledgeManagePageState();
}

class _KnowledgeManagePageState extends State<KnowledgeManagePage> {
  KnowledgeRepository get _repo => widget.service.repo;
  TreeRepository get _trees => widget.service.trees;

  List<KnowledgePoint> _all = <KnowledgePoint>[];
  final Map<String, MasteryStatus> _mastery = <String, MasteryStatus>{};
  final Map<String, String> _noteTitles = <String, String>{};

  // 搜索与筛选
  final _queryCtrl = TextEditingController();
  String _query = '';
  KnowledgePointType? _typeFilter; // null = 全部
  String _originFilter = 'all'; // all | ai | manual | no_note
  MasteryStatus? _masteryFilter; // null = 全部

  // ============ 多选批量删除 ============
  /// 多选态：进入后每条显示 Checkbox，AppBar 显示 关闭 / 全选 /「删除(N)」。
  bool _selectionMode = false;
  Set<String> _selected = <String>{};

  List<KnowledgePoint> get _filtered {
    final q = _query.trim().toLowerCase();
    return _all.where((kp) {
      if (q.isNotEmpty && !kp.name.toLowerCase().contains(q)) return false;
      if (_typeFilter != null && kp.type != _typeFilter) return false;
      if (_originFilter == 'ai' && kp.origin != 'ai_extract') return false;
      if (_originFilter == 'manual' && kp.origin != 'user_manual') return false;
      if (_originFilter == 'no_note' && kp.sourceNoteId.isNotEmpty) return false;
      if (_masteryFilter != null &&
          (_mastery[kp.id] ?? MasteryStatus.unknown) != _masteryFilter) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final all = await _repo.allKnowledgePoints();
    final notes = await _repo.listNotes();
    final mastery = <String, MasteryStatus>{};
    for (final kp in all) {
      mastery[kp.id] = await _repo.currentMastery(kp.id);
    }
    if (!mounted) return;
    setState(() {
      _all = all;
      _mastery
        ..clear()
        ..addAll(mastery);
      _noteTitles
        ..clear()
        ..addAll({for (final n in notes) n.id: n.title});
    });
  }

  String _sourceLabel(KnowledgePoint kp) {
    if (kp.origin == 'user_manual') return '手动';
    if (kp.sourceNoteId.isEmpty) return '无来源笔记';
    final t = _noteTitles[kp.sourceNoteId];
    return t == null || t.isEmpty ? '笔记' : t;
  }

  Color _masteryColor(MasteryStatus s) => switch (s) {
        MasteryStatus.mastered => Colors.green,
        MasteryStatus.learning => Colors.blue,
        MasteryStatus.notMastered => Colors.orange,
        MasteryStatus.abandoned => Colors.grey,
        _ => Colors.grey,
      };

  Future<void> _onTap(KnowledgePoint kp) async {
    if (widget.onOpenTeacher != null) {
      widget.onOpenTeacher!(kp);
      return;
    }
    // 无回调时也能落地（理论不会走到，AppShell 必传）。
    await _reload();
  }

  /// 打开回收站（已删除的知识点只在这里可见，可恢复 / 彻底删除）。
  ///
  /// 从回收站返回后要刷新本页列表：恢复成功的知识点会重新出现在常规列表里
  /// （本页在 AppShell 的 IndexedStack 中常驻，返回时不会自动重建）。
  Future<void> _openRecycleBin() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => KnowledgeRecycleBinPage(repo: _repo),
    ));
    if (!mounted) return;
    await _reload();
  }

  /// 手动新建 / 编辑弹窗。
  Future<void> _showEditDialog(KnowledgePoint? existing) async {
    final nameCtrl =
        TextEditingController(text: existing?.name ?? '');
    final defCtrl =
        TextEditingController(text: existing?.definition ?? '');
    var type = existing?.type ?? KnowledgePointType.concept;
    var sourceNoteId = existing?.sourceNoteId ?? '';
    final notes = await _repo.listNotes();
    if (!mounted) return;
    // 下拉的初始值必须命中列表里的**某一项**（DropdownButtonFormField 断言
    // 「有且仅有一个匹配项」，0 匹配直接崩）。notes 是查库后的新列表，
    // 而 sourceNoteId 可能指向一篇已被软删的笔记（listNotes 只返回未删笔记）
    // → 按 id 从新列表取不到实例。此时补一个「笔记已删除」占位项，
    // 既不崩，也能如实展示当前关联（保存时仍写回原 id，不静默改锚点）。
    final noteIds = <String>[for (final n in notes) n.id];
    final sourceNoteMissing =
        sourceNoteId.isNotEmpty && !noteIds.contains(sourceNoteId);

    await showDialog<KnowledgePoint?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(existing == null ? '新建知识点' : '编辑知识点'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    autofocus: existing == null,
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
                    items: [
                      for (final t in KnowledgePointType.values)
                        DropdownMenuItem(value: t, child: Text(t.label)),
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
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: sourceNoteId,
                    decoration: const InputDecoration(
                      labelText: '关联笔记（可选）',
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('不关联（无来源笔记）'),
                      ),
                      // 原关联的笔记已被软删 → 补占位项，保证 initialValue
                      // 有且仅有一个匹配项（否则 DropdownButton 断言崩溃）。
                      if (sourceNoteMissing)
                        DropdownMenuItem(
                          value: sourceNoteId,
                          child: const Text(
                            '（来源笔记已删除）',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      for (final n in notes)
                        DropdownMenuItem(
                          value: n.id,
                          child: Text(
                            n.title.isEmpty
                                ? n.contentMd.split('\n').first
                                : n.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setSt(() => sourceNoteId = v ?? ''),
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
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) {
                  _toast('名称不能为空');
                  return;
                }
                final kp = KnowledgePoint(
                  id: existing?.id,
                  name: name,
                  type: type,
                  definition: defCtrl.text,
                  sourceNoteId: sourceNoteId,
                  sourceStart: existing?.sourceStart ?? -1,
                  sourceEnd: existing?.sourceEnd ?? -1,
                  sourceQuote: existing?.sourceQuote ?? '',
                  origin: existing?.origin ?? 'user_manual',
                  confidence: existing?.confidence ?? 0,
                  version: existing?.version ?? 1,
                  deviceId: existing?.deviceId ?? '',
                );
                final res = existing == null
                    ? await _repo.createManualKnowledgePoint(
                        name: name,
                        type: type,
                        definition: defCtrl.text,
                        sourceNoteId: sourceNoteId,
                      )
                    : await _repo.updateKpMeta(kp);
                if (!mounted) return;
                if (res is Failure<KnowledgePoint>) {
                  _toast('保存失败：${res.message}');
                  return;
                }
                Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    await _reload();
  }

  /// 加入知识树（反向入口，P1-4）。
  Future<void> _showAddToTreeDialog(KnowledgePoint kp) async {
    final trees = await _trees.listTrees();
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('把「${kp.name}」加入哪棵知识树？'),
        children: [
          for (final t in trees)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, t.id),
              child: Text(
                t.name.isEmpty ? '(未命名知识树)' : t.name,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__new__'),
            child: const Row(
              children: [
                Icon(Icons.add, size: 18),
                SizedBox(width: 4),
                Text('＋ 新建知识树'),
              ],
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
    String? treeId = picked;
    if (picked == '__new__') {
      final name = await _askName('新建知识树', '给这棵树起个名字', '');
      if (name == null || name.trim().isEmpty) return;
      final created = await _trees.createTree(name.trim());
      treeId = created is Success<KnowledgeTree> ? created.value.id : null;
    }
    if (treeId == null) return;
    final res = await _trees.addPoints(treeId, [kp.id]);
    if (!mounted) return;
    res.fold(
      (added) => _toast(added == 0 ? '已经在树里了' : '已加入知识树'),
      (e, _) => _toast('加入失败：$e'),
    );
    await _reload();
  }

  /// 删除（影响面预览，PRD §4.1）。
  Future<void> _confirmDelete(KnowledgePoint kp) async {
    final impacts = await _trees.treesContaining([kp.id]);
    final edgeCount = await _repo.countPrerequisiteEdges(kp.id);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除知识点'),
        content: Text(
          '确定删除「${kp.name}」？\n\n'
          '影响面：所在 ${impacts.length} 棵知识树、涉及 $edgeCount 条前置关系。\n'
          '删除后该知识点从所有界面消失（含知识树画布），不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await _repo.softDeleteKnowledgePoint(kp.id);
    if (!mounted) return;
    res.fold(
      (_) => _toast('已删除'),
      (e, _) => _toast('删除失败：$e'),
    );
    await _reload();
  }

  // ============ 多选批量删除（软删进回收站） ============

  /// 进入多选态并预选 [id]（长按条目入口）。
  void _enterSelection(String id) => setState(() {
        _selectionMode = true;
        _selected = <String>{id};
      });

  /// 进入多选态但不预选任何条目（AppBar 图标入口）。
  void _enterSelectionMode() => setState(() {
        _selectionMode = true;
        _selected = <String>{};
      });

  /// 勾选 / 取消勾选；全部取消时自动退出多选（与笔记列表行为一致）。
  void _toggleSelection(String id) => setState(() {
        if (_selected.contains(id)) {
          _selected.remove(id);
        } else {
          _selected.add(id);
        }
        if (_selected.isEmpty) _selectionMode = false;
      });

  /// 退出多选态（AppBar 关闭按钮）。
  void _exitSelection() => setState(() {
        _selectionMode = false;
        _selected.clear();
      });

  /// 全选当前**可见**（筛选后）的知识点。
  void _selectAll() =>
      setState(() => _selected = <String>{for (final kp in _filtered) kp.id});

  /// 批量删除：确认弹窗（说明将移入回收站、可恢复；汇总前置边影响面）
  /// → 对每个选中 KP 走 [KnowledgeRepository.softDeleteKnowledgePoint]（墓碑）
  /// → toast 回执 → 退出多选并刷新列表。
  Future<void> _confirmBatchDelete() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    // 影响面汇总：涉及前置边总数 + 所在知识树（删前统计，删后边已被级联清掉）。
    var edgeCount = 0;
    for (final id in ids) {
      edgeCount += await _repo.countPrerequisiteEdges(id);
    }
    final impacts = await _trees.treesContaining(ids);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除知识点'),
        content: Text(
          '确定删除选中的 ${ids.length} 个知识点？\n\n'
          '影响面：所在 ${impacts.length} 棵知识树、涉及 $edgeCount 条前置关系。\n'
          '删除后它们将移入回收站，可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '移入回收站',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 逐个软删（墓碑 → 回收站，可恢复）；单条失败不阻断其余。
    var deleted = 0;
    for (final id in ids) {
      final res = await _repo.softDeleteKnowledgePoint(id);
      if (res is Success<int>) {
        deleted += res.value;
      } else if (res is Failure<int>) {
        _toast('删除失败：${res.message}');
      }
    }
    if (!mounted) return;
    _toast('已将 $deleted 个知识点移入回收站');
    _exitSelection();
    await _reload();
  }

  Future<String?> _askName(String title, String label, String initial) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
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

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: _selectionMode
            ? Text('已选 ${_selected.length} 个')
            : const Text('知识点'),
        leading: _selectionMode
            ? IconButton(
                onPressed: _exitSelection,
                icon: const Icon(Icons.close),
                tooltip: '退出多选',
              )
            : null,
        actions: [
          if (_selectionMode) ...[
            IconButton(
              onPressed: _selectAll,
              icon: const Icon(Icons.select_all),
              tooltip: '全选',
            ),
            TextButton(
              onPressed: _selected.isEmpty ? null : _confirmBatchDelete,
              child: Text(
                '删除(${_selected.length})',
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ] else ...[
            IconButton(
              onPressed: _openRecycleBin,
              icon: const Icon(Icons.delete_outline),
              tooltip: '回收站',
            ),
            IconButton(
              onPressed: _enterSelectionMode,
              icon: const Icon(Icons.checklist),
              tooltip: '批量删除',
            ),
            IconButton(
              onPressed: () => _showEditDialog(null),
              icon: const Icon(Icons.add),
              tooltip: '新建知识点',
            ),
            IconButton(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _queryCtrl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '搜索知识点名称',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          // 筛选 chips：类型
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('全部类型'),
                  selected: _typeFilter == null,
                  onSelected: (_) => setState(() => _typeFilter = null),
                ),
                const SizedBox(width: 6),
                for (final t in KnowledgePointType.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(t.label),
                      selected: _typeFilter == t,
                      onSelected: (_) => setState(
                        () => _typeFilter = _typeFilter == t ? null : t,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 筛选 chips：来源
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final f in const [
                  ('all', '全部来源'),
                  ('ai', 'AI 提取'),
                  ('manual', '手动'),
                  ('no_note', '无来源笔记'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(f.$2),
                      selected: _originFilter == f.$1,
                      onSelected: (_) => setState(() => _originFilter = f.$1),
                    ),
                  ),
                const SizedBox(width: 6),
                for (final m in MasteryStatus.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(m.label),
                      selected: _masteryFilter == m,
                      onSelected: (_) => setState(
                        () =>
                            _masteryFilter = _masteryFilter == m ? null : m,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '还没有知识点。点右上角「+」手动新建，\n或去笔记页跑一次提取。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final kp = list[i];
                      final m = _mastery[kp.id] ?? MasteryStatus.unknown;
                      return ListTile(
                        leading: _selectionMode
                            ? Checkbox(
                                value: _selected.contains(kp.id),
                                onChanged: (_) => _toggleSelection(kp.id),
                              )
                            : CircleAvatar(
                                radius: 14,
                                backgroundColor:
                                    _masteryColor(m).withOpacity(0.15),
                                child: Text(
                                  kp.type.label[0],
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: _masteryColor(m),
                                  ),
                                ),
                              ),
                        title: Text(kp.name),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_sourceLabel(kp)),
                            if (kp.definition.isNotEmpty)
                              Text(
                                kp.definition,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _masteryColor(m).withOpacity(0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                m.label,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _masteryColor(m),
                                ),
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: '更多',
                              onSelected: (v) {
                                switch (v) {
                                  case 'edit':
                                    _showEditDialog(kp);
                                  case 'tree':
                                    _showAddToTreeDialog(kp);
                                  case 'teach':
                                    _onTap(kp);
                                  case 'delete':
                                    _confirmDelete(kp);
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text('编辑'),
                                ),
                                PopupMenuItem(
                                  value: 'tree',
                                  child: Text('加入知识树'),
                                ),
                                PopupMenuItem(
                                  value: 'teach',
                                  child: Text('追问 / 讲解'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text(
                                    '删除',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        onTap: _selectionMode
                            ? () => _toggleSelection(kp.id)
                            : () => _onTap(kp),
                        onLongPress:
                            _selectionMode ? null : () => _enterSelection(kp.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
