/// AI 服务状态区（AC-20）。
///
/// 取代设置页里原来的「AI 提供商」列表 / 「AI 任务路由」两区：运维级配置已
/// 收口到管理后台（`llm_server/static/`），App 只负责**展示状态**与两个动作：
/// 打开管理后台（复制地址到剪贴板）、重新连接。
///
/// 数据来源：
/// - 徽标：有没有 `llm_server` 行 + 探活结果 + [AppConfigService.lastSource]；
/// - 服务名：[AppConfigService.last]（下发值）→ 行的 `name` → 内置默认名；
/// - 后端 / 模型：走 [backendOf] / [firstModel] **helper**（C8：白名单与 JSON
///   容错只有一份实现，本页绝不自己解析 `type` / `models` 列）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ai/app_config_service.dart';
import '../../ai/clients/llm_server_client.dart';
import '../../core/logger.dart';
import '../../data/db/drift_database.dart';
import '../../data/repositories/settings_repository.dart';

/// 状态区徽标的四态。
enum AiServiceState { connected, partial, disconnected, unknown }

/// 一次探活的结果。
class _Probe {
  const _Probe({required this.ok, required this.ms, this.error});

  final bool ok;
  final int ms;
  final String? error;
}

class AiServiceStatusSection extends StatefulWidget {
  const AiServiceStatusSection({
    super.key,
    required this.settings,
  });

  final SettingsRepository settings;

  @override
  State<AiServiceStatusSection> createState() => AiServiceStatusSectionState();
}

class AiServiceStatusSectionState extends State<AiServiceStatusSection> {
  static final AppLog _log = AppLog('ai_status');

  AiServiceState _state = AiServiceState.unknown;
  AiProviderRow? _row;
  _Probe? _probe;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// 外部（设置页刷新时）也能触发。
  Future<void> refresh() => _refresh();

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows = await widget.settings.allProviders();
      final llm = rows
          .where((r) => r.protocol == kLlmServerProtocol)
          .toList(growable: false);
      AiProviderRow? row;
      for (final r in llm) {
        if (r.isDefault) {
          row = r;
          break;
        }
      }
      row ??= llm.isEmpty ? null : llm.first;

      _Probe? probe;
      if (row != null) {
        probe = await _probeRow(row);
      }
      if (!mounted) return;
      setState(() {
        _row = row;
        _probe = probe;
        _state = _deriveState(row, probe);
        _busy = false;
      });
    } on Object catch (e, s) {
      _log.e('状态区刷新失败', error: e, stackTrace: s);
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<_Probe> _probeRow(AiProviderRow row) async {
    final sw = Stopwatch()..start();
    final err = await widget.settings.testLlmServer(
      row.baseUrl,
      timeout: const Duration(seconds: 3),
    );
    sw.stop();
    return _Probe(ok: err == null, ms: sw.elapsedMilliseconds, error: err);
  }

  AiServiceState _deriveState(AiProviderRow? row, _Probe? probe) {
    if (AppConfigService.lastSource == AppConfigSource.legacyService) {
      return AiServiceState.partial;
    }
    if (row == null) return AiServiceState.disconnected;
    if (probe == null) return AiServiceState.unknown;
    return probe.ok ? AiServiceState.connected : AiServiceState.disconnected;
  }

  /// 「重新连接」：重新拉一次下发配置（幂等落库），再探一次。
  Future<void> _reconnect() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await AppConfigService.fetchAndApply(widget.settings, prefs);
    } on Object catch (e, s) {
      // fetchAndApply 内部已吞异常，这里只是双保险。
      _log.e('重新连接失败', error: e, stackTrace: s);
    }
    // ⚠️ 跨 await 后必须判 mounted，否则 use_build_context_synchronously。
    if (!mounted) return;
    await _refresh();
    if (!mounted) return;
    final connected = _state == AiServiceState.connected;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(connected ? '已重新连接 ✅' : '仍未连上，请检查管理后台配置'),
        backgroundColor: connected ? Colors.green : Colors.red,
      ),
    );
  }

  /// 「打开管理后台」：不加 url_launcher 依赖（D7），复制地址 + 提示。
  Future<void> _copyConsoleUrl() async {
    final snap = AppConfigService.last;
    final url = (snap?.consoleUrl ?? '').trim().isNotEmpty
        ? snap!.consoleUrl.trim()
        : '${kLlmServerDefaultBaseUrl}/admin';
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 $url，请在浏览器打开')),
    );
  }

  String get _serviceName {
    final pushed = AppConfigService.last?.serviceName.trim() ?? '';
    if (pushed.isNotEmpty) return pushed;
    final rowName = _row?.name.trim() ?? '';
    if (rowName.isNotEmpty) return rowName;
    return 'AIMindTree AI 服务';
  }

  String get _backendLabel => _row == null
      ? '—'
      : (backendOf(_row!.type) == 'auto'
          ? '跟随服务端默认'
          : backendOf(_row!.type));

  String get _modelLabel {
    if (_row == null) return '—';
    final m = firstModel(_row!.models);
    return m.isEmpty ? '后端默认模型' : m;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.hub_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AI 服务状态',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                ),
                _buildBadge(),
              ],
            ),
            const SizedBox(height: 8),
            _kv('服务', _serviceName),
            _kv('后端', _backendLabel),
            _kv('模型', _modelLabel),
            _kv('地址', _row?.baseUrl ?? '（未配置）'),
            _kv(
              '最近检查',
              _probe == null
                  ? '尚未检查'
                  : '${_probe!.ok ? '连通' : '失败'} · ${_probe!.ms}ms',
            ),
            if (_probe != null && !_probe!.ok && _probe!.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '原因：${_probe!.error}',
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '读取失败：$_error',
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _reconnect,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重新连接'),
                ),
                OutlinedButton.icon(
                  onPressed: _copyConsoleUrl,
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  label: const Text('打开管理后台'),
                ),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text(
                '疑难排解',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${_row?.baseUrl ?? kLlmServerDefaultBaseUrl}\n'
                    '如需修改服务地址、后端或模型，请在管理后台调整'
                    '（本机打开：${kLlmServerDefaultBaseUrl}/admin）。\n'
                    '当前下发来源：${_sourceLabel()}',
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _sourceLabel() {
    switch (AppConfigService.lastSource) {
      case AppConfigSource.pushed:
        return '服务端下发（schema 1）';
      case AppConfigSource.legacyService:
        return '服务版本较旧（不支持下发）';
      case AppConfigSource.builtinDefault:
        return '内置默认（下发解析失败）';
      case AppConfigSource.unreachable:
        return '服务不可达';
    }
  }

  Widget _buildBadge() {
    switch (_state) {
      case AiServiceState.connected:
        return _badge('已连接', Colors.green);
      case AiServiceState.partial:
        return _badge('部分可用', Colors.orange);
      case AiServiceState.disconnected:
        return _badge('未连接', Colors.red);
      case AiServiceState.unknown:
        return _badge('未知', Colors.grey);
    }
  }

  static Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  static Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Text(
                k,
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}
