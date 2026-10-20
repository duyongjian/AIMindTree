/// 添加 LLM 服务 Provider 的弹窗表单。
///
/// 字段：**显示名 / Base URL / 后端 Backend / 模型 Model / 设为默认**。
///
/// ⚠️ **没有 API Key 输入框**（密钥边界 C4）：密钥只存在于服务端
/// `llm_server/.env`（已被 `.gitignore` 忽略），App 侧 `api_key_ref` 恒为空串。
///
/// 提交前本地校验：
/// - 显示名非空；
/// - Base URL 形如 `http(s)://...`。
library;

import 'package:flutter/material.dart';

import '../../ai/clients/llm_server_client.dart';

/// 新增表单结果。
class LlmServerFormResult {
  const LlmServerFormResult({
    required this.displayName,
    required this.baseUrl,
    required this.backend,
    required this.model,
    required this.setDefault,
  });

  final String displayName;
  final String baseUrl;

  /// `auto` / `ollama` / `minimax` / `openai_compat`。
  final String backend;

  /// 空串 = 用后端默认模型。
  final String model;
  final bool setDefault;
}

class LlmServerAddDialog extends StatefulWidget {
  const LlmServerAddDialog({super.key});

  @override
  State<LlmServerAddDialog> createState() => _LlmServerAddDialogState();
}

class _LlmServerAddDialogState extends State<LlmServerAddDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController(text: '本地 LLM 服务');
  final _baseUrl = TextEditingController(text: kLlmServerDefaultBaseUrl);
  final _model = TextEditingController();
  String _backend = kLlmServerBackends.first;
  bool _setDefault = true;

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
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
    Navigator.of(context).pop(
      LlmServerFormResult(
        displayName: _name.text.trim(),
        baseUrl: _baseUrl.text.trim(),
        backend: _backend,
        model: _model.text.trim(),
        setDefault: _setDefault,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加 LLM 服务'),
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
                  helperText: '只在 UI 里区分多个服务用',
                ),
                validator: (v) => _validateRequired(v, '显示名'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _baseUrl,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  helperText: '默认 http://127.0.0.1:8787',
                ),
                keyboardType: TextInputType.url,
                validator: _validateBaseUrl,
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '后端 Backend',
                  helperText: '选「跟随服务端默认」则不覆盖服务端配置',
                ),
                child: DropdownButton<String>(
                  value: _backend,
                  isExpanded: true,
                  items: [
                    for (final b in kLlmServerBackends)
                      DropdownMenuItem<String>(
                        value: b,
                        child: Text(_backendLabel(b)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _backend = v ?? 'auto'),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _model,
                decoration: const InputDecoration(
                  labelText: '模型 Model（选填）',
                  helperText: '留空 = 用后端默认模型，例 qwen2.5:7b',
                ),
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('设为默认'),
                value: _setDefault,
                onChanged: (v) => setState(() => _setDefault = v),
              ),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '后端与模型在服务端 llm_server/config.yaml 也可配置；'
                  '此处为按 Provider 覆盖。改 Base URL / Backend / Model 后需重启 App 生效。',
                  style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.5),
                ),
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
        FilledButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }
}

/// 后端下拉的可读文案（`auto` 说人话）。
String _backendLabel(String backend) {
  switch (backend) {
    case 'ollama':
      return 'Ollama（本地）';
    case 'minimax':
      return 'MiniMax';
    case 'openai_compat':
      return 'OpenAI 兼容端点';
    default:
      return '跟随服务端默认（auto）';
  }
}
