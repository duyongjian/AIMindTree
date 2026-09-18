import 'package:aimindtree_app/core/id.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('知识点类型解析（LLM 输出不可信，必须容错）', () {
    test('支持英文 name', () {
      expect(KnowledgePointType.parse('theorem'), KnowledgePointType.theorem);
      expect(KnowledgePointType.parse('myth'), KnowledgePointType.myth);
    });

    test('支持中文标签（模型常返回中文）', () {
      expect(KnowledgePointType.parse('定理'), KnowledgePointType.theorem);
      expect(KnowledgePointType.parse('公式'), KnowledgePointType.formula);
      expect(KnowledgePointType.parse('误区'), KnowledgePointType.myth);
    });

    test('未知/空值回落 concept，不抛异常', () {
      expect(KnowledgePointType.parse('乱七八糟'), KnowledgePointType.concept);
      expect(KnowledgePointType.parse(null), KnowledgePointType.concept);
      expect(KnowledgePointType.parse(''), KnowledgePointType.concept);
    });
  });

  group('掌握状态级联降级（PRD 硬规则4）', () {
    test('mastered → learning', () {
      expect(MasteryStatus.mastered.downgraded, MasteryStatus.learning);
    });

    test('learning → notMastered', () {
      expect(MasteryStatus.learning.downgraded, MasteryStatus.notMastered);
    });

    test('notMastered / unknown → notMastered（不再往下掉）', () {
      expect(MasteryStatus.notMastered.downgraded, MasteryStatus.notMastered);
      expect(MasteryStatus.unknown.downgraded, MasteryStatus.notMastered);
    });

    test('abandoned 也落到 notMastered', () {
      expect(MasteryStatus.abandoned.downgraded, MasteryStatus.notMastered);
    });
  });

  group('ID 生成', () {
    test('ULID 长度 26 且各不相同', () {
      final a = newUlid();
      final b = newUlid();
      expect(a.length, 26, reason: 'ULID 标准长度');
      expect(a, isNot(b));
    });
  });
}
