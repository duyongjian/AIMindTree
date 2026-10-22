/// 笔记编辑器页面（T06 业务流）。
///
/// 标题 + Markdown 正文（分屏：左编辑 / 右预览），底部：
/// - 保存到 Drift；
/// - **提取知识点 (T1)** —— 一键跑通 T1 流水线。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../ai/extraction_service.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/repositories/ai_session_repository.dart';
import '../../features/teacher/teacher_page.dart';
import 'markdown_render.dart';
import 'markdown_toolbar.dart';

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
  /// 图片同步链路尚未接线（见后续「图片插入全链路」任务），当前一律返回 `null`
  /// —— 渲染层会降级成「图片未同步」占位块，保证任何时候整篇笔记都能渲染出来。
  Future<Uint8List?> _resolveAssetBytes(String assetId) async => null;

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
            deviceId: 'local-dev',
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
    setState(() {
      _busy = true;
      _status = '保存并提取…';
    });
    final id = await _save();
    if (id.isEmpty) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    setState(() => _status = '调用 Dify T1…');
    final res = await widget.service.extract(_bodyCtrl.text);
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
          MarkdownToolbar(controller: _bodyCtrl, focusNode: _bodyFocus),
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
