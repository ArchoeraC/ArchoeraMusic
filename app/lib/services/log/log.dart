// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../native_lib_paths.dart';

/// 统一日志级别（数值与 `app/native/log/include/archoera_log.h` 一一对应）。
enum LogLevel {
  debug(0, 'DEBUG'),
  info(1, 'INFO'),
  warn(2, 'WARN'),
  error(3, 'ERROR'),
  fatal(4, 'FATAL');

  const LogLevel(this.value, this.label);

  final int value;
  final String label;
}

/// 统一日志门面。
///
/// 全层（Dart / 平台桥接 / C 引擎 / Rust / Zig）共用同一格式与落盘路径：
/// `[HH:mm:ss LEVEL] [tag] message`，INFO/WARN/ERROR/FATAL 各自独立颜色。
///
/// 实现策略：Dart 载入原生核心库 `libarchoera_log`，所有 Dart 日志经 FFI
/// 写入；其余原生组件由宿主把 [nativeWritePointer] 注入各自的 `*_set_log_sink`。
/// 原生核心**即时写穿** stderr + 文件（追加 + 轮转），不驻留内存队列。
///
/// 原生库缺失时（测试 / 未打包）降级为 Dart 侧等价格式化输出，行为一致但仅控制台。
class Log {
  Log._();

  /// 低于此级别不输出（同时下发到原生核心做二次过滤）。
  static LogLevel minLevel = LogLevel.info;

  static _LogBinding? _binding;
  static bool _debugPrintHooked = false;

  /// 原生 `archoera_log_write` 指针，供其它原生模块注入 sink；未加载时为 null。
  ///
  /// 跨 isolate 安全：`Log.init` 通常只在主 isolate 执行，而原生模块可能在
  /// `Isolate.run(...)` 的临时 isolate 中加载（如引擎 create）。此时本 getter
  /// 会在本 isolate 懒打开核心库以取得同一进程的 `archoera_log_write` 指针
  /// （核心的目录/级别/着色为进程级状态，主 isolate init 后全局生效）。
  static Pointer<NativeFunction<LogWriteNative>>? get nativeWritePointer =>
      (_binding ?? _openBindingLazy())?.writePointer;

  /// 当前有效最小级别：优先读原生核心（跨 isolate 一致），否则用本地 [minLevel]。
  static int get effectiveLevel {
    final b = _binding;
    if (b != null) {
      try {
        return b.level();
      } catch (_) {
        // 旧版核心无 archoera_log_level：退回本地值。
      }
    }
    return minLevel.value;
  }

  static _LogBinding? _openBindingLazy() {
    try {
      final path = NativeLibPaths.resolve(NativeModule.log);
      if (path == null) return null;
      final b = _LogBinding(DynamicLibrary.open(path));
      _binding = b;
      return b;
    } catch (_) {
      return null;
    }
  }

  /// 是否已接上原生核心（否则走 Dart 降级路径）。
  static bool get nativeReady => _binding != null;

  /// 初始化日志核心。
  ///
  /// [dir] 日志目录（通常 `<dataDir>/logs`）；[fileBase] 文件名基；
  /// [level] 最小级别；[color] true/false 强制着色，null = 仅终端着色（推荐）。
  static void init({
    String? dir,
    String fileBase = 'archoera',
    LogLevel level = LogLevel.info,
    bool? color,
    bool fileEnabled = true,
  }) {
    minLevel = level;
    try {
      final path = NativeLibPaths.resolve(NativeModule.log);
      if (path != null) {
        final binding = _LogBinding(DynamicLibrary.open(path));
        final Pointer<Utf8> dirPtr = (dir == null || dir.isEmpty)
            ? nullptr.cast<Utf8>()
            : dir.toNativeUtf8();
        final Pointer<Utf8> basePtr = fileBase.toNativeUtf8();
        try {
          final rc = binding.init(
            dirPtr,
            basePtr,
            level.value,
            color == null ? -1 : (color ? 1 : 0),
          );
          if (rc == 0) {
            _binding = binding;
            // 用户可关闭日志落盘（仅控制台）；dir 为空时本就无文件。
            binding.setFileEnabled(fileEnabled ? 1 : 0);
          }
        } finally {
          if (dirPtr != nullptr) malloc.free(dirPtr);
          malloc.free(basePtr);
        }
      }
    } catch (_) {
      _binding = null;
    }
    _hookDebugPrint();
  }

  /// 运行期开启/关闭日志落盘（使用 [init] 配置的目录；false = 仅控制台）。
  static void setFileEnabled(bool enabled) {
    _binding?.setFileEnabled(enabled ? 1 : 0);
  }

  /// 运行时调整最小级别（同时下发原生核心）。
  static void setLevel(LogLevel level) {
    minLevel = level;
    _binding?.setLevel(level.value);
  }

  /// 运行时可调整着色（null = 自动）。
  static void setColor(bool? enabled) {
    _binding?.setColor(enabled == null ? -1 : (enabled ? 1 : 0));
  }

  /// 便于测试/工具：直接格式化一行（不含颜色）。
  static String formatLine(LogLevel level, String? tag, Object? message) {
    final t = DateTime.now();
    String two(int v) => v < 10 ? '0$v' : '$v';
    final ts = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    final body = (tag == null || tag.isEmpty)
        ? '${message ?? ''}'
        : '[$tag] ${message ?? ''}';
    return '[$ts ${level.label}] $body';
  }

  static void d(String tag, Object? message) =>
      _emit(LogLevel.debug, tag, message);
  static void i(String tag, Object? message) =>
      _emit(LogLevel.info, tag, message);
  static void w(String tag, Object? message) =>
      _emit(LogLevel.warn, tag, message);
  static void e(String tag, Object? message) =>
      _emit(LogLevel.error, tag, message);
  static void f(String tag, Object? message) =>
      _emit(LogLevel.fatal, tag, message);

  /// 以任意级别写日志（供按内容分级/转发的调用方）。
  static void at(LogLevel level, String tag, Object? message) =>
      _emit(level, tag, message);

  static void _emit(LogLevel level, String? tag, Object? message) {
    if (level.value < minLevel.value) return;
    final text = '${message ?? ''}';
    final binding = _binding;
    if (binding != null) {
      try {
        final Pointer<Utf8> tagPtr = (tag == null || tag.isEmpty)
            ? nullptr.cast<Utf8>()
            : tag.toNativeUtf8();
        final Pointer<Utf8> msgPtr = text.toNativeUtf8();
        try {
          binding.write(level.value, tagPtr, msgPtr);
        } finally {
          if (tagPtr != nullptr) malloc.free(tagPtr);
          malloc.free(msgPtr);
        }
        return;
      } catch (_) {
        // 透传失败则走降级路径（绝不因日志抛异常）。
      }
    }
    final line = formatLine(level, tag, text);
    final coloredConsole = stderr.hasTerminal ? _colorize(level, line) : line;
    stderr.writeln(coloredConsole);
  }

  /// 降级路径着色（原生核心可用时由其统一处理）。
  static String _colorize(LogLevel level, String line) {
    const reset = '\x1b[0m';
    final code = switch (level) {
      LogLevel.debug => '\x1b[90m',
      LogLevel.info => '\x1b[32m',
      LogLevel.warn => '\x1b[33m',
      LogLevel.error => '\x1b[31m',
      LogLevel.fatal => '\x1b[1;91m',
    };
    // 仅着色级别记号（与原生实现一致）。
    final token = '[${level.label}]';
    final at = line.indexOf(token);
    if (at < 0) return line;
    return line.replaceRange(at, at + token.length, '$code${level.label}$reset');
  }

  /// 把 Flutter 的 debugPrint 也纳入统一格式（避免游离的控制台输出）。
  static void _hookDebugPrint() {
    if (_debugPrintHooked) return;
    _debugPrintHooked = true;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.isNotEmpty) i('debug', message);
    };
  }
}

// ── FFI 绑定 ──────────────────────────────────────────────────────

typedef _LogInitNative = Int32 Function(
    Pointer<Utf8> dir, Pointer<Utf8> fileBase, Int32 level, Int32 colorMode);
typedef _LogInitDart = int Function(
    Pointer<Utf8> dir, Pointer<Utf8> fileBase, int level, int colorMode);

/// 供各原生模块注入的 sink 函数类型（等于原生 `ArchoeraLogFn`）。
typedef LogWriteNative = Void Function(
    Int32 level, Pointer<Utf8> tag, Pointer<Utf8> message);
typedef _LogWriteDart = void Function(
    int level, Pointer<Utf8> tag, Pointer<Utf8> message);
typedef _LogSetIntNative = Int32 Function(Int32 value);
typedef _LogSetIntDart = int Function(int value);

class _LogBinding {
  _LogBinding(DynamicLibrary lib)
      : init = lib.lookupFunction<_LogInitNative, _LogInitDart>(
            'archoera_log_init'),
        write = lib
            .lookup<NativeFunction<LogWriteNative>>('archoera_log_write')
            .asFunction<_LogWriteDart>(),
        writePointer =
            lib.lookup<NativeFunction<LogWriteNative>>('archoera_log_write'),
        setLevel =
            lib.lookupFunction<_LogSetIntNative, _LogSetIntDart>(
                'archoera_log_set_level'),
        setColor =
            lib.lookupFunction<_LogSetIntNative, _LogSetIntDart>(
                'archoera_log_set_color'),
        level = lib.lookupFunction<Int32 Function(), int Function()>(
            'archoera_log_level'),
        setFileEnabled = lib.lookupFunction<_LogSetIntNative, _LogSetIntDart>(
            'archoera_log_set_file_enabled');

  final _LogInitDart init;
  final _LogWriteDart write;
  final Pointer<NativeFunction<LogWriteNative>> writePointer;
  final _LogSetIntDart setLevel;
  final _LogSetIntDart setColor;
  final int Function() level;
  final _LogSetIntDart setFileEnabled;
}
