/// 同步设备号接线回归测试（2026-10-24 用户实测 bug）。
///
/// 背景：pull 的自回声过滤是「`env.deviceId == 本机 deviceId` → 跳过」
/// （`lib/data/sync/sync_engine.dart:586`）。只要两端拿到**同一个** deviceId，
/// 服务端所有行都会被当成「本机自己上传的」→ 永远 applied=0、skipped=N，
/// 而且换任何中继后端（CF / Netlify / …）表现完全一致，极易被误判成
/// 中继或网络问题（历史上「只有快照没有增量」「应用变更 0 条」都源于此）。
///
/// 曾经的错法：`ExtractionService.bootstrap` 用常量 `'local-dev'` 兜底 deviceId，
/// 而 `main.dart` 又是**无参**调用 bootstrap → 全平台共用一个号码。
///
/// 本测试钉住两件事：
/// 1. `DeviceId.get()` 给出的是每台设备唯一、已持久化的 ULID；
/// 2. 源码守卫：bootstrap 不再把 deviceId 兜底成字面量，且确实用 DeviceId.get()。
library;

import 'dart:io';

import 'package:aimindtree_app/core/id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceId', () {
    test('生成后持久化：非空 ULID，两次调用一致', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DeviceId.overrideForTest(''); // 清掉上一个用例可能留在内存里的缓存
      final a = await DeviceId.get();
      final b = await DeviceId.get();

      expect(a, isNotEmpty);
      expect(a.length, 26, reason: 'ULID 定长 26');
      expect(
        RegExp(r'^[0-9A-Za-z]{26}$').hasMatch(a),
        isTrue,
        reason: 'ULID 只含 Base32 字母数字（大小写视实现而定）',
      );
      expect(b, a, reason: '第二次必须读到持久化的同一个值，不能每次新生成');
    });

    test('已存在的 prefs 值原样复用（不覆盖用户设备号）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'aimindtree.device_id': '01JABCDEFGHJKMNPQRSTVWXYZ0',
      });
      DeviceId.overrideForTest('');
      expect(await DeviceId.get(), '01JABCDEFGHJKMNPQRSTVWXYZ0');
    });
  });

  group('bootstrap 设备号接线（源码守卫）', () {
    test("不再用常量 'local-dev' 兜底 deviceId", () {
      final src = File('lib/ai/extraction_service.dart').readAsStringSync();
      expect(
        src.contains("?? 'local-dev'"),
        isFalse,
        reason: '兜底成常量会让 PC 与手机共用一个设备号 → pull 永远应用 0 条',
      );
      expect(
        src.contains('DeviceId.get()'),
        isTrue,
        reason: '未显式传 deviceId 时必须回落到本机真实设备号',
      );
    });
  });
}
