/// 同步层依赖容器（T03）。
///
/// 把 SyncOutboxRepo / SyncConfig / SyncStatusStore / SyncScheduler 打包，
/// 让 [ExtractionService.bootstrap] 的返回值保持 5 元组。
library;

import 'sync_api.dart';
import 'sync_config.dart';
import 'sync_outbox.dart';
import 'sync_scheduler.dart';
import 'sync_status.dart';

class SyncContext {
  SyncContext({
    required this.outbox,
    required this.config,
    required this.statusStore,
    required this.scheduler,
    required this.api,
  });

  final SyncOutboxRepo outbox;
  final SyncConfig config;
  final SyncStatusStore statusStore;
  final SyncScheduler scheduler;
  final SyncApi api;
}