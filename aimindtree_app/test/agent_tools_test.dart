/// AI 助手知识库工具测试（只读工具 + 权限闸 + 工具调用解析）。
///
/// 覆盖：
/// 1. `AgentToolset.parseCall` 对模型各类输出形态的判定（纯 JSON / 围栏 /
///    夹带解释 / 思考块 / 自然语言 / 形状不对……）；
/// 2. `catalogText` 目录完整性；
/// 3. 7 个只读工具的内存库端到端（建笔记 → 提取知识点 → 建树 → 并入）；
/// 4. 权限预留闸：非 `owner` 权限级的工具一律拒绝（permission_not_granted）；
/// 5. 未知工具 / 缺参数 / 不存在 id 的错误回补（喂回模型自我纠正）；
/// 6. 工具层「引用解析」：tree_id / point_id 传 id 或名称都能工作，
///    重名回 `ambiguous_ref`、查不到回 `not_found` + 结构化 `candidates`。
library;

import 'dart:convert';

import 'package:aimindtree_app/ai/agent_tools.dart';
import 'package:aimindtree_app/core/result.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/models/knowledge_point.dart';
import 'package:aimindtree_app/data/models/knowledge_tree.dart';
import 'package:aimindtree_app/data/repositories/group_repository.dart';
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

    test('list_tree_points：缺 tree_id 时回退当前激活树（问题2）', () async {
      final (_, _, treeId) = await seed();
      // 未设激活树时仍报 missing_arg（旧行为不变）。
      final before = decode(await toolset.dispatch('list_tree_points', const {}));
      expect(before['error'], 'missing_arg');

      toolset.setActiveTree(treeId);
      final out = decode(await toolset.dispatch('list_tree_points', const {}));
      expect(out['tree']['id'], treeId);
      expect(out['points'] as List, hasLength(1));

      // 显式传入的 tree_id 优先于激活树：另建空树并显式指定。
      final other = await trees.createTree('化学');
      final otherId = (other as Success<KnowledgeTree>).value.id;
      final explicit = decode(await toolset.dispatch(
        'list_tree_points',
        {'tree_id': otherId},
      ));
      expect(explicit['tree']['id'], otherId);
      expect(explicit['points'] as List, isEmpty);

      // 清空激活树后恢复 missing_arg。
      toolset.setActiveTree(null);
      final cleared = decode(await toolset.dispatch('list_tree_points', const {}));
      expect(cleared['error'], 'missing_arg');
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

  // ------------------------------------------------ 工具层引用解析（id / 名称）

  group('工具层引用解析：id 查不到时按名称唯一匹配', () {
    test('list_tree_points：传树名 → 解析成真实树并返回成员', () async {
      final (_, _, treeId) = await seed();
      final out = decode(await toolset.dispatch(
        'list_tree_points',
        {'tree_id': '物理'},
      ));
      expect(out.containsKey('error'), isFalse, reason: '树名应被解析，不该 not_found');
      expect(out['tree'], {'id': treeId, 'name': '物理'});
      final pts = out['points'] as List;
      expect(pts, hasLength(1));
      expect(pts.first['name'], '牛顿第一定律');
    });

    test('list_tree_points：树名大小写 / 前后空格不敏感', () async {
      final created = await trees.createTree('Linear Algebra');
      final treeId = (created as Success<KnowledgeTree>).value.id;
      final out = decode(await toolset.dispatch(
        'list_tree_points',
        {'tree_id': '  linear algebra  '},
      ));
      expect(out['tree']['id'], treeId);
      expect(out['points'] as List, isEmpty);
    });

    test('list_tree_points：名字不存在 → not_found + 结构化 candidates', () async {
      final (_, _, treeId) = await seed();
      final out = decode(await toolset.dispatch(
        'list_tree_points',
        {'tree_id': 'linear_algebra'},
      ));
      expect(out['error'], 'not_found');
      final cands = out['candidates'] as List;
      expect(cands, isNotEmpty, reason: '必须回候选让模型自我纠正');
      expect(cands.first['id'], treeId);
      expect(cands.first['name'], '物理');
      expect(out['hint'], isNotEmpty);
      final msg = out['message'] as String;
      expect(msg, contains('linear_algebra'), reason: '保留原始输入便于模型对照');
      expect(msg, isNot('知识树不存在：linear_algebra'),
          reason: 'message 要说明「既不是 id 也不是树名」，不能只是回显输入');
    });

    test('list_tree_points：传真实 id 行为不变（回归护栏）', () async {
      final (_, _, treeId) = await seed();
      final out = decode(await toolset.dispatch(
        'list_tree_points',
        {'tree_id': treeId},
      ));
      expect(out.containsKey('error'), isFalse);
      expect(out['tree'], {'id': treeId, 'name': '物理'});
      expect(out['points'] as List, hasLength(1));
      expect(out['truncated'], isFalse);
    });

    test('list_tree_points：两棵同名树 + 传名字 → ambiguous_ref（候选 2 条）', () async {
      final (_, _, treeId) = await seed();
      final dup = await trees.createTree('物理');
      final dupId = (dup as Success<KnowledgeTree>).value.id;
      final out = decode(await toolset.dispatch(
        'list_tree_points',
        {'tree_id': '物理'},
      ));
      expect(out['error'], 'ambiguous_ref');
      final cands = out['candidates'] as List;
      expect(cands, hasLength(2), reason: '重名时必须列出全部候选，让模型改用 id');
      expect(cands.map((c) => c['id']).toSet(), {treeId, dupId});
      expect(out['message'] as String, contains('不唯一'));
      expect(out.containsKey('points'), isFalse, reason: '重名时绝不能猜一棵返回数据');
    });

    test('写工具 plan：树名换成真实 id，绝不把名称传给仓库', () async {
      final (_, kpId, treeId) = await seed();

      final rename = await toolset.planWrite(
        'rename_knowledge_tree',
        {'tree_id': '物理', 'name': '物理2'},
      );
      expect(rename.isError, isFalse);
      expect(rename.args['tree_id'], treeId);
      expect(rename.summary, contains('物理'));

      final add = await toolset.planWrite(
        'add_points_to_tree',
        {'tree_id': '物理', 'point_ids': [kpId]},
      );
      expect(add.isError, isFalse);
      expect(add.args['tree_id'], treeId);

      final rm = await toolset.planWrite(
        'remove_points_from_tree',
        {'tree_id': '物理', 'point_ids': [kpId]},
      );
      expect(rm.isError, isFalse);
      expect(rm.args['tree_id'], treeId);

      final del = await toolset.planWrite(
        'delete_knowledge_tree',
        {'tree_id': '物理'},
      );
      expect(del.isError, isFalse);
      expect(del.args['tree_id'], treeId);

      final bad = await toolset.planWrite(
        'rename_knowledge_tree',
        {'tree_id': 'no_such_tree_xyz', 'name': 'x'},
      );
      expect(bad.isError, isTrue);
      expect(bad.error as String, contains('物理'), reason: 'plan 报错要带候选名称');
      expect(bad.error as String, contains(treeId), reason: 'plan 报错要带候选 id');
    });

    test('create_group：scope 传不存在的树名 → 规划失败（此前不校验存在性）', () async {
      final groups = GroupRepository(db, deviceId: 'test-device');
      final ts = AgentToolset.create(repo: repo, trees: trees, groups: groups);
      await seed();

      final bad = await ts.planWrite('create_group', {'name': 'g1', 'scope': '不存在的树'});
      expect(bad.isError, isTrue, reason: 'scope 必须校验存在性，不能写进悬空 canvas_id');
      expect(bad.error as String, contains('找不到知识树'));

      final ok = await ts.planWrite('create_group', {'name': 'g1', 'scope': '物理'});
      expect(ok.isError, isFalse);
      expect(ok.summary, contains('物理'));
      final created = decode(await ts.executeWrite('create_group', ok.args));
      expect(created['ok'], isTrue);

      // 留空 / "global" 仍是全局分组（不挂树），语义不变。
      final global = await ts.planWrite('create_group', {'name': 'g2'});
      expect(global.isError, isFalse);
      expect(global.args['scope'], '');
      expect(global.summary, contains('全局'));
    });

    test('get_knowledge_point：传知识点名称 → 成功', () async {
      final (noteId, kpId, _) = await seed();
      final p = decode(await toolset.dispatch(
        'get_knowledge_point',
        {'point_id': ' 牛顿第一定律 '},
      ));
      expect(p.containsKey('error'), isFalse, reason: '知识点名称应被解析');
      expect(p['id'], kpId);
      expect(p['name'], '牛顿第一定律');
      expect(p['source_note_id'], noteId);
      expect(p['definition'], isNotEmpty);
    });

    test('get_knowledge_point：名称查不到 → not_found + 名称包含关键字的候选', () async {
      final (_, kpId, _) = await seed();
      final out = decode(await toolset.dispatch(
        'get_knowledge_point',
        {'point_id': '牛顿'},
      ));
      expect(out['error'], 'not_found');
      final cands = out['candidates'] as List;
      expect(cands, hasLength(1));
      expect(cands.first['id'], kpId);
      expect(cands.first['name'], '牛顿第一定律');
      expect(out['hint'], isNotEmpty);
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
