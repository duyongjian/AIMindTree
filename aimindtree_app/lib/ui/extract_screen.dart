/// T1 提取演示界面（T04 合并双轨后）。
///
/// 左：粘贴笔记 → 触发 ExtractionService(T1) → AiService → Dify；
/// 右：本次「已入库」（含锚点校验通过的）+「被剔除」（幻觉防护）+ 本地库累计。
library;

import 'package:flutter/material.dart';

import '../ai/ai_job_service.dart';
import '../ai/ai_provider.dart';
import '../ai/ai_task.dart';
import '../ai/extraction_service.dart';
import '../core/result.dart';
import '../data/models/knowledge_point.dart';
import '../data/repositories/knowledge_repository.dart';
import '../features/knowledge/kp_dedup.dart';

class ExtractScreen extends StatefulWidget {
  const ExtractScreen({super.key, required this.service});
  final ExtractionService service;

  @override
  State<ExtractScreen> createState() => _ExtractScreenState();
}

class _ExtractScreenState extends State<ExtractScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  /// 本次提取的成功入库部分（含锚点区间）。
  List<KnowledgePoint> _saved = <KnowledgePoint>[];

  /// 本次被幻觉防护剔除的部分（保留给用户看原因）。
  List<RejectedPoint> _rejected = <RejectedPoint>[];

  /// 本地库累计（回读 Drift）。
  List<KnowledgePoint> _stored = <KnowledgePoint>[];

  late final KnowledgeRepository _repo = widget.service.repo;

  @override
  void initState() {
    super.initState();
    _reloadStored();
  }

  Future<void> _reloadStored() async {
    final all = await _repo.allKnowledgePoints();
    // 按更新时间倒序：让「本地库累计」展示最近入库的知识点，而不是库里原始顺序。
    all.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (!mounted) return;
    setState(() => _stored = all);
  }

  /// 提取（B1：默认走任务队列，提交即返回，进度见全局托盘）。
  ///
  /// 路径：存笔记拿 noteId → 提交 T1 job →（立即释放界面）→ onDone 落库。
  /// 队列关闭或服务不可达 → 同一篇笔记同步兜底（不重复存笔记）。
  Future<void> _onExtract() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _saved = <KnowledgePoint>[];
      _rejected = <RejectedPoint>[];
    });
    try {
      // 1) 存笔记拿 noteId（资源锁 note:{id} 的依据；两条路径共用）。
      final saved = await widget.service.stageSaveNote(text);
      if (saved is Failure<Note>) {
        setState(() => _error = saved.message);
        return;
      }
      final note = (saved as Success<Note>).value;

      // 2) 队列路径：提交即返回。
      if (kAiJobQueueEnabled) {
        AiJob? job;
        try {
          job = await widget.service.jobs.submit(
            task: AiTask.t1Extract.code,
            resourceKey: 'note:${note.id}',
            label: '提取《${note.title}》',
            inputs: {'note_text': text},
            onDone: (j) async {
              await _applyT1(note, text, Success(aiTaskResultFromJob(
                j.result ?? const <String, dynamic>{},
              )));
            },
            onError: (e) {
              if (mounted) setState(() => _error = 'T1 提取失败：$e');
            },
          );
        } on Object {
          job = null; // 服务不可达 → 落同步兜底。
        }
        if (job != null) {
          // 入队成功：界面立即释放，进度去托盘看（R1）。
          if (mounted) setState(() => _busy = false);
          return;
        }
        // 锁冲突（submit 返回 null 而非抛异常）：互斥不可绕过，不回落同步（R4）。
        if (mounted) {
          setState(() => _error = '这篇笔记有 AI 任务正在进行，完成后再试');
        }
        return;
      }

      // 3) 同步兜底（开关关闭）：同一篇笔记直接调 T1 + 落库。
      final aiRes =
          await widget.service.ai.run(AiTask.t1Extract, {'note_text': text});
      await _applyT1(note, text, aiRes);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  /// T1 结果落库 + 刷新右栏（队列 onDone 与同步路径共用）。
  Future<void> _applyT1(
    Note note,
    String text,
    Result<AiTaskResult> aiRes,
  ) async {
    if (aiRes is Failure<AiTaskResult>) {
      if (mounted) setState(() => _error = 'T1 提取失败：${aiRes.message}');
      return;
    }
    final res = await widget.service.stagePersist(
      note: note,
      noteContent: text,
      t1: (aiRes as Success<AiTaskResult>).value,
    );
    if (!mounted) return;
    if (res is Success<ExtractionSaveResult>) {
      // 成功落了知识点 → 后台异步跑一轮查重（T14）：与库里有重复簇时
      // 弹窗让用户选择保留者（fire-and-forget，不挡界面）。
      kpDedupSchedule(
        repo: widget.service.repo,
        jobs: widget.service.jobs,
      );
      await _reloadStored();
      if (!mounted) return;
      setState(() {
        _saved = res.value.saved;
        _rejected = res.value.rejected;
      });
    } else if (res is Failure<ExtractionSaveResult>) {
      setState(() => _error = res.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AIMindTree · T1 知识点提取')),
      body: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('粘贴笔记原文，点击提取：',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      maxLines: null,
                      expands: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: '例如：牛顿第一定律：任何物体都要保持匀速直线运动……',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _onExtract,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome),
                    label: Text(_busy ? '提取中…' : '提取知识点 (T1)'),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('错误：$_error',
                          style: const TextStyle(color: Colors.red)),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('本次已入库 (${_saved.length}) · 幻觉剔除 (${_rejected.length})',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final kp in _saved) _KpCard(kp: kp),
                        for (final rj in _rejected)
                          Card(
                            color: Colors.orange.shade50,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              leading: const Icon(Icons.warning_amber,
                                  color: Colors.orange),
                              title: Text(rj.raw.name.isEmpty
                                  ? '(空名知识点)'
                                  : rj.raw.name),
                              subtitle: Text('已剔除：${rj.reason}'),
                            ),
                          ),
                        if (_saved.isEmpty && _rejected.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Text('本次尚无结果。',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey)),
                          ),
                      ],
                    ),
                  ),
                  const Divider(),
                  Text('本地库累计（共 ${_stored.length} 个知识点，最近在前）',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final kp in _stored.take(50))
                          _KpCard(kp: kp),
                        if (_stored.length > 50)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              '…还有 ${_stored.length - 50} 个，去「知识树」查看全部',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KpCard extends StatelessWidget {
  const _KpCard({required this.kp});
  final KnowledgePoint kp;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          title: Text(kp.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('类型：${kp.type.label} · 置信度：${kp.confidence.toStringAsFixed(2)}'),
              if (kp.definition.isNotEmpty) Text('定义：${kp.definition}'),
              Text(
                '锚点：#${kp.sourceStart}-#${kp.sourceEnd}  引用：${kp.sourceQuote}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
}
