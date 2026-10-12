/// T1 提取演示界面（T04 合并双轨后）。
///
/// 左：粘贴笔记 → 触发 ExtractionService(T1) → AiService → Dify；
/// 右：本次「已入库」（含锚点校验通过的）+「被剔除」（幻觉防护）+ 本地库累计。
library;

import 'package:flutter/material.dart';

import '../ai/extraction_service.dart';
import '../core/result.dart';
import '../data/models/knowledge_point.dart';
import '../data/repositories/knowledge_repository.dart';

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
      final res = await widget.service.extract(text);
      if (res is Success<ExtractionSaveResult>) {
        await _reloadStored();
        if (!mounted) return;
        setState(() {
          _saved = res.value.saved;
          _rejected = res.value.rejected;
        });
      } else if (res is Failure<ExtractionSaveResult>) {
        if (!mounted) return;
        setState(() => _error = res.message);
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
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
