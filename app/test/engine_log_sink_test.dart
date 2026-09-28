// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/log/log.dart';
import 'package:archoera_music/services/native_lib_paths.dart';
import 'package:archoera_music/services/playback/engine_bindings.dart';

/// 回归：引擎在 `Isolate.run(...)` 的子 isolate 中加载（AudioEngineProcess.start
/// 的真实场景），`Log` 的静态状态不跨 isolate，必须仍能注入进程级 sink，
/// 使引擎日志进入统一文件/格式。
void main() {
  test('引擎在子 isolate 加载也注入统一 sink', () async {
    if (NativeLibPaths.resolve(NativeModule.mediaEngine) == null ||
        NativeLibPaths.resolve(NativeModule.log) == null) {
      markTestSkipped('原生库未构建');
      return;
    }

    final logDir = Directory.systemTemp.createTempSync('archoera-eng-log');
    final sessionDir = Directory.systemTemp.createTempSync('archoera-eng-sess');
    Log.init(
      dir: logDir.path,
      fileBase: 'englog',
      level: LogLevel.debug,
      color: false,
    );

    int addr;
    try {
      addr = await Isolate.run<int>(() {
        final cfg = engineConfigFromParams();
        try {
          final h = EngineBindings.instance.create(
            source: '${sessionDir.path}/does-not-exist.mp3',
            sessionDir: sessionDir.path,
            playerFile: null,
            config: cfg,
          );
          return h.address;
        } finally {
          calloc.free(cfg);
        }
      });
    } catch (e) {
      // 测试环境缺 FFmpeg/引擎不可用时跳过（不作为失败）。
      markTestSkipped('引擎在测试环境不可用: $e');
      sessionDir.deleteSync(recursive: true);
      logDir.deleteSync(recursive: true);
      return;
    }

    // 引擎线程异步尝试打开源并记录错误。
    await Future<void>.delayed(const Duration(milliseconds: 900));
    EngineBindings.instance.destroy(Pointer<Opaque>.fromAddress(addr));

    try {
      final text = File('${logDir.path}/englog.log').readAsStringSync();
      // 统一格式：`[HH:mm:ss ERROR] [audio-engine:...] ...`（引擎消息自带模块前缀）。
      expect(text, contains('ERROR]'), reason: '引擎 ERROR 应为统一格式');
      expect(text, contains('[audio-engine:'), reason: '引擎模块前缀应保留');
    } finally {
      sessionDir.deleteSync(recursive: true);
      logDir.deleteSync(recursive: true);
    }
  });

  test('EraAudio URL 路径的 FFmpeg 早期日志也归入统一 sink', () async {
    if (NativeLibPaths.resolve(NativeModule.mediaEngine) == null ||
        NativeLibPaths.resolve(NativeModule.log) == null) {
      markTestSkipped('原生库未构建');
      return;
    }
    final logDir = Directory.systemTemp.createTempSync('archoera-url-log');
    final sessionDir = Directory.systemTemp.createTempSync('archoera-url-sess');
    Log.init(
      dir: logDir.path,
      fileBase: 'urllog',
      level: LogLevel.debug,
      color: false,
    );

    int addr;
    try {
      addr = await Isolate.run<int>(() {
        // engineMode=1（EraAudio）→ 走 pipeline_era_url_open（FFmpeg AVIO 传输）。
        final cfg = engineConfigFromParams(engineMode: 1);
        try {
          final h = EngineBindings.instance.create(
            source: 'http://127.0.0.1:1/nope.mp3',
            sessionDir: sessionDir.path,
            playerFile: null,
            config: cfg,
          );
          return h.address;
        } finally {
          calloc.free(cfg);
        }
      });
    } catch (e) {
      markTestSkipped('引擎在测试环境不可用: $e');
      sessionDir.deleteSync(recursive: true);
      logDir.deleteSync(recursive: true);
      return;
    }

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    EngineBindings.instance.destroy(Pointer<Opaque>.fromAddress(addr));

    try {
      final text = File('${logDir.path}/urllog.log').readAsStringSync();
      // 关键：AVIO 打开早于任何 decoder_open；若回调未提前安装，这些 FFmpeg
      // 行只会落到 stderr、不进统一文件。断言 `[ffmpeg]` 证明已归入 sink。
      expect(text, contains('[ffmpeg]'),
          reason: 'URL 传输阶段的 FFmpeg 日志应归入统一 sink');
    } finally {
      sessionDir.deleteSync(recursive: true);
      logDir.deleteSync(recursive: true);
    }
  });
}
