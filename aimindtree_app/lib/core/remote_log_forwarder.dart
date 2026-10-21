/// App → 本机 llm_server 日志抄送器（P0-5：让管理后台 M7 看到 App 侧日志）。
///
/// 只与本机 llm_server 通信，强制不走系统代理（对齐服务端 trust_env=false，
/// 避免本机 HTTP_PROXY 把 127.0.0.1 请求发往代理而「假连不上」）。
///
/// 完全 best-effort：服务未启动 / 网络异常 / 序列化失败一律吞掉，绝不阻塞
/// 业务日志。日志先入本地缓冲，按 2s 周期批量 POST 到 ``/v1/logs``。
library;

import 'dart:convert';
import 'dart:io';

class RemoteLogForwarder {
  RemoteLogForwarder(this.baseUrl, {HttpClient? client})
      : _client = client ?? (HttpClient()..findProxy = (Uri uri) => 'DIRECT');

  /// 形如 ``http://127.0.0.1:8787``。
  final String baseUrl;
  final HttpClient _client;

  final List<Map<String, String>> _buf = <Map<String, String>>[];
  static const int _maxBatch = 100;
  static const Duration _flushInterval = Duration(seconds: 2);
  bool _scheduled = false;

  /// 入队一条日志（非阻塞：仅 append + 调度一次延迟 flush）。
  void enqueue(String level, String module, String message) {
    _buf.add(<String, String>{
      'level': level,
      'module': module,
      'message': message,
    });
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_scheduled) return;
    _scheduled = true;
    Future.delayed(_flushInterval, _flush);
  }

  Future<void> _flush() async {
    _scheduled = false;
    if (_buf.isEmpty) return;
    final List<Map<String, String>> batch;
    if (_buf.length > _maxBatch) {
      batch = _buf.sublist(0, _maxBatch);
      _buf.removeRange(0, _maxBatch); // 溢出部分留待下次 flush，不丢。
    } else {
      batch = List<Map<String, String>>.from(_buf);
      _buf.clear();
    }
    try {
      final base = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
      final req = await _client
          .postUrl(Uri.parse('$base/v1/logs'))
          .timeout(const Duration(seconds: 5));
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.add(utf8.encode(jsonEncode(<String, dynamic>{'entries': batch})));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      await resp.drain(); // 读掉响应体，避免连接挂起。
    } on Object {
      // best-effort：吞掉一切异常，抄送失败绝不影响业务。
    }
  }

  void dispose() => _client.close(force: true);
}
