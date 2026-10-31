/// 设置页（AI 服务状态 + 同步）。
///
/// 变更说明（管理后台 P0）：
/// - **Provider 增删改 / 启停 / 测试连接 / FAB、以及「AI 任务路由」整区已移除**：
///   这些属于运维级配置，已收口到管理后台（`llm_server/static/`，
///   本机 `http://127.0.0.1:8787/admin`）。移除的代码**整段注释保留**（口径 A），
///   回退步骤见 `docs/DESIGN_ADMIN_CONSOLE.md §13`。
/// - 本页现在只做两件事：① 展示 [AiServiceStatusSection]（AI 服务状态）；
///   ② 嵌入 [SyncSettingsSection]（同步）。
///
/// 密钥边界：App 侧**从不**持有任何密钥（`api_key_ref` 恒空串，密钥只在
/// 服务端 `llm_server/.env`）；管理后台也只回显掩码，永不下发明文。
library;

import 'package:flutter/material.dart';

import '../../ai/clients/llm_server_client.dart';
import '../../core/secret_store.dart';
import '../../data/db/drift_database.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/sync/sync_config.dart';
import '../../data/sync/sync_outbox.dart';
import '../../data/sync/sync_scheduler.dart';
import '../../data/sync/sync_status.dart';
import 'ai_service_status_section.dart';
import 'tree_behavior_section.dart';
import 'sync_settings_section.dart';

// ⚠️ 已迁至管理后台（llm_server/static/）—— 整段注释保留，勿删。
// 回退步骤见 docs/DESIGN_ADMIN_CONSOLE.md §13。
// 取代者：管理后台「LLM Provider」/「任务路由」两页。
//
// import '../../ai/ai_task.dart';
// import 'llm_server_add_dialog.dart';
// import 'llm_server_edit_dialog.dart';
//
// /// 可在设置页绑定的任务（已由服务端 /v1/admin/routes 取代）。
// const List<AiTask> kRoutableTasks = <AiTask>[
//   AiTask.t1Extract,
//   AiTask.t3Prerequisite,
//   AiTask.t4GapAnalysis,
// ];

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.syncConfig,
    required this.syncStatusStore,
    required this.syncScheduler,
    required this.syncOutbox,
    required this.secretStore,
    this.onChanged,
  });

  final SettingsRepository settings;
  final SyncConfig syncConfig;
  final SyncStatusStore syncStatusStore;
  final SyncScheduler syncScheduler;
  final SyncOutboxRepo syncOutbox;
  final SecretStore secretStore;

  /// 配置变更回调（重新连接成功后通知 AppShell 给个 SnackBar）。
  final VoidCallback? onChanged;

  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> {
  List<AiProviderRow> _rows = const <AiProviderRow>[];
  bool _loading = true;
  String? _error;

  final _statusKey = GlobalKey<AiServiceStatusSectionState>();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 暴露给外部的刷新入口。
  Future<void> reload() => _reload();

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.settings.allProviders();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
      await _statusKey.currentState?.refresh();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '加载失败：$_error',
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        const SizedBox(height: 8),
        // ★ AI 服务状态（AC-20）：运维配置已迁至管理后台，本页只展示状态。
        AiServiceStatusSection(
          key: _statusKey,
          settings: widget.settings,
          // 任务 B：「重新连接」时一并消费管理后台下发的同步配置。
          syncConfig: widget.syncConfig,
          secretStore: widget.secretStore,
        ),
        // ★ E 模块：知识树行为（双开关：自动查重 / 自动连线）。
        const TreeBehaviorSection(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            '说明',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '• AI 服务由本机「AIMindTree AI 服务」提供，相关配置请在管理后台修改；\n'
            '• 打开管理后台：$kLlmServerDefaultBaseUrl/admin\n'
            '• 密钥保存在服务端，App 不保存任何密钥。',
            style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.6),
          ),
        ),
        if (_rows.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '（尚未写入 AI 服务记录，首次启动会自动创建）',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        SyncSettingsSection(
          config: widget.syncConfig,
          statusStore: widget.syncStatusStore,
          scheduler: widget.syncScheduler,
          outbox: widget.syncOutbox,
          secretStore: widget.secretStore,
        ),
      ],
    );
  }
}

// ⚠️ 已迁至管理后台（llm_server/static/）—— 以下 Provider / 任务路由 UI 整段
// 注释保留，勿删。回退步骤见 docs/DESIGN_ADMIN_CONSOLE.md §13。
//
// class _ProviderVM {
//   const _ProviderVM({required this.row, required this.apiKeyMissing});
//   final AiProviderRow row;
//   final bool apiKeyMissing;
// }
//
// String _backendLabel(String backend) => backend == 'auto'
//     ? '跟随服务端默认'
//     : (kLlmServerBackends.contains(backend) ? backend : 'auto');
//
// class _ProviderTile extends StatelessWidget { ... }
