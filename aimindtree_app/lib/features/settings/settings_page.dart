/// AI Provider + 同步 设置页（T07 收口 + T03 同步）。
///
/// 功能：
/// - 列出 `ai_providers` 表所有 provider（已启用 / 已停用）；
/// - 新增 LLM 服务 provider（显示名 + Base URL + 后端 + 模型，**无 Key 框**）；
/// - 启用 / 停用 switch；
/// - **编辑 provider（显示名 / Base URL / 后端 / 模型）**；
/// - 测试连接（探 `GET {baseUrl}/health`）；
/// - 删除 provider（连带清理 SecretStore **和指向它的任务路由**）；
/// - **「AI 任务路由」区：把 T1/T3/T4 绑到指定的 LLM 服务实例**；
/// - 同步：URL / Token / 启停 / 立即同步（嵌入 [SyncSettingsSection]）。
///
/// 为什么还要能绑：一个 LLM 服务实例 = 一条 `ai_providers` 行，用户可能同时跑
/// 本地 Ollama 与云端 MiniMax。T3 / T4 若不在 `ai_task_routes` 绑定专属 provider，
/// `AiTaskRouter.resolve` 会返回 `null`，App 全程走本地兜底、AI 一次都不跑。
///
/// 密钥边界：密钥只在服务端 `llm_server/.env`，本页**不提供**任何 Key 输入框
/// （`api_key_ref` 恒空串），仅对历史 Dify 行仍显示「密钥缺失」。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../ai/ai_task.dart';
import '../../ai/clients/llm_server_client.dart';
import '../../core/secret_store.dart';
import '../../data/db/drift_database.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/sync/sync_config.dart';
import '../../data/sync/sync_outbox.dart';
import '../../data/sync/sync_scheduler.dart';
import '../../data/sync/sync_status.dart';
import 'llm_server_add_dialog.dart';
import 'llm_server_edit_dialog.dart';
import 'sync_settings_section.dart';

/// 可在设置页绑定的任务。
///
/// 只列**已实现且走 LLM Server structured 端点（`/v1/task/{code}`）**的任务；
/// T5 追问走 `/v1/chat`，属于会话类，统一回落默认 Provider。
const List<AiTask> kRoutableTasks = <AiTask>[
  AiTask.t1Extract,
  AiTask.t3Prerequisite,
  AiTask.t4GapAnalysis,
];

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
  /// 下拉「未绑定」哨兵值：必须是 const，保证与 items 里同一实例（identical 匹配）。
  static const String _unboundValue = '';

  List<_ProviderVM> _items = const <_ProviderVM>[];
  Map<String, AiTaskRouteRow> _routes = const <String, AiTaskRouteRow>{};
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
        // llm_server 无客户端密钥（密钥在服务端 .env）→ 不判「密钥缺失」，
        // 只对遗留的、需要密钥的协议行做提示。
        final needsKey = r.protocol != kLlmServerProtocol;
        final apiKey =
            needsKey ? await widget.settings.resolveApiKey(r.apiKeyRef) : '';
        items.add(
          _ProviderVM(
            row: r,
            apiKeyMissing: needsKey && (apiKey == null || apiKey.isEmpty),
          ),
        );
      }
      final routes = await widget.settings.allRoutes();
      if (!mounted) return;
      setState(() {
        _items = items;
        _routes = <String, AiTaskRouteRow>{for (final r in routes) r.aiTask: r};
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
    final result = await showDialog<LlmServerFormResult>(
      context: context,
      builder: (_) => const LlmServerAddDialog(),
    );
    if (result == null) return;
    try {
      await widget.settings.addLlmServerProvider(
        displayName: result.displayName,
        baseUrl: result.baseUrl,
        backend: result.backend,
        model: result.model,
        setDefault: result.setDefault,
      );
      widget.onChanged?.call();
      await _reload();
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('新增失败：$e')));
    }
  }

  Future<void> _toggleEnabled(AiProviderRow row, bool next) async {
    try {
      await widget.settings.setEnabled(row.id, next);
      widget.onChanged?.call();
      await _reload();
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('切换失败：$e')));
    }
  }

  Future<void> _delete(AiProviderRow row) async {
    final boundTasks = kRoutableTasks
        .where((t) => _routes[t.code]?.providerId == row.id)
        .map((t) => '${t.code} ${t.label}')
        .toList(growable: false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除 Provider'),
        content: Text(
          '确认删除「${row.name}」？'
          '${boundTasks.isEmpty ? '' : '\n\n⚠️ 它还绑定了：${boundTasks.join('、')}\n删除后这些任务会解除绑定（T3/T4 将退回本地兜底）。'}',
        ),
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
      final unbound = await widget.settings.deleteProvider(row.id);
      widget.onChanged?.call();
      await _reload();
      if (!mounted || unbound == 0) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已删除，并解除了 $unbound 个任务绑定')));
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  /// 编辑 provider（显示名 / Base URL / 后端 / 模型）。
  Future<void> _edit(AiProviderRow row) async {
    final initialModel = _firstModel(row.models);
    final initialBackend = row.type.isEmpty ? 'auto' : row.type;
    final result = await showDialog<LlmServerEditResult>(
      context: context,
      builder: (_) => LlmServerEditDialog(
        initialName: row.name,
        initialBaseUrl: row.baseUrl,
        initialBackend: initialBackend,
        initialModel: initialModel,
      ),
    );
    if (result == null) return;
    // Base URL / 后端 / 模型 变了 → bootstrap 里已实例化的 client 还是旧值
    final needsRestart = result.needsRestart;
    try {
      if (row.protocol == kLlmServerProtocol) {
        await widget.settings.updateLlmServerProvider(
          row.id,
          name: result.displayName,
          baseUrl: result.baseUrl,
          backend: result.backend,
          model: result.model,
        );
      } else {
        // 遗留协议行：只改名与地址，密钥不动。
        await widget.settings.updateProvider(
          row.id,
          name: result.displayName,
          baseUrl: result.baseUrl,
        );
      }
      widget.onChanged?.call();
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            needsRestart
                ? '已保存。改了 Base URL / 后端 / 模型，需重启 App 才生效'
                : '已保存',
          ),
        ),
      );
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  /// 绑定 / 解绑任务路由。`providerId` 为空串/null 视为解绑。
  Future<void> _bind(AiTask task, String? providerId) async {
    final unbind = providerId == null || providerId.isEmpty;
    try {
      if (unbind) {
        await widget.settings.unbindTask(task);
      } else {
        await widget.settings.bindTask(task, providerId);
      }
      widget.onChanged?.call();
      await _reload();
      if (!mounted) return;
      final msg = unbind
          ? '${task.code} 已解绑'
                '${_isDedicated(task) ? '（将退回本地兜底，AI 不再参与）' : '（将回落默认 Provider）'}'
          : '${task.code} 已绑定到 ${_nameOf(providerId)}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('绑定失败：$e')));
    }
  }

  Future<void> _test(AiProviderRow row) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('正在测试连接…')));
    // llm_server 无密钥：直接探 /health（密钥由服务端 .env 持有）。
    final err = await widget.settings.testLlmServer(row.baseUrl);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
        err == null ? '连接成功（/health 200）' : '连接失败：$err',
      ),
        backgroundColor: err == null ? Colors.green : Colors.red,
      ),
    );
  }

  /// 专属任务：未绑定时**不会**回落默认 Provider，而是走本地兜底（AI 不参与）。
  static bool _isDedicated(AiTask task) =>
      task == AiTask.t3Prerequisite || task == AiTask.t4GapAnalysis;

  /// 按 id 取显示名；找不到（已删除 / 竞态）时返回占位。
  String _nameOf(String id) {
    for (final vm in _items) {
      if (vm.row.id == id) return vm.row.name;
    }
    return '(已删除)';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _buildBody(context),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addProvider,
        icon: const Icon(Icons.add),
        label: const Text('添加 LLM 服务'),
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
          child: Text(
            '加载失败：$_error',
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '还没有 AI 服务。\n点右下角「添加 LLM 服务」创建一个。',
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
            onEdit: () => _edit(vm.row),
            onDelete: () => _delete(vm.row),
            onTest: () => _test(vm.row),
          ),
        _buildRouteSection(),
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
            '• 密钥仅保存在服务端 .env（llm_server/.env），不写入数据库；\n'
            '• 增删 / 启停 Provider 后需重启 App 才生效（P0 简化）；\n'
            '• 编辑 Provider：只改显示名即时生效，改 Base URL / 后端 / 模型需重启；\n'
            '• 任务路由绑定即时生效，无需重启；\n'
            '• 本地服务（127.0.0.1）仅本机可用；公网场景请使用已配置 CORS 的代理。',
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

  /// AI 任务路由绑定区。
  ///
  /// 绑定在 `AiTaskRouter.resolve` 里**每次现查 DB**，所以改完立即生效、无需重启；
  /// 但下拉只列「已启用」的 provider（bootstrap 只实例化 enabled 的），
  /// 新增 / 启用 provider 仍需重启 App。
  Widget _buildRouteSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 4),
          child: Text(
            'AI 任务路由',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '一个 LLM 服务实例 = 一条 Provider 记录（本地 Ollama / 云端 MiniMax 可共存）。\n'
            '把任务绑到指定的服务实例；T3 / T4 不绑就走本地兜底（AI 不参与）。\n'
            '绑定即时生效；新增 / 启用 Provider 仍需重启 App。',
            style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.6),
          ),
        ),
        for (final task in kRoutableTasks) _routeTile(task),
      ],
    );
  }

  Widget _routeTile(AiTask task) {
    // 只列「已启用」的 provider：绑到停用的 provider 会命中路由却取不到实例，
    // 比「未绑定」更难排查。
    final candidates = _items
        .where((vm) => vm.row.enabled)
        .toList(growable: false);
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(value: _unboundValue, child: Text('未绑定')),
      for (final vm in candidates)
        DropdownMenuItem<String>(
          value: vm.row.id,
          child: Text(vm.row.name, overflow: TextOverflow.ellipsis),
        ),
    ];

    // DropdownButton.value 用 identical 匹配 → 必须取 candidates 里的**同一实例**，
    // 不能直接用 _routes 里的字符串（来自另一次查询，不是同一对象）。
    var value = _unboundValue;
    final boundId = _routes[task.code]?.providerId;
    for (final vm in candidates) {
      if (vm.row.id == boundId) {
        value = vm.row.id;
        break;
      }
    }
    final stale = (boundId ?? '').isNotEmpty && value == _unboundValue;

    final String subtitle;
    final Color subtitleColor;
    if (stale) {
      subtitle = '⚠️ 原绑定的 Provider 已删除或已停用，请重新选择';
      subtitleColor = Colors.orange;
    } else if (value == _unboundValue) {
      subtitle = _isDedicated(task)
          ? '未绑定 → 走本地兜底，AI 不会参与'
          : '未绑定 → 回落默认 Provider';
      subtitleColor = _isDedicated(task) ? Colors.orange : Colors.grey;
    } else {
      final vm = candidates.firstWhere((v) => v.row.id == value);
      subtitle = '${vm.row.baseUrl}${vm.apiKeyMissing ? ' · ⚠️ 密钥缺失' : ''}';
      subtitleColor = vm.apiKeyMissing ? Colors.orange : Colors.grey;
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(child: Text(task.code)),
        title: Text(
          '${task.code} ${task.label}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: subtitleColor, fontSize: 12),
        ),
        trailing: SizedBox(
          width: 200,
          child: DropdownButton<String>(
            value: value,
            items: items,
            isExpanded: true,
            onChanged: (v) => _bind(task, v),
          ),
        ),
      ),
    );
  }
}

class _ProviderVM {
  const _ProviderVM({required this.row, required this.apiKeyMissing});
  final AiProviderRow row;
  final bool apiKeyMissing;
}

/// 从 `ai_providers.models`（JSON 数组字符串）取第一个模型覆盖；失败返回 `''`。
///
/// 表结构不可改（Drift 依赖 build_runner），`models` 列被复用承载 model 覆盖，
/// 最多 1 个元素；`[]` 表示「用后端默认模型」。
String _firstModel(String modelsJson) {
  if (modelsJson.isEmpty) return '';
  try {
    final decoded = jsonDecode(modelsJson);
    if (decoded is List && decoded.isNotEmpty) {
      final first = decoded.first;
      return first is String ? first : first.toString();
    }
  } on Object {
    return '';
  }
  return '';
}

/// 后端名的可读文案（`auto` 说人话）。
String _backendLabel(String backend) => backend == 'auto'
    ? '跟随服务端默认'
    : (kLlmServerBackends.contains(backend) ? backend : 'auto');

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.vm,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onTest,
  });

  final _ProviderVM vm;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final row = vm.row;
    final backend = row.type.isEmpty ? 'auto' : row.type;
    final model = _firstModel(row.models);
    final subtitleParts = <String>[
      row.baseUrl,
      _backendLabel(backend),
      model.isEmpty ? '后端默认模型' : model,
      if (vm.apiKeyMissing) '⚠️ 密钥缺失',
      if (!row.enabled) '已停用',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.bolt)),
        title: Text(
          row.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
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
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
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
