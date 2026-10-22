/// 行 → 同步 payload 的**唯一映射表**（snake_case 列名）。
///
/// 同步的 payload 键必须是**表列名**（snake_case），不能是 Dart 字段名：
/// - 写入侧：本地仓储写完一行 → 用本文件的 `*RowToMap` 生成 payload → 进 outbox；
/// - 读取侧：`sync_engine.dart` 的 `*FromMap` 按同样的键还原成 Drift 行。
///
/// 两份清单（这里 / `sync_engine.dart`）必须成对维护。改列名时两边一起改。
///
/// DateTime 列（`updated_at` / `deleted_at`）在这里保持 `DateTime` 类型，
/// 由 `sync_json.dart` 的编码器负责转成 ISO 8601 字符串。
library;

import '../db/drift_database.dart';

/// notebooks 行 → payload。
Map<String, dynamic> notebookRowToMap(NotebookRow r) => {
      'id': r.id,
      'name': r.name,
      'parent_id': r.parentId,
      'sort_order': r.sortOrder,
      'updated_at': r.updatedAt,
      'version': r.version,
      'device_id': r.deviceId,
      'deleted_at': r.deletedAt,
    };

/// notes 行 → payload。
Map<String, dynamic> noteRowToMap(NoteRow r) => {
      'id': r.id,
      'notebook_id': r.notebookId,
      'title': r.title,
      'content_md': r.contentMd,
      'updated_at': r.updatedAt,
      'version': r.version,
      'device_id': r.deviceId,
      'deleted_at': r.deletedAt,
    };

/// knowledge_points 行 → payload。
Map<String, dynamic> knowledgePointRowToMap(KnowledgePointRow r) => {
      'id': r.id,
      'notebook_id': r.notebookId,
      'name': r.name,
      'type': r.type,
      'definition': r.definition,
      'source_note_id': r.sourceNoteId,
      'source_start': r.sourceStart,
      'source_end': r.sourceEnd,
      'source_quote': r.sourceQuote,
      'origin': r.origin,
      'confidence': r.confidence,
      'updated_at': r.updatedAt,
      'version': r.version,
      'device_id': r.deviceId,
      'deleted_at': r.deletedAt,
    };

/// prerequisite_edges 行 → payload。
Map<String, dynamic> prerequisiteEdgeRowToMap(PrerequisiteEdgeRow r) => {
      'id': r.id,
      'from_kp_id': r.fromKpId,
      'to_kp_id': r.toKpId,
      'reason': r.reason,
      'origin': r.origin,
      'confidence': r.confidence,
      'updated_at': r.updatedAt,
      'version': r.version,
      'device_id': r.deviceId,
      'deleted_at': r.deletedAt,
    };

/// mastery_records 行 → payload。
Map<String, dynamic> masteryRecordRowToMap(MasteryRecordRow r) => {
      'id': r.id,
      'kp_id': r.kpId,
      'status': r.status,
      'source': r.source,
      'updated_at': r.updatedAt,
      'version': r.version,
      'device_id': r.deviceId,
      'deleted_at': r.deletedAt,
    };

/// cards 行 → payload。
Map<String, dynamic> cardRowToMap(CardRow r) => {
      'id': r.id,
      'type': r.type,
      'source_ref': r.sourceRef,
      'parent_card_id': r.parentCardId,
      'regenerated_from_id': r.regeneratedFromId,
      'content_md': r.contentMd,
      'session_id': r.sessionId,
      'model_id': r.modelId,
      'updated_at': r.updatedAt,
      'version': r.version,
      'device_id': r.deviceId,
      'deleted_at': r.deletedAt,
    };

/// canvases 行 → payload。
Map<String, dynamic> canvasRowToMap(CanvasRow r) => {
      'id': r.id,
      'notebook_id': r.notebookId,
      'name': r.name,
      'viewport': r.viewport,
      'updated_at': r.updatedAt,
      'version': r.version,
      'device_id': r.deviceId,
      'deleted_at': r.deletedAt,
    };

/// canvas_nodes 行 → payload。
Map<String, dynamic> canvasNodeRowToMap(CanvasNodeRow r) => {
      'id': r.id,
      'canvas_id': r.canvasId,
      'target_type': r.targetType,
      'target_id': r.targetId,
      'x': r.x,
      'y': r.y,
      'w': r.w,
      'h': r.h,
      'z': r.z,
      'collapsed': r.collapsed,
      'updated_at': r.updatedAt,
      'version': r.version,
      'device_id': r.deviceId,
      'deleted_at': r.deletedAt,
    };

/// canvas_edges 行 → payload。
Map<String, dynamic> canvasEdgeRowToMap(CanvasEdgeRow r) => {
      'id': r.id,
      'canvas_id': r.canvasId,
      'from_node_id': r.fromNodeId,
      'to_node_id': r.toNodeId,
      'edge_type': r.edgeType,
      'prereq_edge_id': r.prereqEdgeId,
      'updated_at': r.updatedAt,
      'version': r.version,
      'device_id': r.deviceId,
      'deleted_at': r.deletedAt,
    };

/// ai_sessions 行 → payload。
Map<String, dynamic> aiSessionRowToMap(AiSessionRow r) => {
      'id': r.id,
      'type': r.type,
      'target_ref': r.targetRef,
      'title': r.title,
      'kp_id': r.kpId,
      'updated_at': r.updatedAt,
      'version': r.version,
      'device_id': r.deviceId,
      'deleted_at': r.deletedAt,
    };

/// ai_messages 行 → payload。
Map<String, dynamic> aiMessageRowToMap(AiMessageRow r) => {
      'id': r.id,
      'session_id': r.sessionId,
      'role': r.role,
      'content_md': r.contentMd,
      'tokens': r.tokens,
      'latency_ms': r.latencyMs,
      'model_id': r.modelId,
      'updated_at': r.updatedAt,
      'version': r.version,
      'device_id': r.deviceId,
      'deleted_at': r.deletedAt,
    };
