// AppConfigService 纯函数自检（**不连网、不依赖数据库**）。
//
// 只测两件事（沙箱里能确定的部分）：
//   ① parse()：正常下发 / 旧版本（schema!=1）/ 非 JSON 对象 / 缺字段；
//   ② shouldWrite()：sha1 + 四列的双判据（首次 / 相同 / sha1 变 / 列被改）。
//
// 网络部分（fetch 的候选枚举、3s/8s 预算、404 降级、apply 落库）不在这里测：
// 跨进程访问 127.0.0.1:8787 会被沙箱 loopback 隔离（C7），需真机补验。
//
// 用法（在 aimindtree_app 目录）：
//   flutter run -d windows tool/smoke_app_config.dart     # 桌面端直接跑
//   flutter test test/app_config_service_test.dart        # 同一套断言走 flutter_test
//
// ⚠️ 本文件 import 了 Flutter 依赖（经 settings_repository → drift），
// 因此**必须**用 flutter 工具链运行，裸 `dart run` 会因为缺 dart:ui 失败。
library;

import 'dart:convert';
import 'dart:io';

import 'package:aimindtree_app/ai/app_config_service.dart';
import 'package:aimindtree_app/ai/clients/llm_server_client.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/repositories/settings_repository.dart';

/// 一条自检结果。
class SmokeCheck {
  const SmokeCheck(this.name, this.passed, [this.detail = '']);

  final String name;
  final bool passed;
  final String detail;
}

/// 正常下发的样例（与服务端 `core/app_config.py` 的 13 字段逐一对应）。
Map<String, dynamic> samplePayload() => <String, dynamic>{
      'schema': 1,
      'server_version': '0.1.0',
      'service_name': 'AIMindTree AI 服务',
      'protocol': 'llm_server',
      'base_url': 'http://127.0.0.1:8787',
      'backend': 'ollama',
      'model': 'qwen3:8b-8k',
      'console_url': 'http://127.0.0.1:8787/admin',
      'timeouts': <String, dynamic>{
        'structured_s': 120,
        'chat_s': 120,
        'connect_s': 10,
      },
      'task_backends': <String, dynamic>{
        'T1': <String, dynamic>{'backend': 'ollama', 'model': 'qwen3:8b-8k'},
        'T3': null,
      },
      'sync': <String, dynamic>{
        'base_url': '',
        'enabled': false,
        'token_set': false,
      },
      'config_sha1': 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678',
      'updated_at': '2026-10-21T16:00:00+08:00',
    };

/// 跑全部断言，返回逐条结果（供 tool 与 flutter_test 共用）。
List<SmokeCheck> runSmokeChecks() {
  final out = <SmokeCheck>[];

  void expect(String name, bool cond, [String detail = '']) {
    out.add(SmokeCheck(name, cond, detail));
  }

  // ---------------- A. parse() ----------------

  try {
    final snap = AppConfigService.parse(samplePayload());
    expect('A① schema == 1', snap.schema == 1, '${snap.schema}');
    expect('A① base_url 正确', snap.baseUrl == 'http://127.0.0.1:8787',
        snap.baseUrl);
    expect('A① backend 正确', snap.backend == 'ollama', snap.backend);
    expect('A① model 正确', snap.model == 'qwen3:8b-8k', snap.model);
    expect(
      'A① timeouts 解析正确',
      snap.timeouts['structured_s'] == 120 && snap.timeouts['connect_s'] == 10,
      snap.timeouts.toString(),
    );
    expect(
      'A① sync 恒有值（Q-C：App 不用判 null）',
      !snap.sync.tokenSet && snap.sync.baseUrl.isEmpty,
      'baseUrl="${snap.sync.baseUrl}" enabled=${snap.sync.enabled} '
          'tokenSet=${snap.sync.tokenSet}',
    );
    expect(
      'A① task_backends 保留 null（= 跟随全局）',
      snap.taskBackends.containsKey('T1') && snap.taskBackends['T3'] == null,
      snap.taskBackends.toString(),
    );
    expect('A① shortSha1 前 8 位', snap.shortSha1.length == 8, snap.shortSha1);
  } on Object catch (e) {
    expect('A① 正常下发解析', false, '$e');
  }

  // ② 旧版本（schema != 1）→ 必须抛 FormatException（走 404 同款降级）
  var threw = false;
  String thrown = '';
  try {
    final v2 = samplePayload();
    v2['schema'] = 2;
    AppConfigService.parse(v2);
  } on FormatException catch (e) {
    threw = true;
    thrown = e.message;
  } on Object catch (e) {
    thrown = '${e.runtimeType}: $e';
  }
  expect('A② schema=2 → FormatException', threw, thrown);

  // ③ 非 JSON 对象
  threw = false;
  try {
    AppConfigService.parse(<Object?>[]);
  } on FormatException {
    threw = true;
  } on Object {
    threw = false;
  }
  expect('A③ 非 JSON 对象 → FormatException', threw);

  // ④ 缺关键字段
  for (final missing in <String>['base_url', 'backend']) {
    final payload = samplePayload()..remove(missing);
    var missThrew = false;
    try {
      AppConfigService.parse(payload);
    } on FormatException {
      missThrew = true;
    } on Object {
      missThrew = false;
    }
    expect('A④ 缺 $missing → FormatException', missThrew);
  }

  // ⑤ 内置默认快照（服务不可达 / 旧版本时用）
  final builtin = AppConfigSnapshot.builtin();
  expect(
    'A⑤ 内置默认 = $kLlmServerDefaultBaseUrl + auto',
    builtin.baseUrl == kLlmServerDefaultBaseUrl && builtin.backend == 'auto',
    '${builtin.baseUrl} / ${builtin.backend}',
  );

  // ---------------- B. shouldWrite() ----------------

  final snap = AppConfigService.parse(samplePayload());
  const name = 'AIMindTree AI 服务';
  const base = 'http://127.0.0.1:8787';
  const backend = 'ollama';
  const model = 'qwen3:8b-8k';

  final row = AiProviderRow(
    id: 'row-1',
    name: name,
    type: backend,
    protocol: kLlmServerProtocol,
    baseUrl: base,
    apiKeyRef: '',
    models: jsonEncode(<String>[model]),
    isDefault: true,
    enabled: true,
  );

  bool write({String? lastSha1, AiProviderRow? target, String m = model}) =>
      AppConfigService.shouldWrite(
        lastSha1: lastSha1,
        snap: snap,
        row: target,
        name: name,
        base: base,
        backend: backend,
        model: m,
      );

  expect('B① 首次（无 sha1）→ 要写', write(lastSha1: null, target: row));
  expect('B② 有 sha1 但表里没行 → 要写',
      write(lastSha1: snap.configSha1, target: null));
  expect(
    'B③ sha1 相同 + 四列一致 → 跳过（N-7 不刷新 updated_at）',
    !write(lastSha1: snap.configSha1, target: row),
  );
  expect('B④ sha1 变了 → 要写', write(lastSha1: '上一个版本的sha1', target: row));
  expect('B⑤ 四列被改（模型不同）→ 要写',
      write(lastSha1: snap.configSha1, target: row, m: '另一个模型'));
  expect(
    'B⑥ 连续两次判定一致（幂等）',
    !write(lastSha1: snap.configSha1, target: row) &&
        !write(lastSha1: snap.configSha1, target: row),
  );

  // ⑧ 服务一直不可达时的降级路径：sha1 为空串也要能命中「已写过」
  final builtinRow = AiProviderRow(
    id: 'row-2',
    name: name,
    type: 'auto',
    protocol: kLlmServerProtocol,
    baseUrl: base,
    apiKeyRef: '',
    models: '[]',
    isDefault: true,
    enabled: true,
  );
  bool writeBuiltin({String? lastSha1, AiProviderRow? target}) =>
      AppConfigService.shouldWrite(
        lastSha1: lastSha1,
        snap: AppConfigSnapshot.builtin(),
        row: target,
        name: name,
        base: base,
        backend: 'auto',
        model: '',
      );
  expect(
    'B⑧ 降级首次（无 sha1）→ 要写',
    writeBuiltin(lastSha1: null, target: builtinRow),
  );
  expect(
    'B⑧ 降级第二次（sha1 为空串 + 四列一致）→ 跳过（不重复写库）',
    !writeBuiltin(lastSha1: '', target: builtinRow),
  );

  // ⑨ 白名单容错：非法 backend 一律收敛为 auto（C8 唯一实现）
  expect(
    'B⑨ backendOf 白名单容错',
    backendOf('不存在的后端') == 'auto' && backendOf('ollama') == 'ollama',
    "backendOf('不存在的后端')=${backendOf('不存在的后端')}",
  );
  expect(
    'B⑨ firstModel JSON 容错',
    firstModel('[]') == '' &&
        firstModel(jsonEncode(<String>['qwen3:8b-8k'])) == 'qwen3:8b-8k' &&
        firstModel('不是 JSON') == '',
  );

  return out;
}

Future<void> main() async {
  stdout.writeln('=' * 72);
  stdout.writeln('AppConfigService 纯函数自检（不连网）');
  stdout.writeln('=' * 72);

  final checks = runSmokeChecks();
  var pass = 0;
  var fail = 0;
  for (final c in checks) {
    if (c.passed) {
      pass++;
      stdout.writeln('  ✅ ${c.name}${c.detail.isEmpty ? '' : '  —— ${c.detail}'}');
    } else {
      fail++;
      stdout.writeln('  ❌ ${c.name}${c.detail.isEmpty ? '' : '\n      ${c.detail}'}');
    }
  }

  stdout.writeln('');
  stdout.writeln('-' * 72);
  stdout.writeln('结果：$pass 通过，$fail 失败（共 ${checks.length} 条）');
  if (fail > 0) {
    stdout.writeln('❌ smoke_app_config FAILED');
    exit(1);
  }
  stdout.writeln('✅ smoke_app_config PASSED');
  exit(0);
}
