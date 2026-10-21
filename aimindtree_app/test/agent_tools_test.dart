/// AI 助手知识库工具测试（只读工具 + 权限闸 + 工具调用解析）。
///
/// 覆盖：
/// 1. `AgentToolset.parseCall` 对模型各类输出形态的判定（纯 JSON / 围栏 /
///    夹带解释 / 思考块 / 自然语言 / 形状不对……）；
/// 2. `catalogText` 目录完整性；
/// 3. 7 个只读工具的内存库端到端（建笔记 → 提取知识点 → 建树 → 并入）；
/// 4. 权限预留闸：非 `owner` 权限级的工具一律拒绝（permission_not_granted）；
/// 5. 未知工具 / 缺参数 / 不存在 id 的错误回补（喂回模型自我纠正）。
library;

import 'dart:convert';

import 'package:aimindtree_app/ai/agent_tools.dart';
import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/models/knowledge_tree.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late KnowledgeRepository repo;
  late TreeRepository trees;
  late AgentToolset toolset;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = KnowledgeRepository(db, deviceId: 'test-device');
    trees = TreeRepository(db, deviceId: 'test-device');
    toolset = AgentToolset.create(repo: repo, trees: trees);
  });

  tearDown(() async {
    await db.close();
  });

  Map<String, dynamic> decode(String s) => jsonDecode(s) as Map<String, dynamic>;

  /// 建一篇笔记 + 一个知识点 + 一棵树，并把点并入树。返回 (noteId, kpId, treeId)。
  Future<(String, String, String)> seed() async {
    const content = '牛顿第一定律：任何物体都要保持匀速直线运动或静止状态。';
    await repo.saveNote(Note(id: 'n1', contentMd: content));
    final ext = await repo.saveExtracted(
      noteId: 'n1',
      noteContent: content,
      rawPoints: const [
        RawKnowledgePoint(
          name: '牛顿第一定律',
          type: '定理',
          definition: '物体在不受外力时保持静止或匀速直线运动。',
          sourceQuote: '任何物体都要保持匀速直线运动',
          confidence: 0.95,
        ),
      ],
    );
    final kpId = (ext as Success<ExtractionSaveResult>).value.saved.first.id;
    final created = await trees.createTree('物理');
    final tree = (created as Success<KnowledgeTree>).value;
    await trees.addPoints(tree.id, [kpId]);
    return ('n1', kpId, tree.id);
  }

  // ---------------------------------------------------------------- parseCall

  group('parseCall：模型输出 → 工具调用判定', () {
    void expectCall(String label, String raw, String? wantTool) {
      final call = AgentToolset.parseCall(raw);
      expect(call?.name, wantTool, reason: label);
    }

    test('纯 JSON / 带参数 / json 围栏', () {
      expectCall('纯 JSON', '{"tool":"list_knowledge_trees","args":{}}', 'list_knowledge_trees');
      expectCall(
        '带参数',
        '{"tool":"list_tree_points","args":{"tree_id":"abc"}}',
        'list_tree_points',
      );
      expectCall(
        'json 围栏',
        '```json\n{"tool":"find_knowledge_points","args":{"keyword":"导数"}}\n```',
        'find_knowledge_points',
      );
    });

    test('夹带解释文字 / 思考块包裹 → 仍能解析（括号配对扫描）', () {
      expectCall(
        '夹带解释',
        '好的，我先查一下这棵树。\n{"tool":"get_note","args":{"note_id":"n1"}}',
        'get_note',
      );
      expectCall(
        '思考块',
        '<think>用户问导数，先看树里有什么</think>\n{"tool":"list_knowledge_trees"}',
        'list_knowledge_trees',
      );
    });

    test('自然语言回答 / 空输出 / 形状不对 → 不是调用', () {
      expectCall('自然语言回答', '导数描述的是变化率，微分是它的局部线性化……', null);
      expectCall('空输出', '', null);
      expectCall('tool 非字符串', '{"tool":123,"args":{}}', null);
      expectCall('无 tool 键', '{"args":{"tree_id":"x"}}', null);
      expectCall('JSON 数组', '[{"tool":"list_notes"}]', null);
    });

    test('未知工具名也返回调用（交给 dispatch 回错误自我纠正）', () {
      expectCall('未知工具名', '{"tool":"no_such_tool","args":{}}', 'no_such_tool');
    });

    test('args 缺失 → 空 map', () {
      final call = AgentToolset.parseCall('{"tool":"list_notes"}');
      expect(call, isNotNull);
      expect(call!.args, isEmpty);
    });
  });

  // ---------------------------------------------------------------- catalogText

  group('catalogText', () {
    test('7 个工具与关键参数都在目录里', () {
      final text = toolset.catalogText();
      for (final name in const [
        'list_knowledge_trees',
        'list_tree_points',
        'get_knowledge_point',
        'find_knowledge_points',
        'list_notes',
        'get_note',
        'get_point_relations',
      ]) {
        expect(text, contains(name), reason: '目录缺少 $name');
      }
      expect(text, contains('tree_id'));
      expect(text, contains('keyword'));
    });

    test('tools 列表与目录一一对应', () {
      expect(toolset.tools.length, 7);
      expect(toolset.tools.every((t) => t.permission == AgentToolPermission.owner), isTrue,
          reason: '现有工具必须全部是 owner 权限级');
    });
  });

  // ---------------------------------------------------------------- 只读工具

  group('只读工具（内存库端到端）', () {
    test('list_knowledge_trees：树名 + 知识点数', () async {
      final (_, _, treeId) = await seed();
      final out = decode(await toolset.dispatch('list_knowledge_trees', const {}));
      final list = out['trees'] as List;
      expect(list, hasLength(1));
      expect(list.first['name'], '物理');
      expect(list.first['point_count'], 1);
      expect(list.first['id'], treeId);
    });

    test('list_tree_points：成员 + 缺参 / 不存在树的错误', () async {
      final (_, _, treeId) = await seed();
      final out = decode(await toolset.dispatch(
        'list_tree_points',
        {'tree_id': treeId},
      ));
      final pts = out['points'] as List;
      expect(pts, hasLength(1));
      expect(pts.first['name'], '牛顿第一定律');
      expect(pts.first['type'], '定理');

      final missing = decode(await toolset.dispatch('list_tree_points', const {}));
      expect(missing['error'], 'missing_arg');

      final notFound = decode(await toolset.dispatch(
        'list_tree_points',
        {'tree_id': 'no-such-tree'},
      ));
      expect(notFound['error'], 'not_found');
    });

    test('get_knowledge_point / get_note：详情与正文', () async {
      final (noteId, kpId, _) = await seed();
      final p = decode(await toolset.dispatch(
        'get_knowledge_point',
        {'point_id': kpId},
      ));
      expect(p['name'], '牛顿第一定律');
      expect(p['definition'], isNotEmpty);
      expect(p['source_note_id'], noteId);

      final bad = decode(await toolset.dispatch(
        'get_knowledge_point',
        {'point_id': 'nope'},
      ));
      expect(bad['error'], 'not_found');

      final n = decode(await toolset.dispatch('get_note', {'note_id': noteId}));
      expect(n['title'], isEmpty); // 笔记无标题 → 空串
      expect(n['content'] as String, contains('牛顿第一定律'));
    });

    test('find_knowledge_points：关键字命中 / 未命中', () async {
      await seed();
      final hit = decode(await toolset.dispatch(
        'find_knowledge_points',
        {'keyword': '牛顿'},
      ));
      expect((hit['hits'] as List), hasLength(1));
      expect(hit['total_scanned'], greaterThanOrEqualTo(1));

      final miss = decode(await toolset.dispatch(
        'find_knowledge_points',
        {'keyword': '量子纠缠xyz'},
      ));
      expect(miss['hits'], isEmpty);

      final noKw = decode(await toolset.dispatch(
        'find_knowledge_points',
        const {},
      ));
      expect(noKw['error'], 'missing_arg');
    });

    test('list_notes：软删笔记不出现', () async {
      final (noteId, _, _) = await seed();
      await repo.saveNote(Note(id: 'n2', contentMd: '第二篇'));
      // 软删 n2：直接写 deletedAt（仓库删除路径的等价最小动作）。
      await (db.update(db.notes)..where((t) => t.id.equals('n2'))).write(
        NotesCompanion(deletedAt: drift.Value(DateTime.now().toUtc())),
      );
      final out = decode(await toolset.dispatch('list_notes', const {}));
      final list = out['notes'] as List;
      expect(list, hasLength(1), reason: '已软删的笔记不得被工具看到');
      expect(list.first['id'], noteId);
      expect(list.first['excerpt'] as String, contains('牛顿'));
    });

    test('get_point_relations：无边时返回空数组', () async {
      final (_, kpId, _) = await seed();
      final out = decode(await toolset.dispatch(
        'get_point_relations',
        {'point_id': kpId},
      ));
      expect(out['prerequisites'], isEmpty);
      expect(out['successors'], isEmpty);
    });

    test('未知工具 → unknown_tool 错误（喂回模型自我纠正）', () async {
      final out = decode(await toolset.dispatch('delete_everything', const {}));
      expect(out['error'], 'unknown_tool');
    });
  });

  // ---------------------------------------------------------------- 权限闸

  group('权限预留闸（AgentToolPermission）', () {
    test('非 owner 权限级的工具一律拒绝，owner 放行', () async {
      final sharedTool = AgentTool(
        name: 'read_shared_library',
        description: '预留：共享库（未启用）',
        permission: AgentToolPermission.shared,
        params: const [],
        exec: (_) async => '{"ok":true}',
      );
      final ownerTool = AgentTool(
        name: 'read_owner_extra',
        description: '测试用 owner 工具',
        permission: AgentToolPermission.owner,
        params: const [],
        exec: (_) async => '{"ok":true}',
      );
      final ts = AgentToolset.create(
        repo: repo,
        trees: trees,
        extraTools: [sharedTool, ownerTool],
      );

      final denied = decode(await ts.dispatch('read_shared_library', const {}));
      expect(denied['error'], 'permission_not_granted');
      expect(denied['message'] as String, contains('shared'));

      final allowed = decode(await ts.dispatch('read_owner_extra', const {}));
      expect(allowed['ok'], isTrue);
    });
  });
}
