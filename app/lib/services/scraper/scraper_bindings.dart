/// archoera_scraper FFI 绑定。
///
/// 定位、加载 libarchoera_scraper.{so,dylib,dll}（统一走 [NativeLibPaths]，
/// ancestors 查找 + dev 兜底模式，见 native_lib_paths.dart）。
/// 模块位于 app/core/scraper，产物 libarchoera_scraper.so 由该模块
/// CMake 构建。
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../native_lib_paths.dart';

typedef ScraperCreateNative = Pointer<Void> Function(Pointer<Utf8> configJson);
typedef ScraperCreateDart = Pointer<Void> Function(Pointer<Utf8> configJson);
typedef ScraperEnqueueNative = Int32 Function(Pointer<Void> handle, Pointer<Utf8> trackJson);
typedef ScraperEnqueueDart = int Function(Pointer<Void> handle, Pointer<Utf8> trackJson);
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
typedef ScraperDestroyNative = Void Function(Pointer<Void> handle);
typedef ScraperDestroyDart = void Function(Pointer<Void> handle);

/// 刮削库句柄：持有 DynamicLibrary + 各函数指针，防止 GC 回收库。
class ScraperBindings {
  ScraperBindings._(this._lib);

  final DynamicLibrary _lib;
  static ScraperBindings? _instance;

  late final ScraperCreateDart create =
      _lib.lookupFunction<ScraperCreateNative, ScraperCreateDart>('archoera_scraper_create');
  late final ScraperEnqueueDart enqueue = _lib.lookupFunction<ScraperEnqueueNative,
      ScraperEnqueueDart>('archoera_scraper_enqueue');
  late final ScraperRunDart run =
      _lib.lookupFunction<ScraperRunNative, ScraperRunDart>('archoera_scraper_run');
  late final ScraperIsDoneDart isDone = _lib.lookupFunction<ScraperIsDoneNative,
      ScraperIsDoneDart>('archoera_scraper_is_done');
  late final ScraperIsRunningDart isRunning = _lib.lookupFunction<ScraperIsRunningNative,
      ScraperIsRunningDart>('archoera_scraper_is_running');
  late final ScraperCancelDart cancel = _lib.lookupFunction<ScraperCancelNative,
      ScraperCancelDart>('archoera_scraper_cancel');
  late final ScraperPollEventDart pollEvent = _lib.lookupFunction<ScraperPollEventNative,
      ScraperPollEventDart>('archoera_scraper_poll_event');
  late final ScraperDestroyDart destroy = _lib.lookupFunction<ScraperDestroyNative,
      ScraperDestroyDart>('archoera_scraper_destroy');

  static ScraperBindings get instance => _instance ??= ScraperBindings._(load());

  /// 定位并加载共享库（失败抛 StateError 附搜索过程）。
  static DynamicLibrary load() {
    final path = resolveSoPath();
    if (path == null) {
      throw StateError('未找到 libarchoera_scraper（已按 ancestors 链与 dev 目录查找）');
    }
    return DynamicLibrary.open(path);
  }

  /// 查找共享库路径：统一走 [NativeLibPaths]（祖先链 + dev 兜底）。
  static String? resolveSoPath() {
    return NativeLibPaths.resolve(NativeModule.scraper);
  }
}
