/// 作业页面（「作业模式」的落点）。
///
/// 进入方式：在知识树里点「作业模式」→ 框选薄弱点 →「布置作业」，把选中的
/// [KnowledgePoint] 连同（若有）已存在的作业 id 传进来。
///
/// 能力：
/// - **AI 生成**：走 T8 出题工作流（会话类，[AiService.chat] 流式累加后解析 JSON）；
///   无可用 Provider 时给明确提示，且页面仍可手动出题，不阻断。
/// - **逐题编辑**：题型 / 难度 / 题干 / 参考答案均可改，也支持删题、手动加题。
/// - **导出 Markdown**：可切换「含答案 / 仅题目」，一键复制到剪贴板。
/// - **落库**：新建或覆盖保存（[HomeworkRepository]），历史在画布「历史」里查看。
///
/// 设计要点：作业**不产生知识点**，题目本身也不是知识实体，所以出题不受「锚点铁律」
/// 约束；但 prompt 会把知识点的 `sourceQuote` 一并喂给模型，作为「不脱离原文」的唯一防线。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ai/ai_service.dart';
import '../../ai/ai_task.dart';
import '../../core/id.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/homework.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/repositories/homework_repository.dart';

class HomeworkPage extends StatefulWidget {
  const HomeworkPage({
    super.key,
    required this.ai,
    required this.db,
    required this.canvasId,
    required this.points,
    this.existingId,
  });

  /// AI 服务（用于 T8 流式出题）。
  final AiService ai;

  final AppDatabase db;

  /// 所属知识树（canvases.id）。
  final String canvasId;

  /// 出题上下文：被选中的薄弱点（名称 / 定义 / 原文出处）。
  final List<KnowledgePoint> points;

  /// 非空 → 编辑已有作业（从库里载入题目）。
  final String? existingId;

  @override
  State<HomeworkPage> createState() => _HomeworkPageState();
}

class _HomeworkPageState extends State<HomeworkPage> {
  late final HomeworkRepository _repo =
      HomeworkRepository(widget.db, deviceId: DeviceId.orEmpty);

  final TextEditingController _titleCtrl = TextEditingController();
  List<HomeworkItem> _items = const <HomeworkItem>[];

  /// 流式出题时的实时原文（展示「正在生成」进度）。
  String _streaming = '';
  bool _busy = false;
  String? _error;
  bool _withAnswer = true;

  @override
  void initState() {
    super.initState();
    if (widget.existingId != null) _loadExisting();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadExisting() async {
    final hw = await _repo.byId(widget.existingId!);
    if (!mounted) return;
    if (hw == null) {
      setState(() => _error = '找不到该作业（可能已被删除）。');
      return;
    }
    setState(() {
      _titleCtrl.text = hw.title;
      _items = hw.items;
    });
  }

  // ===================== 出题 =====================

  String _buildPrompt() {
    final sb = StringBuffer();
    sb.writeln('你是出题老师。下面是一组学生掌握得不好的知识点（薄弱点），'
        '请围绕它们出练习题，帮助学生巩固。');
    sb.writeln('每个知识点都附有「原文出处」，请以原文为依据出题，'
        '不要编造原文里没有的概念或数据。');
    sb.writeln();
    for (var i = 0; i < widget.points.length; i++) {
      final p = widget.points[i];
      sb.writeln('【薄弱点 ${i + 1}】${p.name}');
      if (p.definition.isNotEmpty) sb.writeln('  定义：${p.definition}');
      if (p.sourceQuote.isNotEmpty) sb.writeln('  原文：${p.sourceQuote}');
    }
    sb.writeln();
    sb.writeln('要求：');
    sb.writeln('- 为每个薄弱点各出 1~2 道题；');
    sb.writeln('- 题型从 choice（选择）/ fill（填空）/ short（简答）/ '
        'calc（计算）/ proof（证明或推导）中选择最合适的；');
    sb.writeln('- difficulty 为 1（易）/ 2（中）/ 3（难）。');
    sb.writeln('只输出一个 JSON 数组，不要任何解释、不要 markdown 代码块标记。'
        '每个元素格式：');
    sb.writeln('{"kpName":"知识点名称","type":"short","question":"题目",'
        '"answer":"参考答案或评分要点","difficulty":2}');
    return sb.toString();
  }

  /// 把模型输出解析成题目列表；兼容「裸数组」或「包了一层对象的数组」。
  List<HomeworkItem> _parseQuestions(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return const <HomeworkItem>[];
    // 去掉 ```json ... ``` 围栏。
    if (s.startsWith('```')) {
      final nl = s.indexOf('\n');
      if (nl >= 0) s = s.substring(nl + 1);
      if (s.endsWith('```')) s = s.substring(0, s.length - 3);
      s = s.trim();
    }
    // 优先找数组；找不到再找对象里的列表字段。
    Object? decoded;
    try {
      final arrStart = s.indexOf('[');
      final arrEnd = s.lastIndexOf(']');
      if (arrStart >= 0 && arrEnd > arrStart) {
        decoded = jsonDecode(s.substring(arrStart, arrEnd + 1));
      } else {
        final objStart = s.indexOf('{');
        final objEnd = s.lastIndexOf('}');
        if (objStart >= 0 && objEnd > objStart) {
          final map =
              jsonDecode(s.substring(objStart, objEnd + 1)) as Map<String, dynamic>;
          for (final key in const <String>['questions', 'items', 'data', 'list']) {
            if (map[key] is List) {
              decoded = map[key];
              break;
            }
          }
        }
      }
    } on Object {
      return const <HomeworkItem>[];
    }
    if (decoded is! List) return const <HomeworkItem>[];
    final out = <HomeworkItem>[];
    for (final e in decoded) {
      final it = HomeworkItem.fromJson(e);
      // 没带 kpName 的，按薄弱点顺序兜底补一个名字。
      if (it.kpName.isEmpty && widget.points.isNotEmpty) {
        out.add(it.copyWith(kpName: widget.points[out.length % widget.points.length].name));
      } else {
        out.add(it);
      }
    }
    return out;
  }

  Future<void> _generate() async {
    if (widget.points.isEmpty) {
      _toast('没有可用的知识点内容，无法自动出题。可手动「添加题目」。');
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _streaming = '';
    });
    final buf = StringBuffer();
    try {
      await for (final c in widget.ai.chat(AiTask.t8Quiz, _buildPrompt())) {
        if (c.delta != null) {
          buf.write(c.delta);
          if (mounted) setState(() => _streaming = buf.toString());
        }
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _streaming = '';
        _error = _friendlyError(e);
      });
      return;
    }
    final parsed = _parseQuestions(buf.toString());
    if (!mounted) return;
    setState(() {
      if (parsed.isNotEmpty) {
        _items = parsed;
        _error = null;
      } else {
        _error = 'AI 返回的内容无法解析为题目 JSON。可手动「添加题目」，或点击「重新生成」。';
      }
      _busy = false;
      _streaming = '';
    });
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('没有任何可用的 AI Provider')) {
      return '还没有配置 AI Provider，无法自动出题。'
          '你可以先去「设置」配置，或直接点「添加题目」手动布置。';
    }
    return '出题失败：$msg';
  }

  // ===================== 保存 / 导出 =====================

  Future<void> _save() async {
    if (_items.isEmpty) {
      _toast('还没有题目，先生成或手动添加。');
      return;
    }
    final title = _titleCtrl.text.trim().isEmpty
        ? '作业（${_fmtNow()}）'
        : _titleCtrl.text.trim();
    final kpIds = widget.points.map((p) => p.id).toList();

    void onResult(Result<void> r) {
      r.fold(
        (_) {
          _toast('已保存作业');
          Navigator.of(context).pop(true);
        },
        (e, _) => _toast('保存失败：$e'),
      );
    }

    if (widget.existingId != null) {
      final existing = await _repo.byId(widget.existingId!);
      if (existing == null) {
        final r = await _repo.create(
          canvasId: widget.canvasId,
          title: title,
          kpIds: kpIds,
          items: _items,
        );
        if (!mounted) return;
        onResult(r.map((_) => null));
      } else {
        final r = await _repo.save(existing.copyWith(
          title: title,
          kpIds: kpIds,
          items: _items,
        ));
        if (!mounted) return;
        onResult(r);
      }
    } else {
      final r = await _repo.create(
        canvasId: widget.canvasId,
        title: title,
        kpIds: kpIds,
        items: _items,
      );
      if (!mounted) return;
      onResult(r.map((_) => null));
    }
  }

  String _toMarkdown({required bool withAnswer}) {
    final sb = StringBuffer();
    final title = _titleCtrl.text.trim().isEmpty
        ? '作业'
        : _titleCtrl.text.trim();
    sb.writeln('# $title');
    sb.writeln();
    sb.writeln('共 ${_items.length} 题'
        '${widget.points.isNotEmpty ? '（覆盖 ${widget.points.length} 个薄弱点）' : ''}');
    sb.writeln();
    for (var i = 0; i < _items.length; i++) {
      final it = _items[i];
      sb.writeln('## 第 ${i + 1} 题（${it.typeLabel} · 难度 ${it.difficulty}）');
      if (it.kpName.isNotEmpty) sb.writeln('知识点：${it.kpName}');
      sb.writeln();
      sb.writeln(it.question.trim());
      if (withAnswer) {
        sb.writeln();
        sb.writeln('**参考答案：**');
        sb.writeln(it.answer.trim());
      }
      sb.writeln();
    }
    return sb.toString();
  }

  Future<void> _export() async {
    if (_items.isEmpty) {
      _toast('还没有题目可导出。');
      return;
    }
    final md = _toMarkdown(withAnswer: _withAnswer);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('导出 Markdown'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(md),
            ),
          ),
          actions: [
            Row(
              children: [
                Checkbox(
                  value: _withAnswer,
                  onChanged: (v) => setD(() => _withAnswer = v ?? true),
                ),
                const Text('包含答案'),
              ],
            ),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: md));
                if (!mounted) return;
                Navigator.of(ctx).pop();
                _toast('已复制到剪贴板');
              },
              child: const Text('复制'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  static String _fmtNow() {
    final l = DateTime.now().toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, "0")}-'
        '${l.day.toString().padLeft(2, "0")} '
        '${l.hour.toString().padLeft(2, "0")}:'
        '${l.minute.toString().padLeft(2, "0")}';
  }

  // ===================== 构建 =====================

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.existingId != null ? '编辑作业' : '布置作业'),
          actions: [
            TextButton.icon(
              onPressed: _export,
              icon: const Icon(Icons.download_outlined),
              label: const Text('导出'),
            ),
            TextButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _titleCtrl,
                decoration: const InputDecoration(
                  labelText: '作业标题',
                  hintText: '例如：第三章薄弱点专项练习',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _generate,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome),
                    label: Text(_items.isEmpty ? 'AI 生成' : '重新生成'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _items = [
                      ..._items,
                      const HomeworkItem(
                        kpId: '',
                        kpName: '',
                        type: 'short',
                        question: '',
                        answer: '',
                      ),
                    ]),
                    icon: const Icon(Icons.add),
                    label: const Text('添加题目'),
                  ),
                ],
              ),
              if (_busy && _streaming.isNotEmpty)
                _StreamBanner(text: _streaming),
              if (_error != null)
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_error!,
                            style: const TextStyle(fontSize: 13, color: Colors.red)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Text('题目（${_items.length}）',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (_items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text('还没有题目。点「AI 生成」自动出题，或「添加题目」手动录入。',
                        style: TextStyle(color: Colors.grey)),
                  ),
                )
              else
                for (var i = 0; i < _items.length; i++)
                  _ItemEditor(
                    index: i + 1,
                    item: _items[i],
                    onChanged: (it) => setState(() => _items[i] = it),
                    onDelete: () => setState(() => _items.removeAt(i)),
                  ),
            ],
          ),
        ),
      );
}

/// 单题编辑器：自带 TextEditingController，题型 / 难度可改，可删除。
class _ItemEditor extends StatefulWidget {
  const _ItemEditor({
    required this.index,
    required this.item,
    required this.onChanged,
    required this.onDelete,
  });

  final int index;
  final HomeworkItem item;
  final ValueChanged<HomeworkItem> onChanged;
  final VoidCallback onDelete;

  @override
  State<_ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<_ItemEditor> {
  late final TextEditingController _kp =
      TextEditingController(text: widget.item.kpName);
  late final TextEditingController _q =
      TextEditingController(text: widget.item.question);
  late final TextEditingController _a =
      TextEditingController(text: widget.item.answer);

  @override
  void dispose() {
    _kp.dispose();
    _q.dispose();
    _a.dispose();
    super.dispose();
  }

  HomeworkItem _current() => widget.item.copyWith(
        kpName: _kp.text,
        question: _q.text,
        answer: _a.text,
      );

  void _emit() => widget.onChanged(_current());

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    child: Text('${widget.index}', style: const TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: widget.item.type,
                      items: const [
                        DropdownMenuItem(value: 'choice', child: Text('选择')),
                        DropdownMenuItem(value: 'fill', child: Text('填空')),
                        DropdownMenuItem(value: 'short', child: Text('简答')),
                        DropdownMenuItem(value: 'calc', child: Text('计算')),
                        DropdownMenuItem(value: 'proof', child: Text('证明/推导')),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          widget.onChanged(_current().copyWith(type: v));
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 1, label: Text('易')),
                      ButtonSegment(value: 2, label: Text('中')),
                      ButtonSegment(value: 3, label: Text('难')),
                    ],
                    selected: {widget.item.difficulty},
                    onSelectionChanged: (s) =>
                        widget.onChanged(_current().copyWith(difficulty: s.first)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    tooltip: '删除该题',
                    onPressed: widget.onDelete,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _kp,
                decoration: const InputDecoration(
                  labelText: '关联知识点',
                  isDense: true,
                ),
                onChanged: (_) => _emit(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _q,
                minLines: 1,
                maxLines: null,
                decoration: const InputDecoration(
                  labelText: '题目',
                  isDense: true,
                ),
                onChanged: (_) => _emit(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _a,
                minLines: 1,
                maxLines: null,
                decoration: const InputDecoration(
                  labelText: '参考答案 / 评分要点',
                  isDense: true,
                ),
                onChanged: (_) => _emit(),
              ),
            ],
          ),
        ),
      );
}

/// 出题时的流式进度条（展示模型实时输出，不阻塞编辑）。
class _StreamBanner extends StatelessWidget {
  const _StreamBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.amber.shade50,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('AI 正在出题…', style: TextStyle(fontSize: 13)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              text.length > 300 ? '${text.substring(0, 300)}…' : text,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      );
}
