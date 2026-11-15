/// 知识点仓储（T02 核心）。
///
/// 承载 PRD 两条**产品硬规则**：
/// 1. **锚点校验**：AI 生成的知识点必须能在原文中定位到逐字匹配的 `source_quote`，
///    否则视为幻觉**剔除**并给出原因，绝不入库（PRD §硬规则1）。
/// 2. **级联降级**：把某知识点标为「未掌握」时，所有**依赖它的后继**知识点自动
///    往「更不掌握」方向降一档（PRD §硬规则4）。
///
/// 写操作统一走本仓储（§11：禁止 UI 直写表）；Outbox 追加在 T03 接入。
library;

import 'package:drift/drift.dart';

import '../../core/id.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../db/drift_database.dart';
import '../models/knowledge_point.dart';
import '../sync/sync_outbox_writer.dart';

/// AI 提取出的原始知识点（未校验锚点，来自 Dify/LLM 输出）。
class RawKnowledgePoint {
  const RawKnowledgePoint({
    required this.name,
    this.type = '',
    this.definition = '',
    this.sourceQuote = '',
    this.prerequisites = const <String>[],
    this.confidence = 0,
  });

  final String name;
  final String type;
  final String definition;
  final String sourceQuote;
  final List<String> prerequisites;
  final num confidence;
}

/// 被剔除的知识点及原因（幻觉防护的可观测输出）。
class RejectedPoint {
  const RejectedPoint(this.raw, this.reason);
  final RawKnowledgePoint raw;
  final String reason;
}

/// 提取入库结果：成功入库的 + 被剔除的。
class ExtractionSaveResult {
  const ExtractionSaveResult({required this.saved, required this.rejected});

  final List<KnowledgePoint> saved;
  final List<RejectedPoint> rejected;

  int get savedCount => saved.length;
  int get rejectedCount => rejected.length;
}

/// 删除一篇笔记的执行结果（用于给用户一个明确的回执）。
class NoteDeleteSummary {
  const NoteDeleteSummary({
    required this.pointsDeleted,
    required this.pointsDetached,
    required this.treesAffected,
  });

  /// 被彻底删除的知识点数量。
  final int pointsDeleted;

  /// 只解除树关系、知识点本身保留的数量。
  final int pointsDetached;

  /// 受影响（被解除关系或被清空）的知识树数量。
  final int treesAffected;

  bool get hasChange =>
      pointsDeleted > 0 || pointsDetached > 0 || treesAffected > 0;
}

/// 知识点仓储。
class KnowledgeRepository {
  KnowledgeRepository(this._db, {this.deviceId = ''});

  final AppDatabase _db;
  final String deviceId;

  /// 底层库句柄（只读暴露，不新增写入入口）。
  ///
  /// 存在的理由：查重合并（features/knowledge/kp_dedup.dart）在固定的
  /// `kpDedupSchedule(repo, jobs)` 契约下还要再包一层 `TreeRepository`
  /// （树成员 / 位置迁移），而树仓储与本仓储必须共用**同一个** [AppDatabase]
  /// 实例（否则上行同步的 outbox 身份校验会跳过入队）。设备号取本仓储的
  /// [deviceId]，保证同步行与其它写路径同源。
  AppDatabase get db => _db;

  static final AppLog _log = AppLog('knowledge_repo');

  /// 上行同步写入器（把本地写登记进 outbox；未接线时自动跳过）。
  late final SyncOutboxWriter _sync = SyncOutboxWriter(_db);

  // ============ 写入 ============

  /// 保存（upsert）一条笔记。
  Future<Result<Note>> saveNote(Note note) async {
    try {
      // 必须 bump 版本 + 刷新 updated_at：否则编辑后的行与旧版本号 / 时间戳
      // 同值，接收方 LWW 在 `==` 平局分支里会判成「keep local」，导致
      // 「一端改了、另一端拉取没变化」（见 sync_engine._compare）。删除 /
      // 恢复路径都做了 version+1，这里必须与它们口径一致。读现有行取当前
      // version；新笔记（无现有行）从 1 起算，与 Note 默认 version 一致。
      final existing = await (_db.select(_db.notes)
            ..where((t) => t.id.equals(note.id)))
          .getSingleOrNull();
      final now = DateTime.now().toUtc();
      final toSave = note.copyWith(
        version: (existing?.version ?? 0) + 1,
        updatedAt: now,
      );
      // P0 版本历史：仅在正文真发生变化时，把被覆盖前的旧版本快照进 note_versions。
      // 不动标题/置顶等元数据变更（那不算「内容版本」），避免无意义的版本膨胀。
      if (existing != null && existing.contentMd != toSave.contentMd) {
        await _db.into(_db.noteVersions).insert(NoteVersionsCompanion(
          id: Value(newUlid()),
          noteId: Value(existing.id),
          version: Value(existing.version),
          title: Value(existing.title),
          contentMd: Value(existing.contentMd),
          createdAt: Value(existing.updatedAt),
          deviceId: Value(existing.deviceId),
        ));
        await _trimNoteVersions(existing.id);
      }
      await _db
          .into(_db.notes)
          .insertOnConflictUpdate(NotesCompanion(
            id: Value(toSave.id),
            notebookId: Value(toSave.notebookId),
            title: Value(toSave.title),
            contentMd: Value(toSave.contentMd),
            contentHash: Value(toSave.contentHash),
            // v8 新增：置顶。漏写会让 insertOnConflictUpdate 在冲突更新时
            // 把 pinned 回落成列默认值 false，静默丢掉置顶状态。
            pinned: Value(toSave.pinned),
            updatedAt: Value(toSave.updatedAt),
            version: Value(toSave.version),
            deviceId: Value(toSave.deviceId),
            deletedAt: Value(toSave.deletedAt),
          ));
      await _sync.upsertNote(toSave.id);
      return Success(toSave);
    } on Object catch (e, s) {
      _log.e('保存笔记失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 保留每个笔记最近 30 个版本：超出则删除最旧的（按 created_at 升序）。
  Future<void> _trimNoteVersions(String noteId) async {
    final all = await (_db.select(_db.noteVersions)
          ..where((t) => t.noteId.equals(noteId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
    if (all.length <= 30) return;
    final excess = all.skip(30).map((r) => r.id).toList();
    if (excess.isNotEmpty) {
      await (_db.delete(_db.noteVersions)
            ..where((t) => t.id.isIn(excess)))
          .go();
    }
  }

  /// 把 AI 提取结果**带锚点校验**地入库。
  ///
  /// [noteContent] 用于定位 `source_quote` 的字符区间；未命中原文的一律剔除。
  Future<Result<ExtractionSaveResult>> saveExtracted({
    required String noteId,
    required String noteContent,
    required List<RawKnowledgePoint> rawPoints,
    String? notebookId,
  }) async {
    final saved = <KnowledgePoint>[];
    final rejected = <RejectedPoint>[];

    for (final raw in rawPoints) {
      if (raw.name.trim().isEmpty) {
        rejected.add(RejectedPoint(raw, '知识点名称为空'));
        continue;
      }

      // ★ 锚点校验：quote 必须逐字出现在原文中
      final loc = _locateQuote(noteContent, raw.sourceQuote);
      if (loc == null) {
        rejected.add(RejectedPoint(
          raw,
          '锚点校验失败：source_quote 未在原文中逐字匹配'
          '（quote="${_preview(raw.sourceQuote)}"）',
        ));
        continue;
      }

      final kp = KnowledgePoint(
        notebookId: notebookId,
        name: raw.name.trim(),
        type: KnowledgePointType.parse(raw.type),
        definition: raw.definition,
        sourceNoteId: noteId,
        sourceStart: loc.start,
        sourceEnd: loc.end,
        sourceQuote: raw.sourceQuote,
        origin: 'ai_extract',
        confidence: raw.confidence.toDouble(),
        deviceId: deviceId,
      );

      try {
        await _db.into(_db.knowledgePoints).insert(_kpInsertCompanion(kp));
        saved.add(kp);
        await _sync.upsertKnowledgePoint(kp.id);
      } on Object catch (e, s) {
        _log.e('知识点入库失败：${kp.name}', error: e, stackTrace: s);
        rejected.add(RejectedPoint(raw, '入库异常：$e'));
      }
    }

    if (rejected.isNotEmpty) {
      _log.w('提取入库：成功 ${saved.length} 条，剔除 ${rejected.length} 条（幻觉防护）');
    }
    return Success(ExtractionSaveResult(saved: saved, rejected: rejected));
  }

  /// 批量写入前置关系边。
  Future<Result<int>> addPrerequisiteEdges(
      List<PrerequisiteEdge> edges) async {
    var count = 0;
    try {
      for (final e in edges) {
        await _db
            .into(_db.prerequisiteEdges)
            .insert(PrerequisiteEdgesCompanion(
              id: Value(e.id),
              fromKpId: Value(e.fromKpId),
              toKpId: Value(e.toKpId),
              reason: Value(e.reason),
              origin: Value(e.origin),
              confidence: Value(e.confidence),
              updatedAt: Value(DateTime.now().toUtc()),
              version: const Value(1),
              deviceId: Value(deviceId),
            ));
        count++;
        await _sync.upsertPrerequisiteEdge(e.id);
      }
      return Success(count);
    } on Object catch (e, s) {
      _log.e('写入前置关系失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 手工创建一条前置关系（用户在画布上连线），默认 `origin = 'manual'`。
  ///
  /// AI 自动连线也会调用本方法，仅传入不同的 [origin] / [confidence]
  /// （如 `'ai'` / `0.8`），便于 UI 区分并允许删除。
  /// 同向边已存在时直接返回既有边（幂等），避免重复连线。
  Future<Result<PrerequisiteEdge>> addManualPrerequisiteEdge(
    String fromKpId,
    String toKpId, {
    String reason = '',
    String origin = 'manual',
    double confidence = 1.0,
  }) async {
    try {
      if (fromKpId == toKpId) {
        return Failure(StateError('不能把知识点连接到它自己'));
      }
      // 约束（用户诉求 2026-10-10）：每个知识点最多只能有一个后继（出边）。
      // 已有后继则拒绝，由用户先删旧边再连新边——避免误丢数据。
      final existingSucc = await successorsOf(fromKpId);
      if (existingSucc.isNotEmpty) {
        return Failure(StateError(
            '每个知识点最多只能有一个后继，请先删除该知识点现有的后继关系'));
      }
      // 防环：不能让 to 沿后继链回到 from（否则形成学习环路）。
      if (await _canReach(toKpId, fromKpId)) {
        return Failure(StateError('会形成学习环路，已阻止该连接'));
      }
      final dup = await (_db.select(_db.prerequisiteEdges)
            ..where((t) =>
                t.fromKpId.equals(fromKpId) & t.toKpId.equals(toKpId)))
          .getSingleOrNull();
      if (dup != null) {
        return Success(PrerequisiteEdge(
          id: dup.id,
          fromKpId: dup.fromKpId,
          toKpId: dup.toKpId,
          reason: dup.reason,
          origin: dup.origin,
          confidence: dup.confidence,
        ));
      }

      final edge = PrerequisiteEdge(
        fromKpId: fromKpId,
        toKpId: toKpId,
        reason: reason,
        origin: origin,
        confidence: confidence,
      );
      await addPrerequisiteEdges(<PrerequisiteEdge>[edge]);
      return Success(edge);
    } on Object catch (e, s) {
      _log.e('创建前置关系失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 取出 [ids] 内部的所有前置边（两端都在集合内的边）。
  ///
  /// 自动连线时用于去重与防环（已经存在的边不再重复创建）。
  Future<List<PrerequisiteEdge>> prerequisiteEdgesAmong(
      List<String> ids) async {
    if (ids.isEmpty) return const <PrerequisiteEdge>[];
    final rows = await (_db.select(_db.prerequisiteEdges)
          ..where((t) => t.fromKpId.isIn(ids) & t.toKpId.isIn(ids)))
        .get();
    return rows
        .map((r) => PrerequisiteEdge(
              id: r.id,
              fromKpId: r.fromKpId,
              toKpId: r.toKpId,
              reason: r.reason,
              origin: r.origin,
              confidence: r.confidence,
            ))
        .toList();
  }

  /// 删除一条前置关系（画布上删连线）。
  Future<Result<void>> deletePrerequisiteEdge(String id) async {
    try {
      // 先读出行（硬删后行就没了，version / id 要在删除前留档）。
      final row = await (_db.select(_db.prerequisiteEdges)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      await (_db.delete(_db.prerequisiteEdges)..where((t) => t.id.equals(id)))
          .go();
      if (row != null) {
        await _sync.hardDeletePrerequisiteEdges(<PrerequisiteEdgeRow>[row]);
      }
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('删除前置关系失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 读取画布上已保存的节点位置（kpId → x/y）。
  ///
  /// 未拖动过的节点不在表里，调用方回退到布局引擎算出的默认位置。
  Future<Map<String, ({double x, double y})>> loadNodePositions(
      String canvasId) async {
    final rows = await (_db.select(_db.canvasNodes)
          ..where((t) =>
              t.canvasId.equals(canvasId) & t.targetType.equals('kp')))
        .get();
    return <String, ({double x, double y})>{
      for (final r in rows) r.targetId: (x: r.x, y: r.y),
    };
  }

  /// 保存（upsert）一个知识点节点在画布上的位置。
  ///
  /// 节点 id 用 `canvasId:kpId` 保证唯一，便于 `insertOnConflictUpdate`；
  /// version 递增（而非固定 1），否则 LWW 同步会误判新旧。
  ///
  /// [pinned] 标记该节点是否被「锁定」：拖拽落库、手动重排都走 true（锁定，结构变化
  /// 的自动重排不再移动它）；AI 自动铺位 / 自动补前置落库走 false（浮动，结构变化
  /// 时仍可被布局引擎重新铺位）。
  Future<Result<void>> saveNodePosition(
    String canvasId,
    String kpId,
    double x,
    double y, {
    bool pinned = true,
  }) async {
    final nodeId = '$canvasId:$kpId';
    try {
      final existing =
          await (_db.select(_db.canvasNodes)..where((t) => t.id.equals(nodeId)))
              .getSingleOrNull();
      await _db
          .into(_db.canvasNodes)
          .insertOnConflictUpdate(CanvasNodesCompanion(
            id: Value(nodeId),
            canvasId: Value(canvasId),
            targetType: const Value('kp'),
            targetId: Value(kpId),
            x: Value(x),
            y: Value(y),
            pinned: Value(pinned),
            updatedAt: Value(DateTime.now().toUtc()),
            version: Value((existing?.version ?? 0) + 1),
            deviceId: Value(deviceId),
          ));
      await _sync.upsertCanvasNode(nodeId);
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('保存节点位置失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 读取画布节点当前的（x, y, pinned）状态，供「仅重排未锁定节点」使用。
  ///
  /// 未拖动过的节点不在表里，调用方回退到布局引擎算出的默认位置（按 pinned=true
  /// 处理，结构变化时也不动它）。
  Future<Map<String, ({double x, double y, bool pinned})>> loadNodeLayout(
      String canvasId) async {
    final rows = await (_db.select(_db.canvasNodes)
          ..where((t) =>
              t.canvasId.equals(canvasId) & t.targetType.equals('kp')))
        .get();
    return <String, ({double x, double y, bool pinned})>{
      for (final r in rows)
        r.targetId: (x: r.x, y: r.y, pinned: r.pinned),
    };
  }

  /// 设置掌握状态；若为「未掌握」则触发**后继级联降级**。
  ///
  /// 返回实际被降级（含自身变更）的知识点数量。
  Future<Result<int>> setMastery(
    String kpId,
    MasteryStatus status, {
    MasterySource source = MasterySource.self,
  }) async {
    try {
      await _writeMastery(kpId, status, source);
      var changed = 1;
      if (status == MasteryStatus.notMastered) {
        changed += await _cascadeDowngrade(kpId);
      }
      return Success(changed);
    } on Object catch (e, s) {
      _log.e('设置掌握状态失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 删除一篇笔记，并按用户的选择处置它产生的知识点。
  ///
  /// - 笔记本体走**软删除**（写 `deletedAt`），这样同步时另一端能识别出「删除」
  ///   而不是「本地没有这条数据」（LWW 决策表第一条）。
  /// - [deletePoints] 为 true：知识点彻底删除，连带前置边、掌握记录、
  ///   以及它在**所有**知识树里的成员关系一并清掉。
  /// - 否则只把知识点从 [removeFromTrees] 列出的树里摘掉，知识点本身保留为独立资产。
  Future<Result<NoteDeleteSummary>> deleteNote({
    required String noteId,
    required bool deletePoints,
    required Set<String> removeFromTrees,
  }) async {
    try {
      final kpIds = await pointIdsOfNote(noteId);
      var detached = 0;
      var deleted = 0;
      var trees = 0;

      // 级联硬删的行要在删之前留档（删完就没法取 id / version 了）。
      // 只在「彻底删除」分支需要留档 —— 「只解除树关系」分支不删这些行。
      final cascadeEdges = (kpIds.isEmpty || !deletePoints)
          ? <PrerequisiteEdgeRow>[]
          : await (_db.select(_db.prerequisiteEdges)
                ..where((t) =>
                    t.fromKpId.isIn(kpIds) | t.toKpId.isIn(kpIds)))
              .get();
      final cascadeMastery = (kpIds.isEmpty || !deletePoints)
          ? <MasteryRecordRow>[]
          : await (_db.select(_db.masteryRecords)
                ..where((t) => t.kpId.isIn(kpIds)))
              .get();
      final cascadeNodes = (kpIds.isEmpty || !deletePoints)
          ? <CanvasNodeRow>[]
          : await (_db.select(_db.canvasNodes)
                ..where((t) =>
                    t.targetType.equals('kp') & t.targetId.isIn(kpIds)))
              .get();
      final cascadeKps = (kpIds.isEmpty || !deletePoints)
          ? <KnowledgePointRow>[]
          : await (_db.select(_db.knowledgePoints)..where((t) => t.id.isIn(kpIds)))
              .get();
      final cascadeCanvas = deletePoints
          ? await (_db.select(_db.canvases)..where((t) => t.id.equals(noteId)))
              .getSingleOrNull()
          : null;
      // 「只解除树关系」分支里被摘下的节点（必须在删除前留档）。
      final detachedNodes = (kpIds.isEmpty || removeFromTrees.isEmpty)
          ? <CanvasNodeRow>[]
          : await (_db.select(_db.canvasNodes)
                ..where((t) =>
                    t.canvasId.isIn(removeFromTrees) &
                    t.targetType.equals('kp') &
                    t.targetId.isIn(kpIds)))
              .get();

      if (kpIds.isNotEmpty && deletePoints) {
        // 彻底删除：清掉所有树里的成员关系 + 边 + 掌握记录 + 知识点本身。
        await (_db.delete(_db.canvasNodes)
              ..where((t) => t.targetType.equals('kp') & t.targetId.isIn(kpIds)))
            .go();
        await (_db.delete(_db.prerequisiteEdges)
              ..where((t) => t.fromKpId.isIn(kpIds) | t.toKpId.isIn(kpIds)))
            .go();
        await (_db.delete(_db.masteryRecords)..where((t) => t.kpId.isIn(kpIds)))
            .go();
        await (_db.delete(_db.knowledgePoints)..where((t) => t.id.isIn(kpIds)))
            .go();
        deleted = kpIds.length;
        // 笔记树（id == noteId）此时已空，一并删掉，避免留一棵空的僵尸树。
        await (_db.delete(_db.canvases)..where((t) => t.id.equals(noteId)))
            .go();
      } else if (kpIds.isNotEmpty && removeFromTrees.isNotEmpty) {
        for (final treeId in removeFromTrees) {
          await (_db.delete(_db.canvasNodes)
                ..where((t) =>
                    t.canvasId.equals(treeId) &
                    t.targetType.equals('kp') &
                    t.targetId.isIn(kpIds)))
              .go();
          trees++;
        }
        detached = kpIds.length;
      }

      // 笔记本体软删除（version 递增，保证 LWW 判定为更新的写入）。
      final row =
          await (_db.select(_db.notes)..where((t) => t.id.equals(noteId)))
              .getSingleOrNull();
      await (_db.update(_db.notes)..where((t) => t.id.equals(noteId))).write(
        NotesCompanion(
          deletedAt: Value(DateTime.now().toUtc()),
          updatedAt: Value(DateTime.now().toUtc()),
          version: Value((row?.version ?? 0) + 1),
        ),
      );

      // 上行同步：笔记本体走墓碑；被硬删的级联行逐个入队，让远端跟着删。
      await _sync.tombstoneNote(noteId);
      if (deletePoints) {
        await _sync.hardDeleteCanvasNodes(cascadeNodes);
        await _sync.hardDeletePrerequisiteEdges(cascadeEdges);
        await _sync.hardDeleteMasteryRecords(cascadeMastery);
        await _sync.hardDeleteKnowledgePoints(cascadeKps);
        if (cascadeCanvas != null) {
          await _sync.hardDeleteCanvases(<CanvasRow>[cascadeCanvas]);
        }
      } else {
        // 只解除树关系：被摘下的 canvas_nodes 需要通知远端删除。
        await _sync.hardDeleteCanvasNodes(detachedNodes);
      }

      _log.i('删除笔记 $noteId：知识点删除 $deleted / 解除关系 $detached / 树 $trees');
      return Success(NoteDeleteSummary(
        pointsDeleted: deleted,
        pointsDetached: detached,
        treesAffected: trees,
      ));
    } on Object catch (e, s) {
      _log.e('删除笔记失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 软删除单个知识点（墓碑语义）。
  ///
  /// 与 [deleteNote] 的 `deletePoints=true`（硬删、不可恢复）不同，这里只给
  /// KP 打 `deletedAt` 墓碑，并级联**硬删**其前置边、掌握记录、知识树成员关系
  /// （这些从属数据无需独立墓碑，KP 墓碑足以驱动 LWW 同步判定为删除）。
  ///
  /// 选用软删的原因（PRD §4.1 删除语义矩阵）：让另一端同步时能识别「删除」
  /// 而非「本地没有这条数据」，且误删可在库内翻回 `deletedAt=null` 恢复。
  ///
  /// 返回受影响的知识点数量（1 或 0）。
  Future<Result<int>> softDeleteKnowledgePoint(String kpId) async {
    try {
      final row = await (_db.select(_db.knowledgePoints)
            ..where((t) => t.id.equals(kpId)))
          .getSingleOrNull();
      if (row == null) return const Success<int>(0);
      // 级联：清从属数据（硬删）。先留档（删完就没法取 id / version 了）。
      final cascadeEdges = await (_db.select(_db.prerequisiteEdges)
            ..where((t) => t.fromKpId.equals(kpId) | t.toKpId.equals(kpId)))
          .get();
      final cascadeMastery = await (_db.select(_db.masteryRecords)
            ..where((t) => t.kpId.equals(kpId)))
          .get();
      final cascadeNodes = await (_db.select(_db.canvasNodes)
            ..where((t) => t.targetType.equals('kp') & t.targetId.equals(kpId)))
          .get();
      // 级联：清从属数据（硬删）。
      await (_db.delete(_db.prerequisiteEdges)
            ..where((t) => t.fromKpId.equals(kpId) | t.toKpId.equals(kpId)))
          .go();
      await (_db.delete(_db.masteryRecords)..where((t) => t.kpId.equals(kpId)))
          .go();
      await (_db.delete(_db.canvasNodes)
            ..where((t) => t.targetType.equals('kp') & t.targetId.equals(kpId)))
          .go();
      // KP 本体软删（墓碑；version 递增配合 LWW）。
      await (_db.update(_db.knowledgePoints)..where((t) => t.id.equals(kpId)))
          .write(KnowledgePointsCompanion(
        deletedAt: Value(DateTime.now().toUtc()),
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value(row.version + 1),
      ));
      // 上行同步：KP 本体走墓碑，级联硬删的行逐个入队让远端跟着删。
      await _sync.tombstoneKnowledgePoint(kpId);
      await _sync.hardDeletePrerequisiteEdges(cascadeEdges);
      await _sync.hardDeleteMasteryRecords(cascadeMastery);
      await _sync.hardDeleteCanvasNodes(cascadeNodes);
      _log.i('软删知识点 $kpId（墓碑 + 级联清边/掌握/树成员）');
      return const Success<int>(1);
    } on Object catch (e, s) {
      _log.e('软删知识点失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  // ============ 回收站（软删墓碑的可见面）============

  /// 回收站列表：**已软删**（墓碑）的知识点，按删除时间倒序。
  ///
  /// 这是软删铁律的**唯一例外入口**：常规读路径（[allKnowledgePoints] /
  /// [pointsForNote] / [pointsByIds]）一律过滤 `deleted_at IS NULL`，墓碑行
  /// 在任何常规列表里都不可见；只有这里把墓碑行单独捞出来展示，供用户
  /// 「恢复」或「彻底删除」。
  ///
  /// 注意：这里返回的是**墓碑行本身**（`deletedAt` 非空），调用方不能把它
  /// 混进任何常规列表。
  Future<List<KnowledgePoint>> deletedKnowledgePoints() async {
    final rows = await (_db.select(_db.knowledgePoints)
          ..where((t) => t.deletedAt.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]))
        .get();
    return rows.map(_kpFromRow).toList();
  }

  /// 恢复一个被软删的知识点（回收站 → 常规列表）。
  ///
  /// 墓碑行 `deleted_at` 置空、`version++`、`updated_at` 刷新；恢复后它重新
  /// 出现在 [allKnowledgePoints] 等常规读路径里。
  ///
  /// **只恢复知识点本体**：软删时已级联硬删的前置边 / 掌握记录 / 知识树成员
  /// 关系**不会**被恢复（它们没有墓碑，无法翻回）——恢复后它是一个独立资产，
  /// 需要的话由用户重新入树。
  ///
  /// 上行同步：写库后入队一条 `SyncOp.upsert`（payload = 恢复后该行回读的
  /// row→Map，baseVersion = 新 version），远端按 LWW 判定「复活」胜出，
  /// 于是恢复能跨设备传播。
  Future<Result<KnowledgePoint>> restoreKnowledgePoint(String kpId) async {
    try {
      final row = await (_db.select(_db.knowledgePoints)
            ..where((t) => t.id.equals(kpId)))
          .getSingleOrNull();
      if (row == null) {
        return Failure(StateError('知识点不存在'));
      }
      if (row.deletedAt == null) {
        // 已经在常规列表里：幂等返回，不重复写库、也不重复入队。
        return Success(_kpFromRow(row));
      }
      await (_db.update(_db.knowledgePoints)..where((t) => t.id.equals(kpId)))
          .write(KnowledgePointsCompanion(
        deletedAt: const Value<DateTime?>(null),
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value(row.version + 1),
      ));
      // 上行同步：恢复 = 一条 upsert（payload 是恢复后该行的最终态）。
      // 远端墓碑行会被这条 upsert 覆盖回活（baseVersion = 新 version，
      // 大于墓碑时的 version）。
      await _sync.upsertKnowledgePoint(kpId);
      final restored = await (_db.select(_db.knowledgePoints)
            ..where((t) => t.id.equals(kpId)))
          .getSingleOrNull();
      if (restored == null) {
        return Failure(StateError('恢复后读取知识点失败'));
      }
      _log.i('恢复知识点 $kpId（墓碑置空，version=${restored.version}）');
      return Success(_kpFromRow(restored));
    } on Object catch (e, s) {
      _log.e('恢复知识点失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 彻底删除一个知识点（回收站 → 消失，**不可恢复**）。
  ///
  /// 与 [softDeleteKnowledgePoint]（墓碑，可恢复）不同，这里把墓碑行**物理
  /// 删除**，并清掉可能残留的从属行（前置边 / 掌握记录 / 知识树成员关系）。
  ///
  /// 上行同步：删除前先给该行留档（含 id / version），入队一条
  /// `SyncOp.delete`（payload 含 `deleted_at`），让远端也跟着删。
  Future<Result<void>> purgeKnowledgePoint(String kpId) async {
    try {
      final row = await (_db.select(_db.knowledgePoints)
            ..where((t) => t.id.equals(kpId)))
          .getSingleOrNull();
      if (row == null) {
        // 已经彻底没了：幂等返回。
        return const Success<void>(null);
      }
      // 残留的从属行（软删时通常已级联清空，这里兜底）：先留档再删，
      // 好让远端也跟着删（不留档就取不到 id / version 了）。
      final residualEdges = await (_db.select(_db.prerequisiteEdges)
            ..where((t) => t.fromKpId.equals(kpId) | t.toKpId.equals(kpId)))
          .get();
      final residualMastery = await (_db.select(_db.masteryRecords)
            ..where((t) => t.kpId.equals(kpId)))
          .get();
      final residualNodes = await (_db.select(_db.canvasNodes)
            ..where((t) =>
                t.targetType.equals('kp') & t.targetId.equals(kpId)))
          .get();
      // 彻底删除 = 比墓碑**更新**的一个状态：先把 version 顶上去再删，
      // 这样入队的 delete op 的 baseVersion 严格大于墓碑那次，远端 LWW
      // 判定「彻底删除」胜出，不会被同版本墓碑盖掉。
      final now = DateTime.now().toUtc();
      await (_db.update(_db.knowledgePoints)..where((t) => t.id.equals(kpId)))
          .write(KnowledgePointsCompanion(
        version: Value(row.version + 1),
        updatedAt: Value(now),
      ));
      // 留档（删完就取不到 id / version 了）：重新读一次，拿到带新 version 的行。
      final archived = await (_db.select(_db.knowledgePoints)
            ..where((t) => t.id.equals(kpId)))
          .getSingleOrNull();
      // 硬删：从属行 + KP 墓碑行本身。
      await (_db.delete(_db.prerequisiteEdges)
            ..where((t) => t.fromKpId.equals(kpId) | t.toKpId.equals(kpId)))
          .go();
      await (_db.delete(_db.masteryRecords)..where((t) => t.kpId.equals(kpId)))
          .go();
      await (_db.delete(_db.canvasNodes)
            ..where((t) =>
                t.targetType.equals('kp') & t.targetId.equals(kpId)))
          .go();
      await (_db.delete(_db.knowledgePoints)..where((t) => t.id.equals(kpId)))
          .go();
      // 上行同步：KP 本体走 delete（远端也删，不可恢复），残留从属行同样删。
      await _sync.hardDeleteKnowledgePoints(
        archived == null ? const <KnowledgePointRow>[] : <KnowledgePointRow>[archived],
      );
      await _sync.hardDeletePrerequisiteEdges(residualEdges);
      await _sync.hardDeleteMasteryRecords(residualMastery);
      await _sync.hardDeleteCanvasNodes(residualNodes);
      _log.i('彻底删除知识点 $kpId（物理删除，不可恢复）');
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('彻底删除知识点失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 批量彻底删除（回收站「一键清空」/ 多选「彻底删除(N)」）。
  ///
  /// 数据面 = [purgeKnowledgePoint] 的单条逻辑循环执行：每个 id 先顶
  /// version 留档，再硬删 KP 墓碑行及其残留从属行（前置边 / 掌握记录 /
  /// 知识树成员关系）。**单条失败不阻断其余**（逐条 try/catch），返回
  /// 成功处理的条数；不存在的 id 按幂等计为成功（与单条口径一致）。
  ///
  /// 上行同步：各 id 删前统一留档，删完把**整个列表**一次性交给
  /// [SyncOutboxWriter.hardDeleteKnowledgePoints]（它接受 Iterable），
  /// 每个留档行入队一条 delete op，让远端跟着删。
  Future<Result<int>> purgeKnowledgePoints(List<String> kpIds) async {
    try {
      var deleted = 0;
      final archived = <KnowledgePointRow>[];
      final residualEdges = <PrerequisiteEdgeRow>[];
      final residualMastery = <MasteryRecordRow>[];
      final residualNodes = <CanvasNodeRow>[];
      for (final kpId in kpIds) {
        try {
          final row = await (_db.select(_db.knowledgePoints)
                ..where((t) => t.id.equals(kpId)))
              .getSingleOrNull();
          if (row == null) {
            // 已经彻底没了：幂等计为成功（与单条 purgeKnowledgePoint 一致）。
            deleted += 1;
            continue;
          }
          // 残留的从属行（软删时通常已级联清空，这里兜底）：先留档再删。
          final edges = await (_db.select(_db.prerequisiteEdges)
                ..where((t) => t.fromKpId.equals(kpId) | t.toKpId.equals(kpId)))
              .get();
          final mastery = await (_db.select(_db.masteryRecords)
                ..where((t) => t.kpId.equals(kpId)))
              .get();
          final nodes = await (_db.select(_db.canvasNodes)
                ..where((t) =>
                    t.targetType.equals('kp') & t.targetId.equals(kpId)))
              .get();
          // 彻底删除 = 比墓碑更新的状态：先把 version 顶上去再删，入队
          // delete op 的 baseVersion 严格大于墓碑那次（远端 LWW 判定
          // 「彻底删除」胜出，同单条口径）。
          final now = DateTime.now().toUtc();
          await (_db.update(_db.knowledgePoints)
                ..where((t) => t.id.equals(kpId)))
              .write(KnowledgePointsCompanion(
            version: Value(row.version + 1),
            updatedAt: Value(now),
          ));
          // 留档（删完取不到 id / version）：重读带新 version 的行。
          final archivedRow = await (_db.select(_db.knowledgePoints)
                ..where((t) => t.id.equals(kpId)))
              .getSingleOrNull();
          // 硬删：从属行 + KP 墓碑行本身。
          await (_db.delete(_db.prerequisiteEdges)
                ..where((t) => t.fromKpId.equals(kpId) | t.toKpId.equals(kpId)))
              .go();
          await (_db.delete(_db.masteryRecords)
                ..where((t) => t.kpId.equals(kpId)))
              .go();
          await (_db.delete(_db.canvasNodes)
                ..where((t) =>
                    t.targetType.equals('kp') & t.targetId.equals(kpId)))
              .go();
          await (_db.delete(_db.knowledgePoints)
                ..where((t) => t.id.equals(kpId)))
              .go();
          // 删成功才留档入队（失败的行不留同步痕迹，避免远端误删）。
          if (archivedRow != null) archived.add(archivedRow);
          residualEdges.addAll(edges);
          residualMastery.addAll(mastery);
          residualNodes.addAll(nodes);
          deleted += 1;
        } on Object catch (e, s) {
          _log.e('批量彻底删除知识点失败（跳过该条，不阻断其余）: $kpId',
              error: e, stackTrace: s);
        }
      }
      // 上行同步：整个列表一次性入队（ Iterable 接口），残留从属行同样删。
      await _sync.hardDeleteKnowledgePoints(archived);
      await _sync.hardDeletePrerequisiteEdges(residualEdges);
      await _sync.hardDeleteMasteryRecords(residualMastery);
      await _sync.hardDeleteCanvasNodes(residualNodes);
      _log.i('批量彻底删除 $deleted 个知识点（物理删除，不可恢复）');
      return Success(deleted);
    } on Object catch (e, s) {
      _log.e('批量彻底删除知识点失败', error: e, stackTrace: s);
      return Failure<int>(e, s);
    }
  }

  // ============ 查询 ============

  /// 手动新建知识点（origin = 'user_manual'，锚点四件套豁免，见 PRD §4.2）。
  ///
  /// 手动知识点是产品权威来源，不要求 `source_quote` 自证；[sourceNoteId]
  /// 默认空串哨兵 ''（见 §4.3），表示该知识点不来自某篇笔记。
  Future<Result<KnowledgePoint>> createManualKnowledgePoint({
    required String name,
    KnowledgePointType type = KnowledgePointType.concept,
    String definition = '',
    String sourceNoteId = '',
  }) async {
    try {
      if (name.trim().isEmpty) {
        return Failure(ArgumentError('知识点名称不能为空'));
      }
      final kp = KnowledgePoint(
        name: name.trim(),
        type: type,
        definition: definition,
        sourceNoteId: sourceNoteId,
        sourceStart: -1,
        sourceEnd: -1,
        sourceQuote: '',
        origin: 'user_manual',
        deviceId: deviceId,
      );
      await _db.into(_db.knowledgePoints).insert(_kpInsertCompanion(kp));
      await _sync.upsertKnowledgePoint(kp.id);
      _log.i('手动新建知识点 ${kp.name}（origin=user_manual）');
      return Success(kp);
    } on Object catch (e, s) {
      _log.e('手动新建知识点失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 编辑知识点的展示性字段（名称 / 类型 / 定义 / 来源笔记）。
  ///
  /// 锚点四件套不可改（AI 提取点的出处是硬约束；手动点也不应改写锚点语义）。
  Future<Result<KnowledgePoint>> updateKpMeta(KnowledgePoint kp) async {
    try {
      final row = await (_db.select(_db.knowledgePoints)
            ..where((t) => t.id.equals(kp.id)))
          .getSingleOrNull();
      if (row == null) return Failure(StateError('知识点不存在'));
      await (_db.update(_db.knowledgePoints)..where((t) => t.id.equals(kp.id)))
          .write(KnowledgePointsCompanion(
        name: Value(kp.name),
        type: Value(kp.type.name),
        definition: Value(kp.definition),
        sourceNoteId: Value(kp.sourceNoteId),
        updatedAt: Value(DateTime.now().toUtc()),
        version: Value(row.version + 1),
      ));
      await _sync.upsertKnowledgePoint(kp.id);
      _log.i('编辑知识点 ${kp.name}');
      return Success(kp);
    } on Object catch (e, s) {
      _log.e('编辑知识点失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 置顶 / 取消置顶（用户诉求：控制哪些知识点排在列表最前）。
  ///
  /// **刻意不 bump `updated_at`**（与 [updateKpMeta] 的有意不一致）：
  /// 置顶是纯 UI 排序偏好，不是内容变更。若 bump updated_at，用户每次置顶
  /// 都会把该点推到「最近改动在上」的顶部，把真正的编辑记录淹掉，还会
  /// 误导同步对端「内容变了」。同步侧靠 version bump 触发 LWW 收敛。
  ///
  /// 幂等：目标值与当前值相同 → 不写库、不入队（连点两次不产生版本号噪音）。
  /// 已软删的点不允許置顶（墓碑行不响应 UI 操作）。
  Future<Result<void>> setPinned(String kpId, bool pinned) async {
    try {
      final row = await (_db.select(_db.knowledgePoints)
            ..where((t) => t.id.equals(kpId) & t.deletedAt.isNull()))
          .getSingleOrNull();
      if (row == null) return Failure(StateError('知识点不存在或已删除'));
      if (row.pinned == pinned) return const Success<void>(null);
      await (_db.update(_db.knowledgePoints)..where((t) => t.id.equals(kpId)))
          .write(KnowledgePointsCompanion(
        pinned: Value(pinned),
        version: Value(row.version + 1),
      ));
      await _sync.upsertKnowledgePoint(kpId);
      _log.i('${pinned ? '置顶' : '取消置顶'}知识点 $kpId');
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('设置置顶失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 某知识点涉及的前置边数量（删除时用于弹窗提示影响面，见 PRD §4.1）。
  Future<int> countPrerequisiteEdges(String kpId) async {
    final rows = await (_db.select(_db.prerequisiteEdges)
          ..where((t) => t.fromKpId.equals(kpId) | t.toKpId.equals(kpId)))
        .get();
    return rows.length;
  }

  /// 全部**未删除**知识点（按更新时间倒序）。
  ///
  /// 软删铁律：KP 一旦软删（`deletedAt` 非 null）即视为墓碑，必须过滤，
  /// 否则会泄漏到「本地库累计」、知识树、AI 助手工具等所有读路径
  ///（用户报「知识点删了本地库还看得到」的根因之一）。
  Future<List<KnowledgePoint>> allKnowledgePoints() async {
    final rows = await (_db.select(_db.knowledgePoints)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    return rows.map(_kpFromRow).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  /// 某篇笔记产生的**未删除**知识点。
  Future<List<KnowledgePoint>> pointsForNote(String noteId) async {
    final rows = await (_db.select(_db.knowledgePoints)
          ..where((t) => t.sourceNoteId.equals(noteId) & t.deletedAt.isNull()))
        .get();
    return rows.map(_kpFromRow).toList();
  }

  /// 某篇笔记产生的知识点 id（删除笔记时用于算影响面；只算未删的）。
  Future<List<String>> pointIdsOfNote(String noteId) async {
    final rows = await (_db.select(_db.knowledgePoints)
          ..where((t) => t.sourceNoteId.equals(noteId) & t.deletedAt.isNull()))
        .get();
    return rows.map((r) => r.id).toList();
  }

  /// 按 id 批量取**未删除**知识点（知识树的成员可能来自多篇笔记，不能按 sourceNote 查）。
  Future<List<KnowledgePoint>> pointsByIds(List<String> ids) async {
    if (ids.isEmpty) return const <KnowledgePoint>[];
    final rows = await (_db.select(_db.knowledgePoints)
          ..where((t) => t.id.isIn(ids) & t.deletedAt.isNull()))
        .get();
    return rows.map(_kpFromRow).toList();
  }

  /// 取该知识点所在的**第一棵**知识树 id，供作业归属（`homeworks.canvas_id`）用。
  ///
  /// 一个知识点可能同时出现在多棵树里，而作业只认**一棵**。为了**可复现**，
  /// 这里按 `canvas_id` 升序取第一条成员关系（不加排序时 drift 返回的是物理
  /// 行序，同一知识点两次调用可能落到不同的树，作业的归属就飘了）。
  /// 只认未软删的成员行（`deleted_at IS NULL`）。不在任何树里返回 null，
  /// 调用方需自行回退（作业页允许空 `canvasId`，仍可手动出题）。
  Future<String?> canvasIdForKp(String kpId) async {
    if (kpId.isEmpty) return null;
    final row = await (_db.select(_db.canvasNodes)
          ..where((t) =>
              t.targetType.equals('kp') &
              t.targetId.equals(kpId) &
              t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.canvasId)])
          ..limit(1))
        .getSingleOrNull();
    return row?.canvasId;
  }

  /// 全部未删除笔记。
  ///
  /// [folderId] 非空时按文件夹过滤：
  /// - 空字符串 `''` = 「未分类」（notebook_id 为 null 的笔记）；
  /// - 非空 = 该文件夹下的笔记。
  /// 不传 [folderId] 则返回全部未删笔记（向后兼容原调用方）。
  ///
  /// 排序：置顶笔记（pinned=true）恒在最前，其余按更新时间倒序。
  ///
  /// 软删铁律：`deletedAt` 非空的必须滤掉（与 main.dart / canvas_page 的
  /// 笔记列表同规则，此处收敛成仓库方法，供 AI 助手工具等复用）。
  Future<List<Note>> listNotes({String? folderId}) async {
    final q = _db.select(_db.notes)
      ..where((t) => t.deletedAt.isNull());
    if (folderId != null) {
      // 一行里同时写两路 where（drift 会 AND 起来）。
      q.where((t) => folderId.isEmpty
          ? t.notebookId.isNull()
          : t.notebookId.equals(folderId));
    }
    final rows = await q.get();
    return rows
        .map((r) => Note(
              id: r.id,
              notebookId: r.notebookId,
              title: r.title,
              contentMd: r.contentMd,
              contentHash: r.contentHash,
              pinned: r.pinned,
              updatedAt: r.updatedAt,
              version: r.version,
              deviceId: r.deviceId,
              deletedAt: r.deletedAt,
            ))
        .toList()
      ..sort((a, b) {
        // 置顶优先；同级按更新时间倒序。
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
  }

  /// 置顶 / 取消置顶一篇笔记（version+1、updatedAt 刷新、上行同步）。
  Future<Result<Note>> pinNote(String id, bool pinned) async {
    try {
      final existing = await (_db.select(_db.notes)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (existing == null) {
        return Failure(StateError('笔记不存在'));
      }
      final now = DateTime.now().toUtc();
      await (_db.update(_db.notes)..where((t) => t.id.equals(id))).write(
        NotesCompanion(
          pinned: Value(pinned),
          updatedAt: Value(now),
          version: Value(existing.version + 1),
        ),
      );
      await _sync.upsertNote(id);
      final updated = await (_db.select(_db.notes)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (updated == null) {
        return Failure(StateError('置顶后读取失败'));
      }
      _log.i('置顶笔记 $id = $pinned');
      return Success(_noteFromRow(updated));
    } on Object catch (e, s) {
      _log.e('置顶笔记失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  // ============ 笔记回收站（软删墓碑的可见面）============

  /// 笔记行 → 领域模型（与 [listNotes] 的映射保持一致）。
  Note _noteFromRow(NoteRow r) => Note(
        id: r.id,
        notebookId: r.notebookId,
        title: r.title,
        contentMd: r.contentMd,
        contentHash: r.contentHash,
        pinned: r.pinned,
        updatedAt: r.updatedAt,
        version: r.version,
        deviceId: r.deviceId,
        deletedAt: r.deletedAt,
      );

  /// 回收站列表：**已软删**（墓碑）的笔记，按删除时间倒序。
  ///
  /// 软删铁律的例外入口（与 [deletedKnowledgePoints] 同口径）：常规读路径
  /// （[listNotes]）过滤 `deleted_at IS NULL`，墓碑行不可见；只有这里把墓碑行
  /// 单独捞出来展示，供用户在笔记回收站里「恢复」或「彻底删除」。
  ///
  /// 注意：这里返回的是**墓碑行本身**（`deletedAt` 非空），调用方不能把它
  /// 混进任何常规列表。
  Future<List<Note>> deletedNotes() async {
    final rows = await (_db.select(_db.notes)
          ..where((t) => t.deletedAt.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]))
        .get();
    return rows.map(_noteFromRow).toList();
  }

  /// 恢复一个被软删的笔记（回收站 → 常规列表）。
  ///
  /// 墓碑行 `deleted_at` 置空、`version++`、`updated_at` 刷新；恢复后它重新
  /// 出现在 [listNotes] 等常规读路径里。上行同步入队一条 upsert（与
  /// [restoreKnowledgePoint] 同口径），让恢复跨设备传播。
  Future<Result<Note>> restoreNote(String noteId) async {
    try {
      final row = await (_db.select(_db.notes)
            ..where((t) => t.id.equals(noteId)))
          .getSingleOrNull();
      if (row == null) {
        return Failure(StateError('笔记不存在'));
      }
      if (row.deletedAt == null) {
        // 已经在常规列表里：幂等返回，不重复写库、也不重复入队。
        return Success(_noteFromRow(row));
      }
      await (_db.update(_db.notes)..where((t) => t.id.equals(noteId))).write(
        NotesCompanion(
          deletedAt: const Value<DateTime?>(null),
          updatedAt: Value(DateTime.now().toUtc()),
          version: Value(row.version + 1),
        ),
      );
      // 上行同步：恢复 = 一条 upsert（payload 是恢复后该行的最终态）。
      await _sync.upsertNote(noteId);
      final restored = await (_db.select(_db.notes)
            ..where((t) => t.id.equals(noteId)))
          .getSingleOrNull();
      if (restored == null) {
        return Failure(StateError('恢复后读取笔记失败'));
      }
      _log.i('恢复笔记 $noteId（墓碑置空，version=${restored.version}）');
      return Success(_noteFromRow(restored));
    } on Object catch (e, s) {
      _log.e('恢复笔记失败', error: e, stackTrace: s);
      return Failure(e, s);
    }
  }

  /// 彻底删除一个笔记（回收站 → 消失，**不可恢复**）。
  ///
  /// 与 [deleteNote]（软删墓碑，可恢复）不同，这里把墓碑行**物理删除**，
  /// 并清掉该笔记的附件行（`note_assets`）。
  ///
  /// ⚠️ 同步缺口：当前 [SyncOutboxWriter] 只提供 `upsertNote`，**没有**
  /// `hardDeleteNotes`；因此这里只做**本地**物理删除，跨设备回收待同步层补齐
  /// （见下方 `TODO(sync)`）。不级联知识点：它们在 [deleteNote] 软删时已按
  /// `deletePoints` 决定硬删或保留，此处回收站只对付笔记本体。
  Future<Result<void>> purgeNote(String noteId) async {
    try {
      final row = await (_db.select(_db.notes)
            ..where((t) => t.id.equals(noteId)))
          .getSingleOrNull();
      if (row == null) {
        // 已经彻底没了：幂等返回。
        return const Success<void>(null);
      }
      // 彻底删除 = 比墓碑更新的状态：先把 version 顶上去再删，使删除意图
      // 在跨设备同步时严格晚于墓碑（一旦同步层补齐 notes 物理删除入队）。
      final now = DateTime.now().toUtc();
      await (_db.update(_db.notes)..where((t) => t.id.equals(noteId))).write(
        NotesCompanion(
          version: Value(row.version + 1),
          updatedAt: Value(now),
        ),
      );
      // 硬删：附件行 + 笔记墓碑行本身。
      await (_db.delete(_db.noteAssets)
            ..where((t) => t.noteId.equals(noteId)))
          .go();
      await (_db.delete(_db.notes)..where((t) => t.id.equals(noteId))).go();
      // TODO(sync): enqueue notes hard-delete when sync writer adds hardDeleteNotes.
      // 目前 SyncOutboxWriter 仅有 upsertNote / hardDeleteNoteAssets，没有
      // hardDeleteNotes，跨设备回收待同步层补齐。
      _log.i('彻底删除笔记 $noteId（物理删除，不可恢复）');
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('彻底删除笔记失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 批量彻底删除（回收站「清空」）。
  ///
  /// 数据面 = [purgeNote] 的单条逻辑循环执行。单条失败不阻断其余，返回
  /// 成功处理的条数；不存在的 id 按幂等计为成功（与单条口径一致）。
  Future<Result<int>> purgeNotes(List<String> ids) async {
    var deleted = 0;
    for (final id in ids) {
      final res = await purgeNote(id);
      if (res is Success<void>) deleted += 1;
    }
    return Success<int>(deleted);
  }

  Future<Note?> getNote(String id) async {
    final row = await (_db.select(_db.notes)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return Note(
      id: row.id,
      notebookId: row.notebookId,
      title: row.title,
      contentMd: row.contentMd,
      pinned: row.pinned,
      contentHash: row.contentHash,
      updatedAt: row.updatedAt,
      version: row.version,
      deviceId: row.deviceId,
      deletedAt: row.deletedAt,
    );
  }

  /// 某知识点的**后继**（依赖它的知识点）id 列表。
  Future<List<String>> successorsOf(String kpId) async {
    final rows = await (_db.select(_db.prerequisiteEdges)
          ..where((t) => t.fromKpId.equals(kpId)))
        .get();
    return rows.map((r) => r.toKpId).toList();
  }

  /// 某知识点的**前置**（它依赖的知识点）id 列表。
  Future<List<String>> prerequisitesOf(String kpId) async {
    final rows = await (_db.select(_db.prerequisiteEdges)
          ..where((t) => t.toKpId.equals(kpId)))
          .get();
    return rows.map((r) => r.fromKpId).toList();
  }

  /// 在全局前置图里判断 [start] 是否能沿「后继」走到 [target]。
  ///
  /// 用于连线防环：若 [to] 能抵达 [from]，则加 `from→to` 会成环（学习环路）。
  /// 每个知识点最多一个后继（见 [addManualPrerequisiteEdge]），所以后继链是简单
  /// 路径；这里仍用 BFS + visited 防御可能存在多后继的脏数据。
  Future<bool> _canReach(String start, String target) async {
    if (start == target) return true;
    final visited = <String>{};
    final queue = <String>[start];
    while (queue.isNotEmpty) {
      final cur = queue.removeAt(0);
      if (cur == target) return true;
      if (!visited.add(cur)) continue;
      queue.addAll(await successorsOf(cur));
    }
    return false;
  }

  /// 把一组知识点整体平移 (dx, dy)（拖动分组框时调用）。
  ///
  /// 只平移**已固化过位置**的成员（canvas_nodes 里有行）；没固化过的交给布局引擎，
  /// 暂不平移（避免以 (0,0) 为基准凭空生成坐标）。version 递增以配合 LWW 同步。
  Future<Result<void>> moveGroupMembers(
    String canvasId,
    List<String> memberIds,
    double dx,
    double dy,
  ) async {
    try {
      for (final kpId in memberIds) {
        final id = '$canvasId:$kpId';
        final existing = await (_db.select(_db.canvasNodes)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        if (existing == null) continue; // 没固化过位置：交给布局引擎
        await _db
            .into(_db.canvasNodes)
            .insertOnConflictUpdate(CanvasNodesCompanion(
              id: Value(id),
              canvasId: Value(canvasId),
              targetType: const Value('kp'),
              targetId: Value(kpId),
              x: Value(existing.x + dx),
              y: Value(existing.y + dy),
              updatedAt: Value(DateTime.now().toUtc()),
              version: Value(existing.version + 1),
              deviceId: Value(deviceId),
            ));
        await _sync.upsertCanvasNode(id);
      }
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('平移分组成员失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 当前掌握状态（取最新一条记录）。
  Future<MasteryStatus> currentMastery(String kpId) async {
    final rows = await (_db.select(_db.masteryRecords)
          ..where((t) => t.kpId.equals(kpId))
          ..orderBy([(t) => OrderingTerm.desc(t.version)])
          ..limit(1))
        .get();
    if (rows.isEmpty) return MasteryStatus.unknown;
    return MasteryStatus.parse(rows.first.status);
  }

  // ============ 内部实现 ============

  /// 新建知识点 → 待插入行的**唯一**转换入口。
  ///
  /// 收敛成一处是为了 `createdAt`：该列 v5 才加、且是 nullable（历史行由迁移
  /// 回填 `updated_at`），新行必须在**入库时**显式写入，否则「新数据反而没有
  /// 创建时间」。放在这里，任何写路径都不会漏。
  KnowledgePointsCompanion _kpInsertCompanion(KnowledgePoint kp) =>
      KnowledgePointsCompanion(
        id: Value(kp.id),
        notebookId: Value(kp.notebookId),
        name: Value(kp.name),
        type: Value(kp.type.name),
        definition: Value(kp.definition),
        sourceNoteId: Value(kp.sourceNoteId),
        sourceStart: Value(kp.sourceStart),
        sourceEnd: Value(kp.sourceEnd),
        sourceQuote: Value(kp.sourceQuote),
        origin: Value(kp.origin),
        confidence: Value(kp.confidence),
        pinned: Value(kp.pinned),
        createdAt: Value(kp.createdAt ?? DateTime.now().toUtc()),
        updatedAt: Value(kp.updatedAt),
        version: Value(kp.version),
        deviceId: Value(kp.deviceId),
        deletedAt: Value(kp.deletedAt),
      );

  /// 在原文中定位 quote，返回 [start, end) 字符区间；未找到返回 null。
  ({int start, int end})? _locateQuote(String content, String quote) {
    if (quote.isEmpty || content.isEmpty) return null;
    final idx = content.indexOf(quote);
    if (idx < 0) return null;
    return (start: idx, end: idx + quote.length);
  }

  Future<void> _writeMastery(
    String kpId,
    MasteryStatus status,
    MasterySource source,
  ) async {
    final nextVersion = await _nextMasteryVersion(kpId);
    final id = newUlid();
    await _db.into(_db.masteryRecords).insert(MasteryRecordsCompanion(
          id: Value(id),
          kpId: Value(kpId),
          status: Value(status.name),
          source: Value(source.name),
          updatedAt: Value(DateTime.now().toUtc()),
          version: Value(nextVersion),
          deviceId: Value(deviceId),
        ));
    // 上行同步：mastery_records 是 append-only，每次写入都是一条新行。
    await _sync.upsertMasteryRecord(id);
  }

  /// 计算 [kpId] 下一次写入的 version（max+1；无则 1）。
  ///
  /// MasteryRecords 是 append-only；同毫秒连写多条时 `updatedAt` 排序不稳定
  /// （sqlite 默认按行 id 退而求其次），所以权威排序键改用 `version`。
  /// 跨设备同步时 `version` 越大越赢（LWW 语义天然兼容）。
  Future<int> _nextMasteryVersion(String kpId) async {
    final maxVer = await (_db.selectOnly(_db.masteryRecords)
          ..addColumns([_db.masteryRecords.version.max()])
          ..where(_db.masteryRecords.kpId.equals(kpId)))
        .map((row) => row.read(_db.masteryRecords.version.max()))
        .getSingleOrNull();
    return (maxVer ?? 0) + 1;
  }

  /// 级联降级：沿「后继」方向 BFS，把每个后继降一档，直到无变化或达深度上限。
  ///
  /// 用 visited 集合防止前置图成环时死循环。
  Future<int> _cascadeDowngrade(String rootKpId, {int maxDepth = 32}) async {
    final visited = <String>{rootKpId};
    final queue = <String>[rootKpId];
    var changed = 0;
    var depth = 0;

    while (queue.isNotEmpty && depth < maxDepth) {
      final current = queue.removeAt(0);
      final succs = await successorsOf(current);
      for (final s in succs) {
        if (!visited.add(s)) continue; // 成环保护
        final cur = await currentMastery(s);
        final next = cur.downgraded;
        if (next != cur) {
          await _writeMastery(s, next, MasterySource.tutorCascade);
          changed++;
        }
        queue.add(s);
      }
      depth++;
    }
    return changed;
  }

  KnowledgePoint _kpFromRow(KnowledgePointRow row) => KnowledgePoint(
        id: row.id,
        notebookId: row.notebookId,
        name: row.name,
        type: KnowledgePointType.parse(row.type),
        definition: row.definition,
        sourceNoteId: row.sourceNoteId,
        sourceStart: row.sourceStart,
        sourceEnd: row.sourceEnd,
        sourceQuote: row.sourceQuote,
        origin: row.origin,
        confidence: row.confidence,
        updatedAt: row.updatedAt,
        version: row.version,
        deviceId: row.deviceId,
        deletedAt: row.deletedAt,
        pinned: row.pinned,
        createdAt: row.createdAt,
      );

  static String _preview(String s) =>
      s.length <= 20 ? s : '${s.substring(0, 20)}…';
}
