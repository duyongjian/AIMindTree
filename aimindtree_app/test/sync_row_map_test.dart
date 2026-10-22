/// 同步 payload **键集对齐护栏**（13 张表）。
///
/// 为什么需要这个护栏：同步 payload 是**按键名**存的 JSON。
/// `sync_row_map.dart` 少写一个键（或 `sync_engine.dart` 的 `*FromMap`
/// 读错一个键名），对端 pull 时读不到 → **静默回落默认值 → 数据在其他设备
/// 上无声丢失，且不报错**。这是最难发现的一类 bug，只能靠断言挡住。
///
/// 本文件两道防线：
/// 1. **契约层**：[kSyncTableKeys] 是 13 张表 payload 键集的唯一真相源，
///    任何一处增删键都必须同步改这里（否则测试红）。
/// 2. **源码扫描**：直接从 `sync_row_map.dart`（写侧）与
///    `sync_engine.dart`（读侧）抽取每个 `*RowToMap` / `*FromMap` 用到的键，
///    断言二者**严格相等**——写侧多写了键（读侧没读）或读侧读了写侧没有的
///    键（永远读到 null）都会红。
/// 3. **闭环落库**：给每张表灌一份「每个键都是非默认值」的 payload，
///    走 JSON 往返 → pull → 落库 → 逐键比对。键名错一个，落库值就会
///    悄悄变成默认值 → 断言红。这一道能挡住扫描层看不出的语义错位。
library;

import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/sync/sync_api.dart';
import 'package:aimindtree_app/data/sync/sync_engine.dart';
import 'package:aimindtree_app/data/sync/sync_json.dart';
import 'package:aimindtree_app/data/sync/sync_outbox.dart';
import 'package:aimindtree_app/data/sync/sync_types.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 13 张同步表的 payload 键集契约（**唯一真相源**）。
///
/// 键名一律是 drift 的 **snake_case 列名**，逐字取自 drift 生成产物
/// `lib/data/db/drift_database.g.dart`（`*Companion.custom` 的列名）。
/// 改列名时：`sync_row_map.dart` + `sync_engine.dart` + 本常量，三处一起改。
const Map<String, Set<String>> kSyncTableKeys = <String, Set<String>>{
  'notebooks': <String>{
    'id',
    'name',
    'parent_id',
    'sort_order',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  'notes': <String>{
    'id',
    'notebook_id',
    'title',
    'content_md',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  'knowledge_points': <String>{
    'id',
    'notebook_id',
    'name',
    'type',
    'definition',
    'source_note_id',
    'source_start',
    'source_end',
    'source_quote',
    'origin',
    'confidence',
    // v5 新增：置顶 + 创建时间（少写 = 跨设备静默丢失）。
    'pinned',
    'created_at',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  'prerequisite_edges': <String>{
    'id',
    'from_kp_id',
    'to_kp_id',
    'reason',
    'origin',
    'confidence',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  'mastery_records': <String>{
    'id',
    'kp_id',
    'status',
    'source',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  'cards': <String>{
    'id',
    'type',
    'source_ref',
    'parent_card_id',
    'regenerated_from_id',
    'content_md',
    'session_id',
    'model_id',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  'canvases': <String>{
    'id',
    'notebook_id',
    'name',
    'viewport',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  'canvas_nodes': <String>{
    'id',
    'canvas_id',
    'target_type',
    'target_id',
    'x',
    'y',
    'w',
    'h',
    'z',
    'collapsed',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  'canvas_edges': <String>{
    'id',
    'canvas_id',
    'from_node_id',
    'to_node_id',
    'edge_type',
    'prereq_edge_id',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  'ai_sessions': <String>{
    'id',
    'type',
    'target_ref',
    'title',
    'kp_id',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  'ai_messages': <String>{
    'id',
    'session_id',
    'role',
    'content_md',
    'tokens',
    'latency_ms',
    'model_id',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  // v5 新增表 1：知识点分组。
  'kp_groups': <String>{
    'id',
    'canvas_id',
    'name',
    'order_index',
    'foundational_level',
    // 整段成员 JSON 作为一个字符串同步，**同步层不拆开解析**。
    'members_json',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
  // v5 新增表 2：笔记附件。
  'note_assets': <String>{
    'id',
    'note_id',
    'name',
    'mime',
    'sha1',
    'bytes',
    // ⚠️ 是 `data_base64`（列名），**不是** `dataBase64`（Dart 字段名）。
    'data_base64',
    'updated_at',
    'version',
    'device_id',
    'deleted_at',
  },
};

/// 表名 → (写侧 `*RowToMap` 函数名, 读侧 `*FromMap` 函数名)。
const Map<String, (String, String)> kSyncTableAdapters =
    <String, (String, String)>{
  'notebooks': ('notebookRowToMap', '_notebookFromMap'),
  'notes': ('noteRowToMap', '_noteFromMap'),
  'knowledge_points': ('knowledgePointRowToMap', '_kpFromMap'),
  'prerequisite_edges': ('prerequisiteEdgeRowToMap', '_edgeFromMap'),
  'mastery_records': ('masteryRecordRowToMap', '_masteryFromMap'),
  'cards': ('cardRowToMap', '_cardFromMap'),
  'canvases': ('canvasRowToMap', '_canvasFromMap'),
  'canvas_nodes': ('canvasNodeRowToMap', '_canvasNodeFromMap'),
  'canvas_edges': ('canvasEdgeRowToMap', '_canvasEdgeFromMap'),
  'ai_sessions': ('aiSessionRowToMap', '_aiSessionFromMap'),
  'ai_messages': ('aiMessageRowToMap', '_aiMessageFromMap'),
  'kp_groups': ('kpGroupRowToMap', '_kpGroupFromMap'),
  'note_assets': ('noteAssetRowToMap', '_noteAssetFromMap'),
};

// ============ 源码扫描工具 ============

/// 定位包内文件：`flutter test` 的 cwd 是包根目录，但 IDE 单跑时可能不是，
/// 因此按「相对路径 → 包根 → 脚本所在目录的父目录」依次尝试。
File _locate(String rel) {
  final candidates = <String>[
    rel,
    '../$rel',
    '${Directory.current.path}/$rel',
  ];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f;
  }
  final scriptDir = File.fromUri(Platform.script).parent;
  final fromScript = File('${scriptDir.parent.path}/$rel');
  if (fromScript.existsSync()) return fromScript;
  throw StateError('找不到源文件 $rel（cwd=${Directory.current.path}）');
}

/// 抽取 `sync_row_map.dart` 里每个 `*RowToMap` 写出的键集。
Map<String, Set<String>> _extractWriteKeys(String src) {
  final out = <String, Set<String>>{};
  final startRe =
      RegExp(r'^Map<String, dynamic> (\w+)\(\w+ r\) => \{$');
  final keyRe = RegExp(r"^\s*'([a-z0-9_]+)':");
  String? current;
  final keys = <String>{};
  for (final line in src.split('\n')) {
    final m = startRe.firstMatch(line);
    if (m != null) {
      current = m.group(1);
      keys.clear();
      continue;
    }
    if (current == null) continue;
    final km = keyRe.firstMatch(line);
    if (km != null) keys.add(km.group(1)!);
    if (line.trim() == '};') {
      out[current] = keys.toSet();
      current = null;
    }
  }
  return out;
}

/// 抽取 `sync_engine.dart` 里每个 `*FromMap` 读取的键集。
Map<String, Set<String>> _extractReadKeys(String src) {
  final out = <String, Set<String>>{};
  final startRe = RegExp(
    r'^\s+\w*Companion (_[A-Za-z0-9]+FromMap)\(Map<String, dynamic> p\)',
  );
  final keyRe = RegExp(r"p\['([a-z0-9_]+)'\]");
  String? current;
  final keys = <String>{};
  for (final line in src.split('\n')) {
    final m = startRe.firstMatch(line);
    if (m != null) {
      current = m.group(1);
      keys.clear();
      continue;
    }
    if (current == null) continue;
    for (final km in keyRe.allMatches(line)) {
      keys.add(km.group(1)!);
    }
    // 函数体以独占一行的 `);` 收尾。
    if (line.trim() == ');') {
      out[current] = keys.toSet();
      current = null;
    }
  }
  return out;
}

// ============ 落库探针 ============

/// 一张表的「非默认值探测」用例。
class _KeyProbe {
  const _KeyProbe({
    required this.table,
    required this.id,
    required this.payload,
    required this.read,
  });

  final String table;

  /// 探测行的主键（各表不同，避免互相干扰）。
  final String id;

  /// 除 `updated_at` / `version` / `device_id` 外的键 → **非默认**探测值。
  ///
  /// 每个值都必须刻意避开该列的默认值，否则「键名写错 → 回落默认值」
  /// 这种静默丢失就检测不出来。
  final Map<String, Object?> payload;

  /// 落库后按 payload 键名取回实际值。
  final Future<Map<String, Object?>> Function(AppDatabase db, String id) read;
}

/// 探测用的固定时刻（毫秒为 0：drift 的 DateTime 列按秒存储）。
final DateTime _probeTime = DateTime.utc(2026, 3, 4, 5, 6, 7);
final DateTime _probeDeletedAt = DateTime.utc(2026, 3, 4, 5, 6, 8);
final DateTime _probeCreatedAt = DateTime.utc(2025, 12, 31, 23, 59, 58);
const int _probeVersion = 42;
const String _probeDeviceId = 'remote-probe-device';

// 注意：不能用 const——元素里的 read 是闭包、deleted_at 等探测值是 final 的
// DateTime， Dart 的 const 列表要求元素可常量求值。
final List<_KeyProbe> _probes = <_KeyProbe>[
  _KeyProbe(
    table: 'notebooks',
    id: 'probe-notebook',
    payload: <String, Object?>{
      'id': 'probe-notebook',
      'name': 'probe-name',
      'parent_id': 'probe-parent',
      'sort_order': 7,
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r = await (db.select(db.notebooks)..where((t) => t.id.equals(id)))
          .getSingle();
      return <String, Object?>{
        'id': r.id,
        'name': r.name,
        'parent_id': r.parentId,
        'sort_order': r.sortOrder,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };
    },
  ),
  _KeyProbe(
    table: 'notes',
    id: 'probe-note',
    payload: <String, Object?>{
      'id': 'probe-note',
      'notebook_id': 'probe-notebook',
      'title': 'probe-title',
      'content_md': '# probe 正文',
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r =
          await (db.select(db.notes)..where((t) => t.id.equals(id))).getSingle();
      return <String, Object?>{
        'id': r.id,
        'notebook_id': r.notebookId,
        'title': r.title,
        'content_md': r.contentMd,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };
    },
  ),
  _KeyProbe(
    table: 'knowledge_points',
    id: 'probe-kp',
    payload: <String, Object?>{
      'id': 'probe-kp',
      'notebook_id': 'probe-notebook',
      'name': 'probe-知识点',
      'type': 'theorem',
      'definition': 'probe-定义',
      'source_note_id': 'probe-note',
      'source_start': 11,
      'source_end': 22,
      'source_quote': 'probe-引用',
      'origin': 'user_manual',
      'confidence': 0.75,
      // ★ v5 新增两列：默认值分别是 false / null，探测值刻意取反。
      'pinned': true,
      'created_at': _probeCreatedAt,
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r = await (db.select(db.knowledgePoints)
            ..where((t) => t.id.equals(id)))
          .getSingle();
      return <String, Object?>{
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
        'pinned': r.pinned,
        'created_at': r.createdAt,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };
    },
  ),
  _KeyProbe(
    table: 'prerequisite_edges',
    id: 'probe-edge',
    payload: <String, Object?>{
      'id': 'probe-edge',
      'from_kp_id': 'probe-kp-a',
      'to_kp_id': 'probe-kp-b',
      'reason': 'probe-理由',
      'origin': 'manual',
      'confidence': 0.5,
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r = await (db.select(db.prerequisiteEdges)
            ..where((t) => t.id.equals(id)))
          .getSingle();
      return <String, Object?>{
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
    },
  ),
  _KeyProbe(
    table: 'mastery_records',
    id: 'probe-mastery',
    payload: <String, Object?>{
      'id': 'probe-mastery',
      'kp_id': 'probe-kp',
      'status': 'mastered',
      'source': 'quiz',
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r = await (db.select(db.masteryRecords)
            ..where((t) => t.id.equals(id)))
          .getSingle();
      return <String, Object?>{
        'id': r.id,
        'kp_id': r.kpId,
        'status': r.status,
        'source': r.source,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };
    },
  ),
  _KeyProbe(
    table: 'cards',
    id: 'probe-card',
    payload: <String, Object?>{
      'id': 'probe-card',
      'type': 'cloze',
      'source_ref': '{"probe":1}',
      'parent_card_id': 'probe-parent-card',
      'regenerated_from_id': 'probe-regen',
      'content_md': 'probe-卡片正文',
      'session_id': 'probe-session',
      'model_id': 'probe-model',
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r =
          await (db.select(db.cards)..where((t) => t.id.equals(id))).getSingle();
      return <String, Object?>{
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
    },
  ),
  _KeyProbe(
    table: 'canvases',
    id: 'probe-canvas',
    payload: <String, Object?>{
      'id': 'probe-canvas',
      'notebook_id': 'probe-notebook',
      'name': 'probe-画布',
      'viewport': '{"x":1,"y":2,"zoom":3}',
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r = await (db.select(db.canvases)..where((t) => t.id.equals(id)))
          .getSingle();
      return <String, Object?>{
        'id': r.id,
        'notebook_id': r.notebookId,
        'name': r.name,
        'viewport': r.viewport,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };
    },
  ),
  _KeyProbe(
    table: 'canvas_nodes',
    id: 'probe-node',
    payload: <String, Object?>{
      'id': 'probe-node',
      'canvas_id': 'probe-canvas',
      'target_type': 'kp',
      'target_id': 'probe-kp',
      'x': 1.5,
      'y': 2.5,
      'w': 3.5,
      'h': 4.5,
      'z': 9,
      'collapsed': true,
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r = await (db.select(db.canvasNodes)..where((t) => t.id.equals(id)))
          .getSingle();
      return <String, Object?>{
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
    },
  ),
  _KeyProbe(
    table: 'canvas_edges',
    id: 'probe-canvas-edge',
    payload: <String, Object?>{
      'id': 'probe-canvas-edge',
      'canvas_id': 'probe-canvas',
      'from_node_id': 'probe-node-a',
      'to_node_id': 'probe-node-b',
      'edge_type': 'prereq',
      'prereq_edge_id': 'probe-edge',
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r = await (db.select(db.canvasEdges)..where((t) => t.id.equals(id)))
          .getSingle();
      return <String, Object?>{
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
    },
  ),
  _KeyProbe(
    table: 'ai_sessions',
    id: 'probe-session',
    payload: <String, Object?>{
      'id': 'probe-session',
      'type': 'tutor',
      'target_ref': 'probe-目标',
      'title': 'probe-会话',
      'kp_id': 'probe-kp',
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r = await (db.select(db.aiSessions)..where((t) => t.id.equals(id)))
          .getSingle();
      return <String, Object?>{
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
    },
  ),
  _KeyProbe(
    table: 'ai_messages',
    id: 'probe-message',
    payload: <String, Object?>{
      'id': 'probe-message',
      'session_id': 'probe-session',
      'role': 'assistant',
      'content_md': 'probe-回答',
      'tokens': 123,
      'latency_ms': 456,
      'model_id': 'probe-model',
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r = await (db.select(db.aiMessages)..where((t) => t.id.equals(id)))
          .getSingle();
      return <String, Object?>{
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
    },
  ),
  _KeyProbe(
    table: 'kp_groups',
    id: 'probe-group',
    payload: <String, Object?>{
      'id': 'probe-group',
      'canvas_id': 'probe-canvas',
      'name': 'probe-分组',
      'order_index': 3,
      'foundational_level': 2,
      // 整段成员 JSON：同步层原样搬运，不拆开解析。
      'members_json': '[{"kpId":"probe-kp","level":5}]',
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r =
          await (db.select(db.kpGroups)..where((t) => t.id.equals(id)))
              .getSingle();
      return <String, Object?>{
        'id': r.id,
        'canvas_id': r.canvasId,
        'name': r.name,
        'order_index': r.orderIndex,
        'foundational_level': r.foundationalLevel,
        'members_json': r.membersJson,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };
    },
  ),
  _KeyProbe(
    table: 'note_assets',
    id: 'probe-asset',
    payload: <String, Object?>{
      'id': 'probe-asset',
      'note_id': 'probe-note',
      'name': 'probe-shot.png',
      'mime': 'image/jpeg',
      'sha1': 'probe-sha1-value',
      'bytes': 2048,
      // ⚠️ 键名是列名 `data_base64`，不是 Dart 字段名 `dataBase64`。
      'data_base64': 'cHJvYmUtYnl0ZXM=',
      'deleted_at': _probeDeletedAt,
    },
    read: (db, id) async {
      final r =
          await (db.select(db.noteAssets)..where((t) => t.id.equals(id)))
              .getSingle();
      return <String, Object?>{
        'id': r.id,
        'note_id': r.noteId,
        'name': r.name,
        'mime': r.mime,
        'sha1': r.sha1,
        'bytes': r.bytes,
        'data_base64': r.dataBase64,
        'updated_at': r.updatedAt,
        'version': r.version,
        'device_id': r.deviceId,
        'deleted_at': r.deletedAt,
      };
    },
  ),
];

void main() {
  group('契约：kSyncTableKeys', () {
    test('覆盖 13 张同步表，且与 kSyncTableAllowlist 一致', () {
      expect(kSyncTableKeys.length, 13);
      expect(
        kSyncTableKeys.keys.toSet(),
        kSyncTableAllowlist,
        reason: 'sync_engine 的白名单与键集契约必须逐表一致',
      );
    });

    test('每张表都有对应的 adapter 映射', () {
      expect(kSyncTableAdapters.length, kSyncTableKeys.length);
      for (final table in kSyncTableKeys.keys) {
        expect(kSyncTableAdapters.containsKey(table), isTrue,
            reason: '$table 缺少 adapter 映射');
      }
    });
  });

  group('源码扫描：写键集 ↔ 读键集严格对齐', () {
    late Map<String, Set<String>> writeKeys;
    late Map<String, Set<String>> readKeys;

    setUpAll(() {
      writeKeys =
          _extractWriteKeys(_locate('lib/data/sync/sync_row_map.dart')
              .readAsStringSync());
      readKeys = _extractReadKeys(
          _locate('lib/data/sync/sync_engine.dart').readAsStringSync());
    });

    test('扫描器确实抽到了 13 对 adapter（防止正则悄悄失效）', () {
      for (final entry in kSyncTableAdapters.entries) {
        expect(writeKeys.containsKey(entry.value.$1), isTrue,
            reason: 'sync_row_map.dart 里找不到 ${entry.value.$1}');
        expect(readKeys.containsKey(entry.value.$2), isTrue,
            reason: 'sync_engine.dart 里找不到 ${entry.value.$2}');
      }
    });

    for (final entry in kSyncTableAdapters.entries) {
      final table = entry.key;
      final toMap = entry.value.$1;
      final fromMap = entry.value.$2;

      test('$table: $toMap 写出的键 == $fromMap 读到的键', () {
        final w = writeKeys[toMap]!;
        final r = readKeys[fromMap]!;

        // ① 写侧的每个键，读侧都要读（否则 payload 里带着却落不了库）。
        expect(r, w, reason: '$table：读键集与写键集不相等'
            '\n  写侧多出（对端会静默丢）: ${w.difference(r)}'
            '\n  读侧多出（永远读到 null）: ${r.difference(w)}');

        // ② 两者都要等于契约里的键集（防止扫描器误抽 / 契约漏改）。
        final contract = kSyncTableKeys[table]!;
        expect(w, contract, reason: '$table：写侧键集与契约不一致'
            '\n  契约多出: ${contract.difference(w)}'
            '\n  写侧多出: ${w.difference(contract)}');
      });
    }
  });

  group('闭环：payload → JSON 往返 → pull → 落库，逐键比对', () {
    late AppDatabase db;
    late SyncOutboxRepo outbox;
    late MockSyncApi api;
    late SyncEngine engine;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      outbox = SyncOutboxRepo(db, deviceId: 'local-dev');
      api = MockSyncApi(deviceIdOfCaller: _probeDeviceId);
      engine = SyncEngine(db: db, api: api, outbox: outbox, deviceId: 'local-dev');
    });

    tearDown(() async {
      SyncOutboxRepo.current = null;
      await db.close();
    });

    for (final probe in _probes) {
      test('${probe.table}: 每个键都落库（键名错 = 静默回落默认值 → 红）',
          () async {
        final table = probe.table;
        final contract = kSyncTableKeys[table]!;

        // 构造 payload：探测值 + 三个会被 _hydrate 覆盖的键（用 envelope 的值）。
        final payload = <String, dynamic>{
          ...probe.payload,
          'updated_at': _probeTime,
          'version': _probeVersion,
          'device_id': _probeDeviceId,
        };
        // 探测 payload 必须覆盖契约里的**全部**键（少一个键，该列就被漏测）。
        expect(payload.keys.toSet(), contract,
            reason: '$table：探测 payload 与契约键集不一致');

        // 真实链路：payload 里的 DateTime 经 JSON 往返后变成 ISO 字符串。
        final roundTripped =
            jsonDecode(encodeSyncJson(payload)) as Map<String, dynamic>;

        api.enqueuePull(<SyncEnvelope>[
          SyncEnvelope(
            deviceId: _probeDeviceId,
            entityTable: table,
            entityId: probe.id,
            op: SyncOp.upsert,
            payload: roundTripped,
            baseVersion: _probeVersion,
            updatedAt: _probeTime,
            // 故意留空：非空会走「硬删」分支，就测不到落库了。
            deletedAt: null,
          ),
        ]);

        final report = await engine.pull();
        expect(report.applied, 1, reason: '$table：pull 未应用');

        final landed = await probe.read(db, probe.id);
        expect(landed.keys.toSet(), contract,
            reason: '$table：落库取回的键集与契约不一致');

        for (final key in contract) {
          _expectValueEqual(table, key, landed[key], payload[key]);
        }
      });
    }
  });
}

/// 逐键比对（DateTime 按「时刻」比，num 按浮点比，其余按相等比）。
void _expectValueEqual(
  String table,
  String key,
  Object? actual,
  Object? expected,
) {
  final reason = '$table.$key 落库值不对（键名写错会静默回落默认值）：'
      'expected=$expected actual=$actual';
  if (expected is DateTime) {
    expect(actual, isA<DateTime>(), reason: reason);
    expect((actual! as DateTime).isAtSameMomentAs(expected), isTrue,
        reason: reason);
    return;
  }
  if (expected is num) {
    expect(actual, isA<num>(), reason: reason);
    expect((actual! as num).toDouble(), closeTo(expected.toDouble(), 1e-9),
        reason: reason);
    return;
  }
  expect(actual, expected, reason: reason);
}
