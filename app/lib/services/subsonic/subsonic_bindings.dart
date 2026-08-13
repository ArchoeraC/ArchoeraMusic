/// archoera_subsonic FFI 绑定（Go c-shared 服务端库）。
///
/// 定位、加载 libarchoera_subsonic.{so,dylib,dll}（统一走 [NativeLibPaths]，
/// ancestors 查找 + dev 兜底模式，见 native_lib_paths.dart）。产物由
/// app/core/subsonic/build.sh 构建（go build -buildmode=c-shared，含 Rust
/// 转码器 dlopen 依赖）。
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../native_lib_paths.dart';

typedef SubsonicCreateNative = IntPtr Function(Pointer<Utf8> configJson);
typedef SubsonicCreateDart = int Function(Pointer<Utf8> configJson);
typedef SubsonicPollEventNative =
    Int32 Function(IntPtr handle, Pointer<Uint8> buf, Int32 bufLen);
typedef SubsonicPollEventDart =
    int Function(int handle, Pointer<Uint8> buf, int bufLen);
typedef SubsonicDestroyNative = Void Function(IntPtr handle);
typedef SubsonicDestroyDart = void Function(int handle);
typedef SubsonicLyricResponseNative =
    Void Function(IntPtr handle, IntPtr requestId, Pointer<Utf8> resultJson);
typedef SubsonicLyricResponseDart =
    void Function(int handle, int requestId, Pointer<Utf8> resultJson);
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
  late final SubsonicLyricResponseDart lyricResponse = _lib
      .lookupFunction<SubsonicLyricResponseNative, SubsonicLyricResponseDart>(
        'archoera_subsonic_lyric_response',
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
      _instance ??= SubsonicBindings._(load());

  /// 定位并加载共享库（失败抛 StateError 附搜索过程）。
  static DynamicLibrary load() {
    final path = resolveSoPath();
    if (path == null) {
      throw StateError('未找到 libarchoera_subsonic（已按 ancestors 链与 dev 目录查找）');
    }
    return DynamicLibrary.open(path);
  }

  /// 查找共享库路径：统一走 [NativeLibPaths]（祖先链 + dev 兜底）。
  static String? resolveSoPath() {
    return NativeLibPaths.resolve(NativeModule.subsonic);
  }
}
