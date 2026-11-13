// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 应用版本读取（构建时写入 `pubspec.yaml` 的 `version:`）。
///
/// 启动最早处调用 [loadAppVersion] 读取一次并缓存。对外两个版本视图：
/// - [appVersion]：完整版本（含 `+构建号`，如 `0.9.20+5`），供设置页展示；
/// - [clientVersion]：**语义版本**（截断 `+构建号`，如 `0.9.20`），供客户端标识
///   （NekoMusic 的 UA，见 `services/neko/neko_identity.dart`）。
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

/// 发布通道（编译期 `--dart-define=ARCHOERA_CHANNEL=…`）。
///
/// - `0` Release（正式版）
/// - `1` Beta（CI 手动构建）
/// - `2` Dev（默认：未传 define 的本地/开发构建）
/// - `3` Nightly（自动构建产物）
///
/// 未传 define 或数值越界时回退 [ReleaseChannel.dev]。
enum ReleaseChannel {
  release(0, 'Release'),
  beta(1, 'Beta'),
  dev(2, 'Dev'),
  nightly(3, 'Nightly');

  const ReleaseChannel(this.value, this.label);

  /// define 的数值（0–3）。
  final int value;

  /// 用户可见的通道名（不展示原始数字）。
  final String label;

  /// 当前编译期通道。
  static ReleaseChannel get current =>
      fromValue(int.tryParse(_channelDefine) ?? dev.value);

  /// 数值 → 通道；未知值回退 [dev]。
  static ReleaseChannel fromValue(int? value) => switch (value) {
    0 => release,
    1 => beta,
    2 => dev,
    3 => nightly,
    _ => dev,
  };

  /// 编译期定义（`String.fromEnvironment` 只接受字符串 define）。
  static const String _channelDefine = String.fromEnvironment(
    'ARCHOERA_CHANNEL',
    defaultValue: '2',
  );
}

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
