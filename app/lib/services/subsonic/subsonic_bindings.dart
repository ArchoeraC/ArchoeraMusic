/// archoera_subsonic FFI 绑定（Go c-shared 服务端库）。
///
/// 定位、加载 libarchoera_subsonic.{so,dylib,dll}（与 scraper 相同的
/// ancestors 查找模式：exe 祖先链找 `subsonic/build/`，dev 兜底
/// `cwd/core/subsonic/build`）。产物由 app/core/subsonic/build.sh 构建
/// （go build -buildmode=c-shared，含 Rust 转码器 dlopen 依赖）。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef SubsonicCreateNative = IntPtr Function(Pointer<Utf8> configJson);
typedef SubsonicCreateDart = int Function(Pointer<Utf8> configJson);
typedef SubsonicPollEventNative = Int32 Function(
    IntPtr handle, Pointer<Uint8> buf, Int32 bufLen);
typedef SubsonicPollEventDart = int Function(
    int handle, Pointer<Uint8> buf, int bufLen);
typedef SubsonicDestroyNative = Void Function(IntPtr handle);
typedef SubsonicDestroyDart = void Function(int handle);
typedef SubsonicLyricResponseNative = Void Function(
    IntPtr handle, IntPtr requestId, Pointer<Utf8> resultJson);
typedef SubsonicLyricResponseDart = void Function(
    int handle, int requestId, Pointer<Utf8> resultJson);
typedef SubsonicEncryptNative = Int32 Function(
    IntPtr handle, Pointer<Utf8> plain, Pointer<Uint8> buf, Int32 bufLen);
typedef SubsonicEncryptDart = int Function(
    int handle, Pointer<Utf8> plain, Pointer<Uint8> buf, int bufLen);
typedef SubsonicDecryptNative = Int32 Function(
    IntPtr handle, Pointer<Utf8> cipher, Pointer<Uint8> buf, Int32 bufLen);
typedef SubsonicDecryptDart = int Function(
    int handle, Pointer<Utf8> cipher, Pointer<Uint8> buf, int bufLen);

/// Subsonic 服务端库句柄：持有 DynamicLibrary + 各函数指针，防止 GC 回收库。
class SubsonicBindings {
  SubsonicBindings._(this._lib);

  final DynamicLibrary _lib;
  static SubsonicBindings? _instance;

  late final SubsonicCreateDart create = _lib
      .lookupFunction<SubsonicCreateNative, SubsonicCreateDart>(
          'archoera_subsonic_create');
  late final SubsonicPollEventDart pollEvent = _lib
      .lookupFunction<SubsonicPollEventNative, SubsonicPollEventDart>(
          'archoera_subsonic_poll_event');
  late final SubsonicDestroyDart destroy = _lib
      .lookupFunction<SubsonicDestroyNative, SubsonicDestroyDart>(
          'archoera_subsonic_destroy');
  late final SubsonicLyricResponseDart lyricResponse = _lib
      .lookupFunction<SubsonicLyricResponseNative, SubsonicLyricResponseDart>(
          'archoera_subsonic_lyric_response');
  late final SubsonicEncryptDart encrypt = _lib
      .lookupFunction<SubsonicEncryptNative, SubsonicEncryptDart>(
          'archoera_subsonic_encrypt');
  late final SubsonicDecryptDart decrypt = _lib
      .lookupFunction<SubsonicDecryptNative, SubsonicDecryptDart>(
          'archoera_subsonic_decrypt');

  static SubsonicBindings get instance => _instance ??= SubsonicBindings._(load());

  /// 定位并加载共享库（失败抛 StateError 附搜索过程）。
  static DynamicLibrary load() {
    final path = resolveSoPath();
    if (path == null) {
      throw StateError('未找到 libarchoera_subsonic（已按 ancestors 链与 dev 目录查找）');
    }
    return DynamicLibrary.open(path);
  }

  /// 查找共享库路径：Platform.resolvedExecutable 祖先链逐级找 `subsonic/build/`；
  /// 未命中回退 dev 兜底 `cwd/core/subsonic/build/`。
  static String? resolveSoPath() {
    final fileName = Platform.isWindows
        ? 'archoera_subsonic.dll'
        : Platform.isMacOS
            ? 'libarchoera_subsonic.dylib'
            : 'libarchoera_subsonic.so';

    // 1) bundle：exe 祖先链找 subsonic/build/
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 8; i++) {
      final candidate = File('${dir.path}/subsonic/build/$fileName');
      if (candidate.existsSync()) return candidate.absolute.path;
      dir = dir.parent;
    }

    // 2) dev 兜底：flutter run 的 cwd 为 app/ → app/core/subsonic/build/
    final fromCwd = File('${Directory.current.path}/core/subsonic/build/$fileName');
    if (fromCwd.existsSync()) return fromCwd.absolute.path;

    return null;
  }
}
