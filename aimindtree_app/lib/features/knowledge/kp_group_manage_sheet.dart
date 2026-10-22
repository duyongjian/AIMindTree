/// 知识点分组管理面板（modal bottom sheet，全局作用域）。
///
/// **只允许出现在知识点管理页**（架构定稿 2026-10-22）：分组是知识点界面的
/// 整理工具，不进知识树画布、不碰 `canvas_page.dart` / `auto_graph_service.dart`。
///
/// 能力：新建 / 重命名 / 删除全局组 + 展示每组有效成员数。
/// - 删除走 [GroupRepository.deleteGroup]（软删 + 墓碑同步），**不解散成员**——
///   组内知识点只是回到「未分组」，绝不会连知识点一起删。
/// - 成员数只统计 [liveKpIds] 里仍存在的知识点（已软删的知识点可能残留在
///   `members_json` 里，不计入展示，避免「组里 3 个点却只显示 2 条」的困惑）。
library;

import 'package:flutter/material.dart';

import '../../core/result.dart';
import '../../data/models/kp_group.dart';
import '../../data/repositories/group_repository.dart';

/// 打开分组管理面板；返回时调用方应刷新列表（组结构可能已变）。
Future<void> showKpGroupManageSheet(
  BuildContext context, {
  required GroupRepository groups,
  Set<String> liveKpIds = const <String>{},
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => KpGroupManageSheet(
      groups: groups,
      liveKpIds: liveKpIds,
    ),
  );
}

class KpGroupManageSheet extends StatefulWidget {
  const KpGroupManageSheet({
    super.key,
    required this.groups,
    this.liveKpIds = const <String>{},
  });

  final GroupRepository groups;

  /// 仍存在的知识点 id（用于统计「有效成员数」，过滤已软删残留）。
  final Set<String> liveKpIds;

  @override
  State<KpGroupManageSheet> createState() => _KpGroupManageSheetState();
}

class _KpGroupManageSheetState extends State<KpGroupManageSheet> {
  List<KpGroup> _groups = <KpGroup>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final groups = await widget.groups.listGlobalGroups();
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _loading = false;
    });
  }

  /// 组名展示：空名统一显示占位（与画布未命名树同一手法）。
  String _displayName(KpGroup g) => g.name.isEmpty ? '(未命名分组)' : g.name;

  int _liveCount(KpGroup g) =>
      g.members.where((m) => widget.liveKpIds.contains(m.kpId)).length;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ));
  }

  Future<String?> _askName(String title, String initial) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '分组名称'),
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

  Future<void> _create() async {
    final name = await _askName('新建分组', '');
    if (name == null || name.isEmpty) return;
    final res = await widget.groups.createGlobalGroup(name: name);
    if (!mounted) return;
    res.fold(
      (_) => _toast('已创建「$name」'),
      (e, _) => _toast('创建失败：$e'),
    );
    await _load();
  }

  Future<void> _rename(KpGroup g) async {
    final name = await _askName('重命名分组', g.name);
    if (name == null || name.isEmpty || name == g.name) return;
    final res = await widget.groups.renameGroup(g.id, name);
    if (!mounted) return;
    res.fold(
      (_) => _toast('已重命名'),
      (e, _) => _toast('重命名失败：$e'),
    );
    await _load();
  }

  Future<void> _delete(KpGroup g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除分组「${_displayName(g)}」？'),
        content: Text(
          '组内 ${_liveCount(g)} 个知识点将回到「未分组」，'
          '知识点本身不会被删除。',
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
    final res = await widget.groups.deleteGroup(g.id);
    if (!mounted) return;
    res.fold(
      (_) => _toast('已删除分组'),
      (e, _) => _toast('删除失败：$e'),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          height: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '分组管理',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _create,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新建分组'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _groups.isEmpty
                        ? const Center(
                            child: Text(
                              '还没有分组。\n点右上角「新建分组」把知识点归类整理。',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _groups.length,
                            itemBuilder: (_, i) {
                              final g = _groups[i];
                              return ListTile(
                                leading: CircleAvatar(
                                  radius: 14,
                                  child: Text(
                                    '${i + 1}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                title: Text(_displayName(g)),
                                subtitle: Text('${_liveCount(g)} 个知识点'),
                                trailing: IconButton(
                                  onPressed: () => _delete(g),
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: '删除分组',
                                  color: Colors.red,
                                ),
                                onTap: () => _rename(g),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
