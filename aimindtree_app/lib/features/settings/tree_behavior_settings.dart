/// 知识树「行为」偏好（查重 / 连线开关）。
///
/// 纯本地偏好，用 [SharedPreferences] 持久化（与 `ai_service_status_section`
/// 同款方案），不进 Drift、不同步。
///
/// 读取走内存缓存（同步 getter，App 启动 [load] 后即准确）；写入异步落盘。
/// 这样「是否查重 / 是否自动连线」这类高频判定点可以零成本同步读取，
/// 又不阻塞调用方。
///
/// 推荐默认：查重开（true）/ 连线关（false）—— 即「AI 助手把知识点加入树」
/// 默认只做知识点查重、不自动连边，用户可在设置页按需开启。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kDedupEnabled = 'kp_dedup_enabled';
const String _kAutoLinkEnabled = 'kp_auto_link_enabled';

/// 知识树行为设置（单例）。
class TreeBehaviorSettings extends ChangeNotifier {
  TreeBehaviorSettings._();

  /// 全局唯一实例；App 启动（[load]）后内存态即准确。
  static final TreeBehaviorSettings instance = TreeBehaviorSettings._();

  bool _dedupEnabled = true;
  bool _autoLinkEnabled = false;
  bool _loaded = false;

  /// 是否启用「自动知识点查重」（默认 true）。
  bool get dedupEnabled => _dedupEnabled;

  /// 是否启用「自动连线」（默认 false）。
  bool get autoLinkEnabled => _autoLinkEnabled;

  /// 是否已从 SharedPreferences 载入（首屏前 [load] 一次即可）。
  bool get isLoaded => _loaded;

  /// 载入持久化偏好（幂等；重复调用安全）。建议 App 启动、runApp 前调用一次。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _dedupEnabled = prefs.getBool(_kDedupEnabled) ?? true;
    _autoLinkEnabled = prefs.getBool(_kAutoLinkEnabled) ?? false;
    _loaded = true;
    notifyListeners();
  }

  /// 设置「自动知识点查重」开关（同步更新内存，异步落盘）。
  Future<void> setDedupEnabled(bool value) async {
    if (_dedupEnabled == value) return;
    _dedupEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDedupEnabled, value);
  }

  /// 设置「自动连线」开关（同步更新内存，异步落盘）。
  Future<void> setAutoLinkEnabled(bool value) async {
    if (_autoLinkEnabled == value) return;
    _autoLinkEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoLinkEnabled, value);
  }
}
