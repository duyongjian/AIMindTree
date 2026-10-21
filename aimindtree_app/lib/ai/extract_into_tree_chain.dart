/// 「提取 → 入树 → 自动连线」链式复合任务（C1 / C6 共用，方案 §11.1）。
///
/// 为什么是 App 侧链式而不是服务端复合 stage：T3 需要「新知识点入库后的 id」
/// 才能连线，而 DB 在 App 侧（Drift sqlite），服务端拿不到新 id。于是：
/// T1 job（``keepLockOnDone`` 持锁）→ onDone 落库入树 → 同锁提交 T3 job →
/// onDone 连线。锁跨两个 job 不落空，托盘显示两行。
///
/// 取消语义（Q6）：任一段取消 → 回滚（删笔记连带其知识点 + 出树）；
/// T3 失败 → 保留 T1 成果（托盘 SnackBar 明说可手动重试）。
library;

import 'ai_job_service.dart';
import 'ai_provider.dart';
import 'ai_task.dart';
import 'auto_graph_service.dart';
import 'extraction_service.dart';
import '../canvas/layout_autoplace.dart';
import '../core/logger.dart';
import '../core/result.dart';
import '../data/db/drift_database.dart';
import '../data/models/knowledge_point.dart';
import '../data/models/knowledge_tree.dart';
import '../data/repositories/knowledge_repository.dart';

/// 复合链提交结果。
enum ChainOutcome {
  /// 已入队（进度见全局托盘）。
  queued,

  /// 资源锁被占（R4：互斥不绕过，不回落同步）。
  locked,

  /// 服务不可达（调用方走同步兜底；[note] 已存，供兜底复用不重复存笔记）。
  serviceDown,
}

class ExtractIntoTreeChain {
  ExtractIntoTreeChain({
    required this.service,
    required this.auto,
    required this.db,
    required this.onRefresh,
    this.onMessage,
  });

  final ExtractionService service;
  final AutoGraphService auto;
  final AppDatabase db;

  /// 页面刷新（canvas: 重载当前树；agent: setState 清候选）。
  final void Function(KnowledgeTree tree) onRefresh;

  /// 需要 toast 的消息（回滚结果等无上下文场景）。
  final void Function(String message)? onMessage;

  static final AppLog _log = AppLog('extract_chain');

  /// 同步兜底：笔记已由队列路径存过，只补 T1 + 落库（**不重复存笔记**）。
  static Future<Result<ExtractionSaveResult>> extractWithExistingNote(
    ExtractionService service,
    Note note,
    String content,
  ) async {
    final aiRes =
        await service.ai.run(AiTask.t1Extract, {'note_text': content});
    if (aiRes is Failure<AiTaskResult>) {
      return Failure(aiRes.error, aiRes.stackTrace);
    }
    return service.stagePersist(
      note: note,
      noteContent: content,
      t1: (aiRes as Success<AiTaskResult>).value,
    );
  }

  /// 提交复合链。返回 ``(outcome, note)``；note 非空 = 笔记已存。
  Future<(ChainOutcome, Note)> submit({
    required KnowledgeTree tree,
    required String md,
    required String label,
  }) async {
    final saved = await service.stageSaveNote(md);
    if (saved is Failure<Note>) {
      throw StateError('保存笔记失败：${saved.message}');
    }
    final note = (saved as Success<Note>).value;

    try {
      final job = await service.jobs.submit(
        task: 'T1',
        resourceKey: 'tree:${tree.id}',
        label: label,
        inputs: {'note_text': md},
        keepLockOnDone: true, // 锁延续到 T3 段
        onDone: (j1) => _onT1Done(note, tree, j1),
        onCancel: () => _rollback(note, tree),
      );
      if (job == null) return (ChainOutcome.locked, note);
      return (ChainOutcome.queued, note);
    } on Object catch (e) {
      _log.w('复合链提交失败（服务不可达？）：$e');
      return (ChainOutcome.serviceDown, note);
    }
  }

  /// 第一段（T1）完成：落库 → 入树 → 落位 → 同锁提交 T3。
  Future<void> _onT1Done(Note note, KnowledgeTree tree, AiJob job1) async {
    final t1 = aiTaskResultFromJob(job1.result ?? const <String, dynamic>{});
    final ext = await service.stagePersist(
      note: note,
      noteContent: note.contentMd,
      t1: t1,
    );
    if (ext is Failure<ExtractionSaveResult>) {
      service.jobs.releaseLock('tree:${tree.id}');
      onMessage?.call('T1 锚定失败：${ext.message}');
      return;
    }
    final res = (ext as Success<ExtractionSaveResult>).value;
    final ids = res.saved.map((k) => k.id).toList();
    if (ids.isEmpty) {
      service.jobs.releaseLock('tree:${tree.id}');
      onMessage?.call('没有可锚定的知识点被收录'
          '（${res.rejectedCount} 条因缺少原文出处被剔除）');
      return;
    }

    final existing = await service.trees.memberPointIds(tree.id);
    final newIds = ids.where((id) => !existing.contains(id)).toList();
    final addRes = await service.trees.addPoints(tree.id, ids);
    final added = addRes.valueOrNull ?? 0;
    if (addRes is Failure<int>) {
      service.jobs.releaseLock('tree:${tree.id}');
      onMessage?.call('并入失败：${addRes.message}');
      return;
    }
    // 新并入的点默认 x/y=0，用布局引擎算不重叠坐标。
    await autoPlaceNewPointsInTree(
      db: db,
      trees: service.trees,
      repo: service.repo,
      treeId: tree.id,
      newIds: newIds,
    );
    job1.doneMessage = '已加入「${tree.name}」：$added 个知识点，正在自动连线…';
    onRefresh(tree);

    // 第二段：T3 自动连线（同锁，链式提交）。
    final inputs = await auto.linkInputsFor(tree.id);
    if (inputs == null) {
      service.jobs.releaseLock('tree:${tree.id}');
      return; // 点数不足：doneMessage 已说明加入成功
    }
    try {
      final job2 = await service.jobs.submit(
        task: 'T3',
        resourceKey: 'tree:${tree.id}',
        label: '自动连线《${tree.name}》',
        inputs: inputs,
        stages: const <String>['T1', 'T3'],
        onDone: (j2) async {
          final linkRes = await auto.linkFromParsed(tree.id, j2.result?['parsed']);
          var linkNote = '';
          linkRes.fold(
            (r) {
              if (r.created > 0) linkNote = '，自动建立 ${r.created} 条前置关系';
            },
            (e, _) {
              linkNote = '（自动连线未完成：$e，可稍后手动点「自动连线」）';
            },
          );
          j2.doneMessage = '已加入「${tree.name}」：$added 个知识点$linkNote';
          onRefresh(tree);
        },
        onCancel: () => _rollback(note, tree),
      );
      if (job2 == null) {
        // 理论上不会（keepLockOnDone 保着锁）；防御性放锁。
        service.jobs.releaseLock('tree:${tree.id}');
      }
    } on Object catch (e) {
      service.jobs.releaseLock('tree:${tree.id}');
      onMessage?.call('已加入 $added 个知识点（自动连线提交失败：$e）');
    }
  }

  /// Q6：复合链任一段取消 → 半成品回滚（删笔记连带其知识点 + 从树中移除）。
  Future<void> _rollback(Note note, KnowledgeTree tree) async {
    try {
      await service.repo.deleteNote(
        noteId: note.id,
        deletePoints: true,
        // deletePoints=true 时仓库会顺带清掉所有树的成员关系；这里仍按
        // 契约显式给出本链唯一可能写入的树（复合链只往 tree.id 加点）。
        removeFromTrees: <String>{tree.id},
      );
    } on Object catch (e) {
      _log.e('回滚失败（note=${note.id}）', error: e);
      onMessage?.call('已取消，但回滚不完整：$e（可在笔记列表手动删除）');
      return;
    }
    onMessage?.call('已取消「${tree.name}」的加入操作，半成品已回滚');
    onRefresh(tree);
  }
}
