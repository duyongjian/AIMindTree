/// **已迁至管理后台** —— 整段注释保留，勿删。
///
/// 原职责：编辑 LLM 服务 Provider 的弹窗表单（显示名 / Base URL / 后端 / 模型）。
///
/// 现在这些都属于**运维级配置**，由管理后台「LLM Provider」页承担
/// （本机 `http://127.0.0.1:8787/admin`）；App 启动时从 `GET /v1/app/config`
/// 拉取下发配置并幂等覆盖，不再需要用户手填。
///
/// 取代者：`llm_server/static/views-a.js` 的 M2（LLM Provider）。
/// 回退步骤见 `docs/DESIGN_ADMIN_CONSOLE.md §13`：
///   ① 取消本文件注释；② 取消 `llm_server_add_dialog.dart` 注释；
///   ③ 反注释 `settings_page.dart` 里对应的 import 与 Provider 区块。
library;

// import 'package:flutter/material.dart';
//
// import '../../ai/clients/llm_server_client.dart';
//
// /// 编辑结果。
// class LlmServerEditResult {
//   const LlmServerEditResult({
//     required this.displayName,
//     required this.baseUrl,
//     required this.backend,
//     required this.model,
//     this.initialBaseUrl = '',
//     this.initialBackend = 'auto',
//     this.initialModel = '',
//   });
//
//   final String displayName;
//   final String baseUrl;
//   final String backend;
//
//   /// 空串 = 用后端默认模型。
//   final String model;
//
//   /// 以下三项由 dialog 回填初始值，用于计算 [needsRestart]。
//   final String initialBaseUrl;
//   final String initialBackend;
//   final String initialModel;
//
//   /// 改了连接参数 → 内存里的 client 实例还是旧的，需重启 App。
//   bool get needsRestart =>
//       baseUrl != initialBaseUrl ||
//       backend != initialBackend ||
//       model != initialModel;
// }
//
// class LlmServerEditDialog extends StatefulWidget {
//   const LlmServerEditDialog({
//     super.key,
//     required this.initialName,
//     required this.initialBaseUrl,
//     this.initialBackend = 'auto',
//     this.initialModel = '',
//   });
//
//   final String initialName;
//   final String initialBaseUrl;
//   final String initialBackend;
//   final String initialModel;
//
//   @override
//   State<LlmServerEditDialog> createState() => _LlmServerEditDialogState();
// }
//
// class _LlmServerEditDialogState extends State<LlmServerEditDialog> {
//   final _formKey = GlobalKey<FormState>();
//   late final TextEditingController _name;
//   late final TextEditingController _baseUrl;
//   late final TextEditingController _model;
//   late String _backend;
//
//   @override
//   void initState() {
//     super.initState();
//     _name = TextEditingController(text: widget.initialName);
//     _baseUrl = TextEditingController(text: widget.initialBaseUrl);
//     _model = TextEditingController(text: widget.initialModel);
//     _backend = kLlmServerBackends.contains(widget.initialBackend)
//         ? widget.initialBackend
//         : kLlmServerBackends.first;
//   }
//
//   @override
//   void dispose() {
//     _name.dispose();
//     _baseUrl.dispose();
//     _model.dispose();
//     super.dispose();
//   }
//
//   String? _validateBaseUrl(String? v) {
//     if (v == null || v.trim().isEmpty) return '请填写 Base URL';
//     final s = v.trim();
//     final ok = s.startsWith('http://') || s.startsWith('https://');
//     if (!ok) return '需以 http:// 或 https:// 开头';
//     return null;
//   }
//
//   String? _validateRequired(String? v, String label) {
//     if (v == null || v.trim().isEmpty) return '请填写 $label';
//     return null;
//   }
//
//   void _submit() {
//     if (!_formKey.currentState!.validate()) return;
//     Navigator.of(context).pop(
//       LlmServerEditResult(
//         displayName: _name.text.trim(),
//         baseUrl: _baseUrl.text.trim(),
//         backend: _backend,
//         model: _model.text.trim(),
//         initialBaseUrl: widget.initialBaseUrl,
//         initialBackend: widget.initialBackend,
//         initialModel: widget.initialModel,
//       ),
//     );
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     return AlertDialog(
//       title: const Text('编辑 LLM 服务'),
//       content: SizedBox(
//         width: 480,
//         child: Form(
//           key: _formKey,
//           child: Column(
//             mainAxisSize: MainAxisSize.min,
//             children: [
//               TextFormField(
//                 controller: _name,
//                 decoration: const InputDecoration(
//                   labelText: '显示名',
//                   helperText: '只在 UI 里区分多个服务用',
//                 ),
//                 validator: (v) => _validateRequired(v, '显示名'),
//               ),
//               const SizedBox(height: 12),
//               TextFormField(
//                 controller: _baseUrl,
//                 decoration: const InputDecoration(
//                   labelText: 'Base URL',
//                   helperText: '默认 http://127.0.0.1:8787',
//                 ),
//                 keyboardType: TextInputType.url,
//                 validator: _validateBaseUrl,
//               ),
//               const SizedBox(height: 12),
//               InputDecorator(
//                 decoration: const InputDecoration(
//                   labelText: '后端 Backend',
//                   helperText: '选「跟随服务端默认」则不覆盖服务端配置',
//                 ),
//                 child: DropdownButton<String>(
//                   value: _backend,
//                   isExpanded: true,
//                   items: [
//                     for (final b in kLlmServerBackends)
//                       DropdownMenuItem<String>(
//                         value: b,
//                         child: Text(_backendLabel(b)),
//                       ),
//                   ],
//                   onChanged: (v) => setState(() => _backend = v ?? 'auto'),
//                 ),
//               ),
//               const SizedBox(height: 12),
//               TextFormField(
//                 controller: _model,
//                 decoration: const InputDecoration(
//                   labelText: '模型 Model（选填）',
//                   helperText: '留空 = 用后端默认模型，例 qwen2.5:7b',
//                 ),
//               ),
//               const SizedBox(height: 4),
//               const Align(
//                 alignment: Alignment.centerLeft,
//                 child: Text(
//                   '后端与模型在服务端 llm_server/config.yaml 也可配置；'
//                   '此处为按 Provider 覆盖。改 Base URL / Backend / Model 后需重启 App 生效。',
//                   style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.5),
//                 ),
//               ),
//             ],
//           ),
//         ),
//       ),
//       actions: [
//         TextButton(
//           onPressed: () => Navigator.of(context).pop(),
//           child: const Text('取消'),
//         ),
//         FilledButton(onPressed: _submit, child: const Text('保存')),
//       ],
//     );
//   }
// }
//
// /// 后端下拉的可读文案（`auto` 说人话）。
// String _backendLabel(String backend) {
//   switch (backend) {
//     case 'ollama':
//       return 'Ollama（本地）';
//     case 'minimax':
//       return 'MiniMax';
//     case 'openai_compat':
//       return 'OpenAI 兼容端点';
//     default:
//       return '跟随服务端默认（auto）';
//   }
// }
