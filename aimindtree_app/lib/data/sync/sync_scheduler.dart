/// SyncScheduler：同步调度（T03）。
///
/// **自动调度已下线**（改设置页手动 push / pull 双按钮）；本类保留供手动
/// 触发（[runOnce]）与测试连接（[testConnection]）使用，start/stop 暂不
/// 删除以防别处引用。
library;

import 'dart:async';

import '../../core/logger.dart';
import 'sync_api.dart';
import 'sync_engine.dart';
import 'sync_status.dart';

class SyncScheduler {
  SyncScheduler({
    required this.engine,
    required this.api,
    required this.statusStore,
    this.interval = const Duration(seconds: 60),
    this.maxConsecutiveFailures = 3,
    this.backoff = const Duration(minutes: 5),
  });

  final SyncEngine engine;
  final SyncApi api;
  final SyncStatusStore statusStore;
  final Duration interval;
  final int maxConsecutiveFailures;
  final Duration backoff;

  static final AppLog _log = AppLog('sync_sched');
  Timer? _timer;
  int _consecutiveFailures = 0;
  bool _running = false;

  /// 启动调度（启动一次 + 开启周期）。
  void start() {
    _timer?.cancel();
    _log.i('scheduler start interval=$interval');
    // 启动一次性
    unawaited(runOnce());
    _timer = Timer.periodic(interval, (_) => unawaited(runOnce()));
  }

  /// 停止调度。
  void stop() {
    _timer?.cancel();
    _timer = null;
    _log.i('scheduler stop');
  }

  /// 触发一次完整 push+pull（手动 / 周期共用）。
  ///
  /// 返回 null 表示成功；非 null 是错误描述。
  Future<String?> runOnce() async {
    if (_running) {
      _log.d('已有 sync 进行中，跳过本次触发');
      return null;
    }
    _running = true;
    await statusStore.setStatus('syncing');
    try {
      // 1) push
      final pushReport = await engine.push();
      await statusStore.setLastPushAt(DateTime.now().toUtc());
      if (pushReport.failed > 0) {
        _log.w('push 部分失败 ${pushReport.failed} 条，继续 pull');
      }

      // 2) pull
      final pullReport = await engine.pull();
      await statusStore.setLastPulledAt(pullReport.serverTime);

      // 3) 成功状态
      _consecutiveFailures = 0;
      await statusStore.setStatus('ok');
      _log.i('sync ok push=${pushReport.pushed} pull=${pullReport.applied}');
      return null;
    } on Object catch (e) {
      _consecutiveFailures++;
      final msg = 'sync 失败（连续 $_consecutiveFailures 次）：$e';
      _log.w(msg);
      await statusStore.setStatus('error:$e');
      if (_consecutiveFailures >= maxConsecutiveFailures) {
        _log.w('连续失败达上限，下次重试延后到 ${backoff.inMinutes} 分钟后');
        _timer?.cancel();
        _timer = Timer(backoff, () {
          _consecutiveFailures = 0;
          start();
        });
      }
      return msg;
    } finally {
      _running = false;
    }
  }

  /// 测试连通性（不修改 outbox / last_pulled_at）。
  Future<String?> testConnection() => api.testConnection();

  void dispose() {
    stop();
    api.close();
  }
}