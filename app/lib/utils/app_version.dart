// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 应用版本读取（构建时写入 `pubspec.yaml` 的 `version:`）。
///
/// 启动最早处调用 [loadAppVersion] 读取一次并缓存。对外两个版本视图：
/// - [appVersion]：完整版本（含 `+构建号`，如 `0.9.20+5`），供设置页展示；
/// - [clientVersion]：**语义版本**（截断 `+构建号`，如 `0.9.20`），供客户端标识
///   （NekoMusic 的 UA / `X-Neko-Client`，见 `services/neko/neko_identity.dart`）。
///
/// 实现走 `rootBundle` 读取内置的 `pubspec.yaml`（与设置页「版本」同源），**不使用
/// `package_info_plus` 等平台插件**——本项目禁止 Dart 直接调平台 API（见 AGENTS.md
/// 「系统调用统一走 C++ 桥接器」）。
library;

import 'package:flutter/services.dart' show rootBundle;

/// 完整版本（含 `+构建号`）；未加载 / 读取失败为空串。
String _appVersion = '';

/// 语义版本（截断 `+构建号`）；未加载 / 读取失败为空串。
String _clientVersion = '';

/// 完整版本（含构建号，供设置页展示）。
String get appVersion => _appVersion;

/// 语义版本（截断构建号；供客户端标识）。
String get clientVersion => _clientVersion;

/// 从内置 `pubspec.yaml` 读取 `version:` 并缓存完整 / 语义两个视图（失败静默）。
Future<void> loadAppVersion() async {
  if (_appVersion.isNotEmpty) return;
  try {
    final data = await rootBundle.loadString('pubspec.yaml');
    final match = RegExp(
      r'^version:\s*([0-9][^\s#]*)(?:\s*#.*)?$',
      multiLine: true,
    ).firstMatch(data);
    final raw = match?.group(1) ?? '';
    _appVersion = raw;
    // 截断构建号：0.9.20+5 → 0.9.20；0.9.11+rev.4 → 0.9.11
    final plus = raw.indexOf('+');
    _clientVersion = plus >= 0 ? raw.substring(0, plus) : raw;
  } catch (_) {
    // 读取失败：保持空串，标识 / UA 回退 unknown
  }
}
