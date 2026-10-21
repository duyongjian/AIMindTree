/// 核心实体模型（ARCHITECTURE §5.1 / §11）。
///
/// 这些是**纯 Dart 领域对象**，不依赖 Drift，便于单元测试与未来替换持久化。
/// 与 Drift 行的互转放在 Repository / DAO 层。
library;

import '../../core/id.dart';

/// 知识点类型（PRD）。
enum KnowledgePointType {
  concept,
  formula,
  theorem,
  method,
  fact,
  myth;

  /// 中文标签（UI 展示 + 对 LLM 输出容错）。
  String get label => switch (this) {
        KnowledgePointType.concept => '概念',
        KnowledgePointType.formula => '公式',
        KnowledgePointType.theorem => '定理',
        KnowledgePointType.method => '方法',
        KnowledgePointType.fact => '事实',
        KnowledgePointType.myth => '误区',
      };

  /// 从 name 或中文标签解析，未知回落 concept（LLM 输出不可信，必须容错）。
  static KnowledgePointType parse(String? raw) {
    if (raw == null || raw.isEmpty) return KnowledgePointType.concept;
    final v = raw.trim();
    for (final e in KnowledgePointType.values) {
      if (e.name == v || e.label == v) return e;
    }
    return KnowledgePointType.concept;
  }
}

/// 掌握状态（★级联降级的基础）。
enum MasteryStatus {
  unknown,
  notMastered,
  learning,
  mastered,
  abandoned;

  String get label => switch (this) {
        MasteryStatus.unknown => '未评估',
        MasteryStatus.notMastered => '未掌握',
        MasteryStatus.learning => '学习中',
        MasteryStatus.mastered => '已掌握',
        MasteryStatus.abandoned => '已放弃',
      };

  static MasteryStatus parse(String? raw) {
    if (raw == null || raw.isEmpty) return MasteryStatus.unknown;
    for (final e in MasteryStatus.values) {
      if (e.name == raw) return e;
    }
    return MasteryStatus.unknown;
  }

  /// 级联降级：往「更不掌握」方向退一档（PRD：标未掌握 → 依赖它的后继级联降级）。
  MasteryStatus get downgraded => switch (this) {
        MasteryStatus.mastered => MasteryStatus.learning,
        MasteryStatus.learning => MasteryStatus.notMastered,
        _ => MasteryStatus.notMastered,
      };
}

/// 掌握状态来源。
enum MasterySource {
  self,
  ai,
  tutorCascade;

  static MasterySource parse(String? raw) {
    for (final e in MasterySource.values) {
      if (e.name == raw) return e;
    }
    return MasterySource.self;
  }
}

/// 笔记。
class Note {
  Note({
    String? id,
    this.notebookId,
    this.title = '',
    this.contentMd = '',
    this.contentHash = '',
    DateTime? updatedAt,
    this.version = 1,
    this.deviceId = '',
    this.deletedAt,
  })  : id = id ?? newUlid(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String id;
  final String? notebookId;
  final String title;
  final String contentMd;
  final String contentHash;
  final DateTime updatedAt;
  final int version;
  final String deviceId;
  final DateTime? deletedAt;

  Note copyWith({
    String? title,
    String? contentMd,
    String? contentHash,
    DateTime? updatedAt,
    int? version,
  }) =>
      Note(
        id: id,
        notebookId: notebookId,
        title: title ?? this.title,
        contentMd: contentMd ?? this.contentMd,
        contentHash: contentHash ?? this.contentHash,
        updatedAt: updatedAt ?? this.updatedAt,
        version: version ?? this.version,
        deviceId: deviceId,
        deletedAt: deletedAt,
      );
}

/// 知识点（★必须带来源锚点）。
class KnowledgePoint {
  KnowledgePoint({
    String? id,
    this.notebookId,
    required this.name,
    this.type = KnowledgePointType.concept,
    this.definition = '',
    required this.sourceNoteId,
    required this.sourceStart,
    required this.sourceEnd,
    required this.sourceQuote,
    this.origin = 'ai_extract',
    this.confidence = 0.0,
    this.mastery = MasteryStatus.unknown,
    DateTime? updatedAt,
    this.version = 1,
    this.deviceId = '',
    this.deletedAt,
  })  : id = id ?? newUlid(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String id;
  final String? notebookId;
  final String name;
  final KnowledgePointType type;
  final String definition;

  // ---- 锚点四件套（★无锚点 = 幻觉，Repository 入库前剔除）----
  final String sourceNoteId;
  final int sourceStart;
  final int sourceEnd;
  final String sourceQuote;

  final String origin;
  final double confidence;

  /// 当前掌握状态（冗余展示用，权威数据在 mastery_records）。
  final MasteryStatus mastery;

  final DateTime updatedAt;
  final int version;
  final String deviceId;
  final DateTime? deletedAt;

  KnowledgePoint copyWith({
    String? name,
    KnowledgePointType? type,
    MasteryStatus? mastery,
    String? definition,
    double? confidence,
    String? sourceNoteId,
    DateTime? updatedAt,
  }) =>
      KnowledgePoint(
        id: id,
        notebookId: notebookId,
        name: name ?? this.name,
        type: type ?? this.type,
        definition: definition ?? this.definition,
        sourceNoteId: sourceNoteId ?? this.sourceNoteId,
        sourceStart: sourceStart,
        sourceEnd: sourceEnd,
        sourceQuote: sourceQuote,
        origin: origin,
        confidence: confidence ?? this.confidence,
        mastery: mastery ?? this.mastery,
        updatedAt: updatedAt ?? this.updatedAt,
        version: version,
        deviceId: deviceId,
        deletedAt: deletedAt,
      );
}

/// 前置关系边：from 是 to 的前置（先学 from，才能学 to）。
class PrerequisiteEdge {
  PrerequisiteEdge({
    String? id,
    required this.fromKpId,
    required this.toKpId,
    this.reason = '',
    this.origin = 'ai',
    this.confidence = 0.0,
  }) : id = id ?? newUlid();

  final String id;
  final String fromKpId;
  final String toKpId;
  final String reason;
  final String origin;
  final double confidence;
}

/// 掌握状态记录。
class MasteryRecord {
  MasteryRecord({
    String? id,
    required this.kpId,
    required this.status,
    this.source = MasterySource.self,
    DateTime? updatedAt,
  })  : id = id ?? newUlid(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String id;
  final String kpId;
  final MasteryStatus status;
  final MasterySource source;
  final DateTime updatedAt;
}
