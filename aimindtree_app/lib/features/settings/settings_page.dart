/// AI Provider + 同步 设置页（T07 收口 + T03 同步）。
///
/// 功能：
/// - 列出 `ai_providers` 表所有 provider（已启用 / 已停用 / 密钥缺失）；
/// - 新增 Dify provider（displayName + baseUrl + apiKey）；
/// - 启用 / 停用 switch；
/// - 测试连接（探 `/console/api/setup`）；
/// - 删除 provider（连带清理 SecretStore）；
/// - 同步：URL / Token / 启停 / 立即同步（嵌入 [SyncSettingsSection]）。
library;

import 'package:flutter/material.dart';

import '../../core/secret_store.dart';
import '../../data/db/drift_database.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/sync/sync_config.dart';
import '../../data/sync/sync_outbox.dart';
import '../../data/sync/sync_scheduler.dart';
import '../../data/sync/sync_status.dart';
import 'dify_add_dialog.dart';
import 'sync_settings_section.dart';

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

  /// Provider 列表变更回调（如新增/删除/启停后通知 AppShell 给个 SnackBar）。
  final VoidCallback? onChanged;

  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> {
  List<_ProviderVM> _items = const <_ProviderVM>[];
  bool _loading = true;
  String? _error;

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
      final items = <_ProviderVM>[];
      for (final r in rows) {
        final apiKey = await widget.settings.resolveApiKey(r.apiKeyRef);
        items.add(_ProviderVM(
          row: r,
          apiKeyMissing: apiKey == null || apiKey.isEmpty,
        ));
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _addProvider() async {
    final result = await showDialog<DifyProviderFormResult>(
      context: context,
      builder: (_) => const DifyAddDialog(),
    );
    if (result == null) return;
    try {
      await widget.settings.addDifyProvider(
        displayName: result.displayName,
        baseUrl: result.baseUrl,
        apiKey: result.apiKey,
      );
      widget.onChanged?.call();
      await _reload();
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('新增失败：$e')),
      );
    }
  }

  Future<void> _toggleEnabled(AiProviderRow row, bool next) async {
    try {
      await widget.settings.setEnabled(row.id, next);
      widget.onChanged?.call();
      await _reload();
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('切换失败：$e')),
      );
    }
  }

  Future<void> _delete(AiProviderRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除 Provider'),
        content: Text('确认删除「${row.name}」？\n相关 API Key 也会被一起清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.settings.deleteProvider(row.id);
      widget.onChanged?.call();
      await _reload();
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
    }
  }

  Future<void> _test(AiProviderRow row) async {
    final apiKey = await widget.settings.resolveApiKey(row.apiKeyRef);
    if (apiKey == null || apiKey.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密钥缺失，无法测试。')),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在测试连接…')),
    );
    final err = await widget.settings.testDify(row.baseUrl, apiKey);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err == null ? '连接成功（HTTP 200）' : '连接失败：$err'),
        backgroundColor: err == null ? Colors.green : Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: _buildBody(context),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addProvider,
        icon: const Icon(Icons.add),
        label: const Text('添加 Dify'),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('加载失败：$_error', style: const TextStyle(color: Colors.red)),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '还没有 AI 提供商。\n点右下角「添加 Dify」创建一个。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'AI 提供商',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        for (final vm in _items)
          _ProviderTile(
            vm: vm,
            onToggle: (v) => _toggleEnabled(vm.row, v),
            onDelete: () => _delete(vm.row),
            onTest: () => _test(vm.row),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            '说明',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '• 密钥仅保存在本机 SecretStore，不写入数据库；\n'
            '• 增删 / 启停后需重启 App 才生效（P0 简化）；\n'
            '• 本地 Dify（http://localhost）仅桌面端开发期可用；\n'
            '• 公网 / Web 端请走 supabase ai-proxy（后续 T03+ 接入）。',
            style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.6),
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

class _ProviderVM {
  const _ProviderVM({required this.row, required this.apiKeyMissing});
  final AiProviderRow row;
  final bool apiKeyMissing;
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.vm,
    required this.onToggle,
    required this.onDelete,
    required this.onTest,
  });

  final _ProviderVM vm;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final row = vm.row;
    final subtitleParts = <String>[
      row.baseUrl,
      if (vm.apiKeyMissing) '⚠️ 密钥缺失',
      if (!row.enabled) '已停用',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.bolt)),
        title: Text(row.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          subtitleParts.join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: vm.apiKeyMissing ? Colors.orange : Colors.grey,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: row.enabled,
              onChanged: vm.apiKeyMissing ? null : onToggle,
            ),
            IconButton(
              tooltip: '测试连接',
              icon: const Icon(Icons.network_check),
              onPressed: onTest,
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}