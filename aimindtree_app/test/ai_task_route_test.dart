/// AiTaskRouter 任务级路由测试。
///
/// 覆盖 ARCHITECTURE §6 的解析优先级：
/// ① `ai_task_routes` 命中 → 用其 provider；
/// ② 专属任务（T3/T4）未命中 → **返回 null**（禁止回落 T1）；
/// ③ 通用任务未命中 → 回落 fallback。
///
/// 需要 sqlite3 native assets；沙箱里不可用，故沿用 skip 探测。
library;

import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProvider implements AiProvider {
  _FakeProvider(this.id);

  @override
  final String id;

  @override
  String get protocol => 'dify';

  @override
  Future<AiTaskResult> runTask(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 120),
  }) async =>
      AiTaskResult(content: '$id:${task.code}');

  @override
  Stream<AiChunk> streamChat(
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 120),
  }) async* {
    yield AiChunk(delta: id, done: true);
  }

  @override
  void dispose() {}
}

void main() {
  final shouldSkip = !_probeSqlite();

  group('AiTaskRouter.resolve', skip: shouldSkip, () {
    late AppDatabase db;
    late _FakeProvider t1Provider;
    late _FakeProvider t3Provider;
    late AiTaskRouter router;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      t1Provider = _FakeProvider('p-t1');
      t3Provider = _FakeProvider('p-t3');
      router = AiTaskRouter(
        db: db,
        providers: <String, AiProvider>{
          t1Provider.id: t1Provider,
          t3Provider.id: t3Provider,
        },
        fallback: t1Provider,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('T3 未绑定 → null（禁止回落 T1 工作流）', () async {
      expect(await router.resolve(AiTask.t3Prerequisite), isNull);
      expect(await router.resolve(AiTask.t4GapAnalysis), isNull);
    });

    test('T3 绑定后 → 返回绑定的 provider', () async {
      await db.aiTaskRouteDao.bind(
        task: AiTask.t3Prerequisite,
        providerId: t3Provider.id,
      );
      final p = await router.resolve(AiTask.t3Prerequisite);
      expect(p, isNotNull);
      expect(p!.id, t3Provider.id);
    });

    test('T3 绑定到未实例化的 provider id → 仍是 null', () async {
      await db.aiTaskRouteDao.bind(
        task: AiTask.t3Prerequisite,
        providerId: 'p-not-loaded',
      );
      expect(await router.resolve(AiTask.t3Prerequisite), isNull);
    });

    test('T1 未绑定 → 回落 fallback', () async {
      expect(await router.resolve(AiTask.t1Extract), same(t1Provider));
    });

    test('T1 绑定 → 绑定优先于 fallback', () async {
      await db.aiTaskRouteDao.bind(
        task: AiTask.t1Extract,
        providerId: t3Provider.id,
      );
      final p = await router.resolve(AiTask.t1Extract);
      expect(p!.id, t3Provider.id);
    });

    test('路由查询失败不致命：db 为 null 时按 ②③ 走', () async {
      final noDb = AiTaskRouter(
        providers: <String, AiProvider>{t3Provider.id: t3Provider},
        fallback: t1Provider,
      );
      expect(await noDb.resolve(AiTask.t3Prerequisite), isNull);
      expect(await noDb.resolve(AiTask.t1Extract), same(t1Provider));
    });
  });
}

bool _probeSqlite() {
  try {
    NativeDatabase.memory();
    return true;
  } on Object {
    return false;
  }
}
