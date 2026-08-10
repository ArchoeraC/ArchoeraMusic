import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'engine_paths.dart';

/// C 侧 `EngineConfig` 结构体映射（对齐 audio_engine.h，标准 ABI 布局）。
final class EngineConfigC extends Struct {
  @Int32()
  external int outputSampleRate;

  @Int32()
  external int outputChannels;

  @Int32()
  external int bitrate;

  @Int32()
  external int frameSizeMs;

  @Int64()
  external int startOffsetMs;

  @Bool()
  external bool skipEncoder;

  @Array(10)
  external Array<Float> eqGains;

  @Float()
  external double eqPreampDb;

  @Bool()
  external bool normalization;

  @Float()
  external double normalizationGain;

  @Bool()
  external bool limiterEnabled;

  @Float()
  external double limiterThresholdDb;

  @Bool()
  external bool fftEnabled;

  @Int32()
  external int fftSize;

  @Bool()
  external bool tempoEnabled;

  @Float()
  external double tempoSpeed;

  @Float()
  external double tempoPitch;

  @Bool()
  external bool tempoPitchSync;
}

typedef _CreateNative = Pointer<Opaque> Function(
    Pointer<Utf8>, Pointer<EngineConfigC>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Int32);
typedef _CreateDart = Pointer<Opaque> Function(
    Pointer<Utf8>, Pointer<EngineConfigC>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, int);
typedef _CommandNative = Int32 Function(Pointer<Opaque>, Pointer<Utf8>);
typedef _CommandDart = int Function(Pointer<Opaque>, Pointer<Utf8>);
typedef _PollEventNative = Int32 Function(Pointer<Opaque>, Pointer<Uint8>, Int32);
typedef _PollEventDart = int Function(Pointer<Opaque>, Pointer<Uint8>, int);
typedef _IsDoneNative = Int32 Function(Pointer<Opaque>);
typedef _IsDoneDart = int Function(Pointer<Opaque>);
typedef _DestroyNative = Void Function(Pointer<Opaque>);
typedef _DestroyDart = void Function(Pointer<Opaque>);

/// 引擎 FFI 绑定（libarchoera_mediaengine.so）。
///
/// 全部调用为短调用（引擎在库内自有线程转码/播放），不阻塞 Dart isolate。
/// 句柄 [handle] 为 C 侧 `ArchoeraMediaEngine*`。
class EngineBindings {
  EngineBindings._(this._lib);

  /// 加载动态库并绑定全部函数（懒加载）。
  static EngineBindings? _instance;
  static EngineBindings get instance =>
      _instance ??= EngineBindings._(DynamicLibrary.open(_libPath()));

  static String _libPath() {
    final name = Platform.isWindows
        ? 'archoera_mediaengine.dll'
        : (Platform.isMacOS
            ? 'libarchoera_mediaengine.dylib'
            : 'libarchoera_mediaengine.so');
    return '${EnginePaths.resolveEngineDir()}/build/$name';
  }

  final DynamicLibrary _lib;

  late final _CreateDart _create = _lib
      .lookupFunction<_CreateNative, _CreateDart>('archoera_mediaengine_create');
  late final _CommandDart _command = _lib
      .lookupFunction<_CommandNative, _CommandDart>('archoera_mediaengine_command');
  late final _PollEventDart _pollEvent = _lib
      .lookupFunction<_PollEventNative, _PollEventDart>(
          'archoera_mediaengine_poll_event');
  late final _IsDoneDart _isDone = _lib
      .lookupFunction<_IsDoneNative, _IsDoneDart>('archoera_mediaengine_is_done');
  late final _DestroyDart _destroy = _lib
      .lookupFunction<_DestroyNative, _DestroyDart>(
          'archoera_mediaengine_destroy');

  /// 创建引擎会话（失败抛 [StateError]，错误信息取引擎 errbuf）。
  ///
  /// [config] 为 [EngineConfigC.fromParams] 分配的指针，本调用不负责释放，
  /// 由调用方在返回后 `calloc.free(config)`。
  Pointer<Opaque> create({
    required String source,
    required String sessionDir,
    String? playerFile,
    required Pointer<EngineConfigC> config,
  }) {
    final src = source.toNativeUtf8();
    final dir = sessionDir.toNativeUtf8();
    final pf = (playerFile ?? '').toNativeUtf8();
    final errBuf = calloc<Uint8>(128);
    final h = _create(
      src,
      config,
      playerFile == null ? nullptr : pf,
      dir,
      errBuf.cast(),
      128,
    );
    final errMsg = h == nullptr ? errBuf.cast<Utf8>().toDartString().trim() : '';
    calloc.free(src);
    calloc.free(dir);
    calloc.free(pf);
    calloc.free(errBuf);
    if (h == nullptr) {
      throw StateError('引擎创建失败: $errMsg');
    }
    return h;
  }

  /// 发送控制命令（JSON 行）。
  int command(Pointer<Opaque> handle, String jsonLine) {
    final s = jsonLine.toNativeUtf8();
    final r = _command(handle, s);
    calloc.free(s);
    return r;
  }

  /// 取一条事件；返回事件文本或 null（队列空）。
  String? pollEvent(Pointer<Opaque> handle) {
    final buf = calloc<Uint8>(2048);
    final r = _pollEvent(handle, buf, 2048);
    if (r == 0) {
      calloc.free(buf);
      return null;
    }
    final s = buf.cast<Utf8>().toDartString();
    calloc.free(buf);
    return s;
  }

  /// 引擎线程是否已退出。
  bool isDone(Pointer<Opaque> handle) => _isDone(handle) != 0;

  void destroy(Pointer<Opaque> handle) => _destroy(handle);
}

/// 从 Dart 播放参数分配并填充 EngineConfig（对齐 audio_engine.h）。
///
/// Struct 必须经 calloc 分配（不可用生成构造函数）；返回原生内存指针，
/// 调用方须 `calloc.free(result)` 释放。
Pointer<EngineConfigC> engineConfigFromParams({
  int bitrate = 128000,
  bool passthrough = true,
  int offsetMs = 0,
  List<double>? eqGains,
  double preamp = 0,
  bool normalization = false,
  double? tempoSpeed,
  double? tempoPitch,
}) {
  final p = calloc<EngineConfigC>();
  p.ref
    ..outputSampleRate = passthrough ? 0 : 48000
    ..outputChannels = 2
    ..bitrate = bitrate
    ..frameSizeMs = 20
    ..startOffsetMs = offsetMs
    ..skipEncoder = false // 播放模式由库内强制置 true
    ..limiterEnabled = true
    ..limiterThresholdDb = -1.0
    ..fftEnabled = false
    ..fftSize = 1024
    ..tempoEnabled = tempoSpeed != null || tempoPitch != null
    ..tempoSpeed = tempoSpeed ?? 1.0
    ..tempoPitch = tempoPitch ?? 0.0
    ..tempoPitchSync = true;
  for (var i = 0; i < 10; i++) {
    p.ref.eqGains[i] = (eqGains != null && i < eqGains.length) ? eqGains[i] : 0;
  }
  p.ref.eqPreampDb = preamp;
  p.ref.normalization = normalization;
  return p;
}
