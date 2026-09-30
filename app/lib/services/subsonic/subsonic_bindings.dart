// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// archoera_subsonic FFI 绑定（Go c-shared 服务端库）。
///
/// 定位、加载 libarchoera_subsonic.{so,dylib,dll}（统一走 [NativeLibPaths]，
/// ancestors 查找 + dev 兜底模式，见 native_lib_paths.dart）。产物由
/// app/core/subsonic/build.sh 构建（go build -buildmode=c-shared，含 Rust
/// 转码器 dlopen 依赖）。
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../log/log.dart';
import '../native_lib_paths.dart';
import '../native_library_registry.dart' as ffi_registry;

typedef SubsonicCreateNative = IntPtr Function(Pointer<Utf8> configJson);
typedef SubsonicCreateDart = int Function(Pointer<Utf8> configJson);
typedef SubsonicPollEventNative =
    Int32 Function(IntPtr handle, Pointer<Uint8> buf, Int32 bufLen);
typedef SubsonicPollEventDart =
    int Function(int handle, Pointer<Uint8> buf, int bufLen);
typedef SubsonicDestroyNative = Void Function(IntPtr handle);
typedef SubsonicDestroyDart = void Function(int handle);
typedef SubsonicEncryptNative =
    Int32 Function(
      IntPtr handle,
      Pointer<Utf8> plain,
      Pointer<Uint8> buf,
      Int32 bufLen,
    );
typedef SubsonicEncryptDart =
    int Function(
      int handle,
      Pointer<Utf8> plain,
      Pointer<Uint8> buf,
      int bufLen,
    );
typedef SubsonicDecryptNative =
    Int32 Function(
      IntPtr handle,
      Pointer<Utf8> cipher,
      Pointer<Uint8> buf,
      Int32 bufLen,
    );
typedef SubsonicDecryptDart =
    int Function(
      int handle,
      Pointer<Utf8> cipher,
      Pointer<Uint8> buf,
      int bufLen,
    );
typedef SubsonicShredFilesNative =
    Int32 Function(
      IntPtr handle,
      Pointer<Utf8> reqJson,
      Pointer<Uint8> buf,
      Int32 bufLen,
    );
typedef SubsonicShredFilesDart =
    int Function(
      int handle,
      Pointer<Utf8> reqJson,
      Pointer<Uint8> buf,
      int bufLen,
    );
typedef SubsonicSetLogSinkNative =
    Void Function(Pointer<NativeFunction<LogWriteNative>> fn, Int32 minLevel);
typedef SubsonicSetLogSinkDart = void Function(
    Pointer<NativeFunction<LogWriteNative>> fn, int minLevel);

/// Subsonic 服务端库句柄：持有 DynamicLibrary + 各函数指针，防止 GC 回收库。
class SubsonicBindings {
  SubsonicBindings._(this._lib);

  final DynamicLibrary _lib;
  static SubsonicBindings? _instance;

  late final SubsonicCreateDart create = _lib
      .lookupFunction<SubsonicCreateNative, SubsonicCreateDart>(
        'archoera_subsonic_create',
      );
  late final SubsonicPollEventDart pollEvent = _lib
      .lookupFunction<SubsonicPollEventNative, SubsonicPollEventDart>(
        'archoera_subsonic_poll_event',
      );
  late final SubsonicDestroyDart destroy = _lib
      .lookupFunction<SubsonicDestroyNative, SubsonicDestroyDart>(
        'archoera_subsonic_destroy',
      );
  late final SubsonicEncryptDart encrypt = _lib
      .lookupFunction<SubsonicEncryptNative, SubsonicEncryptDart>(
        'archoera_subsonic_encrypt',
      );
  late final SubsonicDecryptDart decrypt = _lib
      .lookupFunction<SubsonicDecryptNative, SubsonicDecryptDart>(
        'archoera_subsonic_decrypt',
      );
  late final SubsonicShredFilesDart shredFiles = _lib
      .lookupFunction<SubsonicShredFilesNative, SubsonicShredFilesDart>(
        'archoera_subsonic_shred_files',
      );

  static SubsonicBindings get instance =>
      _instance ??= (SubsonicBindings._(load())..installLogSink());

  /// 注入统一日志 sink（缺失符号时静默跳过，兼容旧版库）。
  void installLogSink() {
    final sink = Log.nativeWritePointer;
    if (sink == null) return;
    try {
      _lib.lookupFunction<SubsonicSetLogSinkNative, SubsonicSetLogSinkDart>(
        'archoera_subsonic_set_log_sink',
      )(sink, Log.effectiveLevel);
    } catch (_) {
      // 旧版库无此符号：保持 Go log 兜底。
    }
  }

  /// 定位并加载共享库（失败抛 StateError 附搜索过程）。经统一注册表引用计数。
  static DynamicLibrary load() {
    final path = resolveSoPath();
    if (path == null) {
      throw StateError('未找到 libarchoera_subsonic（已按 ancestors 链与 dev 目录查找）');
    }
    return ffi_registry.acquire(NativeModule.subsonic, path: path);
  }

  /// 释放本 isolate 对 subsonic 库的引用并作废单例（用后归零即真正卸载）。
  static void release() {
    final inst = _instance;
    _instance = null;
    if (inst != null) {
      ffi_registry.release(NativeModule.subsonic);
    }
  }

  /// 查找共享库路径：统一走 [NativeLibPaths]（祖先链 + dev 兜底）。
  static String? resolveSoPath() {
    return NativeLibPaths.resolve(NativeModule.subsonic);
  }
}
