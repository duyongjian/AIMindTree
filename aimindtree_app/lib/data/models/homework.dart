/// 作业（「作业模式」的领域模型）。
///
/// 一份作业 = 一棵知识树里挑出的一批**薄弱点** + 给它们出的题。
///
/// 设计要点：
/// - 作业**不产生新知识点**：[Homework.kpIds] 只是已有知识点的 id 快照，
///   题目本身也不是知识实体，所以不受「锚点铁律」约束（那条管的是知识点入库）。
/// - 但出题的**依据**仍然来自知识点的 `sourceQuote`（见作业页的 prompt 组装），
///   免得模型脱离原文自由发挥——这是「题目离题」的唯一防线。
/// - 题目整体以 JSON 存在 `homeworks.items_json`，编辑时整体覆写；没有单题查询
///   需求，不拆子表（拆表会多一张要手工复刻 drift 生成类的表）。
library;

import 'dart:convert';

/// 一份作业。
class Homework {
  const Homework({
    required this.id,
    required this.canvasId,
    required this.title,
    required this.kpIds,
    required this.items,
  });

  final String id;

  /// 所属知识树（canvases.id）。
  final String canvasId;

  final String title;

  /// 布置时选中的薄弱点 id（快照：知识点日后改名也不影响历史作业）。
  final List<String> kpIds;

  final List<HomeworkItem> items;

  Homework copyWith({
    String? title,
    List<String>? kpIds,
    List<HomeworkItem>? items,
  }) =>
      Homework(
        id: id,
        canvasId: canvasId,
        title: title ?? this.title,
        kpIds: kpIds ?? this.kpIds,
        items: items ?? this.items,
      );

  /// 未删掉的题数量（用户可以在生成后删题）。
  int get itemCount => items.length;
}

/// 一道题。
class HomeworkItem {
  const HomeworkItem({
    required this.kpId,
    required this.kpName,
    required this.type,
    required this.question,
    required this.answer,
    this.difficulty = 2,
  });

  /// 关联的知识点 id；自由补充题可以为空串。
  final String kpId;

  /// 知识点名称（冗余存一份，历史作业在知识点改名后仍可读）。
  final String kpName;

  /// 题型：choice / fill / short / calc / proof。
  final String type;

  final String question;

  /// 参考答案 / 评分要点。
  final String answer;

  /// 难度 1（易）~ 3（难）。
  final int difficulty;

  HomeworkItem copyWith({
    String? kpId,
    String? kpName,
    String? type,
    String? question,
    String? answer,
    int? difficulty,
  }) =>
      HomeworkItem(
        kpId: kpId ?? this.kpId,
        kpName: kpName ?? this.kpName,
        type: type ?? this.type,
        question: question ?? this.question,
        answer: answer ?? this.answer,
        difficulty: difficulty ?? this.difficulty,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kpId': kpId,
        'kpName': kpName,
        'type': type,
        'question': question,
        'answer': answer,
        'difficulty': difficulty,
      };

  static HomeworkItem fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      return const HomeworkItem(
          kpId: '', kpName: '', type: 'short', question: '', answer: '');
    }
    final d = (raw['difficulty'] as num?)?.toInt() ?? 2;
    return HomeworkItem(
      kpId: (raw['kpId'] as String?) ?? '',
      kpName: (raw['kpName'] as String?) ?? '',
      type: (raw['type'] as String?) ?? 'short',
      question: (raw['question'] as String?) ?? '',
      answer: (raw['answer'] as String?) ?? '',
      difficulty: d.clamp(1, 3),
    );
  }

  String get typeLabel => switch (type) {
        'choice' => '选择',
        'fill' => '填空',
        'calc' => '计算',
        'proof' => '证明/推导',
        _ => '简答',
      };
}

/// 编码成 `homeworks.items_json`。
String encodeHomeworkItems(List<HomeworkItem> items) =>
    jsonEncode(<Map<String, dynamic>>[for (final i in items) i.toJson()]);

/// 解析 `homeworks.items_json`；坏数据返回空列表，不抛异常。
List<HomeworkItem> decodeHomeworkItems(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <HomeworkItem>[];
    return <HomeworkItem>[for (final e in decoded) HomeworkItem.fromJson(e)];
  } on Object {
    return const <HomeworkItem>[];
  }
}

/// 编码 `homeworks.kp_ids_json`。
String encodeKpIds(List<String> ids) => jsonEncode(ids);

/// 解析 `homeworks.kp_ids_json`。
List<String> decodeKpIds(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>[];
    return <String>[
      for (final e in decoded)
        if (e is String) e,
    ];
  } on Object {
    return const <String>[];
  }
}
