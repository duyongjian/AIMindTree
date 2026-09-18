/// 删除笔记的确认弹窗。
///
/// 笔记被删除时，它提取出的知识点可能已经被并入若干棵知识树。直接静默删除会让
/// 用户莫名其妙地丢掉树里的节点，所以这里把「影响面」摊开给用户勾选：
/// - 什么都不勾 → 知识点留在原来的树里，只是笔记本体没了；
/// - 勾某些树 → 把这些知识点从这些树里摘掉（知识点本身仍是独立资产）；
/// - 勾「彻底删除知识点」→ 知识点、前置边、掌握记录一起删，不可恢复。
library;

import 'package:flutter/material.dart';

import '../../data/models/knowledge_tree.dart';

/// 用户在弹窗里的选择结果。
class DeleteNotePlan {
  const DeleteNotePlan({
    required this.deletePoints,
    required this.removeFromTrees,
  });

  /// 是否连知识点本身一起彻底删除。
  final bool deletePoints;

  /// 只解除关系的知识树 id 集合（[deletePoints] 为 true 时忽略）。
  final Set<String> removeFromTrees;
}

/// 返回 null 表示用户取消。
Future<DeleteNotePlan?> showDeleteNoteDialog({
  required BuildContext context,
  required String noteTitle,
  required int pointCount,
  required List<TreeImpact> impacts,
}) {
  // 没有知识点时不必展示影响面，走简单确认。
  if (pointCount == 0) {
    return showDialog<DeleteNotePlan>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定删除「$noteTitle」？这篇笔记没有知识点。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              ctx,
              const DeleteNotePlan(
                deletePoints: false,
                removeFromTrees: <String>{},
              ),
            ),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  return showDialog<DeleteNotePlan>(
    context: context,
    builder: (ctx) => _DeleteNoteDialog(
      noteTitle: noteTitle,
      pointCount: pointCount,
      impacts: impacts,
    ),
  );
}

class _DeleteNoteDialog extends StatefulWidget {
  const _DeleteNoteDialog({
    required this.noteTitle,
    required this.pointCount,
    required this.impacts,
  });

  final String noteTitle;
  final int pointCount;
  final List<TreeImpact> impacts;

  @override
  State<_DeleteNoteDialog> createState() => _DeleteNoteDialogState();
}

class _DeleteNoteDialogState extends State<_DeleteNoteDialog> {
  final Set<String> _selected = <String>{};
  bool _deletePoints = false;

  @override
  Widget build(BuildContext context) {
    final impacts = widget.impacts;
    return AlertDialog(
      title: const Text('删除笔记'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('「${widget.noteTitle}」已提取出 ${widget.pointCount} 个知识点。'),
              const SizedBox(height: 12),
              if (impacts.isEmpty)
                const Text(
                  '这些知识点目前不属于任何知识树。',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                )
              else ...[
                const Text('它们当前属于以下知识树，勾选表示一并移除：'),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: impacts.length,
                    itemBuilder: (_, i) {
                      final im = impacts[i];
                      return CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _selected.contains(im.treeId),
                        onChanged: _deletePoints
                            ? null
                            : (v) => setState(() => v == true
                                ? _selected.add(im.treeId)
                                : _selected.remove(im.treeId)),
                        title: Text(
                          im.treeName.isEmpty ? '(未命名知识树)' : im.treeName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle:
                            Text('${im.pointCount} 个知识点来自这篇笔记'),
                      );
                    },
                  ),
                ),
              ],
              const Divider(height: 20),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _deletePoints,
                onChanged: (v) => setState(() => _deletePoints = v ?? false),
                title: const Text(
                  '彻底删除这些知识点',
                  style: TextStyle(color: Colors.red),
                ),
                subtitle: const Text(
                  '含前置关系与掌握记录，从所有知识树中移除，不可恢复',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _hintText,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            DeleteNotePlan(
              deletePoints: _deletePoints,
              removeFromTrees: _deletePoints ? <String>{} : _selected.toSet(),
            ),
          ),
          child: const Text('删除', style: TextStyle(color: Colors.red)),
        ),
      ],
    );
  }

  String get _hintText {
    if (_deletePoints) {
      return '将删除 ${widget.pointCount} 个知识点及其所有关系；笔记本体一并删除。';
    }
    if (_selected.isEmpty) {
      return '笔记本体删除，知识点保留在原知识树中。';
    }
    return '将从 ${_selected.length} 棵知识树中移除这些知识点（未在其它树中的知识点会变为未归类，之后可用「并入」重新加回）。';
  }
}
