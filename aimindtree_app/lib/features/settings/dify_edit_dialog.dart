/// 编辑 Dify Provider 的弹窗表单。
///
/// 与新增表单（`dify_add_dialog.dart`）的唯一语义差别：**API Key 可选**。
/// 留空 = 不修改密钥（SecretStore 里原来的值保持不动）。
/// 理由：大多数编辑只是改个显示名 / 修个写错的 URL，没必要把密钥重填一遍，
/// 而密钥一旦重填错了，排查成本比现在高得多。
library;


// ⚠️ 已停用（Dify 方案下线）—— 整段注释保留，勿删。
// 取代者：lib/features/settings/llm_server_edit_dialog.dart（无 API Key 输入框）。
// 回退时取消注释并把 settings_page.dart 的 import 改回。

// import 'package:flutter/material.dart';
//
// /// 编辑结果。`apiKey` 为 null 或空串表示「不改密钥」。
// class DifyEditResult {
//   const DifyEditResult({
//     required this.displayName,
//     required this.baseUrl,
//     this.apiKey,
//   });
//   final String displayName;
//   final String baseUrl;
//   final String? apiKey;
//
//   bool get changesApiKey => apiKey != null && apiKey!.isNotEmpty;
// }
//
// class DifyEditDialog extends StatefulWidget {
//   const DifyEditDialog({
//     super.key,
//     required this.initialName,
//     required this.initialBaseUrl,
//   });
//
//   final String initialName;
//   final String initialBaseUrl;
//
//   @override
//   State<DifyEditDialog> createState() => _DifyEditDialogState();
// }
//
// class _DifyEditDialogState extends State<DifyEditDialog> {
//   final _formKey = GlobalKey<FormState>();
//   late final TextEditingController _name;
//   late final TextEditingController _baseUrl;
//   final _apiKey = TextEditingController();
//   bool _obscure = true;
//
//   @override
//   void initState() {
//     super.initState();
//     _name = TextEditingController(text: widget.initialName);
//     _baseUrl = TextEditingController(text: widget.initialBaseUrl);
//   }
//
//   @override
//   void dispose() {
//     _name.dispose();
//     _baseUrl.dispose();
//     _apiKey.dispose();
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
//       DifyEditResult(
//         displayName: _name.text.trim(),
//         baseUrl: _baseUrl.text.trim(),
//         apiKey: _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim(),
//       ),
//     );
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     return AlertDialog(
//       title: const Text('编辑 Dify Provider'),
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
//                   helperText: '只在 UI 里区分多个 provider 用',
//                 ),
//                 validator: (v) => _validateRequired(v, '显示名'),
//               ),
//               const SizedBox(height: 12),
//               TextFormField(
//                 controller: _baseUrl,
//                 decoration: const InputDecoration(
//                   labelText: 'Base URL',
//                   helperText: '形如 http://localhost:8080',
//                 ),
//                 keyboardType: TextInputType.url,
//                 validator: _validateBaseUrl,
//               ),
//               const SizedBox(height: 12),
//               TextFormField(
//                 controller: _apiKey,
//                 obscureText: _obscure,
//                 decoration: InputDecoration(
//                   labelText: 'API Key（选填）',
//                   helperText: '留空则不修改当前密钥',
//                   suffixIcon: IconButton(
//                     icon: Icon(
//                       _obscure ? Icons.visibility : Icons.visibility_off,
//                     ),
//                     onPressed: () => setState(() => _obscure = !_obscure),
//                   ),
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
