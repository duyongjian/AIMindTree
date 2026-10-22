import 'package:flutter/material.dart';

import 'ai/ai_task_router.dart';
import 'ai/extraction_service.dart';
import 'core/result.dart';
import 'core/secret_store.dart';
import 'data/db/drift_database.dart';
import 'data/models/knowledge_point.dart';
import 'data/models/knowledge_tree.dart';
import 'data/repositories/ai_session_repository.dart';
import 'data/repositories/knowledge_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/sync/sync_context.dart';
import 'features/agent/agent_page.dart';
import 'features/canvas/canvas_page.dart';
import 'features/knowledge/knowledge_manage_page.dart';
import 'features/notes/delete_note_dialog.dart';
import 'features/notes/note_editor_page.dart';
import 'features/teacher/teacher_page.dart';
import 'features/settings/settings_page.dart';
import 'ui/job_tray.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final (service, db, router, settings, sync) =
      await ExtractionService.bootstrap();
  runApp(MyApp(
    service: service,
    db: db,
    router: router,
    settings: settings,
    sync: sync,
    secretStore: await FileSecretStore.defaultInstance(),
  ));
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.service,
    required this.db,
    required this.router,
    required this.settings,
    required this.sync,
    required this.secretStore,
  });

  final ExtractionService service;
  final AppDatabase db;
  final AiTaskRouter router;
  final SettingsRepository settings;
  final SyncContext sync;
  final SecretStore secretStore;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AIMindTree',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: AppShell(
          service: service,
          db: db,
          settings: settings,
          sync: sync,
          secretStore: secretStore,
        ),
      );
}

/// 应用壳：底部导航 笔记 / 提取 / 知识树 / 设置。
/// 老师模式从知识树节点点入。
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.service,
    required this.db,
    required this.settings,
    required this.sync,
    required this.secretStore,
  });
  final ExtractionService service;
  final AppDatabase db;
  final SettingsRepository settings;
  final SyncContext sync;
  final SecretStore secretStore;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  late final AiSessionRepository _sessions = AiSessionRepository(widget.db);
  // 触发画布刷新（提取完后跳过去时用）
  final _canvasKey = GlobalKey<CanvasPageState>();
  // 笔记列表触发刷新
  final _notesKey = GlobalKey<NotesListPageState>();
  // 设置页 key（用于添加 provider 后重载）
  final _settingsKey = GlobalKey<SettingsPageState>();
  // 知识点页 key（切进入时刷新列表）
  final _kpKey = GlobalKey<KnowledgeManagePageState>();
  // AI 助手 Tab key（切进入时刷新其知识树下拉列表）
  final _agentKey = GlobalKey<AgentPageState>();

  @override
  void initState() {
    super.initState();
  }

  Future<void> _openTeacher(KnowledgePoint kp) async {
    // B4：同点的老师模式会话已开着（或该 kp 锁被别的任务占着）→ 挡住，
    // 不静默失败：toast 说人话 + 展开托盘让用户看到是谁占着。
    if (widget.service.jobs.isLocked('kp:${kp.id}')) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(const SnackBar(
        content: Text('该知识点的老师模式会话已打开，完成或关闭后再试'),
        duration: Duration(seconds: 2),
      ));
      widget.service.jobs.requestExpandTray();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TeacherPage(
        kp: kp,
        sessions: _sessions,
        ai: widget.service.ai,
        repo: widget.service.repo,
        jobs: widget.service.jobs,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      NotesListPage(
        key: _notesKey,
        service: widget.service,
        db: widget.db,
        onJumpToCanvas: () {
          setState(() => _index = 3);
          _canvasKey.currentState?.refresh();
        },
      ),
      KnowledgeManagePage(
        key: _kpKey,
        service: widget.service,
        db: widget.db,
        onOpenTeacher: _openTeacher,
      ),
      AgentPage(
        key: _agentKey,
        service: widget.service,
        db: widget.db,
      ),
      CanvasPage(
        key: _canvasKey,
        service: widget.service,
        db: widget.db,
        onKpTap: _openTeacher,
      ),
      SettingsPage(
        key: _settingsKey,
        settings: widget.settings,
        syncConfig: widget.sync.config,
        syncStatusStore: widget.sync.statusStore,
        syncScheduler: widget.sync.scheduler,
        syncOutbox: widget.sync.outbox,
        secretStore: widget.secretStore,
        onChanged: () {
          // 设置变更提示：当前 P0 需重启生效，给个 SnackBar 提示。
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('AI 服务配置已刷新。'),
            duration: Duration(seconds: 3),
          ));
        },
      ),
    ];
    return Scaffold(
      // 任务托盘置顶（方案 §5.2）：折叠 4px 细条不挡内容，5 Tab 常驻可见。
      body: Column(
        children: [
          JobTray(jobs: widget.service.jobs),
          Expanded(child: IndexedStack(index: _index, children: pages)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          // IndexedStack 常驻不重建：每次进入都显式刷新对应页，
          // 让别处（提取 / AI 助手入树 / 回收站恢复 / 后台改动）写入的数据
          // 立刻可见，不需要用户手动刷新。
          switch (i) {
            case 0:
              _notesKey.currentState?.reload();
            case 1:
              _kpKey.currentState?.refresh();
            case 2:
              _agentKey.currentState?.refresh();
            case 3:
              _canvasKey.currentState?.refresh();
          }
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.edit_note_outlined),
            selectedIcon: const Icon(Icons.edit_note),
            label: '笔记',
          ),
          NavigationDestination(
            icon: const Icon(Icons.lightbulb_outline),
            selectedIcon: const Icon(Icons.lightbulb),
            label: '知识点',
          ),
          NavigationDestination(
            icon: _agentDestinationIcon(Icons.assistant_outlined, selected: false),
            selectedIcon: _agentDestinationIcon(Icons.assistant, selected: true),
            label: 'AI 助手',
          ),
          NavigationDestination(
            icon: const Icon(Icons.account_tree_outlined),
            selectedIcon: const Icon(Icons.account_tree),
            label: '知识树',
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }

  /// AI 助手 Tab 的突出标识：渐变底色圆角方块 + 白图标，
  /// 未选中时不透明度略低、选中时不透明，与其它单色图标 Tab 区分开。
  Widget _agentDestinationIcon(IconData icon, {required bool selected}) {
    return Opacity(
      opacity: selected ? 1.0 : 0.85,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF7C4DFF), Color(0xFF448AFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}

/// 笔记列表页（T06 新增）。
class NotesListPage extends StatefulWidget {
  const NotesListPage({
    super.key,
    required this.service,
    required this.db,
    this.onJumpToCanvas,
  });

  final ExtractionService service;
  final AppDatabase db;
  final VoidCallback? onJumpToCanvas;

  @override
  State<NotesListPage> createState() => NotesListPageState();
}

class NotesListPageState extends State<NotesListPage> {
  List<Note> _notes = <Note>[];

  /// P1-2：多选删除模式。
  bool _selectionMode = false;
  Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> reload() => _reload();
  Future<void> _reload() async {
    // 删除是软删除（写 deletedAt），列表必须过滤掉已删除的笔记。
    final rows = await (widget.db.select(widget.db.notes)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    final notes = rows
        .map((r) => Note(
              id: r.id,
              contentMd: r.contentMd,
              title: r.title,
              updatedAt: r.updatedAt,
              deviceId: r.deviceId,
              version: r.version,
            ))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (!mounted) return;
    setState(() => _notes = notes);
  }

  Future<void> _openEditor({String? id}) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => NoteEditorPage(
        service: widget.service,
        db: widget.db,
        noteId: id,
      ),
    ));
    if (!mounted) return;
    await _reload();
    if (changed == true && widget.onJumpToCanvas != null) {
      widget.onJumpToCanvas!();
    }
  }

  Future<void> _onNoteAction(String action, Note n) async {
    switch (action) {
      case 'merge':
        await _mergeIntoTree(n);
        break;
      case 'delete':
        await _deleteNote(n);
        break;
    }
  }

  /// 把这篇笔记的知识点并进一棵用户选择的知识树（可反复并入不同的树）。
  Future<void> _mergeIntoTree(Note n) async {
    final trees = await widget.service.trees.listTrees();
    if (!mounted) return;
    if (trees.isEmpty) {
      _toast('还没有知识树，先去「知识树」页新建一棵');
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('并入哪棵知识树？'),
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
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
    if (picked == null) return;

    final kps = await widget.service.repo.pointsForNote(n.id);
    if (kps.isEmpty) {
      if (!mounted) return;
      _toast('这篇笔记还没有知识点，先去「提取」页跑一次 T1');
      return;
    }
    final res = await widget.service.trees
        .addPoints(picked, kps.map((p) => p.id).toList());
    if (!mounted) return;
    res.fold(
      (added) => _toast(added == 0
          ? '这些知识点已经在这棵树里了'
          : '已并入 $added 个知识点'),
      (e, _) => _toast('并入失败：$e'),
    );
  }

  /// 删除笔记：先弹窗摊开「会影响哪些知识树」，再执行。
  Future<void> _deleteNote(Note n) async {
    final title = n.title.isEmpty ? n.contentMd.split('\n').first : n.title;
    final kpIds = await widget.service.repo.pointIdsOfNote(n.id);
    final impacts = await widget.service.trees.treesContaining(kpIds);
    if (!mounted) return;

    final plan = await showDeleteNoteDialog(
      context: context,
      noteTitle: title.isEmpty ? '(无标题)' : title,
      pointCount: kpIds.length,
      impacts: impacts,
    );
    if (plan == null) return;

    final res = await widget.service.repo.deleteNote(
      noteId: n.id,
      deletePoints: plan.deletePoints,
      removeFromTrees: plan.removeFromTrees,
    );
    if (!mounted) return;
    final summary = res.valueOrNull;
    if (summary == null) {
      res.fold((_) => null, (e, _) => _toast('删除失败：$e'));
      return;
    }
    _toast(
      plan.deletePoints
          ? '已删除笔记，并删除 ${summary.pointsDeleted} 个知识点'
          : summary.treesAffected == 0
              ? '已删除笔记，知识点保留在原知识树中'
              : '已删除笔记，并从 ${summary.treesAffected} 棵知识树中移除知识点',
    );
    await _reload();
  }

  // ============ P1-2：多选删除 ============

  void _enterSelection(String id) => setState(() {
        _selectionMode = true;
        _selected = <String>{id};
      });

  /// AppBar 图标入口：进入多选删除（不预选任何一篇；全部取消勾选时自动退出）。
  ///
  /// 原多选只能长按进入，可发现性差（任务 E：只提入口，删除语义不变）。
  void _enterSelectionMode() => setState(() => _selectionMode = true);

  void _toggle(String id) => setState(() {
        if (_selected.contains(id)) {
          _selected.remove(id);
        } else {
          _selected.add(id);
        }
        if (_selected.isEmpty) _selectionMode = false;
      });

  void _exitSelection() => setState(() {
        _selectionMode = false;
        _selected.clear();
      });

  void _selectAll() =>
      setState(() => _selected = <String>{for (final n in _notes) n.id});

  /// 批量删除：摊开影响面（涉及知识点总数 + 涉及的树），统一应用删除方案。
  Future<void> _deleteSelected() async {
    final notes = _notes.where((n) => _selected.contains(n.id)).toList();
    if (notes.isEmpty) return;

    final allKpIds = <String>{};
    final impactsMap = <String, TreeImpact>{};
    for (final n in notes) {
      final kpIds = await widget.service.repo.pointIdsOfNote(n.id);
      allKpIds.addAll(kpIds);
      final impacts =
          await widget.service.trees.treesContaining(kpIds);
      for (final im in impacts) {
        final cur = impactsMap[im.treeId];
        impactsMap[im.treeId] = cur == null
            ? im
            : TreeImpact(
                treeId: im.treeId,
                treeName: im.treeName,
                pointCount: cur.pointCount + im.pointCount,
              );
      }
    }
    if (!mounted) return;

    final plan = await showDeleteNoteDialog(
      context: context,
      noteTitle: '${notes.length} 篇笔记',
      pointCount: allKpIds.length,
      impacts: impactsMap.values.toList(),
    );
    if (plan == null) return;

    var deletedPoints = 0;
    var maxTreesAffected = 0;
    for (final n in notes) {
      final res = await widget.service.repo.deleteNote(
        noteId: n.id,
        deletePoints: plan.deletePoints,
        removeFromTrees: plan.removeFromTrees,
      );
      if (res is Success<NoteDeleteSummary>) {
        deletedPoints += res.value.pointsDeleted;
        if (res.value.treesAffected > maxTreesAffected) {
          maxTreesAffected = res.value.treesAffected;
        }
      }
    }
    if (!mounted) return;
    final tail = plan.deletePoints
        ? '，并删除 $deletedPoints 个知识点'
        : (maxTreesAffected > 0
            ? '，从 $maxTreesAffected 棵知识树移除知识点'
            : '，知识点保留');
    _toast('已删除 ${notes.length} 篇笔记$tail');
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
    await _reload();
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
    return Scaffold(
      appBar: AppBar(
        title: _selectionMode
            ? Text('已选 ${_selected.length} 篇')
            : const Text('笔记'),
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
            IconButton(
              onPressed: _selected.isEmpty ? null : _deleteSelected,
              icon: const Icon(Icons.delete),
              tooltip: '删除所选',
            ),
          ] else ...[
            // 批量删除入口（任务 E）：多选原本只能长按进入，这里补一个
            // 常驻可见的图标，删除语义与单篇删除均不变。
            IconButton(
              onPressed: _enterSelectionMode,
              icon: const Icon(Icons.checklist),
              tooltip: '批量删除',
            ),
            IconButton(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              tooltip: '新笔记',
            ),
          ],
        ],
      ),
      body: _notes.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('还没有笔记。点 + 创建一条。',
                      style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => _openEditor(),
                    icon: const Icon(Icons.add),
                    label: const Text('新建'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _notes.length,
              itemBuilder: (_, i) {
                final n = _notes[i];
                final preview = n.contentMd.length > 80
                    ? '${n.contentMd.substring(0, 80)}…'
                    : n.contentMd;
                return ListTile(
                  leading: _selectionMode
                      ? Checkbox(
                          value: _selected.contains(n.id),
                          onChanged: (_) => _toggle(n.id),
                        )
                      : const Icon(Icons.description_outlined),
                  title: Text(n.title.isEmpty ? '(无标题)' : n.title),
                  subtitle: Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(n.updatedAt),
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '更多操作',
                        onSelected: (v) => _onNoteAction(v, n),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'merge',
                            child: Text('把知识点并入知识树'),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(
                              '删除笔记',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  onTap: _selectionMode
                      ? () => _toggle(n.id)
                      : () => _openEditor(id: n.id),
                  onLongPress: _selectionMode ? null : () => _enterSelection(n.id),
                );
              },
            ),
    );
  }

  static String _formatTime(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, "0")}-${l.day.toString().padLeft(2, "0")} '
        '${l.hour.toString().padLeft(2, "0")}:${l.minute.toString().padLeft(2, "0")}';
  }
}
