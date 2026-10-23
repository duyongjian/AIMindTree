/// AI 助手的长期记忆存储。
///
/// 设计要点：
/// 1. **文件即真相**：记忆以 JSON 文件形式落在 App 文档目录
///    （`agent_memory.json`），用户可在设置里「查看记忆文件内容」，也能
///    直接看到文件路径，符合「数据本地化、可审计」的口径。
/// 2. **开关独立于内容**：是否启用记忆由 SharedPreferences 的
///    `agent_memory_enabled` 控制；关闭后 AI 既读不到记忆、也写不进记忆，
///    但已有的记忆内容**保留**（重新打开即可恢复），不会被清空。
/// 3. **结构化存储**：每条记忆是一个 `{key, content, created_at, updated_at}`，
///    按 key 幂等 upsert、按 key 删除；content 用 UTF-8 存（支持中文）。
/// 4. **全本地**：不联网、不进同步、不外发，与 AI 助手其它工具同信任域。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kMemEnabledKey = 'agent_memory_enabled';
const String _kMemFileName = 'agent_memory.json';

/// 单条记忆。
class AgentMemoryEntry {
  const AgentMemoryEntry({
    required this.key,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });

  final String key;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'content': content,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  static AgentMemoryEntry fromJson(Map<String, dynamic> j) {
    DateTime parse(String? s, DateTime fallback) {
      if (s == null) return fallback;
      final d = DateTime.tryParse(s);
      return d ?? fallback;
    }

    final now = DateTime.now();
    return AgentMemoryEntry(
      key: (j['key'] as String?) ?? '',
      content: (j['content'] as String?) ?? '',
      createdAt: parse(j['created_at'] as String?, now),
      updatedAt: parse(j['updated_at'] as String?, now),
    );
  }
}

/// 长期记忆存储（文件 + 开关）。
///
/// 单例语义由调用方持有（agent_page 持有一个实例即可）；本类不强制单例，
/// 但 `enabled` 开关与文件都收敛到同一份 SharedPreferences / 同一路径，
/// 多次实例化也不会冲突。
class AgentMemoryStore {
  AgentMemoryStore({this.enabledByDefault = false});

  /// 首次启动默认是否开启记忆（用于未来可能的引导，当前 UI 仍以存储值为准）。
  final bool enabledByDefault;

  bool _enabled = false;
  bool get enabled => _enabled;

  File? _file;

  /// 初始化：读开关 + 预解析文件路径。**必须在任何读 / 写前调用一次。**
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kMemEnabledKey) ?? enabledByDefault;
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/$_kMemFileName');
  }

  Future<File> _ensureFile() async {
    if (_file == null) {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/$_kMemFileName');
    }
    return _file!;
  }

  /// 记忆文件绝对路径（供 UI「查看记忆文件内容」展示）。
  Future<String> get filePath async => (await _ensureFile()).path;

  /// 开启 / 关闭记忆；持久化到 SharedPreferences。
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMemEnabledKey, value);
  }

  /// 读全部记忆（文件损坏时回落空列表，不抛异常）。
  Future<List<AgentMemoryEntry>> readAll() async {
    try {
      final f = await _ensureFile();
      if (!f.existsSync()) return const <AgentMemoryEntry>[];
      final text = await f.readAsString();
      if (text.trim().isEmpty) return const <AgentMemoryEntry>[];
      final decoded = jsonDecode(text);
      if (decoded is! Map) return const <AgentMemoryEntry>[];
      final list = decoded['entries'];
      if (list is! List) return const <AgentMemoryEntry>[];
      return <AgentMemoryEntry>[
        for (final e in list)
          if (e is Map<String, dynamic>) AgentMemoryEntry.fromJson(e),
      ];
    } on Object {
      return const <AgentMemoryEntry>[];
    }
  }

  /// 记忆文件原始内容（供「查看记忆文件内容」直接展示）。
  Future<String> rawContent() async {
    final f = await _ensureFile();
    if (!f.existsSync()) return '{\n  "entries": []\n}';
    return await f.readAsString();
  }

  /// 幂等写入 / 覆盖一条记忆（按 key）。
  Future<void> upsert(String key, String content) async {
    final now = DateTime.now();
    final all = await readAll();
    final idx = all.indexWhere((e) => e.key == key);
    final entry = idx >= 0
        ? AgentMemoryEntry(
            key: key,
            content: content,
            createdAt: all[idx].createdAt,
            updatedAt: now,
          )
        : AgentMemoryEntry(
            key: key,
            content: content,
            createdAt: now,
            updatedAt: now,
          );
    final next = <AgentMemoryEntry>[...all];
    if (idx >= 0) {
      next[idx] = entry;
    } else {
      next.add(entry);
    }
    await _writeAll(next);
  }

  /// 删除一条记忆（按 key）；key 不存在时幂等。
  Future<void> remove(String key) async {
    final all = await readAll();
    final next = all.where((e) => e.key != key).toList();
    if (next.length == all.length) return; // 无变化，省一次写
    await _writeAll(next);
  }

  /// 清空全部记忆（谨慎：仅清内容，不影响开关）。
  Future<void> clear() async => _writeAll(const <AgentMemoryEntry>[]);

  Future<void> _writeAll(List<AgentMemoryEntry> entries) async {
    final f = await _ensureFile();
    final obj = <String, dynamic>{
      'entries': [for (final e in entries) e.toJson()],
    };
    await f.writeAsString(jsonEncode(obj), flush: true);
  }

  /// 给 prompt 用的可读上下文；禁用或为空时返回空串。
  Future<String> toContext() async {
    if (!_enabled) return '';
    final entries = await readAll();
    if (entries.isEmpty) return '';
    final b = StringBuffer('【长期记忆】下面是用户希望你长期记住的偏好 / 事实'
        '（回答时请结合这些背景）：\n');
    for (final e in entries) {
      b.writeln('- ${e.key}：${e.content}');
    }
    return b.toString().trimRight();
  }
}
