import 'package:aimindtree_app/ai/structured_parse.dart';
import 'package:flutter_test/flutter_test.dart';

/// StructuredText.parse 的健壮性回归测试。
///
/// 背景（实测踩坑）：旧实现用「首 `{` → 末 `}`」硬切，一旦模型输出**未闭合**的
/// `<think>` 思考块、且思考文字里含 `{`，切片起点会落进思考文字，拼出来的串不是
/// 合法 JSON → 解析失败 → 静默返回 null → 上层无声退回本地兜底，AI 等于没跑。
/// 现改为「括号配对扫描」（见 _scanJson / _matchEnd），以下用例固化该行为。
///
/// 本文件由 `dify_parse_structured_test.dart` 改名改写而来：解析能力已从
/// `DifyResult`（随 Dify 停用）抽到 `StructuredText`（协议无关）。
void main() {
  group('StructuredText.parse', () {
    test('① 纯 JSON 直接解析', () {
      final r = StructuredText.parse('{"gaps":[{"name":"力","level":1}]}');
      expect(r, isNotNull);
      final map = r! as Map<String, dynamic>;
      expect((map['gaps'] as List<dynamic>).length, 1);
    });

    test('② 闭合的 <think>...</think> 被剥离', () {
      const raw =
          '<think>让我分析一下 F=ma</think>\n{"gaps":[{"name":"力","level":1}]}';
      expect(StructuredText.parse(raw), isNotNull);
    });

    test('③ 未闭合的 <think> 且思考块内含 { —— 旧实现必挂的回归用例', () {
      // 思考块里有个 `{` 且没有 </think>：旧的「首 { → 末 }」硬切会失败。
      const raw = '<think>\n'
          '考虑 F=ma 的情形 { 这里没闭合\n'
          '牛顿第二定律涉及力与加速度\n'
          '{"gaps":[{"name":"力","definition":"物体间的相互作用","level":1}]}';
      final r = StructuredText.parse(raw);
      expect(r, isNotNull,
          reason: '未闭合的思考块不应导致解析失败（旧实现在此返回 null）');
      final map = r! as Map<String, dynamic>;
      expect((map['gaps'] as List<dynamic>).length, 1);
    });

    test('④ ```json 代码块包裹', () {
      const raw = '```json\n{"gaps":[{"name":"力","level":1}]}\n```';
      expect(StructuredText.parse(raw), isNotNull);
    });

    test('⑤ 前后夹带无关文字', () {
      const raw =
          '好的，分析结果如下：\n{"gaps":[{"name":"力","level":1}]}\n希望对你有帮助。';
      expect(StructuredText.parse(raw), isNotNull);
    });

    test('⑥ 字符串值内含 } / { 不被误判为结构符号', () {
      const raw = '{"gaps":[{"name":"a}b","definition":"x{y","level":1}]}';
      final r = StructuredText.parse(raw);
      expect(r, isNotNull);
      final map = r! as Map<String, dynamic>;
      final first = (map['gaps'] as List<dynamic>).first as Map<String, dynamic>;
      expect(first['name'], 'a}b');
      expect(first['definition'], 'x{y');
    });

    test('⑦ 输出被截断 → 抢救完整条目，且绝不退化成内层片段', () {
      const raw = '{"gaps":[{"name":"力","level":1},{"name":"加速';
      final r = StructuredText.parse(raw);
      // 关键：绝不能返回内层片段 {"name":"力","level":1} —— 它本身合法但形状不对，
      // 调用方取不到 `gaps` 却会以为解析成功。
      expect(r, isNotNull);
      final map = r! as Map<String, dynamic>;
      final gaps = map['gaps'] as List<dynamic>;
      expect(gaps.length, 1,
          reason: '只保留完整条目，被截断的第 2 条直接丢弃（不补全、不编造）');
      expect((gaps.first as Map<String, dynamic>)['name'], '力');
    });

    test('⑧ 未闭合的 <reasoning> 思考块（⓪ 层新增覆盖）', () {
      // 未闭合 → ⓪ 层会把「<reasoning> → 末尾」整段吃掉（结果为空串）；
      // 但 parse 必须回退到原文继续扫描，绝不能因此返回 null。
      const raw =
          '<reasoning>\n先想想力与加速度的关系\n{"gaps":[{"name":"力","level":1}]}';
      final r = StructuredText.parse(raw);
      expect(r, isNotNull, reason: '⓪ 层吃掉正文后必须回退，不能静默失败');
      final map = r! as Map<String, dynamic>;
      expect((map['gaps'] as List<dynamic>).length, 1);
    });

    test('⑨ 前后混杂假结构符：只认第一个能解码的完整片段', () {
      const raw = '前缀 {not json}\n'
          '{"gaps":[{"name":"a}b","definition":"x{y","level":1}]}\n'
          '后缀 { trailing }';
      final r = StructuredText.parse(raw);
      expect(r, isNotNull);
      final map = r! as Map<String, dynamic>;
      final gaps = map['gaps'] as List<dynamic>;
      expect(gaps.length, 1);
      expect((gaps.first as Map<String, dynamic>)['name'], 'a}b');
    });
  });
}
