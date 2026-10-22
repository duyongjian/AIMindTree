/// 知识点回收站（P2：软删墓碑的可见面）。
///
/// **软删铁律的可见面**：知识点被删除后写 `deleted_at` 墓碑，从所有常规列表
/// （知识点管理页 / 知识树画布 / 笔记详情知识点区 / AI 助手检索）里消失，
/// **只出现在本回收站**。用户可以：
/// - 「恢复」→ 墓碑置空、version++，知识点回到常规列表（不自动加入任何知识树）；
/// - 「彻底删除」→ 物理删除，不可恢复。
///
/// 数据铁律：本页只读 [KnowledgeRepository.deletedKnowledgePoints]（只返回
/// `deleted_at` 非空的墓碑行），恢复 / 彻底删除一律走仓储层
/// （[KnowledgeRepository.restoreKnowledgePoint] /
/// [KnowledgeRepository.purgeKnowledgePoint]），**禁止 UI 直写表**。
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
        setState(() => _deleted = _deleted.where((k) => k.id != kp.id).toList());
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
        setState(() => _deleted = _deleted.where((k) => k.id != kp.id).toList());
        _reload();
        _toast('已彻底删除');
      },
      (e, _) => _toast('彻底删除失败：$e'),
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
        title: const Text('回收站'),
        actions: [
          IconButton(
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
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
  Widget _buildTile(KnowledgePoint kp) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
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
    );
  }
}
