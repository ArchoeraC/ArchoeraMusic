// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 平台能力工厂（facade 文档 §4 / bridge 文档 §6）。
///
/// 加载 libarchoera_platform → 契约版本校验 → apl_init → 能力位图门禁：
/// 位图含对应能力位 → FFI 实现；否则 Noop（静默降级）。
/// 库缺失 / 版本不符 / init 失败 → 全部 Noop（桥接未随包/未编译的场景）。
///
/// 主程序只依赖 [power]/[media]/[window] 三个接口，不感知 FFI 细节。
library;

import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ffi_system_media.dart';
import 'ffi_system_power.dart';
import 'ffi_system_window.dart';
import 'platform_bindings.dart';
import 'system_media.dart';
import 'system_power.dart';
import 'system_window.dart';

class PlatformCapabilities {
  PlatformCapabilities._(
    this._bindings, {
    required this.power,
    required this.media,
    required this.window,
    required this.caps,
  });

  final PlatformBindings? _bindings;

  /// 能力位图（桥接未加载为 0；门禁判定以它为准）。
  final int caps;

  final SystemPower power;
  final SystemMedia media;
  final SystemWindow window;

  bool get powerInhibitAvailable => caps & aplCapPowerInhibit != 0;
  bool get screenStateAvailable => caps & aplCapPowerScreenState != 0;
  bool get mediaSessionAvailable => caps & aplCapMediaSession != 0;
  bool get windowStateAvailable => caps & aplCapWindowState != 0;
  bool get appInstanceAvailable => caps & aplCapAppInstance != 0;
  bool get systemAccentAvailable => caps & aplCapSystemAccent != 0;
  bool get bridgeLoaded => _bindings != null;

  /// 单实例仲裁：返回 true = 首实例（继续启动）；false = 已有实例（应退出）。
  /// 桥接不可用/无该能力 → true（不阻断启动，降级为允许多开）。
  bool acquireSingleInstance() {
    final b = _bindings;
    if (b == null || caps & aplCapAppInstance == 0) return true;
    return b.acquireInstance() == 1;
  }

  /// 系统主题色（DE accent）；桥接不可用/无该能力返回 null。
  Color? systemAccent() {
    final b = _bindings;
    if (b == null || caps & aplCapSystemAccent == 0) return null;
    return b.systemAccent();
  }

  /// 订阅/取消系统主题色变更事件；返回 0=成功，负=不可用。
  int setAccentEvents(bool on) {
    final b = _bindings;
    if (b == null || caps & aplCapSystemAccent == 0) return aplErrUnsupported;
    return b.setAccentEvents(on);
  }

  /// 系统主题色变更流（桥接不可用为空流）。
  Stream<void> get accentEvents => _bindings?.accentEvents ?? const Stream.empty();

  /// 系统提示（桥接不可用时返回错误码）。返回 0=成功。
  int notify(String title, String body) {
    final b = _bindings;
    if (b == null) return aplErrBackend;
    return b.notify(title, body);
  }

  static PlatformCapabilities? _instance;

  /// 进程级单例；重复访问返回同一实例。
  static PlatformCapabilities instance() {
    final existing = _instance;
    if (existing != null) return existing;
    final b = PlatformBindings.tryLoad();
    final caps = b?.capabilities() ?? 0;
    final built = PlatformCapabilities._(
      b,
      caps: caps,
      power: (b != null && caps & aplCapPowerInhibit != 0)
          ? FfiSystemPower(b)
          : NoopSystemPower.instance,
      media: (b != null && caps & aplCapMediaSession != 0)
          ? FfiSystemMedia(b)
          : NoopSystemMedia.instance,
      window: (b != null && caps & aplCapWindowState != 0)
          ? FfiSystemWindow(b)
          : NoopSystemWindow.instance,
    );
    _instance = built;
    return built;
  }

  /// 释放全部能力实现与桥接（进程退出前；幂等）。
  Future<void> dispose() async {
    await power.dispose();
    await media.dispose();
    await window.dispose();
    _bindings?.dispose();
    _instance = null;
  }
}

/// Riverpod 注入点（应用级单例，随 ProviderScope 释放）。
final platformCapabilitiesProvider = Provider<PlatformCapabilities>((ref) {
  final caps = PlatformCapabilities.instance();
  ref.onDispose(caps.dispose);
  return caps;
});
