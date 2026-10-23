/// 知识点回收站（P2：软删墓碑的可见面）。
///
/// **软删铁律的可见面**：知识点被删除后写 `deleted_at` 墓碑，从所有常规列表
/// （知识点管理页 / 知识树画布 / 笔记详情知识点区 / AI 助手检索）里消失，
/// **只出现在本回收站**。用户可以：
/// - 「恢复」→ 墓碑置空、version++，知识点回到常规列表（不自动加入任何知识树）；
/// - 「彻底删除」→ 物理删除，不可恢复。
/// - 「一键清空」→ 对整个回收站一次确认后全部物理删除（不可恢复）；
/// - 多选态（AppBar 图标 / 长按卡片进入）→ 全选 +「彻底删除(N)」批量物理删除。
///
/// 数据铁律：本页只读 [KnowledgeRepository.deletedKnowledgePoints]（只返回
/// `deleted_at` 非空的墓碑行），恢复 / 彻底删除一律走仓储层
/// （[KnowledgeRepository.restoreKnowledgePoint] /
/// [KnowledgeRepository.purgeKnowledgePoint] /
/// [KnowledgeRepository.purgeKnowledgePoints]），**禁止 UI 直写表**。
library;

import 'package:flutter/material.dart';

import '../../core/result.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/repositories/knowledge_repository.dart';

/// 知识点回收站页。
class KnowledgeRecycleBinPage extends StatefulWidget {
  const KnowledgeRecycleBinPage({super.key, required this.repo});

  /// 知识点仓储（写操作只走它，见 §11 禁 UI 直写表）。
  final KnowledgeRepository repo;

  @override
  State<KnowledgeRecycleBinPage> createState() =>
      _KnowledgeRecycleBinPageState();
}

class _KnowledgeRecycleBinPageState extends State<KnowledgeRecycleBinPage> {
  /// 墓碑行（已删除的知识点）。
  List<KnowledgePoint> _deleted = <KnowledgePoint>[];

  /// 笔记 id → 标题（用于展示来源标签）。
  final Map<String, String> _noteTitles = <String, String>{};

  /// 搜索关键词（按名称过滤）。
  final _queryCtrl = TextEditingController();
  String _query = '';

  // ============ 多选批量彻底删除 ============
  /// 多选态：进入后每条卡片显示 Checkbox，AppBar 显示 关闭 / 全选 /
  /// 「彻底删除(N)」（形态对齐知识点管理页的多选态）。
  bool _selectionMode = false;
  Set<String> _selected = <String>{};

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

  /// 重新拉取回收站列表（只取墓碑行）。
  Future<void> _reload() async {
    final deleted = await widget.repo.deletedKnowledgePoints();
    // 笔记标题只用于来源标签展示；笔记本身可能被删了，查不到就退化成
    // 「笔记」标签，不影响主流程。
    final notes = await widget.repo.listNotes();
    if (!mounted) return;
    setState(() {
      _deleted = deleted;
      _noteTitles
        ..clear()
        ..addAll({for (final n in notes) n.id: n.title});
      // 摘掉已不在回收站里的勾选（恢复 / 彻底删除后残留的脏 id）。
      _selected.removeWhere((id) => !deleted.any((k) => k.id == id));
    });
  }

  /// 按名称过滤后的列表。
  List<KnowledgePoint> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _deleted;
    return _deleted
        .where((kp) => kp.name.toLowerCase().contains(q))
        .toList();
  }

  /// 来源标签：手动 / AI 提取 / 无来源笔记 / 笔记标题。
  String _sourceLabel(KnowledgePoint kp) {
    if (kp.origin == 'user_manual') return '手动';
    if (kp.sourceNoteId.isEmpty) return '无来源笔记';
    final t = _noteTitles[kp.sourceNoteId];
    return t == null || t.isEmpty ? '笔记' : t;
  }

  /// 恢复：墓碑置空 → 知识点回到常规列表。
  Future<void> _restore(KnowledgePoint kp) async {
    final res = await widget.repo.restoreKnowledgePoint(kp.id);
    if (!mounted) return;
    res.fold(
      (_) {
        setState(() {
          _deleted = _deleted.where((k) => k.id != kp.id).toList();
          // 多选态里恢复掉的条目要摘掉勾选，不能留着参与批量彻底删除。
          _selected.remove(kp.id);
        });
        _toast('已恢复');
      },
      (e, _) => _toast('恢复失败：$e'),
    );
  }

  /// 彻底删除：二次确认 → 物理删除（不可恢复）。
  Future<void> _confirmPurge(KnowledgePoint kp) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('彻底删除'),
        content: Text(
          '彻底删除后不可恢复，确认？\n\n'
          '「${kp.name}」将从回收站中被物理删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('彻底删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await widget.repo.purgeKnowledgePoint(kp.id);
    if (!mounted) return;
    res.fold(
      (_) {
        // 先把这行从本地列表摘掉（列表立即反映结果），再后台重载对齐。
        setState(() {
          _deleted = _deleted.where((k) => k.id != kp.id).toList();
          _selected.remove(kp.id);
        });
        _reload();
        _toast('已彻底删除');
      },
      (e, _) => _toast('彻底删除失败：$e'),
    );
  }

  // ============ 一键清空 / 多选批量彻底删除 ============

  /// 「一键清空」入口：确认弹窗（文案写明彻底删除 N 个、不可恢复）→
  /// 对整个回收站（全量，不受搜索过滤影响）走批量物理删除。
  Future<void> _confirmPurgeAll() async {
    final ids = <String>[for (final kp in _deleted) kp.id];
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('一键清空回收站'),
        content: Text(
          '彻底删除 ${ids.length} 个知识点，不可恢复。\n\n'
          '删除后它们将从所有设备消失，无法找回。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('彻底删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _purgeMany(ids);
  }

  /// 多选态「彻底删除(N)」：确认弹窗（写明不可恢复）→ 对选中项批量
  /// 物理删除。
  Future<void> _confirmPurgeSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量彻底删除'),
        content: Text(
          '确定彻底删除选中的 ${ids.length} 个知识点？\n\n'
          '删除后不可恢复，它们将从回收站中物理删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('彻底删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _purgeMany(ids);
  }

  /// 批量物理删除的执行体（一键清空 / 多选彻底删除共用）：走仓储层
  /// [KnowledgeRepository.purgeKnowledgePoints]（单条失败不阻断其余）→
  /// 本地列表立即摘除 → 后台重载对齐 → toast 回执。
  Future<void> _purgeMany(List<String> ids) async {
    final res = await widget.repo.purgeKnowledgePoints(ids);
    if (!mounted) return;
    res.fold(
      (n) {
        final purged = ids.toSet();
        setState(() {
          _deleted = _deleted.where((k) => !purged.contains(k.id)).toList();
          _selected.clear();
          _selectionMode = false;
        });
        _reload();
        _toast('已彻底删除 $n 个知识点');
      },
      (e, _) => _toast('彻底删除失败：$e'),
    );
  }

  /// 进入多选态并预选 [id]（长按卡片入口）。
  void _enterSelection(String id) => setState(() {
        _selectionMode = true;
        _selected = <String>{id};
      });

  /// 进入多选态但不预选任何条目（AppBar 图标入口）。
  void _enterSelectionMode() => setState(() {
        _selectionMode = true;
        _selected = <String>{};
      });

  /// 勾选 / 取消勾选；全部取消时自动退出多选（与管理页行为一致）。
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

  /// 全选当前**可见**（搜索过滤后）的墓碑行。
  void _selectAll() =>
      setState(() => _selected = <String>{for (final kp in _filtered) kp.id});

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ));
  }

  /// 删除时间格式化（本地时区，yyyy-MM-dd HH:mm）。
  static String _formatTime(DateTime? t) {
    if (t == null) return '未知时间';
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, "0")}-'
        '${l.day.toString().padLeft(2, "0")} '
        '${l.hour.toString().padLeft(2, "0")}:${l.minute.toString().padLeft(2, "0")}';
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: _selectionMode
            ? Text('已选 ${_selected.length} 个')
            : const Text('回收站'),
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
              onPressed: _selected.isEmpty ? null : _confirmPurgeSelected,
              child: Text(
                '彻底删除(${_selected.length})',
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ] else ...[
            IconButton(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
            ),
            // 一键清空：空回收站时禁用（没东西可清）。
            IconButton(
              onPressed: _deleted.isEmpty ? null : _confirmPurgeAll,
              icon: const Icon(Icons.delete_sweep),
              tooltip: '一键清空回收站',
            ),
            // 多选批量彻底删除入口（长按卡片亦可进入）。
            IconButton(
              onPressed: _enterSelectionMode,
              icon: const Icon(Icons.checklist),
              tooltip: '批量彻底删除',
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
                hintText: '搜索已删除的知识点',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.delete_outline,
                            size: 40, color: Colors.grey),
                        const SizedBox(height: 8),
                        Text(
                          _deleted.isEmpty
                              ? '回收站是空的'
                              : '没有匹配「$_query」的已删除知识点',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: list.length,
                    itemBuilder: (_, i) => _buildTile(list[i]),
                  ),
          ),
        ],
      ),
    );
  }

  /// 单条墓碑行：名称 / 类型 / 来源标签 / 删除时间 + 两个动作按钮。
  ///
  /// 多选态：行首加 Checkbox，点卡片即切换勾选；常规态长按卡片进入
  /// 多选并预选该条（与管理页长按入口一致）。
  Widget _buildTile(KnowledgePoint kp) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: _selectionMode ? () => _toggleSelection(kp.id) : null,
        onLongPress: _selectionMode ? null : () => _enterSelection(kp.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (_selectionMode)
                    Checkbox(
                      value: _selected.contains(kp.id),
                      onChanged: (_) => _toggleSelection(kp.id),
                    ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      kp.type.label,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      kp.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.lineThrough,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${_sourceLabel(kp)} · 删除于 ${_formatTime(kp.deletedAt)}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      onPressed: () => _restore(kp),
                      icon: const Icon(Icons.restore, size: 18),
                      label: const Text('恢复'),
                    ),
                    TextButton.icon(
                      onPressed: () => _confirmPurge(kp),
                      icon: const Icon(Icons.delete_forever, size: 18),
                      label: const Text(
                        '彻底删除',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
