// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/security/vault_process.dart';

/// Vector A（加载器注入）Dart 侧单测——不需要 vault 二进制：
///   - [VaultProcess.sanitizedEnvironment] 从环境表中剔除加载器注入变量
///     （`LD_PRELOAD`/`LD_AUDIT`/`LD_LIBRARY_PATH`/`DYLD_*`），并原样保留其余
///     变量（locale / D-Bus / OS 钥匙串后端等必须继续可用）；
///   - [VaultProcess.loaderInjectionVars] 覆盖 Linux 与 macOS 的载荷变量；
///   - `kDebugMode` 门控（`ARCHOERA_VAULT_BIN` 仅 debug/test 生效）编译通过
///     （`dart analyze` 覆盖其编译；此处断言 debug 下 `kDebugMode` 为真，
///     测试即 debug 构建）。
void main() {
  test('sanitizedEnvironment 剔除注入变量并保留其余环境', () {
    final input = <String, String>{
      'LD_PRELOAD': '/tmp/evil.so',
      'LD_AUDIT': '/tmp/evil-audit.so',
      'LD_LIBRARY_PATH': '/tmp/evil-libs',
      'DYLD_INSERT_LIBRARIES': '/tmp/evil.dylib',
      'DYLD_LIBRARY_PATH': '/tmp/evil-dyld',
      'DYLD_FRAMEWORK_PATH': '/tmp/evil-frameworks',
      'PATH': '/usr/bin:/bin',
      'LANG': 'zh_CN.UTF-8',
      'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/run/user/1000/bus',
    };
    final out = VaultProcess.sanitizedEnvironment(input);
    for (final key in VaultProcess.loaderInjectionVars) {
      expect(out.containsKey(key), isFalse, reason: '$key 应从净化环境剔除');
    }
    // 其余变量必须原样保留（locale / D-Bus / PATH 等不能丢）。
    expect(out['PATH'], '/usr/bin:/bin');
    expect(out['LANG'], 'zh_CN.UTF-8');
    expect(out['DBUS_SESSION_BUS_ADDRESS'], 'unix:path=/run/user/1000/bus');
    // 输入表不应被就地修改。
    expect(input['LD_PRELOAD'], '/tmp/evil.so');
  });

  test('loaderInjectionVars 覆盖两平台载荷；真实环境净化后不含注入变量', () {
    expect(VaultProcess.loaderInjectionVars, contains('LD_PRELOAD'));
    expect(VaultProcess.loaderInjectionVars, contains('LD_AUDIT'));
    expect(VaultProcess.loaderInjectionVars, contains('DYLD_INSERT_LIBRARIES'));
    // 不拒绝合法用途的变量之一被列为需要剔除（缩小库搜索面），但注入变量必在列。
    final sanitized = VaultProcess.sanitizedEnvironment();
    for (final key in VaultProcess.loaderInjectionVars) {
      expect(sanitized.containsKey(key), isFalse);
    }
    // 非注入键数量 = 原始数量 - 实际存在的注入键数量（逐键保留语义）。
    final original = Platform.environment;
    final removed =
        VaultProcess.loaderInjectionVars.where(original.containsKey).length;
    expect(sanitized.length, original.length - removed);
  });

  test('kDebugMode 门控在测试（debug）构建下编译并生效', () {
    // 门控逻辑：`kDebugMode || const bool.fromEnvironment(...)`。测试以 debug
    // 运行，故 kDebugMode 为真 → `ARCHOERA_VAULT_BIN` 在本环境被信任（CI 依赖）。
    expect(kDebugMode, isTrue);
  });
}
