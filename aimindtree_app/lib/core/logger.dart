/// 日志封装（ARCHITECTURE §11：按模块打 tag；发布版降为 warning 级）。
library;

import 'package:logger/logger.dart';

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

  void d(String message) => _logger.d('[$tag] $message');
  void i(String message) => _logger.i('[$tag] $message');
  void w(String message) => _logger.w('[$tag] $message');

  void e(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) =>
      _logger.e('[$tag] $message', error: error, stackTrace: stackTrace);
}
