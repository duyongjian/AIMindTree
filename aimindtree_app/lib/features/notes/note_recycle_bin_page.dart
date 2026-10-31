/// 笔记回收站（软删墓碑的可见面）。
///
/// 笔记被删除后写 `deletedAt` 墓碑，从常规列表（笔记列表页 / AI 助手检索）
/// 里消失，**只出现在本回收站**。用户可以：
/// - 「恢复」→ 墓碑置空、version++，笔记回到常规列表；
/// - 「彻底删除」→ 物理删除，不可恢复。
/// - 「清空」→ 对整个回收站确认后全部物理删除（不可恢复）。
///
/// 数据铁律：本页只读 [KnowledgeRepository.deletedNotes]（只返回 `deleted_at`
/// 非空的墓碑行），恢复 / 彻底删除一律走仓储层
/// （[KnowledgeRepository.restoreNote] / [KnowledgeRepository.purgeNote] /
/// [KnowledgeRepository.purgeNotes]），**禁止 UI 直写表**。
///
/// 结构与 [KnowledgeRecycleBinPage] 对齐，但针对笔记（无来源标签 / 无多选态，
/// 仅按条目恢复 / 彻底删除）。
library;

import 'package:flutter/material.dart';

import '../../core/result.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/repositories/knowledge_repository.dart';

/// 笔记回收站页。
class NoteRecycleBinPage extends StatefulWidget {
  const NoteRecycleBinPage({super.key, required this.repo});

  /// 笔记仓储（写操作只走它，见上）。
  final KnowledgeRepository repo;

  @override
  State<NoteRecycleBinPage> createState() => _NoteRecycleBinPageState();
}

class _NoteRecycleBinPageState extends State<NoteRecycleBinPage> {
  /// 墓碑行（已删除的笔记）。
  List<Note> _deleted = <Note>[];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 重新拉取回收站列表（只取墓碑行）。
  Future<void> _reload() async {
    final deleted = await widget.repo.deletedNotes();
    if (!mounted) return;
    setState(() => _deleted = deleted);
  }

  /// 恢复：墓碑置空 → 笔记回到常规列表。
  Future<void> _restore(Note n) async {
    final res = await widget.repo.restoreNote(n.id);
    if (!mounted) return;
    res.fold(
      (_) {
        setState(() => _deleted = _deleted.where((x) => x.id != n.id).toList());
        _toast('已恢复');
      },
      (e, _) => _toast('恢复失败：$e'),
    );
  }

  /// 彻底删除：二次确认 → 物理删除（不可恢复）。
  Future<void> _confirmPurge(Note n) async {
    final title = n.title.isEmpty ? '(无标题)' : n.title;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('彻底删除'),
        content: Text(
          '彻底删除后不可恢复，确认？\n\n'
          '「$title」将从回收站中被物理删除。',
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
    final res = await widget.repo.purgeNote(n.id);
    if (!mounted) return;
    res.fold(
      (_) {
        // 先把这行从本地列表摘掉（列表立即反映结果），再后台重载对齐。
        setState(() => _deleted = _deleted.where((x) => x.id != n.id).toList());
        _reload();
        _toast('已彻底删除');
      },
      (e, _) => _toast('彻底删除失败：$e'),
    );
  }

  /// 「清空」：确认弹窗（文案写明彻底删除 N 篇、不可恢复）→
  /// 对整个回收站（全量，不受任何过滤影响）走批量物理删除。
  Future<void> _confirmPurgeAll() async {
    if (_deleted.isEmpty) return;
    final ids = <String>[for (final n in _deleted) n.id];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空回收站'),
        content: Text(
          '彻底删除 ${ids.length} 篇笔记，不可恢复。\n\n'
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
    final res = await widget.repo.purgeNotes(ids);
    if (!mounted) return;
    res.fold(
      (_) {
        setState(() => _deleted = <Note>[]);
        _toast('已清空回收站');
      },
      (e, _) => _toast('清空失败：$e'),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('笔记回收站'),
        // 进入方式是 push，Flutter 会自动补返回箭头（leading）；此处只加清空入口。
        actions: [
          IconButton(
            onPressed: _deleted.isEmpty ? null : _confirmPurgeAll,
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空回收站',
          ),
        ],
      ),
      body: _deleted.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline, size: 40, color: Colors.grey),
                  SizedBox(height: 8),
                  Text('回收站是空的', style: TextStyle(color: Colors.grey)),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _deleted.length,
              itemBuilder: (_, i) => _buildTile(_deleted[i]),
            ),
    );
  }

  /// 单条墓碑行：标题（无标题时显示占位）/ 删除时间 + 两个动作按钮。
  Widget _buildTile(Note n) {
    final title = n.title.isEmpty ? '(无标题)' : n.title;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.lineThrough,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '删除于 ${_formatTime(n.deletedAt)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    onPressed: () => _restore(n),
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('恢复'),
                  ),
                  TextButton.icon(
                    onPressed: () => _confirmPurge(n),
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
