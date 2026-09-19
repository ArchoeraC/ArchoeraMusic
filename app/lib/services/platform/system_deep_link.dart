// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemDeepLink 契约：自定义 URI scheme 注册 + 唤醒分发（archoera://）。
///
/// 平台负责：注册当前用户处理程序（Windows HKCU / Linux desktop+GIO /
/// macOS Info.plist）、把 URL 回传（WM_COPYDATA / D-Bus OpenUri / AppleEvent）、
/// 次实例转发与窗口置前。桥接未置能力位时由工厂注入 [NoopSystemDeepLink]。
///
/// 见 docs/platform-native-bridge.md §3。
library;

import 'dart:async';

import 'platform_failure.dart';

abstract interface class SystemDeepLink {
  /// 收到的 deep link URI 流（含冷启动待取项）。
  Stream<Uri> get uris;

  /// 后端失败 / 断连（UI toast 由消费方决定；默认仅日志）。
  Stream<PlatformCapabilityFailure> get failures;

  /// 注册当前用户的 scheme 处理程序；true=成功。
  Future<bool> register(String scheme);

  /// 注销 scheme 处理程序。
  Future<void> unregister(String scheme);

  /// 置前 / 激活主窗口。
  Future<void> activateWindow();

  /// 次实例转发自身 argv 中的 URI：1=已转发 / 0=无 / <0=错误。
  Future<int> forward();

  /// 释放底层资源；幂等。
  Future<void> dispose();
}

/// 空实现：无 deep link（静默降级）。
class NoopSystemDeepLink implements SystemDeepLink {
  static final NoopSystemDeepLink instance = NoopSystemDeepLink._();

  NoopSystemDeepLink._();

  @override
  Stream<Uri> get uris => const Stream.empty();

  @override
  Stream<PlatformCapabilityFailure> get failures => const Stream.empty();

  @override
  Future<bool> register(String scheme) async => false;

  @override
  Future<void> unregister(String scheme) async {}

  @override
  Future<void> activateWindow() async {}

  @override
  Future<int> forward() async => 0;

  @override
  Future<void> dispose() async {}
}
