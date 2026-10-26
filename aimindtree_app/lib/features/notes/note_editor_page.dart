/// 笔记编辑器页面（T06 业务流）。
///
/// 标题 + **所见即所得**正文（T4 接线后已删除「左编辑 / 右预览」双框：
/// 正文区就是渲染结果，点哪块哪块就地变成输入框，格式化只能走工具栏），底部：
/// - 保存到 Drift；
/// - **提取知识点 (T1)** —— 一键跑通 T1 流水线（先选模式：仅知识点 /
///   仅要点重点 / 两者都要；走 prompt variant，不是新任务码）；
/// - **划词提取 (T15)** —— 选中一段正文 → 直接生成知识点，归属本笔记；
/// - **插入图片**（T05）：选本地图片 → 附件库（base64 唯一权威存储）
///   → 正文插入图片块 → 随笔记一起同步。
///
/// **数据面不变**：`content_md` 永远是 Markdown 纯文本（同步 / AI / 画布都读它），
/// 页面只是把这份 Markdown 交给 [NoteEditorController] 双向映射成块模型。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../ai/extraction_service.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/models/note_asset.dart';
import '../../data/repositories/ai_session_repository.dart';
import '../../features/teacher/teacher_page.dart';
import 'block_model.dart';
import 'image_source.dart';
import 'markdown_actions.dart';
import 'markdown_toolbar.dart';
import 'note_editor_body.dart';
import 'note_editor_controller.dart';

/// 划词提取的选中文字上限：超过就截断（提示词与上下文都按「一段」设计）。
const int kSelectionMaxLength = 2000;

/// T1 提示词变体（提取模式）→ 人话，用于状态栏回执。
String _variantLabel(String variant) => switch (variant) {
      '' => 'T1（仅知识点）',
      'keypoints' => 'T1.keypoints（仅要点重点）',
      'both' => 'T1.both（知识点+要点）',
      _ => 'T1（$variant）',
    };

class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({
    super.key,
    required this.service,
    required this.db,
    this.noteId,
  });

  final ExtractionService service;
  final AppDatabase db;

  /// null = 新建；非空 = 编辑已有。
  final String? noteId;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  final _titleCtrl = TextEditingController();

  /// 正文状态机（T3）：文档 / 焦点 / 选区 / 序列化缓存都在它手里。
  /// 页面**不再持有** `TextEditingController` / `FocusNode`（一次只有一个活动行，
  /// 每个行的控制器由控制器注册并统一 dispose）。
  late final NoteEditorController _controller;

  bool _busy = false;
  bool _dirty = false;
  String _status = '';
  Note? _note;

  /// 本笔记提取出的知识点（P1-5：笔记详情展示并可跳转）。
  List<KnowledgePoint> _kps = <KnowledgePoint>[];

  /// 目录 / 大纲：点击「目录」时即时从正文抽取，供右侧抽屉展示。
  List<MarkdownHeading> _tocHeadings = const <MarkdownHeading>[];

  /// Scaffold 句柄：用于打开右侧「目录」抽屉（endDrawer）。
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 上一次正文 / 标题内容：用于区分「改了文字」与「仅移动光标」，
  /// 避免纯选区变化（点击目录跳转、点进输入框）误标「●未保存」。
  String _lastTitle = '';
  String _lastBody = '';

  @override
  void initState() {
    super.initState();
    _controller = NoteEditorController(resolveAsset: _resolveAssetBytes);
    _controller.addListener(_onBodyChanged);
    _titleCtrl.addListener(() {
      if (_titleCtrl.text != _lastTitle) {
        _lastTitle = _titleCtrl.text;
        setState(() => _dirty = true);
      }
    });
    if (widget.noteId != null) _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onBodyChanged);
    _controller.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  /// 正文变更监听：**只有序列化结果真的变了**才置脏。
  ///
  /// 与旧 `_bodyCtrl` 监听同款语义（设计 §7.2）：进出编辑态、移动光标、
  /// 点目录跳转都只改 `active`，不改 [NoteEditorController.markdown] → 不置脏。
  void _onBodyChanged() {
    final md = _controller.markdown;
    if (md == _lastBody) return;
    _lastBody = md;
    if (!mounted) return;
    setState(() => _dirty = true);
  }

  Future<void> _load() async {
    final row = await (widget.db.select(widget.db.notes)
          ..where((t) => t.id.equals(widget.noteId!))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return;
    // 顺序不能反：**先**同步「上次内容」再喂控制器，否则监听器会误标「●未保存」。
    _lastTitle = row.title;
    _lastBody = row.contentMd;
    _titleCtrl.text = row.title;
    _controller.setMarkdown(row.contentMd);
    if (!mounted) return;
    setState(() {
      _note = Note(
        id: row.id,
        contentMd: row.contentMd,
        title: row.title,
        updatedAt: row.updatedAt,
        deviceId: row.deviceId,
        version: row.version,
      );
      _dirty = false;
    });
    await _reloadKps();
  }

  /// P1-5：回读本笔记提取的知识点。
  Future<void> _reloadKps() async {
    if (_note == null) return;
    final kps = await widget.service.repo.pointsForNote(_note!.id);
    if (!mounted) return;
    setState(() => _kps = kps);
  }

  /// P1-5：跳转到知识点详情 / 老师模式页。
  Future<void> _openKp(KnowledgePoint kp) async {
    await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => TeacherPage(
        kp: kp,
        sessions: AiSessionRepository(widget.db,
            deviceId: widget.service.repo.deviceId),
        ai: widget.service.ai,
        repo: widget.service.repo,
        jobs: widget.service.jobs,
      ),
    ));
  }

  /// 笔记内嵌图片 `aimindtree-asset://<assetId>` 的字节解析器。
  ///
  /// 走 [NoteAssetRepository.resolveBytes]（LRU → 库 → base64 解码 →
  /// 回填缓存）；附件不存在（同步未到 / 已删）返回 null，渲染层降级成
  /// 「图片未同步」占位块，保证任何时候整篇笔记都能渲染出来。
  Future<Uint8List?> _resolveAssetBytes(String assetId) =>
      widget.service.assets.resolveBytes(assetId);

  /// 插入图片（T05 全链路）：
  /// 1. 系统选图（取消 = 静默返回，失败 = 状态栏报错）；
  /// 2. 新笔记先落盘一次拿 noteId（附件必须归属已存在的笔记，
  ///    避免「附件行比笔记行先入同步批次」的乱序）；
  /// 3. 附件入库（sha1 同笔记去重 / 2MB 上限，失败状态栏报错）；
  /// 4. 正文光标处插入 `![name](aimindtree-asset://<id>)`；
  /// 5. 立即再保存一次——引用随笔记一起落库，不留孤儿附件。
  ///
  /// [_busy] 在选图前就置起：系统对话框开着的时候不让重复点按钮
  /// （会叠两个对话框），也不让保存 / 提取插队。
  Future<void> _insertImage() async {
    if (_busy) return;
    setState(() => _busy = true);
    final PickedImage? picked;
    try {
      picked = await pickImage();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '选图失败：$e';
        });
      }
      return;
    }
    if (picked == null || !mounted) {
      // 用户取消：静默恢复，不打扰。
      if (mounted) setState(() => _busy = false);
      return;
    }
    try {
      setState(() => _status = '插入图片…');
      // 2) 新笔记还没有 id：先按当前内容保存一次。
      var noteId = _note?.id;
      if (noteId == null) {
        final id = await _save();
        if (id.isEmpty || !mounted) return;
        noteId = id;
      }
      // 3) 附件入库（去重 / 上限都在仓储层）。
      final res = await widget.service.assets.putAsset(
        noteId: noteId,
        bytes: picked.bytes,
        name: picked.name,
        mime: picked.mime,
      );
      if (!mounted) return;
      if (res is Failure<String>) {
        setState(() => _status = '图片入库失败：${res.message}');
        return;
      }
      final assetId = (res as Success<String>).value;
      // 4) 在活动块之后插入图片块（控制器负责序列化 `![alt](aimindtree-asset://id)`）。
      _controller.insertImageBlock(assetId, alt: picked.name);
      // 5) 立即保存：引用落库 + reconcile 顺带清理（理论无孤儿）。
      //    保存成功/失败的状态由 _save() 自己写，这里不覆盖。
      await _save();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 当前正文选区对应的文字。
  ///
  /// 改造后选区活在「活动行」里（跨块选区 v1 不支持），读法整体交给
  /// [NoteEditorController.selectionText]；无活动行 → 空串 → 走原有的
  /// 「请先在正文中选中要提取的文字」提示。
  String _selectionText() => _controller.selectionText();

  /// 划词提取（T15）：把正文里选中的一段文字直接变成一个知识点。
  ///
  /// 流程：读选区 → 空/过长校验 → 新笔记先落盘拿 id → 调
  /// [ExtractionService.extractFromSelection] → 刷新知识点区。
  /// **不清空选区**：提取完用户还能看到自己选的是哪一段。
  Future<void> _onExtractFromSelection() async {
    if (_busy) return;
    final rawSelection = _selectionText().trim();
    if (rawSelection.isEmpty) {
      _snack('请先在正文中选中要提取的文字');
      return;
    }
    var selection = rawSelection;
    if (selection.length > kSelectionMaxLength) {
      selection = selection.substring(0, kSelectionMaxLength);
      _snack('选中文字过长，已截取前 $kSelectionMaxLength 字');
    }

    // 新笔记还没有 id：先保存一次（知识点必须归属已存在的笔记）。
    if (_note == null) {
      final id = await _save();
      if (id.isEmpty || !mounted) {
        // 保存失败：_save() 已把原因写进状态栏；这里必须把 _busy 还回去，
        // 否则 AppBar 三个按钮会永久禁用（与 _onExtract 同款口径）。
        if (mounted) setState(() => _busy = false);
        return;
      }
    }

    setState(() {
      _busy = true;
      _status = '划词提取…';
    });
    final res = await widget.service.extractFromSelection(
      note: _note!,
      selection: selection,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    switch (res) {
      case Success(value: final kp):
        _status = '已提取：${kp.name}';
        _snack('已提取：${kp.name}');
        await _reloadKps();
      case Failure():
        _status = '❌ 划词提取失败：${res.message}';
        _snack(res.message);
    }
  }

  /// AppBar 溢出菜单「复制全文」：把整篇 Markdown 放进剪贴板。
  ///
  /// v1 不支持跨块选区（设计 §5.5），所以给跨块搬运留这一条出口。
  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _controller.markdown));
    _snack('已复制全文（Markdown 原文）');
  }

  /// 底部提示条（划词提取的结果 / 失败原因）。
  void _snack(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  /// 提取模式选择（D）：仅知识点 / 仅要点重点 / 两者都要。
  /// 返回 null = 用户取消（不提取）。
  ///
  /// 返回值是**提示词变体**（T1 的 variant，走 body 穿透），不是新任务码：
  /// - `''` = 仅提取知识点（默认，不传 variant，服务端走 `t1_extract.md`）；
  /// - `'keypoints'` = 仅提取要点重点（`t1_extract__keypoints.md`）；
  /// - `'both'` = 两者都要（`t1_extract__both.md`）。
  ///
  /// 用 [RadioGroup] 统一托管选中态：`RadioListTile` 的 `groupValue` /
  /// `onChanged` 在新版 Flutter 已弃用（RadioGroup 祖先接管），单点会刷
  /// deprecated INFO，所以这里走新 API。
  Future<String?> _pickExtractVariant() async {
    var picked = ''; // 默认「仅知识点」
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext inner, void Function(void Function()) setSheet) {
          return AlertDialog(
            title: const Text('选择提取模式'),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            content: RadioGroup<String>(
              groupValue: picked,
              onChanged: (String? v) => setSheet(() => picked = v ?? ''),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const <Widget>[
                  RadioListTile<String>(
                    value: '',
                    title: Text('仅知识点'),
                    subtitle: Text('从笔记里提炼知识点（默认）'),
                  ),
                  RadioListTile<String>(
                    value: 'keypoints',
                    title: Text('仅要点重点'),
                    subtitle: Text('只要要点重点，不生成知识点'),
                  ),
                  RadioListTile<String>(
                    value: 'both',
                    title: Text('知识点 + 要点'),
                    subtitle: Text('两者都要，一次生成'),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(picked),
                child: const Text('开始提取'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<String> _save() async {
    final id = _note?.id;
    // 正文取控制器的序列化缓存（未编辑的块走原文直通 → L1 字节相等）。
    final content = _controller.markdown;
    final title = _titleCtrl.text.trim().isEmpty
        ? content.split('\n').first
        : _titleCtrl.text.trim();
    final note = (id == null)
        ? Note(
            contentMd: content,
            title: title,
            // 同步设备号：必须与仓库内其它写入路径同源（每台设备唯一），
            // 否则本机上传的行会被 pull 的自回声过滤误判为「本机自己上传的」。
            deviceId: widget.service.repo.deviceId,
          )
        : _note!.copyWith(
            title: title,
            contentMd: content,
          );
    final res = await widget.service.repo.saveNote(note);
    if (res is Success<Note>) {
      setState(() {
        _note = res.value;
        _dirty = false;
        _status = '已保存';
      });
      // 孤儿附件清理（T05）：正文引用是图片归属的唯一权威来源——
      // 用户删掉某行 `![...](aimindtree-asset://id)` 后，对应附件在本次
      // 保存时物理回收（删除意图经 hardDeleteNoteAssets 告诉同步对端）。
      // 只在这里做：画布「补前置」等其它保存路径不编排图片引用，
      // 误跑 reconcile 会把别人笔记里的插图删掉。
      await widget.service.assets.reconcileForNote(
        res.value.id,
        extractAssetIds(content),
      );
      return res.value.id;
    }
    setState(() => _status = '保存失败：${(res as Failure<Note>).message}');
    return '';
  }

  Future<void> _onSave() async {
    setState(() {
      _busy = true;
      _status = '保存中…';
    });
    await _save();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _onExtract() async {
    // D：先选模式（仅知识点 / 仅要点重点 / 两者都要），取消则不提取。
    final variant = await _pickExtractVariant();
    if (variant == null || !mounted) return;

    setState(() {
      _busy = true;
      _status = '保存并提取…';
    });
    final id = await _save();
    if (id.isEmpty) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    setState(() => _status = '调用 $_variantLabel(variant)…');
    // 传当前笔记（_save 成功后 _note 已是最新保存态）：知识点归属本笔记，
    // 不再空降一篇新笔记（2026-10-24 用户实测 bug：旧笔记不显示提取结果）。
    // variant 走 body 穿透：URL 仍是 /v1/task/T1，服务端按 (T1, variant)
    // 选提示词变体。
    final res = await widget.service.extract(
      _controller.markdown,
      existingNote: _note,
      variant: variant,
    );
    if (!mounted) return;
    switch (res) {
      case Success(value: final v):
      setState(() {
      _status =
          '✅ 已入库 ${v.savedCount} 条，幻觉剔除 ${v.rejectedCount} 条';
      _busy = false;
    });
    await _reloadKps();
      case Failure():
        setState(() {
          _status = '❌ 提取失败：${res.message}';
          _busy = false;
        });
    }
  }

  /// P1-5：本笔记提取的知识点区（正文下方），逐条可点进详情 / 老师模式。
  ///
  /// 用 [ExpansionTile] 包成**可折叠**区域（用户要求「下面提取知识点的展示
  /// 应该是可供隐藏的」）：默认展开，点标题栏的箭头即可收起 / 再展开。
  /// 折叠态下只保留标题行（含数量），不占用正文下方的纵向空间。
  Widget _buildKpSection() {
    if (_note == null) return const SizedBox.shrink();
    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      backgroundColor: Colors.grey.shade50,
      collapsedBackgroundColor: Colors.grey.shade50,
      title: Text(
        '本笔记提取的知识点（${_kps.length}）',
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      children: [
        if (_kps.isEmpty)
          const Text(
            '还没有知识点，点右上角「提取知识点」试试。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final kp in _kps)
                ActionChip(
                  label: Text(
                    kp.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  avatar: const Icon(Icons.lightbulb_outline, size: 16),
                  onPressed: () => _openKp(kp),
                ),
            ],
          ),
      ],
    );
  }

  /// 打开「目录 / 大纲」抽屉：先按当前正文即时抽取标题，再拉开右侧抽屉。
  ///
  /// `extractHeadings` 继续复用（`markdown_actions.dart` 不删，它的单测仍是回归网）。
  void _openToc() {
    setState(() => _tocHeadings = extractHeadings(_controller.markdown));
    _scaffoldKey.currentState?.openEndDrawer();
  }

  /// 目录项点击：把光标定位到对应的标题块（标题行首），便于就地编辑。
  ///
  /// 抽屉仍用 [MarkdownHeading]（字符偏移那套），但跳转改成「按文本 + 级别
  /// 找到对应的 [HeadingBlock]」→ 直接 `focusBlock`，不再拿字符偏移去猜。
  void _jumpToHeading(MarkdownHeading h) {
    final ref = _refForHeading(h);
    if (ref == null) return;
    _controller.focusBlock(ref);
  }

  /// 目录项 → 块引用：优先「级别 + 文本」全等，退一步只按文本匹配。
  BlockRef? _refForHeading(MarkdownHeading h) {
    BlockRef? byTextOnly;
    for (final block in _controller.doc.blocks) {
      if (block is! HeadingBlock) continue;
      final ref = BlockRef(block.id);
      if (_controller.textOf(ref) != h.title) continue;
      if (block.level == h.level) return ref;
      byTextOnly ??= ref;
    }
    return byTextOnly;
  }

  /// 目录 / 大纲抽屉：按标题级别缩进展示，点击跳转。
  Widget _buildTocDrawer() {
    final headings = _tocHeadings;
    return Drawer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DrawerHeader(
            margin: EdgeInsets.zero,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Text('目录 / 大纲',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
          Expanded(
            child: headings.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '正文暂无标题。\n用「# 一级 / ## 二级 / ### 三级 …」标记即可生成目录。',
                        style: TextStyle(color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: headings.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final h = headings[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.only(
                          left: 16.0 * (h.level - 1) + 16,
                          right: 16,
                        ),
                        leading: Text('H${h.level}',
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12)),
                        title: Text(h.title),
                        onTap: () {
                          Navigator.of(ctx).pop(); // 先关抽屉再跳，避免遮挡
                          _jumpToHeading(h);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      endDrawer: _buildTocDrawer(),
      appBar: AppBar(
        title: Text(_note == null ? '新笔记' : (_note!.title.isEmpty ? '无标题' : _note!.title)),
        actions: [
          IconButton(
            onPressed: _openToc,
            icon: const Icon(Icons.list_alt),
            tooltip: '目录 / 大纲',
          ),
          IconButton(
            onPressed: _busy ? null : _onSave,
            icon: const Icon(Icons.save),
            tooltip: '保存',
          ),
          IconButton(
            onPressed: _busy ? null : _onExtract,
            icon: const Icon(Icons.auto_awesome),
            tooltip: '提取知识点 (T1)',
          ),
          IconButton(
            onPressed: _busy ? null : _onExtractFromSelection,
            icon: const Icon(Icons.auto_fix_high),
            tooltip: '划词提取',
          ),
          // 跨块搬运的唯一出口（v1 不支持跨块选区，设计 §5.5 第 4 条）。
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (String value) {
              if (value == 'copy') _copyAll();
            },
            itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'copy', child: Text('复制全文')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: '标题（可留空，自动取首行）',
                isDense: true,
              ),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const Divider(height: 1),
          MarkdownToolbar(
            controller: _controller,
            onInsertImage: _insertImage,
          ),
          // 正文主体 = 所见即所得（不再有「左源码 / 右预览」双框）。
          // NoteEditorBody 内部已监听控制器（AnimatedBuilder），页面不必再套一层。
          Expanded(
            child: NoteEditorBody(
              key: const ValueKey<String>('note-body'),
              controller: _controller,
            ),
          ),
          _buildKpSection(),
          if (_status.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.indigo.shade50,
              child: Row(
                children: [
                  Expanded(child: Text(_status, style: const TextStyle(fontSize: 12))),
                  if (_dirty)
                    const Text('●未保存',
                        style: TextStyle(fontSize: 12, color: Colors.orange)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
