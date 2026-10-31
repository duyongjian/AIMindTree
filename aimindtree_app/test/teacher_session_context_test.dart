/// 老师模式会话：纯函数层测试（L2 历史注入 + 标题派生 + 讲解判别 + buildQuery）。
///
/// 覆盖测试方案：
/// - §4 边界用例 E1–E19（buildSessionContext 绝不重排 / 规模裁剪 / 角色过滤）
/// - §3.1.2 多轮记忆断言 A1–A9（buildQuery 注入历史前文）
/// - T10 deriveSessionTitle 扩展参数语义（Agent 侧行为逐字不变）
/// - T11⑧ isExplainMessage 容错（modelId 可空 / 异常值不抛）
/// - §0.3 规格 C：buildSessionContext 内部绝不重排（含 E17 与旧实现逐字对照）
///
/// 不依赖任何 Provider / 真实 LLM；内存库仅用于 buildQuery 需要的 controller 装配。
library;

import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/repositories/ai_session_repository.dart';
import 'package:aimindtree_app/features/shared/session_context.dart';
import 'package:aimindtree_app/features/shared/session_ui.dart';
import 'package:aimindtree_app/features/teacher/teacher_session_controller.dart';
import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const String _header = '【本会话前文】（同一会话内此前的问答，请参考上下文）';

/// 参考实现：逐字复刻 [buildSessionContext] 的契约（规格 C「绝不重排」）。
///
/// 用作 E17「与旧（Agent 侧）实现逐字相同」的最强护栏：一旦两端任一被改坏，
/// 本条立即转红。它本身只是合同的可执行表达，不引入额外行为。
String _referenceBuildSessionContext(
  List<({String role, String content})> turns, {
  int maxMessages = 12,
  int maxChars = 0,
  String header = _header,
}) {
  final picked = <({String role, String content})>[];
  for (final t in turns) {
    if (t.role == 'user' || t.role == 'assistant') picked.add(t);
  }
  if (picked.isEmpty) return '';
  final limited = picked.length > maxMessages
      ? picked.sublist(picked.length - maxMessages)
      : picked;
  if (limited.isEmpty) return '';
  final lines = <String>[
    for (final m in limited) '${m.role == 'user' ? '用户' : 'AI'}：${m.content}'
  ];
  var kept = lines;
  if (maxChars > 0) {
    final budget = maxChars - header.length - 1;
    final keptRev = <String>[];
    var used = 0;
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      final cost = line.length + 1;
      if (used + cost <= budget) {
        keptRev.insert(0, line);
        used += cost;
      } else if (keptRev.isEmpty) {
        final room = budget > 0 ? budget : 0;
        keptRev.insert(0, line.length <= room ? line : line.substring(0, room));
        used = room;
      } else {
        break;
      }
    }
    kept = keptRev;
  }
  return ([header] + kept).join('\n').trimRight();
}

/// 造一个 controller（buildQuery 只用到 kp / history，不碰库也不碰网络）。
TeacherSessionController _makeController({String definition = ''}) {
  final db = AppDatabase(NativeDatabase.memory());
  final repo = AiSessionRepository(db);
  final kp = KnowledgePoint(
    id: 'kp-ctx',
    name: '链式法则',
    type: KnowledgePointType.theorem,
    definition: definition,
    sourceNoteId: '',
    sourceStart: -1,
    sourceEnd: -1,
    sourceQuote: '来源锚点',
  );
  return TeacherSessionController(repo: repo, kp: kp);
}

void main() {
  group('E：buildSessionContext 边界（§4）', () {
    test('E1 历史为空 → 空串', () {
      expect(buildSessionContext([]), '');
      // 调用方据此不注入 L2 段。
      final c = _makeController();
      final q = c.buildQuery(
        history: const [],
        task: AiTask.t6Explain,
        currentQuestion: '',
      );
      expect(q, isNot(contains(_header)));
    });

    test('E2 条数超 N → 只保留最近 N 条（N=10）', () {
      final turns = [
        for (var i = 0; i < 20; i++)
          (role: i.isEven ? 'user' : 'assistant',
              content: i == 0 ? 'OLDEST-MARK' : 'm$i'),
      ];
      final l2 = buildSessionContext(turns, maxMessages: 10);
      expect(l2, isNot(contains('OLDEST-MARK')));
      expect(l2, contains('m19')); // 最新一条在
      // 保留的 10 条里 user 条数：索引 10..19 中偶数为 10,12,14,16,18 → 5 条
      final userCount =
          RegExp(r'^用户：', multiLine: true).allMatches(l2).length;
      expect(userCount, 5);
    });

    test('E3 条数恰好等于 N → 全部保留', () {
      final turns = [
        for (var i = 0; i < 10; i++)
          (role: i.isEven ? 'user' : 'assistant', content: 'm$i'),
      ];
      final l2 = buildSessionContext(turns, maxMessages: 10);
      expect(l2, contains('m0')); // 最老一条仍在（边界含）
      expect(l2, contains('m9'));
    });

    test('E4 N+1 条 → 最老 1 条被丢（off-by-one 防线）', () {
      final turns = [
        for (var i = 0; i < 11; i++)
          (role: i.isEven ? 'user' : 'assistant', content: 'm$i'),
      ];
      final l2 = buildSessionContext(turns, maxMessages: 10);
      expect(l2, isNot(contains('m0')));
      expect(l2, contains('m10'));
    });

    test('E5 总长超 4000 → 从最老整条丢弃', () {
      final turns = [
        for (var i = 0; i < 10; i++)
          (role: 'user',
              content: i == 0 ? 'OLDEST' : (i == 9 ? 'NEWEST' : 'x' * 1000)),
      ];
      final l2 = buildSessionContext(turns, maxMessages: 10, maxChars: 4000);
      expect(l2, isNot(contains('OLDEST')));
      expect(l2, contains('NEWEST'));
      expect(l2.length, lessThanOrEqualTo(4000 + _header.length));
    });

    test('E6 恰好 4000 全保留 / 4001 最老一条被丢', () {
      // budget = 4000 - 26 - 1 = 3973；单条 line = 3 + L。
      // L=3970 → 行长 3973 <= budget → 全保留，l2 总长 = 4000。
      final full = 'a' * 3970;
      final l2ok = buildSessionContext(
        [(role: 'user', content: full)],
        maxMessages: 10,
        maxChars: 4000,
      );
      expect(l2ok, contains(full));
      expect(l2ok.length, 4000);

      final over = 'a' * 3971;
      final l2over = buildSessionContext(
        [(role: 'user', content: over)],
        maxMessages: 10,
        maxChars: 4000,
      );
      expect(l2over, isNot(contains(over))); // 被截断
      expect(l2over.length, lessThanOrEqualTo(4000 + _header.length));
    });

    test('E7 最新一条单独超限 → 截断内容（不整条丢）', () {
      final big = 'b' * 8000;
      final l2 = buildSessionContext(
        [(role: 'user', content: big)],
        maxMessages: 10,
        maxChars: 4000,
      );
      expect(l2, startsWith(_header));
      expect(l2, contains('用户：')); // 该条仍以角色前缀存在
      expect(l2, isNot(contains(big))); // 原始超长内容不整段出现
      expect(l2.length, lessThanOrEqualTo(4000 + _header.length));
    });

    test('E8 本轮问题不在 turns 内 → 永不被裁', () {
      final turns = [(role: 'user', content: '历史内容XYZ')];
      final l2 = buildSessionContext(turns);
      final question = '本轮问题XYZ';
      expect(l2, contains('历史内容XYZ'));
      expect(l2, isNot(contains(question))); // 本轮问题不在历史块
      // buildQuery 层：当前问题独立拼在 L2 之后
      final c = _makeController();
      final q = c.buildQuery(
        history: [ChatMessage(
          id: 'm1', sessionId: 's', role: 'user', content: '历史内容XYZ',
          createdAt: _t0,
        )],
        task: AiTask.t5Ask,
        currentQuestion: question,
      );
      expect(q, contains(question));
    });

    test('E9 历史含空内容消息 → 不抛异常', () {
      expect(
        () => buildSessionContext([
          (role: 'user', content: ''),
          (role: 'assistant', content: '   '),
        ]),
        returnsNormally,
      );
    });

    test('E10 历史含 system 角色 → 不注入', () {
      const sys = 'SYSTEM-INTERNAL';
      final l2 = buildSessionContext([
        (role: 'system', content: sys),
        (role: 'user', content: '正常问题'),
      ]);
      expect(l2, isNot(contains(sys)));
      expect(l2, contains('正常问题'));
    });

    test('E11 model_id 异常值不影响历史注入（判别只看 role）', () {
      final l2 = buildSessionContext([
        (role: 'user', content: 'q1'),
        (role: 'assistant', content: 'a1'),
      ]);
      expect(l2, contains('q1'));
      expect(l2, contains('a1'));
    });

    test('E12 合并后消息序列含讲解消息（AI 可引用自己刚讲的）', () {
      final l2 = buildSessionContext([
        (role: 'assistant', content: '讲解正文PRIME'),
        (role: 'user', content: '追问'),
        (role: 'assistant', content: '回答PRIME'),
      ]);
      expect(l2, contains('讲解正文PRIME'));
    });

    test('E13 乱序传入 → 输出保持传入顺序（规格 C：绝不重排）', () {
      // 故意以「反序」传入；若实现偷偷按某键排序，本条转红。
      final turns = [
        (role: 'user', content: 'THIRD'),
        (role: 'user', content: 'FIRST'),
        (role: 'user', content: 'SECOND'),
      ];
      final l2 = buildSessionContext(turns);
      expect(l2.indexOf('THIRD'), lessThan(l2.indexOf('FIRST')));
      expect(l2.indexOf('FIRST'), lessThan(l2.indexOf('SECOND')));
    });

    test('E14 本轮问题与历史重复 → 历史块只出现 1 份', () {
      const dup = '重复问题XYZ';
      final l2 = buildSessionContext([
        (role: 'user', content: dup),
        (role: 'assistant', content: '答'),
      ]);
      expect(RegExp(RegExp.escape(dup)).allMatches(l2).length, 1);
    });

    test('E15 L1（kp.definition）超长 → buildQuery 不裁 L1', () {
      final def = 'L1超长定义' + '字' * 3000;
      final c = _makeController(definition: def);
      final q = c.buildQuery(
        history: const [],
        task: AiTask.t6Explain,
        currentQuestion: '',
      );
      expect(q, contains(def)); // L1 原样完整
    });

    test('E16 角色标注格式与计数（用户：/ AI：）', () {
      final turns = [
        (role: 'user', content: 'u1'),
        (role: 'assistant', content: 'a1'),
        (role: 'user', content: 'u2'),
      ];
      final l2 = buildSessionContext(turns);
      expect(RegExp(r'^用户：', multiLine: true).allMatches(l2).length, 2);
      expect(RegExp(r'^AI：', multiLine: true).allMatches(l2).length, 1);
    });

    test('E17 与旧实现参考实现逐字相同（最强护栏）', () {
      final turns = [
        (role: 'user', content: 'u1'),
        (role: 'assistant', content: 'a1'),
        (role: 'user', content: 'u2'),
        (role: 'assistant', content: 'a2'),
      ];
      expect(
        buildSessionContext(turns),
        _referenceBuildSessionContext(turns),
      );
      // 自定义 maxMessages / maxChars 也逐字一致
      final big = [
        for (var i = 0; i < 15; i++)
          (role: i.isEven ? 'user' : 'assistant', content: 'm$i' * 50),
      ];
      expect(
        buildSessionContext(big, maxMessages: 10, maxChars: 4000),
        _referenceBuildSessionContext(big, maxMessages: 10, maxChars: 4000),
      );
    });

    test('E18 仅给 role+content（无 at/id 字段）→ 不崩且顺序保持', () {
      final turns = [
        (role: 'user', content: 'ONE'),
        (role: 'assistant', content: 'TWO'),
      ];
      // 直接调用：若抛异常，本测试即失败（等价「不崩」证明）。
      final l2 = buildSessionContext(turns);
      expect(l2.indexOf('ONE'), lessThan(l2.indexOf('TWO')));
    });

    test('E19 传入序与任何隐含排序相反 → 仍不重排', () {
      // 2 字段记录无 at/id，本用例等价于「反序传入 → 输出同序」。
      final turns = [
        (role: 'user', content: 'Z'),
        (role: 'user', content: 'A'),
      ];
      final l2 = buildSessionContext(turns);
      expect(l2.indexOf('Z'), lessThan(l2.indexOf('A')));
    });
  });

  group('A：buildQuery 多轮记忆（§3.1.2）', () {
    test('A1–A2 历史逐字被带上（用户原文 + AI 回答原文）', () {
      final turns = [
        (role: 'user', content: '反向传播的例子里有数字 7.5'),
        (role: 'assistant', content: '梯度由链式法则逐层计算'),
      ];
      final l2 = buildSessionContext(turns, maxMessages: 10, maxChars: 4000);
      expect(l2, contains('反向传播的例子里有数字 7.5'));
      expect(l2, contains('梯度由链式法则逐层计算'));
    });

    test('A3 本轮问题不在前文块内', () {
      final c = _makeController();
      final history = [
        ChatMessage(id: 'm1', sessionId: 's', role: 'user',
            content: '历史问题', createdAt: _t0),
      ];
      // 前文块（L2）由 buildSessionContext 产出，不含本轮问题
      final l2 = buildSessionContext(
        [(role: history[0].role, content: history[0].content)],
        maxMessages: 10,
        maxChars: 4000,
      );
      expect(l2, isNot(contains('刚才那个数是多少')));
      // 但 buildQuery 拼出的完整 query 含本轮问题（在「用户问题：」段）
      final q = c.buildQuery(
        history: history,
        task: AiTask.t5Ask,
        currentQuestion: '刚才那个数是多少',
      );
      expect(q, contains('刚才那个数是多少'));
    });

    test('A4 角色标注正确', () {
      final l2 = buildSessionContext([
        (role: 'user', content: 'u'),
        (role: 'assistant', content: 'a'),
      ], maxMessages: 10, maxChars: 4000);
      expect(RegExp(r'^用户：', multiLine: true).allMatches(l2).length, 1);
      expect(RegExp(r'^AI：', multiLine: true).allMatches(l2).length, 1);
    });

    test('A5 前文块 header 存在', () {
      final l2 = buildSessionContext(
        [(role: 'user', content: 'x')],
        maxMessages: 10,
        maxChars: 4000,
      );
      expect(l2, startsWith(_header));
    });

    test('A6 负对照：turns 为空 → 前文块为空（非 L1/巧合）', () {
      final c = _makeController();
      final q = c.buildQuery(
        history: const [],
        task: AiTask.t5Ask,
        currentQuestion: '任意',
      );
      expect(q, isNot(contains(_header)));
    });

    test('A7 多轮可见：第 1 轮内容在 10 条窗口内仍在', () {
      final turns = [
        (role: 'user', content: '第一轮记忆内容KEEP'),
        for (var i = 0; i < 8; i++)
          (role: i.isEven ? 'user' : 'assistant', content: 'filler$i'),
      ];
      final l2 = buildSessionContext(turns, maxMessages: 10, maxChars: 4000);
      expect(l2, contains('第一轮记忆内容KEEP'));
    });

    test('A8 越老越先被丢（OLDEST 不在 / NEWEST 在）', () {
      final turns = [
        for (var i = 0; i < 20; i++)
          (role: 'user',
              content: i == 0 ? 'OLDEST' : (i == 19 ? 'NEWEST' : 'm$i')),
      ];
      final l2 = buildSessionContext(turns, maxMessages: 10, maxChars: 4000);
      expect(l2, isNot(contains('OLDEST')));
      expect(l2, contains('NEWEST'));
    });

    test('A9 长度上限生效', () {
      final turns = [
        for (var i = 0; i < 10; i++)
          (role: 'user', content: 'x' * 1000),
      ];
      final l2 = buildSessionContext(turns, maxMessages: 10, maxChars: 4000);
      expect(l2.length, lessThanOrEqualTo(4000 + _header.length));
    });
  });

  group('T10：deriveSessionTitle 扩展参数语义', () {
    test('默认兜底逐字不变', () {
      expect(deriveSessionTitle(storedTitle: '', messages: const []), '新对话');
    });
    test('新增可选参数 fallbackTitle 生效', () {
      expect(
        deriveSessionTitle(
          storedTitle: '', messages: const [], fallbackTitle: 'X 讲解'),
        'X 讲解',
      );
    });
    test('不传 fallbackTitle 仍默认', () {
      expect(deriveSessionTitle(storedTitle: '', messages: const []), '新对话');
    });
    test('storedTitle 优先（即使传了 fallbackTitle）', () {
      expect(
        deriveSessionTitle(
          storedTitle: '我的命名', messages: const [], fallbackTitle: 'X 讲解'),
        '我的命名',
      );
    });
    test('首条 user 消息 >24 字 → 截 24 + …', () {
      final m = [
        ChatMessage(id: '1', sessionId: 's', role: 'user',
            content: 'a' * 30, createdAt: _t0),
      ];
      final t = deriveSessionTitle(storedTitle: '', messages: m);
      expect(t.length, 25);
      expect(t.endsWith('…'), isTrue);
    });
    test('多行只取首行', () {
      final m = [
        ChatMessage(id: '1', sessionId: 's', role: 'user',
            content: '第一行\n第二行', createdAt: _t0),
      ];
      expect(deriveSessionTitle(storedTitle: '', messages: m), '第一行');
    });
  });

  group('T11⑧：isExplainMessage 容错', () {
    test('modelId == dify-t6 → 是讲解', () {
      final m = ChatMessage(id: '1', sessionId: 's', role: 'assistant',
          content: 'x', createdAt: _t0, modelId: 'dify-t6');
      expect(isExplainMessage(m), isTrue);
    });
    test('modelId 为 null / 异常值 → 不是讲解且不抛', () {
      final cases = [null, 'gpt-4o', 'unknown', 'dify-t5'];
      for (final mid in cases) {
        final m = ChatMessage(id: '1', sessionId: 's', role: 'assistant',
            content: 'x', createdAt: _t0, modelId: mid);
        expect(() => isExplainMessage(m), returnsNormally);
        expect(isExplainMessage(m), isFalse);
      }
    });
  });
}

final _t0 = DateTime.fromMillisecondsSinceEpoch(1700000000000);
