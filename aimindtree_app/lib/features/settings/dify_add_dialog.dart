/// 添加 Dify Provider 的弹窗表单（T07）。
///
/// 输入：
/// - displayName：UI 显示名（任意字符串）；
/// - baseUrl：Dify 服务根 URL，例 `http://localhost:8080`；
/// - apiKey：Dify 应用的 API Key（应用 → 访问 API 处获取）。
///
/// 提交前本地校验：
/// - displayName / baseUrl / apiKey 非空；
/// - baseUrl 形如 `http(s)://...`。
library;

import 'package:flutter/material.dart';

class DifyProviderFormResult {
  const DifyProviderFormResult({
    required this.displayName,
    required this.baseUrl,
    required this.apiKey,
  });
  final String displayName;
  final String baseUrl;
  final String apiKey;
}

class DifyAddDialog extends StatefulWidget {
  const DifyAddDialog({super.key});

  @override
  State<DifyAddDialog> createState() => _DifyAddDialogState();
}

class _DifyAddDialogState extends State<DifyAddDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController(text: '我的 Dify');
  final _baseUrl = TextEditingController(text: 'http://localhost:8080');
  final _apiKey = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  String? _validateBaseUrl(String? v) {
    if (v == null || v.trim().isEmpty) return '请填写 Base URL';
    final s = v.trim();
    final ok = s.startsWith('http://') || s.startsWith('https://');
    if (!ok) return '需以 http:// 或 https:// 开头';
    return null;
  }

  String? _validateRequired(String? v, String label) {
    if (v == null || v.trim().isEmpty) return '请填写 $label';
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(DifyProviderFormResult(
      displayName: _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加 Dify Provider'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '显示名',
                  helperText: '只在 UI 里区分多个 provider 用',
                ),
                validator: (v) => _validateRequired(v, '显示名'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _baseUrl,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  helperText: '形如 http://localhost:8080',
                ),
                keyboardType: TextInputType.url,
                validator: _validateBaseUrl,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _apiKey,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  helperText: 'Dify 应用 → 访问 API 处获取（仅本机存储）',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) => _validateRequired(v, 'API Key'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('添加'),
        ),
      ],
    );
  }
}