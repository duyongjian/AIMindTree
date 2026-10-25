/// 纯函数单测：T1 分块提取的 splitForBatching / summarizePoints / dedupePoints。
///
/// 只测纯函数，不触碰网络 / 数据库，可在 `flutter test` 下独立运行。
import 'package:aimindtree_app/ai/extraction_batching.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:flutter_test/flutter_test.dart';

RawKnowledgePoint kp({
  required String name,
  String type = '',
  String definition = '',
  String sourceQuote = '',
  List<String> prerequisites = const <String>[],
  num confidence = 0,
}) =>
    RawKnowledgePoint(
      name: name,
      type: type,
      definition: definition,
      sourceQuote: sourceQuote,
      prerequisites: prerequisites,
      confidence: confidence,
    );

void main() {
  group('splitForBatching', () {
    test('(a) 短文本 → 单个块', () {
      const text = '这是一段较短的笔记内容，远未达到分块上限。';
      final chunks = splitForBatching(text);
      expect(chunks, hasLength(1));
      expect(chunks.single, text);
    });

    test('(b) 长多句文本 → 多个块且每个块不超过 maxChars', () {
      // 拼出远超 3000 字、含大量句末标点的长文本。
      final sentences = <String>[];
      for (var i = 0; i < 400; i++) {
        sentences.add('知识点$i是关于机器学习的一个重要概念，'
            '它需要结合上下文来理解其具体含义，并且常与其他概念配合使用。');
      }
      final text = sentences.join();
      expect(text.length, greaterThan(3000));

      final chunks = splitForBatching(text, maxChars: 3000);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(3000));
        expect(c.trim().isNotEmpty, isTrue); // 绝不产生空块
      }
      // 块拼接（去块间换行）应能还原原文字（顺序一致、内容不丢）。
      final joined = chunks.join('');
      // 句末分隔符后可能夹了块边界换行，这里只校验不丢字符总量。
      expect(joined.length, text.length);
    });

    test('空文本 → 空列表', () {
      expect(splitForBatching(''), isEmpty);
      expect(splitForBatching('   \n  \n '), isEmpty);
    });
  });

  group('summarizePoints', () {
    test('(c) 输出形如 "N. 名称(类型): 定义" 且受 maxChars 上限约束', () {
      final points = <RawKnowledgePoint>[
        kp(name: '梯度下降', type: '概念',
            definition: '通过迭代减小损失函数的优化方法'),
        kp(name: '过拟合', type: '事实',
            definition: '模型在训练集好但测试集差'),
        kp(name: '正则化', type: '方法',
            definition: '通过惩罚项限制模型复杂度'),
      ];
      final s = summarizePoints(points, maxChars: 600);
      expect(s, contains('1. 梯度下降(概念):'));
      expect(s, contains('2. 过拟合(事实):'));
      expect(s, contains('; '));
      expect(s.length, lessThanOrEqualTo(600));
    });

    test('(c2) 条目过多时在上限处截断', () {
      final points = List<RawKnowledgePoint>.generate(
        100,
        (i) => kp(name: '点$i', type: '概念', definition: '这是第$i个知识点的定义内容'),
      );
      final s = summarizePoints(points, maxChars: 200);
      expect(s.length, lessThanOrEqualTo(200));
      // 不会把所有 100 条都塞进去。
      expect(s.contains('100. 点99'), isFalse);
    });
  });

  group('dedupePoints', () {
    test('(d) 同名（归一化后）保留 definition 更长的一个', () {
      final points = <RawKnowledgePoint>[
        kp(name: '梯度下降', type: '概念',
            definition: '短定义'),
        kp(name: ' 梯度下降 ', type: '概念',
            definition: '通过迭代减小损失函数的优化方法，常用于模型训练。'),
        kp(name: '过拟合', type: '事实',
            definition: '模型在训练集好但测试集差'),
      ];
      final deduped = dedupePoints(points);
      // 梯度下降（两种写法归一化同名）合并为 1 条，过拟合 1 条 → 共 2 条。
      expect(deduped, hasLength(2));
      final gd = deduped.firstWhere((p) => p.name.trim() == '梯度下降');
      expect(gd.definition, '通过迭代减小损失函数的优化方法，常用于模型训练。');
    });

    test('不同名保留各自', () {
      final points = <RawKnowledgePoint>[
        kp(name: 'A', definition: 'a'),
        kp(name: 'B', definition: 'b'),
      ];
      expect(dedupePoints(points), hasLength(2));
    });

    test('空名点不被去重、原样保留', () {
      final points = <RawKnowledgePoint>[
        kp(name: '', definition: '无名点X'),
        kp(name: '', definition: '无名点Y'),
        kp(name: '有名字', definition: 'z'),
      ];
      final deduped = dedupePoints(points);
      expect(deduped, hasLength(3));
    });
  });
}
