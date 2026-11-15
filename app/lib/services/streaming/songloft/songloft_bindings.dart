// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Songloft 客户端 FFI 绑定（与 Subsonic 服务端共用
/// `libarchoera_subsonic` c-shared 库）。
///
/// 导出符号由 `app/core/subsonic/lib_songloft.go` 提供；加载走统一
/// [NativeLibPaths] / ffi 注册表，与 [SubsonicBindings] 使用同一个库。
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../native_lib_paths.dart';
import '../../native_library_registry.dart' as ffi_registry;

typedef SongloftOpenNative = IntPtr Function(Pointer<Utf8> configJson);
typedef SongloftOpenDart = int Function(Pointer<Utf8> configJson);
typedef SongloftCloseNative = Void Function(IntPtr handle);
typedef SongloftCloseDart = void Function(int handle);
typedef SongloftCallNative =
    Int32 Function(IntPtr handle, Pointer<Utf8> requestJson);
typedef SongloftCallDart =
    int Function(int handle, Pointer<Utf8> requestJson);
typedef SongloftTakeEventNative =
    Pointer<Utf8> Function(IntPtr handle, Pointer<Int32> outLen);
typedef SongloftTakeEventDart =
    Pointer<Utf8> Function(int handle, Pointer<Int32> outLen);
typedef SongloftFreeNative = Void Function(Pointer<Utf8> ptr);
typedef SongloftFreeDart = void Function(Pointer<Utf8> ptr);

/// Songloft 客户端库句柄。
class SongloftBindings {
  SongloftBindings._(this._lib);

  final DynamicLibrary _lib;
  static SongloftBindings? _instance;

  late final SongloftOpenDart open = _lib
      .lookupFunction<SongloftOpenNative, SongloftOpenDart>(
        'archoera_songloft_open',
      );
  late final SongloftCloseDart close = _lib
      .lookupFunction<SongloftCloseNative, SongloftCloseDart>(
        'archoera_songloft_close',
      );
  late final SongloftCallDart call = _lib
      .lookupFunction<SongloftCallNative, SongloftCallDart>(
        'archoera_songloft_call',
      );
  late final SongloftTakeEventDart takeEvent = _lib
      .lookupFunction<SongloftTakeEventNative, SongloftTakeEventDart>(
        'archoera_songloft_take_event',
      );
  late final SongloftFreeDart free = _lib
      .lookupFunction<SongloftFreeNative, SongloftFreeDart>(
        'archoera_songloft_free',
      );

  static SongloftBindings get instance => _instance ??= _load();

  static SongloftBindings _load() {
    final path = NativeLibPaths.resolve(NativeModule.subsonic);
    if (path == null) {
      throw StateError('未找到 libarchoera_subsonic（Songloft 客户端依赖同一 FFI 库）');
    }
    return SongloftBindings._(
      ffi_registry.acquire(NativeModule.subsonic, path: path),
    );
  }

  /// 释放本 isolate 的引用（不主动卸载：Go runtime 线程常驻）。
  static void release() {
    _instance = null;
    ffi_registry.release(NativeModule.subsonic);
  }
}
