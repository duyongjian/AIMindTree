import 'package:flutter/material.dart';

import 'ai/ai_task_router.dart';
import 'ai/extraction_service.dart';
import 'core/result.dart';
import 'core/secret_store.dart';
import 'data/db/drift_database.dart';
import 'data/models/knowledge_point.dart';
import 'data/repositories/ai_session_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/sync/sync_context.dart';
import 'features/agent/agent_page.dart';
import 'features/canvas/canvas_page.dart';
import 'features/notes/delete_note_dialog.dart';
import 'features/notes/note_editor_page.dart';
import 'features/teacher/teacher_page.dart';
import 'features/settings/settings_page.dart';
import 'ui/extract_screen.dart';

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

  @override
  void initState() {
    super.initState();
  }

  Future<void> _openTeacher(KnowledgePoint kp) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TeacherPage(
        kp: kp,
        sessions: _sessions,
        ai: widget.service.ai,
        repo: widget.service.repo,
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
          setState(() => _index = 2);
          _canvasKey.currentState?.refresh();
        },
      ),
      ExtractScreen(service: widget.service),
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
            content: Text('Provider 设置已保存，重启 App 后生效。'),
            duration: Duration(seconds: 3),
          ));
        },
      ),
      AgentPage(service: widget.service, db: widget.db),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          // 知识树 Tab：页面被 IndexedStack 常驻，不会重建，必须显式刷新
          // 才能看到「提取」页刚写入的知识点。
          if (i == 2) _canvasKey.currentState?.refresh();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.edit_note_outlined),
            selectedIcon: Icon(Icons.edit_note),
            label: '笔记',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: '提取',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_tree_outlined),
            selectedIcon: Icon(Icons.account_tree),
            label: '知识树',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
          NavigationDestination(
            icon: Icon(Icons.assistant_outlined),
            selectedIcon: Icon(Icons.assistant),
            label: 'AI 助手',
          ),
        ],
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
        title: const Text('笔记'),
        actions: [
          IconButton(
            onPressed: () => _openEditor(),
            icon: const Icon(Icons.add),
            tooltip: '新笔记',
          ),
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
                  leading: const Icon(Icons.description_outlined),
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
                  onTap: () => _openEditor(id: n.id),
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
