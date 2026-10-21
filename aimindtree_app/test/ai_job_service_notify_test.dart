/// AiJobService 通知合流回归测试（P0-1）。
///
/// 根因：旧版 ``_notify()`` 同步 ``revision.value++``，若监听者
/// （JobTray）在父 widget 的 build 阶段（如 ``TeacherPage.initState`` 调
/// ``holdInteractive`` 触发的通知）做 ``setState``，会抛
/// 「setState() or markNeedsBuild() called during build」并黑屏。
///
/// 修复：``_notify()`` 把 +1 合流并延后到微任务。本测试锁定两条不变量：
///   1. 同步调用 ``_notify``（经 ``holdInteractive``）不会立刻改 ``revision.value``；
///   2. 一帧内多次 ``_notify`` 只 +1（合流），而非按调用次数累加。
import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AiJobService 通知合流（P0-1 防黑屏）', () {
    test('holdInteractive 同步调用不立即 bump revision', () async {
      final svc = AiJobService(baseUrl: 'http://127.0.0.1:1');
      final before = svc.revision.value;
      final id = svc.holdInteractive('kp:1', label: '老师模式');
      // 同步点：通知被延后到微任务，revision 此刻不应变化。
      expect(svc.revision.value, equals(before));
      // 让微任务跑完。
      await Future.microtask(() {});
      expect(svc.revision.value, equals(before + 1));
      svc.releaseInteractive(id);
    });

    test('一帧内多次 notify 只 +1（合流）', () async {
      final svc = AiJobService(baseUrl: 'http://127.0.0.1:1');
      final before = svc.revision.value;
      // 模拟高频轮询 / 多次状态变化在同一帧内发生。
      final ids = <String>[];
      for (var i = 0; i < 5; i++) {
        ids.add(svc.holdInteractive('kp:$i', label: '会话$i'));
      }
      // 同步点：无论调用几次，都不该有同步 +1。
      expect(svc.revision.value, equals(before));
      await Future.microtask(() {});
      // 合流后只 +1。
      expect(svc.revision.value, equals(before + 1));
      // 释放所有交互锁。
      for (final id in ids) {
        svc.releaseInteractive(id);
      }
    });
  });
}
