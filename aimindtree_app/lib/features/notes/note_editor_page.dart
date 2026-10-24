/// 笔记编辑器页面（T06 业务流）。
///
/// 标题 + Markdown 正文（分屏：左编辑 / 右预览），底部：
/// - 保存到 Drift；
/// - **提取知识点 (T1)** —— 一键跑通 T1 流水线（先选模式：仅知识点 /
///   仅要点重点 / 两者都要；走 prompt variant，不是新任务码）；
/// - **划词提取 (T15)** —— 选中一段正文 → 直接生成知识点，归属本笔记；
/// - **插入图片**（T05）：选本地图片 → 附件库（base64 唯一权威存储）
///   → 正文插入 `aimindtree-asset://<id>` 引用 → 随笔记一起同步。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../ai/extraction_service.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/models/note_asset.dart';
import '../../data/repositories/ai_session_repository.dart';
import '../../features/teacher/teacher_page.dart';
import 'image_source.dart';
import 'markdown_actions.dart';
import 'markdown_render.dart';
import 'markdown_toolbar.dart';

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
  final _bodyCtrl = TextEditingController();
  final _bodyFocus = FocusNode();
  bool _busy = false;
  bool _dirty = false;
  String _status = '';
  Note? _note;

  /// 本笔记提取出的知识点（P1-5：笔记详情展示并可跳转）。
  List<KnowledgePoint> _kps = <KnowledgePoint>[];

  @override
  void initState() {
    super.initState();
    _titleCtrl.addListener(() => setState(() => _dirty = true));
    _bodyCtrl.addListener(() => setState(() => _dirty = true));
    if (widget.noteId != null) _load();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final row = await (widget.db.select(widget.db.notes)
          ..where((t) => t.id.equals(widget.noteId!))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return;
    setState(() {
      _titleCtrl.text = row.title;
      _bodyCtrl.text = row.contentMd;
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
        sessions: AiSessionRepository(widget.db),
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
      // 4) 插入引用（与工具栏同步动作同一套纯函数 + 写回口径）。
      final r = insertImage(
        _bodyCtrl.text,
        _bodyCtrl.selection,
        assetId,
        picked.name,
      );
      _bodyCtrl.value = _bodyCtrl.value.copyWith(
        text: r.text,
        selection: r.selection,
        composing: TextRange.empty,
      );
      _bodyFocus.requestFocus();
      // 5) 立即保存：引用落库 + reconcile 顺带清理（理论无孤儿）。
      //    保存成功/失败的状态由 _save() 自己写，这里不覆盖。
      await _save();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 当前正文选区对应的文字。
  ///
  /// 不依赖 `TextSelection.textContent`（该 API 并非所有 SDK 版本都有，
  /// 且无法处理「光标越界」的异常态）：自己按 base/extent 归一化后截取，
  /// 支持反向选区（先选尾部再往回拖）并把偏移夹取到正文范围内。
  String _selectionText() {
    final text = _bodyCtrl.text;
    final sel = _bodyCtrl.selection;
    final base = sel.baseOffset < 0 ? 0 : sel.baseOffset;
    final extent = sel.extentOffset < 0 ? 0 : sel.extentOffset;
    final start = (base <= extent ? base : extent).clamp(0, text.length);
    final end = (base <= extent ? extent : base).clamp(0, text.length);
    if (start >= end) return '';
    return text.substring(start, end);
  }

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
    final content = _bodyCtrl.text;
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
      _bodyCtrl.text,
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
  Widget _buildKpSection() {
    if (_note == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.grey.shade50),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '本笔记提取的知识点（${_kps.length}）',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 6),
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_note == null ? '新笔记' : (_note!.title.isEmpty ? '无标题' : _note!.title)),
        actions: [
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
            controller: _bodyCtrl,
            focusNode: _bodyFocus,
            onInsertImage: _insertImage,
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: TextField(
                      controller: _bodyCtrl,
                      focusNode: _bodyFocus,
                      maxLines: null,
                      expands: true,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Markdown 原文…\n\n# 标题\n- 列表\n**加粗** *斜体* `行内代码`',
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: renderMarkdownBlocks(
                            _bodyCtrl.text,
                            resolveAsset: _resolveAssetBytes,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
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
