// AppConfigService 纯函数测试（复用 tool/smoke_app_config.dart 的断言集）。
//
// 与 tool 版同源：断言只写一份，既能 `flutter run -d windows` 直跑看明细，
// 也能 `flutter test` 无头回归（CI / 沙箱都能跑）。
library;

import 'package:aimindtree_app/ai/app_config_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/smoke_app_config.dart';

void main() {
  test('AppConfigService.parse / shouldWrite 全部断言通过', () {
    final checks = runSmokeChecks();
    final failed = checks.where((c) => !c.passed).toList(growable: false);
    expect(
      failed,
      isEmpty,
      reason: failed.isEmpty
          ? ''
          : '失败 ${failed.length} 条：\n' +
              failed.map((c) => '  - ${c.name}: ${c.detail}').join('\n'),
    );
  });

  test('降级快照自带内置默认值（服务不可达时用）', () {
    final snap = AppConfigSnapshot.builtin();
    expect(snap.baseUrl, 'http://127.0.0.1:8787');
    expect(snap.backend, 'auto');
    expect(snap.model, '');
    expect(snap.sync.tokenSet, isFalse);
    expect(snap.configSha1, '');
  });
}
