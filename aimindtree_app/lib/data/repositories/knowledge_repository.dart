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

  static final AppLog _log = AppLog('knowledge_repo');

  // ============ 写入 ============

  /// 保存（upsert）一条笔记。
  Future<Result<Note>> saveNote(Note note) async {
    try {
      await _db
          .into(_db.notes)
          .insertOnConflictUpdate(NotesCompanion(
            id: Value(note.id),
            notebookId: Value(note.notebookId),
            title: Value(note.title),
            contentMd: Value(note.contentMd),
            contentHash: Value(note.contentHash),
            updatedAt: Value(note.updatedAt),
            version: Value(note.version),
            deviceId: Value(note.deviceId),
            deletedAt: Value(note.deletedAt),
          ));
      return Success(note);
    } on Object catch (e, s) {
      _log.e('保存笔记失败', error: e, stackTrace: s);
      return Failure(e, s);
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
        await _db.into(_db.knowledgePoints).insert(KnowledgePointsCompanion(
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
              updatedAt: Value(kp.updatedAt),
              version: Value(kp.version),
              deviceId: Value(kp.deviceId),
              deletedAt: Value(kp.deletedAt),
            ));
        saved.add(kp);
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
      await (_db.delete(_db.prerequisiteEdges)..where((t) => t.id.equals(id)))
          .go();
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
  Future<Result<void>> saveNodePosition(
    String canvasId,
    String kpId,
    double x,
    double y,
  ) async {
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
            updatedAt: Value(DateTime.now().toUtc()),
            version: Value((existing?.version ?? 0) + 1),
            deviceId: Value(deviceId),
          ));
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('保存节点位置失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
  }

  /// 清空某块画布上已保存的节点位置（「重新布局」用）。
  ///
  /// 位置固化后一直有效，用户把图拖乱需要一个一键恢复自动布局的入口。
  Future<Result<void>> clearNodePositions(String canvasId) async {
    try {
      await (_db.delete(_db.canvasNodes)
            ..where((t) =>
                t.canvasId.equals(canvasId) & t.targetType.equals('kp')))
          .go();
      return const Success<void>(null);
    } on Object catch (e, s) {
      _log.e('清空节点位置失败', error: e, stackTrace: s);
      return Failure<void>(e, s);
    }
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

  // ============ 查询 ============

  Future<List<KnowledgePoint>> allKnowledgePoints() async {
    final rows = await _db.select(_db.knowledgePoints).get();
    return rows.map(_kpFromRow).toList();
  }

  Future<List<KnowledgePoint>> pointsForNote(String noteId) async {
    final rows = await (_db.select(_db.knowledgePoints)
          ..where((t) => t.sourceNoteId.equals(noteId)))
        .get();
    return rows.map(_kpFromRow).toList();
  }

  /// 某篇笔记产生的知识点 id（删除笔记时用于算影响面）。
  Future<List<String>> pointIdsOfNote(String noteId) async {
    final rows = await (_db.select(_db.knowledgePoints)
          ..where((t) => t.sourceNoteId.equals(noteId)))
        .get();
    return rows.map((r) => r.id).toList();
  }

  /// 按 id 批量取知识点（知识树的成员可能来自多篇笔记，不能按 sourceNote 查）。
  Future<List<KnowledgePoint>> pointsByIds(List<String> ids) async {
    if (ids.isEmpty) return const <KnowledgePoint>[];
    final rows = await (_db.select(_db.knowledgePoints)
          ..where((t) => t.id.isIn(ids)))
        .get();
    return rows.map(_kpFromRow).toList();
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
    await _db.into(_db.masteryRecords).insert(MasteryRecordsCompanion(
          id: Value(newUlid()),
          kpId: Value(kpId),
          status: Value(status.name),
          source: Value(source.name),
          updatedAt: Value(DateTime.now().toUtc()),
          version: Value(nextVersion),
          deviceId: Value(deviceId),
        ));
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
      );

  static String _preview(String s) =>
      s.length <= 20 ? s : '${s.substring(0, 20)}…';
}
