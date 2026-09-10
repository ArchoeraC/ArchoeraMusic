// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 平台能力工厂单测：本机无 libarchoera_platform（zig 产物未随测试环境），
// 应全部落 Noop 静默降级；桥接加载成功路径由 P1+ 手动验收覆盖。
//
// 注意：PlatformCapabilities 为进程级单例，测试只验证 Noop 形态，
// 不与 FFI 实现混用（bridgeLoaded 仅在真机带产物时为 true）。

import 'package:archoera_music/services/platform/ffi_system_power.dart';
import 'package:archoera_music/services/platform/platform_capabilities.dart';
import 'package:archoera_music/services/platform/system_media.dart';
import 'package:archoera_music/services/platform/system_power.dart';
import 'package:archoera_music/services/platform/system_window.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('factory falls back when bridge library missing', () {
    final caps = PlatformCapabilities.instance();
    if (caps.bridgeLoaded) {
      // 开发机装了 zig 产物时跳过无桥接断言（P1+ 手动验收覆盖）
      return;
    }
    expect(caps.caps, 0);
    // 三平台均已原生抑制；桥接缺失时 Noop 静默降级
    expect(caps.power, isA<NoopSystemPower>());
    expect(caps.media, isA<NoopSystemMedia>());
    expect(caps.window, isA<NoopSystemWindow>());
    expect(caps.powerInhibitAvailable, isFalse);
    expect(caps.mediaSessionAvailable, isFalse);
    expect(caps.windowStateAvailable, isFalse);
  });

  test('factory uses FFI implementation when capability present', () {
    final caps = PlatformCapabilities.instance();
    if (!caps.bridgeLoaded) return;
    // P1：Linux 置位 POWER_*；Windows/macOS 在 P3/P4 前为 0（wakelock 兜底）
    if (caps.powerInhibitAvailable) {
      expect(caps.power, isA<FfiSystemPower>());
    } else {
      expect(caps.power, isA<NoopSystemPower>());
    }
  });

  test('Noop contracts degrade silently', () async {
    final caps = PlatformCapabilities.instance();
    if (caps.bridgeLoaded) return;

    expect(await caps.power.setSleepInhibit(true), isFalse);
    expect(await caps.media.setNowPlaying(null), isFalse);
    expect(await caps.media.setPlaybackState(MediaPlaybackState.playing), isFalse);
    expect(await caps.window.setEvents(true), isFalse);
    await expectLater(caps.power.screenState, emitsDone);
    await expectLater(caps.media.commands, emitsDone);
    await expectLater(caps.window.state, emitsDone);
    await expectLater(caps.power.failures, emitsDone);
  });
}
