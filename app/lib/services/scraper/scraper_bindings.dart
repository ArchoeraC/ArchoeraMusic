// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// archoera_scraper FFI 绑定。
///
/// 定位、加载 libarchoera_scraper.{so,dylib,dll}（统一走 [NativeLibPaths]，
/// ancestors 查找 + dev 兜底模式，见 native_lib_paths.dart）。
/// 模块位于 app/core/scraper，产物 libarchoera_scraper.so 由该模块
/// CMake 构建。
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../log/log.dart';
import '../native_lib_paths.dart';
import '../native_library_registry.dart' as ffi_registry;

typedef ScraperCreateNative = Pointer<Void> Function(Pointer<Utf8> configJson);
typedef ScraperCreateDart = Pointer<Void> Function(Pointer<Utf8> configJson);
typedef ScraperEnqueueNative = Int32 Function(
  Pointer<Void> handle,
  Pointer<Utf8> trackJson,
);
typedef ScraperEnqueueDart = int Function(
  Pointer<Void> handle,
  Pointer<Utf8> trackJson,
);
typedef ScraperRunNative = Int32 Function(Pointer<Void> handle);
typedef ScraperRunDart = int Function(Pointer<Void> handle);
typedef ScraperIsDoneNative = Int32 Function(Pointer<Void> handle);
typedef ScraperIsDoneDart = int Function(Pointer<Void> handle);
typedef ScraperIsRunningNative = Int32 Function(Pointer<Void> handle);
typedef ScraperIsRunningDart = int Function(Pointer<Void> handle);
typedef ScraperCancelNative = Void Function(Pointer<Void> handle);
typedef ScraperCancelDart = void Function(Pointer<Void> handle);
typedef ScraperPollEventNative = Pointer<Utf8> Function(Pointer<Void> handle);
typedef ScraperPollEventDart = Pointer<Utf8> Function(Pointer<Void> handle);
typedef ScraperWaitEventNative = Int32 Function(
  Pointer<Void> handle,
  Pointer<Uint8> buf,
  Int32 cap,
  Int32 timeoutMs,
);
typedef ScraperWaitEventDart = int Function(
  Pointer<Void> handle,
  Pointer<Uint8> buf,
  int cap,
  int timeoutMs,
);
typedef ScraperDestroyNative = Void Function(Pointer<Void> handle);
typedef ScraperDestroyDart = void Function(Pointer<Void> handle);
typedef ScraperSetLogSinkNative = Void Function(
  Pointer<NativeFunction<LogWriteNative>> fn,
  Int32 minLevel,
);
typedef ScraperSetLogSinkDart = void Function(
  Pointer<NativeFunction<LogWriteNative>> fn,
  int minLevel,
);
typedef ScraperReadTagsNative = Pointer<Utf8> Function(Pointer<Utf8> filePath);
typedef ScraperReadTagsDart = Pointer<Utf8> Function(Pointer<Utf8> filePath);
typedef ScraperWriteTagsNative = Pointer<Utf8> Function(
  Pointer<Utf8> filePath,
  Pointer<Utf8> tagsJson,
);
typedef ScraperWriteTagsDart = Pointer<Utf8> Function(
  Pointer<Utf8> filePath,
  Pointer<Utf8> tagsJson,
);
typedef ScraperFreeStringNative = Void Function(Pointer<Utf8> s);
typedef ScraperFreeStringDart = void Function(Pointer<Utf8> s);

/// 刮削库句柄：持有 DynamicLibrary + 各函数指针，防止 GC 回收库。
class ScraperBindings {
  ScraperBindings._(this._lib);

  final DynamicLibrary _lib;
  static ScraperBindings? _instance;

  late final ScraperCreateDart create = _lib
      .lookupFunction<ScraperCreateNative, ScraperCreateDart>(
        'archoera_scraper_create',
      );
  late final ScraperEnqueueDart enqueue = _lib
      .lookupFunction<ScraperEnqueueNative, ScraperEnqueueDart>(
        'archoera_scraper_enqueue',
      );
  late final ScraperRunDart run = _lib
      .lookupFunction<ScraperRunNative, ScraperRunDart>('archoera_scraper_run');
  late final ScraperIsDoneDart isDone = _lib
      .lookupFunction<ScraperIsDoneNative, ScraperIsDoneDart>(
        'archoera_scraper_is_done',
      );
  late final ScraperIsRunningDart isRunning = _lib
      .lookupFunction<ScraperIsRunningNative, ScraperIsRunningDart>(
        'archoera_scraper_is_running',
      );
  late final ScraperCancelDart cancel = _lib
      .lookupFunction<ScraperCancelNative, ScraperCancelDart>(
        'archoera_scraper_cancel',
      );
  late final ScraperPollEventDart _pollEvent = _lib
      .lookupFunction<ScraperPollEventNative, ScraperPollEventDart>(
        'archoera_scraper_poll_event',
      );
  late final ScraperWaitEventDart _waitEvent = _lib
      .lookupFunction<ScraperWaitEventNative, ScraperWaitEventDart>(
        'archoera_scraper_wait_event',
      );
  late final ScraperDestroyDart _destroy = _lib
      .lookupFunction<ScraperDestroyNative, ScraperDestroyDart>(
        'archoera_scraper_destroy',
      );
  late final ScraperReadTagsDart _readTags = _lib
      .lookupFunction<ScraperReadTagsNative, ScraperReadTagsDart>(
        'archoera_scraper_read_tags',
      );
  late final ScraperWriteTagsDart _writeTags = _lib
      .lookupFunction<ScraperWriteTagsNative, ScraperWriteTagsDart>(
        'archoera_scraper_write_tags',
      );
  late final ScraperFreeStringDart _freeString = _lib
      .lookupFunction<ScraperFreeStringNative, ScraperFreeStringDart>(
        'archoera_scraper_free_string',
      );

  /// 读取单文件标签 → JSON 字符串（空字符串表示无结果）。
  String readTagsJson(String filePath) {
    final pathPtr = filePath.toNativeUtf8();
    Pointer<Utf8> result = nullptr;
    try {
      result = _readTags(pathPtr);
      if (result.address == 0) return '';
      return result.toDartString();
    } finally {
      calloc.free(pathPtr);
      if (result.address != 0) _freeString(result);
    }
  }

  /// 写入单文件标签 → JSON 字符串。
  String writeTagsJson(String filePath, String tagsJson) {
    final pathPtr = filePath.toNativeUtf8();
    final jsonPtr = tagsJson.toNativeUtf8();
    Pointer<Utf8> result = nullptr;
    try {
      result = _writeTags(pathPtr, jsonPtr);
      if (result.address == 0) return '';
      return result.toDartString();
    } finally {
      calloc.free(pathPtr);
      calloc.free(jsonPtr);
      if (result.address != 0) _freeString(result);
    }
  }

  /// 取一条事件 JSON（poll 回退）；无则返回 null。
  Pointer<Utf8> pollEvent(Pointer<Void> handle) => _pollEvent(handle);

  /// 阻塞等待一条事件（**接收 isolate 事件泵专用**；须在独立 isolate 调用，
  /// 避免阻塞主 isolate）。缓冲由调用方分配/释放。
  ///
  /// 返回 >0 事件字节数（已写入 [buf]，'\0' 结尾）；0 超时；-1 已销毁
  /// （调用方应退出事件泵，勿再对本句柄调用任何函数）。
  int waitEventInto(
    Pointer<Void> handle,
    Pointer<Uint8> buf,
    int cap,
    int timeoutMs,
  ) => _waitEvent(handle, buf, cap, timeoutMs);

  void destroy(Pointer<Void> handle) => _destroy(handle);

  static ScraperBindings get instance =>
      _instance ??= (ScraperBindings._(load())..installLogSink());

  /// 注入统一日志 sink（缺失符号时静默跳过，兼容旧版库）。
  void installLogSink() {
    final sink = Log.nativeWritePointer;
    if (sink == null) return;
    try {
      _lib.lookupFunction<ScraperSetLogSinkNative, ScraperSetLogSinkDart>(
        'archoera_scraper_set_log_sink',
      )(sink, Log.effectiveLevel);
    } catch (_) {
      // 旧版库无此符号：保持 stderr 兜底。
    }
  }

  /// 定位并加载共享库（失败抛 StateError 附搜索过程）。经统一注册表引用计数。
  static DynamicLibrary load() {
    final path = resolveSoPath();
    if (path == null) {
      throw StateError('未找到 libarchoera_scraper（已按 ancestors 链与 dev 目录查找）');
    }
    return ffi_registry.acquire(NativeModule.scraper, path: path);
  }

  /// 释放本 isolate 对 scraper 库的引用并作废单例（用后归零即真正卸载）。
  ///
  /// 仅在确认本 isolate 无在途调用（含事件泵 isolate 已退出）时调用。
  static void release() {
    final inst = _instance;
    _instance = null;
    if (inst != null) {
      ffi_registry.release(NativeModule.scraper);
    }
  }

  /// 查找共享库路径：统一走 [NativeLibPaths]（祖先链 + dev 兜底）。
  static String? resolveSoPath() {
    return NativeLibPaths.resolve(NativeModule.scraper);
  }
}
