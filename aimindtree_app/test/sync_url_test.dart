/// normalizeSyncBaseUrl：Vercel 缺 /api 前缀自动补全。
///
/// 2026-10-24 用户实测「注册失败：auth auth/register 返回 404」的根治防呆——
/// Vercel 平台把 api/ 函数挂在 /api/* 下，手填裸域名在平台层 404。补全在
/// HttpSyncApi / SyncAccountApi 构造点统一生效，用户填什么域名都能通。
library;

import 'package:aimindtree_app/data/sync/sync_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeSyncBaseUrl', () {
    test('Vercel 裸域名自动补 /api', () {
      expect(
        normalizeSyncBaseUrl('https://aimindtree-syncrelayvercel.vercel.app'),
        'https://aimindtree-syncrelayvercel.vercel.app/api',
      );
    });

    test('Vercel 根路径（带尾斜杠）同样补 /api', () {
      expect(
        normalizeSyncBaseUrl('https://aimindtree-syncrelayvercel.vercel.app/'),
        'https://aimindtree-syncrelayvercel.vercel.app/api',
      );
    });

    test('已带 /api 不动（含尾斜杠变体）', () {
      expect(
        normalizeSyncBaseUrl('https://aimindtree-syncrelayvercel.vercel.app/api'),
        'https://aimindtree-syncrelayvercel.vercel.app/api',
      );
      expect(
        normalizeSyncBaseUrl('https://aimindtree-syncrelayvercel.vercel.app/api/'),
        'https://aimindtree-syncrelayvercel.vercel.app/api/',
      );
    });

    test('非 Vercel 域名原样返回（workers.dev / CloudBase / Netlify / 空串）', () {
      const urls = [
        'https://aimindtree-sync-relay.tuanx.workers.dev',
        'https://mindtree-d7glv6crkd8e9fba9-1409358097.ap-shanghai.app.tcloudbase.com/sync-relay',
        'https://aimindtree-sync-relay.netlify.app',
        '',
      ];
      for (final u in urls) {
        expect(normalizeSyncBaseUrl(u), u);
      }
    });

    test('前后空白先 trim；无 scheme / 不可解析原样返回', () {
      expect(
        normalizeSyncBaseUrl('  https://x.vercel.app  '),
        'https://x.vercel.app/api',
      );
      expect(normalizeSyncBaseUrl('not a url'), 'not a url');
      expect(normalizeSyncBaseUrl('x.vercel.app'), 'x.vercel.app');
    });

    test('http:// 的 vercel.app 也补（协议不挑）', () {
      expect(
        normalizeSyncBaseUrl('http://x.vercel.app'),
        'http://x.vercel.app/api',
      );
    });
  });
}
