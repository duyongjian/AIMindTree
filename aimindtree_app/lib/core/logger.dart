/// 日志封装（ARCHITECTURE §11：按模块打 tag；发布版降为 warning 级）。
library;

import 'package:logger/logger.dart';

import 'remote_log_forwarder.dart';

/// 全局底层 logger。
///
/// 发布构建（Profile/Release）自动只保留 warning 及以上（§11 约定）。
final Logger _logger = Logger(
  level: kReleaseLogLevel,
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 8,
    lineLength: 100,
    colors: false,
  ),
);

/// 发布版日志级别：只留 warning 及以上。
const Level kReleaseLogLevel = Level.warning;

/// 按模块取 logger：`final _log = AppLog('note_repo');`
class AppLog {
  const AppLog(this.tag);

  final String tag;

  /// 远程抄送器（App → 本机 llm_server /v1/logs，使 M7 可见 App 日志）。
  /// 由 bootstrap 在拿到 llm_server 地址后装配；null = 不抄送。
  static RemoteLogForwarder? forwarder;

  void d(String message) {
    _logger.d('[$tag] $message');
    _forward('DEBUG', message);
  }

  void i(String message) {
    _logger.i('[$tag] $message');
    _forward('INFO', message);
  }

  void w(String message) {
    _logger.w('[$tag] $message');
    _forward('WARNING', message);
  }

  void e(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final merged =
        error != null ? '[$tag] $message — $error' : '[$tag] $message';
    _logger.e(merged, error: error, stackTrace: stackTrace);
    _forward('ERROR', message);
  }

  void _forward(String level, String message) {
    final f = forwarder;
    if (f == null) return;
    // 防止 error 详情把单条撑爆：截断到 4000 字（对齐服务端 MAX_MESSAGE_CHARS）。
    final m = message.length > 4000
        ? '${message.substring(0, 4000)}…'
        : message;
    try {
      f.enqueue(level, 'app.$tag', m);
    } on Object {
      // 抄送失败绝不影响业务日志。
    }
  }
}
