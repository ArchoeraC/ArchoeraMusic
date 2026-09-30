// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 统一可关闭原生库注册表测试：引用计数 + `DynamicLibrary.close()`。
///
/// 用系统 `libm` 验证 open/close 语义（Linux/macOS/Windows 名称不同，仅在本机
/// 存在的平台上跑；找不到则跳过）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/native_lib_paths.dart';
import 'package:archoera_music/services/native_library_registry.dart'
    as registry;

String? _probeLib() {
  const candidates = <String>[
    '/lib/x86_64-linux-gnu/libm.so.6',
    '/usr/lib/x86_64-linux-gnu/libm.so.6',
    '/usr/lib/libm.so.6',
    '/lib/libm.so.6',
    '/usr/lib/libSystem.B.dylib',
    r'C:\Windows\System32\msvcrt.dll',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

void main() {
  final lib = _probeLib();
  test('acquire/release 引用计数与卸载', () {
    if (lib == null) {
      markTestSkipped('本机无可用探测库');
      return;
    }
    expect(registry.isOpen(NativeModule.fft), isFalse);
    final a = registry.acquire(NativeModule.fft, path: lib);
    expect(registry.isOpen(NativeModule.fft), isTrue);
    expect(registry.refsOf(NativeModule.fft), 1);
    final b = registry.acquire(NativeModule.fft, path: lib);
    expect(identical(a, b), isTrue); // 复用一个对象
    expect(registry.refsOf(NativeModule.fft), 2);
    expect(registry.release(NativeModule.fft), isFalse); // 未归零
    expect(registry.refsOf(NativeModule.fft), 1);
    expect(registry.release(NativeModule.fft), isTrue); // 归零 → close
    expect(registry.isOpen(NativeModule.fft), isFalse);
  });

  test('重复 release 安全', () {
    if (lib == null) {
      markTestSkipped('本机无可用探测库');
      return;
    }
    expect(registry.release(NativeModule.fft), isFalse);
    expect(registry.isOpen(NativeModule.fft), isFalse);
  });
}
