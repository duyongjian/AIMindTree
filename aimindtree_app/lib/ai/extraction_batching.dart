/// T1 分块提取的纯函数集合（批量提取 / 长文防遗漏 + 运行摘要防重复）。
///
/// 设计约束（见任务说明）：
/// - 纯函数、确定性、可单测；不依赖网络 / 数据库 / Flutter 运行环境。
/// - 复用 [RawKnowledgePoint] 作为知识点载体（与 [ExtractionService] 一致）；
///   其定义所在的 `knowledge_repository.dart` 虽会引入 drift，但 [RawKnowledgePoint]
///   本身是零依赖的纯数据类，本文件不主动 `import 'package:drift/...'`，
///   便于在 `flutter test` 下零副作用地对纯函数做单测。
library;

import '../data/repositories/knowledge_repository.dart';

/// 句末 / 段内分隔符：句子终止符与分号（中文/英文/全角半角）。
const String _sentenceTerminators = '.!?！？;；';

/// 把长文本切成若干块，单块长度不超过 [maxChars]。
///
/// 分块策略（贪心、在段落 / 句子边界处切，绝不产生空块）：
/// 1. 先按 `\n+` 拆成「段落」；
/// 2. 对超过 [maxChars] 的段落，再按句末分隔符（[ _sentenceTerminators ]、
///    以及残留的 `\n`）继续细分；
/// 3. 把段 / 句子片段贪心累计进当前块，直到「再加下一段会超 [maxChars]」
///    才另起一块（块间用 `\n` 连接，尽量保留段落结构）；
/// 4. 单句超长（极端情况）按 [maxChars] 暴力切片，保证单块不超限。
List<String> splitForBatching(String text, {int maxChars = 3000}) {
  if (text.isEmpty) return const <String>[];

  // 1) 段落拆分（一个或多个换行视为段落边界）。
  final paragraphs =
      text.split(RegExp(r'\n+')).where((p) => p.trim().isNotEmpty).toList();

  // 2) 把每个段落规整为「段级片段」（长段落内部再按句末切）。
  final segments = <String>[];
  for (final p in paragraphs) {
    if (p.length <= maxChars) {
      segments.add(p);
      continue;
    }
    // 超长段落：按句末分隔符切分。
    final pieces = _splitBySentence(p);
    var buf = '';
    for (final piece in pieces) {
      if (piece.length > maxChars) {
        // 单句仍超长：先把已缓冲的段落盘，再对超长句暴力切片。
        if (buf.isNotEmpty) {
          segments.add(buf);
          buf = '';
        }
        for (var i = 0; i < piece.length; i += maxChars) {
          final end = (i + maxChars < piece.length) ? i + maxChars : piece.length;
          segments.add(piece.substring(i, end));
        }
        continue;
      }
      if (buf.isEmpty) {
        buf = piece;
      } else if (buf.length + piece.length <= maxChars) {
        buf = '$buf$piece';
      } else {
        segments.add(buf);
        buf = piece;
      }
    }
    if (buf.isNotEmpty) segments.add(buf);
  }

  if (segments.isEmpty) return const <String>[];

  // 3) 段级片段贪心累计成块。
  final chunks = <String>[];
  var current = '';
  for (final seg in segments) {
    if (current.isEmpty) {
      current = seg;
    } else if (current.length + 1 + seg.length <= maxChars) {
      current = '$current\n$seg';
    } else {
      chunks.add(current);
      current = seg;
    }
  }
  if (current.isNotEmpty) chunks.add(current);

  return chunks;
}

/// 在句末分隔符（[ _sentenceTerminators ] / `\n`）之后切分，保留分隔符。
List<String> _splitBySentence(String text) {
  final out = <String>[];
  final buf = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    buf.write(c);
    if (_sentenceTerminators.contains(c) || c == '\n') {
      out.add(buf.toString());
      buf.clear();
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

/// 把已提取的知识点压成一段紧凑的运行摘要，供后续分块「防重复」使用。
///
/// 形如：`1. 梯度下降(概念): 通过迭代减小损失函数的优化方法; 2. 过拟合(事实): ...`。
/// 整体长度上限 [maxChars]：在加入下一个条目会超限时停止，并做最终截断兜底。
String summarizePoints(List<RawKnowledgePoint> points, {int maxChars = 600}) {
  final sb = StringBuffer();
  var idx = 0;
  for (final p in points) {
    idx++;
    final type = p.type.trim().isNotEmpty ? '(${p.type.trim()})' : '';
    final def = p.definition.trim();
    final entry = '$idx. ${p.name.trim()}$type: $def';
    if (sb.isEmpty) {
      sb.write(entry);
    } else if (sb.length + 2 + entry.length <= maxChars) {
      sb.write('; $entry');
    } else {
      break;
    }
  }
  final result = sb.toString();
  if (result.length > maxChars) {
    return result.substring(0, maxChars);
  }
  return result;
}

/// 按归一化名称去重（trim + 小写 + 折叠内部空白）。
///
/// 同名（归一化后）的多个点，保留 `definition` 更长的一个（信息更全），
/// 其余丢弃。名称为空的点不参与去重，原样保留（避免把无名义点混为一谈）。
List<RawKnowledgePoint> dedupePoints(List<RawKnowledgePoint> points) {
  String normalize(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  final byKey = <String, RawKnowledgePoint>{};
  final noName = <RawKnowledgePoint>[];
  for (final p in points) {
    final key = normalize(p.name);
    if (key.isEmpty) {
      noName.add(p);
      continue;
    }
    final existing = byKey[key];
    if (existing == null || p.definition.length > existing.definition.length) {
      byKey[key] = p;
    }
  }
  return <RawKnowledgePoint>[...byKey.values, ...noName];
}
