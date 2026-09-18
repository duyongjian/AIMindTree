/// SecretStore 单元测试（T07）。
///
/// 只覆盖纯 dart 实现（InMemorySecretStore），不依赖 path_provider。
/// FileSecretStore 在沙箱里 path_provider 不可用，留作真机测试。
library;

import 'package:aimindtree_app/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InMemorySecretStore（测试用）', () {
    test('get 未设置的 key 返回 null', () async {
      final store = InMemorySecretStore();
      expect(await store.get('nope'), isNull);
    });

    test('set + get 往返一致', () async {
      final store = InMemorySecretStore();
      await store.set('alpha', 'token-a');
      await store.set('beta', 'token-b');
      expect(await store.get('alpha'), 'token-a');
      expect(await store.get('beta'), 'token-b');
    });

    test('set 覆盖旧值', () async {
      final store = InMemorySecretStore();
      await store.set('k', 'v1');
      await store.set('k', 'v2');
      expect(await store.get('k'), 'v2');
    });

    test('delete 移除 key', () async {
      final store = InMemorySecretStore();
      await store.set('k', 'v');
      await store.delete('k');
      expect(await store.get('k'), isNull);
    });

    test('delete 不存在的 key 不抛', () async {
      final store = InMemorySecretStore();
      await store.delete('nope');
      expect(await store.get('nope'), isNull);
    });

    test('all 返回当前所有 kv 快照（修改不影响返回的 Map）', () async {
      final store = InMemorySecretStore();
      await store.set('a', '1');
      await store.set('b', '2');
      final snap = await store.all();
      expect(snap, {'a': '1', 'b': '2'});
      // 修改 store 不影响快照
      await store.set('a', '!');
      expect(snap['a'], '1');
      // 修改快照也不影响 store
      snap['c'] = '3';
      expect(await store.get('c'), isNull);
    });
  });
}