/// 跨端平台判定（ARCHITECTURE §7 跨端兼容要点 / PRD §7.7 卡片混合形态）。
///
/// 刻意**不 import dart:io** —— Flutter Web 不支持 dart:io，这里统一用
/// `flutter/foundation.dart` 的 `defaultTargetPlatform`，保证 Web 可编译。
library;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// 桌面端：Windows / macOS / Linux。
bool get isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// 移动端：Android / iOS。
bool get isMobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Web 端。
bool get isWeb => kIsWeb;

/// 卡片形态（PRD §7.7）：桌面贴画布（inline），手机走底部抽屉（drawer）。
enum CardForm {
  /// 桌面：卡片直接贴在画布上，与源节点连线。
  inline,

  /// 手机：底部抽屉展示。
  drawer,
}

/// 屏宽 → 卡片形态（v1.1：任意端可手动切换，这里给默认值）。
CardForm cardFormForWidth(double width) =>
    width >= 900 ? CardForm.inline : CardForm.drawer;
