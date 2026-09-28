// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/log/log.dart';
import 'package:archoera_music/services/native_lib_paths.dart';

/// 端到端：Dart → libarchoera_log（FFI）→ 落盘，验证统一格式。
/// 原生库未构建时跳过（不使测试红）。
void main() {
  test('Dart 经原生核心写出统一格式日志', () {
    final libPath = NativeLibPaths.resolve(NativeModule.log);
    if (libPath == null) {
      markTestSkipped('libarchoera_log 未构建（先跑 app/native/log 的 CMake）');
      return;
    }

    final dir = Directory.systemTemp.createTempSync('archoera-log-it');
    try {
      Log.init(
        dir: dir.path,
        fileBase: 'itest',
        level: LogLevel.debug,
        color: false,
      );
      expect(Log.nativeReady, isTrue, reason: '原生核心应已载入');

      Log.w('resolver', 'could not resolve song x.mp3:invalid tag');
      Log.e('', '429 too many requests');
      Log.f('kernel', 'Kernel Decode Error');

      final file = File('${dir.path}/itest.log');
      expect(file.existsSync(), isTrue, reason: '应创建日志文件');
      final text = file.readAsStringSync();
      expect(
        text,
        contains('WARN] [resolver] could not resolve song x.mp3:invalid tag'),
      );
      expect(text, contains('ERROR] 429 too many requests'));
      expect(text, contains('FATAL] [kernel] Kernel Decode Error'));
      // 时间戳前缀 [HH:MM:SS
      expect(text, matches(RegExp(r'^\[\d\d:\d\d:\d\d ')));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('跨 isolate 懒加载 sink 指针可用（引擎在 Isolate.run 内加载的场景）', () async {
    if (NativeLibPaths.resolve(NativeModule.log) == null) {
      markTestSkipped('libarchoera_log 未构建（先跑 app/native/log 的 CMake）');
      return;
    }
    // 子 isolate 无主 isolate 的 Log.init 状态；nativeWritePointer 应能懒加载
    // 出同一进程的核心指针，从而让该 isolate 内加载的原生模块也能注入 sink。
    final ok = await Isolate.run(() => Log.nativeWritePointer != null);
    expect(ok, isTrue);
  });
}
