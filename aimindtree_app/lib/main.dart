import 'package:flutter/material.dart';

import 'ai/ai_task_router.dart';
import 'ai/extraction_service.dart';
import 'core/result.dart';
import 'core/secret_store.dart';
import 'data/db/drift_database.dart';
import 'data/models/knowledge_point.dart';
import 'data/models/knowledge_tree.dart';
import 'data/models/notebook.dart';
import 'data/repositories/ai_session_repository.dart';
import 'data/repositories/knowledge_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/sync/http_proxy.dart';
import 'data/sync/sync_context.dart';
import 'features/agent/agent_page.dart';
import 'features/canvas/canvas_page.dart';
import 'features/knowledge/kp_dedup.dart';
import 'features/knowledge/knowledge_manage_page.dart';
import 'features/notes/delete_note_dialog.dart';
import 'features/notes/note_editor_page.dart';
import 'features/notes/note_recycle_bin_page.dart';
import 'features/teacher/teacher_page.dart';
import 'features/settings/settings_page.dart';
import 'features/settings/tree_behavior_settings.dart';
import 'ui/job_tray.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先探测系统代理（环境变量 / Windows 注册表 / 常见本地端口），
  // 让后续同步请求能走代理（Dart HttpClient 默认不读系统代理）。
  await initSystemProxy();
  final (service, db, router, settings, sync) =
      await ExtractionService.bootstrap();
  // 载入知识树行为偏好（查重 / 连线开关），内存态随后即准确，供各判定点同步读。
  await TreeBehaviorSettings.instance.load();
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
        // 全局导航键：后台任务（如 T14 知识点查重完成）没有页面上下文时，
        // 靠它弹对话窗（见 features/knowledge/kp_dedup.dart）。
        navigatorKey: kGlobalNavigatorKey,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        // ★任务托盘提到 Navigator **之上**：托盘原本挂在 AppShell 的 body 里，
        //   任何 push 出来的页面（老师模式 / 布置作业 / 作业历史 / 回收站）都会
        //   整屏盖住它 —— 用户因此「看不见正在跑 / 排队中的 AI 任务」。
        //   现在它是一层常驻顶栏：无任务时高度 0 完全不占位，有任务时把所有页面
        //   一起下推（不遮挡任何内容，也不吃点击）。
        //   装配细节见 JobTrayHost：Overlay 必须是这里的**根**（吃窗口的有限
        //   约束）；塞进 Column 会因无穷高约束直接抛
        //   「Overlay was given infinite constraints and cannot be sized by a
        //   suitable child」，首帧布局中断后连带刷屏
        //   「debugFrameWasSentToEngine is not true」。
        builder: (context, child) => Directionality(
          textDirection: TextDirection.ltr,
          child: JobTrayHost(
            jobs: service.jobs,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
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
  late final AiSessionRepository _sessions =
      AiSessionRepository(widget.db, deviceId: widget.service.repo.deviceId);
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
      // 任务托盘已上移到 MaterialApp.builder（见 AIMindTreeApp.build）：
      // 挂在壳的 body 里会被 push 出来的页面整屏盖住。
      body: IndexedStack(index: _index, children: pages),
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
/// 文件夹树节点（由扁平列表按 parentId 组装，供抽屉递归渲染）。
class _FolderNode {
  _FolderNode({required this.folder, required this.children});
  final Notebook folder;
  final List<_FolderNode> children;
}

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

  /// 搜索关键词（标题 + 正文，不区分大小写）。
  String _query = '';

  /// 是否处于搜索框展开态（AppBar 标题换成搜索输入框）。
  bool _searching = false;

  /// P1-2：多选删除模式。
  bool _selectionMode = false;
  Set<String> _selected = <String>{};

  /// 文件夹树（仓库层已按置顶 / 排序排好），用于抽屉渲染与层级组装。
  List<Notebook> _folders = <Notebook>[];

  /// 当前选中的文件夹：null=全部笔记，''=未分类，其余为 folderId。
  String? _selectedFolderId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> reload() => _reload();
  Future<void> _reload() async {
    // 1) 加载文件夹树（置顶 / 排序已在仓库层完成）。
    final folderRes = await widget.service.notebooks.listFolders();
    if (!mounted) return;
    final folders =
        folderRes is Success<List<Notebook>> ? folderRes.value : <Notebook>[];

    // 2) 按当前选中的文件夹（全部 / 未分类 / 具体文件夹）加载笔记；
    //    置顶优先、软删过滤、搜索内存过滤已在仓库层 + 下方完成。
    final notes =
        await widget.service.repo.listNotes(folderId: _selectedFolderId);
    // 内存过滤（搜索）：不新增 SQL，过滤逻辑只在本页。
    List<Note> result = notes;
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      result = notes.where((n) =>
        n.title.toLowerCase().contains(q) ||
        n.contentMd.toLowerCase().contains(q)).toList();
    }
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _notes = result;
    });
  }

  /// 切换选中的文件夹：null=全部，''=未分类，folderId=具体文件夹。
  Future<void> _selectFolder(String? id) async {
    setState(() => _selectedFolderId = id);
    await _reload();
  }

  Future<void> _openEditor({String? id}) async {
    // 在「某个具体文件夹」下点 + 新建时，把该文件夹作为预选归属下传编辑器。
    final initialFolder = (_selectedFolderId != null && _selectedFolderId!.isNotEmpty)
        ? _selectedFolderId
        : null;
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => NoteEditorPage(
        service: widget.service,
        db: widget.db,
        noteId: id,
        notebookId: initialFolder,
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
      case 'pin':
        await _pinNote(n);
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

  // ============ 笔记文件夹（置顶 + 增删改查） ============

  /// 文件夹导航抽屉：全部 / 未分类 + 层级文件夹树。
  /// 文件夹行的「⋯」操作菜单（新建子文件夹 / 重命名 / 置顶 / 删除）。
  Widget _folderMoreMenu(Notebook f, BuildContext popCtx, VoidCallback onChange) =>
      PopupMenuButton<String>(
        tooltip: '文件夹操作',
        onSelected: (v) async {
          switch (v) {
            case 'add':
              await _createFolder(parentId: f.id);
            case 'rename':
              await _renameFolder(f);
            case 'pin':
              await _pinFolder(f);
            case 'delete':
              await _deleteFolder(f);
          }
          onChange();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'add', child: Text('新建子文件夹')),
          PopupMenuItem(value: 'rename', child: Text('重命名')),
          PopupMenuItem(value: 'pin', child: Text('置顶 / 取消置顶')),
          PopupMenuItem(
            value: 'delete',
            child: Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      );

  /// 右上角文件夹选择弹层：支持按名称搜索，选中即切换笔记列表过滤。
  /// 保留原有的树形层级、置顶标记与增删改查入口。
  Future<void> _openFolderPicker() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        var query = '';
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final q = query.trim().toLowerCase();
            final List<Widget> folderWidgets;
            if (q.isEmpty) {
              final tree = _buildFolderTree(_folders);
              folderWidgets = [
                for (final node in tree)
                  _folderNode(node, 0,
                      popCtx: ctx, onChange: () => setLocal(() {}))
              ];
            } else {
              final matches = _folders
                  .where((f) => f.name.toLowerCase().contains(q))
                  .toList();
              folderWidgets = [
                for (final f in matches)
                  _folderTile(
                    label: f.name.isEmpty ? '(未命名文件夹)' : f.name,
                    pinned: f.pinned,
                    selected: _selectedFolderId == f.id,
                    trailing: _folderMoreMenu(f, ctx, () => setLocal(() {})),
                    onTap: () {
                      Navigator.pop(ctx);
                      _selectFolder(f.id);
                    },
                  ),
                if (matches.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('没有匹配的文件夹',
                        style: TextStyle(color: Colors.grey)),
                  ),
              ];
            }
            final pickerHeight = MediaQuery.of(ctx).size.height * 0.7;
            return Align(
              alignment: Alignment.topRight,
              child: Material(
                type: MaterialType.card,
                elevation: 8,
                borderRadius: BorderRadius.circular(12),
                color: Theme.of(ctx).colorScheme.surface,
                child: SizedBox(
                  width: 340,
                  height: pickerHeight,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text('笔记文件夹',
                                  style: TextStyle(
                                      fontSize: 16, fontWeight: FontWeight.bold)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: '关闭',
                              onPressed: () => Navigator.pop(ctx),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        child: TextField(
                          autofocus: true,
                          decoration: const InputDecoration(
                            hintText: '搜索文件夹',
                            prefixIcon: Icon(Icons.search, size: 20),
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) => setLocal(() => query = v),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          children: [
                            _folderTile(
                              label: '全部笔记',
                              selected: _selectedFolderId == null,
                              onTap: () {
                                Navigator.pop(ctx);
                                _selectFolder(null);
                              },
                            ),
                            _folderTile(
                              label: '未分类',
                              selected: _selectedFolderId == '',
                              onTap: () {
                                Navigator.pop(ctx);
                                _selectFolder('');
                              },
                            ),
                            const Divider(),
                            ...folderWidgets,
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.create_new_folder_outlined),
                        title: const Text('新建文件夹'),
                        onTap: () async {
                          await _createFolder();
                          setLocal(() {});
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 递归渲染文件夹节点（按层级缩进），每个节点带操作菜单。
  /// [popCtx] 用于关闭文件夹选择弹层；[onChange] 在增删改后置顶后刷新弹层。
  Widget _folderNode(_FolderNode node, int depth,
      {required BuildContext popCtx, required VoidCallback onChange}) {
    final f = node.folder;
    return Column(
      children: [
        _folderTile(
          label: f.name.isEmpty ? '(未命名文件夹)' : f.name,
          indent: 16.0 * depth,
          selected: _selectedFolderId == f.id,
          pinned: f.pinned,
          trailing: _folderMoreMenu(f, popCtx, onChange),
          onTap: () {
            Navigator.pop(popCtx);
            _selectFolder(f.id);
          },
        ),
        for (final child in node.children)
          _folderNode(child, depth + 1, popCtx: popCtx, onChange: onChange),
      ],
    );
  }

  Widget _folderTile({
    required String label,
    required bool selected,
    bool pinned = false,
    double indent = 0,
    Widget? trailing,
    required VoidCallback onTap,
  }) =>
      ListTile(
        dense: true,
        selected: selected,
        contentPadding: EdgeInsets.only(left: indent + 16, right: 8),
        leading: pinned
            ? const Icon(Icons.push_pin, size: 16)
            : const Icon(Icons.folder_outlined, size: 20),
        title: Text(label),
        trailing: trailing,
        onTap: onTap,
      );

  /// 由扁平列表按 parentId 组装成树（父不存在 / 已删视为根级）。
  List<_FolderNode> _buildFolderTree(List<Notebook> folders) {
    final childrenOf = <String?, List<Notebook>>{};
    for (final f in folders) {
      (childrenOf[f.parentId] ??= <Notebook>[]).add(f);
    }
    List<_FolderNode> buildLevel(String? pid) =>
        [for (final f in childrenOf[pid] ?? <Notebook>[]) _FolderNode(folder: f, children: buildLevel(f.id))];
    return buildLevel(null);
  }

  /// 新建文件夹（[parentId] 非空即成为子文件夹）。
  Future<void> _createFolder({String? parentId}) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(parentId == null
            ? '新建文件夹'
            : '在「${_folderName(parentId)}」下新建子文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '文件夹名称'),
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final res =
        await widget.service.notebooks.createFolder(name: name, parentId: parentId);
    if (!mounted) return;
    res.fold(
      (_) {
        _toast('已创建文件夹「$name」');
        _reload();
      },
      (e, _) => _toast('创建文件夹失败：$e'),
    );
  }

  String _folderName(String id) {
    final f = _folders.where((x) => x.id == id).firstOrNull;
    return f?.name ?? '(未知)';
  }

  Future<void> _renameFolder(Notebook f) async {
    final ctrl = TextEditingController(text: f.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '文件夹名称'),
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final res = await widget.service.notebooks.renameFolder(f.id, name);
    if (!mounted) return;
    res.fold(
      (_) {
        _toast('已重命名为「$name」');
        _reload();
      },
      (e, _) => _toast('重命名失败：$e'),
    );
  }

  Future<void> _pinFolder(Notebook f) async {
    final res = await widget.service.notebooks.pinFolder(f.id, !f.pinned);
    if (!mounted) return;
    res.fold(
      (_) => _reload(),
      (e, _) => _toast('置顶操作失败：$e'),
    );
  }

  Future<void> _deleteFolder(Notebook f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件夹？'),
        content: const Text('文件夹将被删除，其下笔记退回「未分类」。\n（子文件夹会被移到根级。）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await widget.service.notebooks.deleteFolder(f.id);
    if (!mounted) return;
    res.fold(
      (_) {
        if (_selectedFolderId == f.id) _selectedFolderId = null;
        _toast('已删除文件夹');
        _reload();
      },
      (e, _) => _toast('删除文件夹失败：$e'),
    );
  }

  /// 置顶 / 取消置顶一篇笔记。
  Future<void> _pinNote(Note n) async {
    final res = await widget.service.repo.pinNote(n.id, !n.pinned);
    if (!mounted) return;
    res.fold(
      (_) => _reload(),
      (e, _) => _toast('置顶笔记失败：$e'),
    );
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
            : _searching
                ? TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '搜索标题或正文',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: (v) {
                      setState(() => _query = v);
                      _reload();
                    },
                  )
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
            // 文件夹导航：右上角弹层，支持搜索与切换。
            IconButton(
              onPressed: _openFolderPicker,
              icon: const Icon(Icons.folder_outlined),
              tooltip: '文件夹（搜索 / 切换）',
            ),
            // 搜索：展开搜索框时显示「关闭」，否则显示「搜索」入口。
            if (_searching)
              IconButton(
                onPressed: () {
                  setState(() {
                    _searching = false;
                    _query = '';
                  });
                  _reload();
                },
                icon: const Icon(Icons.close),
                tooltip: '退出搜索',
              )
            else
              IconButton(
                onPressed: () => setState(() => _searching = true),
                icon: const Icon(Icons.search),
                tooltip: '搜索',
              ),
            // 回收站：进入笔记回收站（恢复 / 彻底删除软删的笔记）。
            IconButton(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => NoteRecycleBinPage(repo: widget.service.repo),
                ));
                await _reload();
              },
              icon: const Icon(Icons.delete_outline),
              tooltip: '回收站',
            ),
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
                      : (n.pinned
                          ? const Icon(Icons.push_pin, color: Colors.amber)
                          : const Icon(Icons.description_outlined)),
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
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'pin',
                            child: Text(n.pinned ? '取消置顶' : '置顶笔记'),
                          ),
                          const PopupMenuItem(
                            value: 'merge',
                            child: Text('把知识点并入知识树'),
                          ),
                          const PopupMenuItem(
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
