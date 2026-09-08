// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../native_lib_paths.dart';

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

  @Int32()
  external int engineMode; // 0=Stable(FFmpeg 默认) 1=EraAudio(自研内核,实验性)

  @Int32()
  external int noDiskCache; // 1 = 内存播放模式（不写 stream.wav/.pcm）

  @Int64()
  external int pcmMemCapKb; // 0=auto / >0=用户上限(KB) / -1=无上限
}

typedef _CreateNative =
    Pointer<Opaque> Function(
      Pointer<Utf8>,
      Pointer<EngineConfigC>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Int32,
    );
typedef _CreateDart =
    Pointer<Opaque> Function(
      Pointer<Utf8>,
      Pointer<EngineConfigC>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
    );
typedef _CommandNative = Int32 Function(Pointer<Opaque>, Pointer<Utf8>);
typedef _CommandDart = int Function(Pointer<Opaque>, Pointer<Utf8>);
typedef _PollEventNative =
    Int32 Function(Pointer<Opaque>, Pointer<Uint8>, Int32);
typedef _PollEventDart = int Function(Pointer<Opaque>, Pointer<Uint8>, int);
typedef _WaitEventNative =
    Int32 Function(Pointer<Opaque>, Pointer<Uint8>, Int32, Int32);
typedef _WaitEventDart = int Function(Pointer<Opaque>, Pointer<Uint8>, int, int);
typedef _IsDoneNative = Int32 Function(Pointer<Opaque>);
typedef _IsDoneDart = int Function(Pointer<Opaque>);
typedef _DestroyNative = Void Function(Pointer<Opaque>);
typedef _DestroyDart = void Function(Pointer<Opaque>);
typedef _ListSinksNative = Int32 Function(Pointer<Uint8>, Int32);
typedef _ListSinksDart = int Function(Pointer<Uint8>, int);

// 内存播放模式（no_disk_cache）频谱拉取：archoera_mediaengine_pcm_window
typedef _PcmWindowNative =
    Int32 Function(Pointer<Opaque>, Int32, Int32, Pointer<Float>, Pointer<Float>);
typedef _PcmWindowDart =
    int Function(Pointer<Opaque>, int, int, Pointer<Float>, Pointer<Float>);

// 会话重建计数：archoera_mediaengine_pcm_epoch
typedef _PcmEpochNative = Int32 Function(Pointer<Opaque>);
typedef _PcmEpochDart = int Function(Pointer<Opaque>);

// 可用内存（MB）：archoera_mediaengine_mem_available_mb（M3 预算管理器）
typedef _MemAvailNative = Int64 Function();
typedef _MemAvailDart = int Function();

// SegStore 内存源（M2，docs/audio-memory-source.md）：Dart 整曲/分段拉流 fill →
// 引擎 AVIO-mem 解码。segstore_new/fill/set_total/destroy 由 Dart 会话持有并
// 调用；archoera_mediaengine_create_store 把句柄交给引擎（引擎不释放，destroy
// 后由 Dart 侧 segstore_destroy）。
typedef _SegstoreNewNative =
    Pointer<Opaque> Function(Uint64, Uint64, Uint64);
typedef _SegstoreNewDart = Pointer<Opaque> Function(int, int, int);
typedef _SegstoreFillNative =
    Int32 Function(Pointer<Opaque>, Uint64, Pointer<Uint8>, Uint64);
typedef _SegstoreFillDart = int Function(Pointer<Opaque>, int, Pointer<Uint8>, int);
typedef _SegstoreSetTotalNative = Void Function(Pointer<Opaque>, Uint64);
typedef _SegstoreSetTotalDart = void Function(Pointer<Opaque>, int);
typedef _SegstoreDestroyNative = Void Function(Pointer<Opaque>);
typedef _SegstoreDestroyDart = void Function(Pointer<Opaque>);
typedef _CreateStoreNative =
    Pointer<Opaque> Function(
      Pointer<Opaque>,
      Pointer<EngineConfigC>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Int32,
    );
typedef _CreateStoreDart =
    Pointer<Opaque> Function(
      Pointer<Opaque>,
      Pointer<EngineConfigC>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
    );

/// C 侧 `SegStore*` 句柄（引擎地址；仅 Dart 会话持有，随引擎 destroy 后释放）。
typedef SegStoreHandle = int;

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
    return NativeLibPaths.resolveRequired(
      NativeModule.mediaEngine,
      hint: '请设置 ARCHOERA_AUDIO_ENGINE 环境变量',
    );
  }

  final DynamicLibrary _lib;

  late final _CreateDart _create = _lib
      .lookupFunction<_CreateNative, _CreateDart>(
        'archoera_mediaengine_create',
      );
  late final _CommandDart _command = _lib
      .lookupFunction<_CommandNative, _CommandDart>(
        'archoera_mediaengine_command',
      );
  late final _PollEventDart _pollEvent = _lib
      .lookupFunction<_PollEventNative, _PollEventDart>(
        'archoera_mediaengine_poll_event',
      );
  late final _WaitEventDart _waitEvent = _lib
      .lookupFunction<_WaitEventNative, _WaitEventDart>(
        'archoera_mediaengine_wait_event',
      );
  late final _IsDoneDart _isDone = _lib
      .lookupFunction<_IsDoneNative, _IsDoneDart>(
        'archoera_mediaengine_is_done',
      );
  late final _DestroyDart _destroy = _lib
      .lookupFunction<_DestroyNative, _DestroyDart>(
        'archoera_mediaengine_destroy',
      );
  late final _ListSinksDart _listSinks = _lib
      .lookupFunction<_ListSinksNative, _ListSinksDart>(
        'archoera_mediaengine_list_sinks',
      );
  late final _PcmWindowDart _pcmWindowFfi = _lib
      .lookupFunction<_PcmWindowNative, _PcmWindowDart>(
        'archoera_mediaengine_pcm_window',
      );
  late final _PcmEpochDart _pcmEpochFfi = _lib
      .lookupFunction<_PcmEpochNative, _PcmEpochDart>(
        'archoera_mediaengine_pcm_epoch',
      );
  late final _MemAvailDart _memAvailFfi = _lib
      .lookupFunction<_MemAvailNative, _MemAvailDart>(
        'archoera_mediaengine_mem_available_mb',
      );
  late final _SegstoreNewDart _segstoreNew = _lib
      .lookupFunction<_SegstoreNewNative, _SegstoreNewDart>('segstore_new');
  late final _SegstoreFillDart _segstoreFill = _lib
      .lookupFunction<_SegstoreFillNative, _SegstoreFillDart>('segstore_fill');
  late final _SegstoreSetTotalDart _segstoreSetTotal = _lib
      .lookupFunction<_SegstoreSetTotalNative, _SegstoreSetTotalDart>(
        'segstore_set_total',
      );
  late final _SegstoreDestroyDart _segstoreDestroy = _lib
      .lookupFunction<_SegstoreDestroyNative, _SegstoreDestroyDart>(
        'segstore_destroy',
      );
  late final _CreateStoreDart _createStore = _lib
      .lookupFunction<_CreateStoreNative, _CreateStoreDart>(
        'archoera_mediaengine_create_store',
      );

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
    final errMsg = h == nullptr
        ? errBuf.cast<Utf8>().toDartString().trim()
        : '';
    calloc.free(src);
    calloc.free(dir);
    calloc.free(pf);
    calloc.free(errBuf);
    if (h == nullptr) {
      throw StateError('引擎创建失败: $errMsg');
    }
    return h;
  }

  /// 从 SegStore 内存源创建引擎会话（store 会话，source 置空；语义 ≈ [create]，
  /// 引擎线程经 `pipeline_create_store` AVIO-mem 解码，docs/audio-memory-source.md）。
  ///
  /// [store] 为 C 侧 `SegStore*` 地址，由本库 [segstoreNew] 创建、Dart 会话持有。
  /// 引擎 destroy **不释放** store——调用方须在 [destroy] 之后 [segstoreDestroy]。
  /// [config] 同 [create]，本调用不负责释放。
  Pointer<Opaque> createStore({
    required SegStoreHandle store,
    required String sessionDir,
    String? playerFile,
    required Pointer<EngineConfigC> config,
  }) {
    final dir = sessionDir.toNativeUtf8();
    final pf = (playerFile ?? '').toNativeUtf8();
    final errBuf = calloc<Uint8>(128);
    final h = _createStore(
      Pointer<Opaque>.fromAddress(store),
      config,
      playerFile == null ? nullptr : pf,
      dir,
      errBuf.cast(),
      128,
    );
    final errMsg = h == nullptr
        ? errBuf.cast<Utf8>().toDartString().trim()
        : '';
    calloc.free(dir);
    calloc.free(pf);
    calloc.free(errBuf);
    if (h == nullptr) {
      throw StateError('引擎创建失败（store）: $errMsg');
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

  /// 阻塞等待一条事件（**接收 isolate 事件泵专用**；须在独立 isolate 线程
  /// 调用，避免阻塞主 isolate）。缓冲由调用方分配/释放。
  ///
  /// 返回 >0 事件字节数（已写入 [buf]，'\0' 结尾）；0 超时；-1 已销毁
  /// （调用方应退出事件泵，勿再对本句柄调用任何函数）。
  int waitEventInto(
    Pointer<Opaque> handle,
    Pointer<Uint8> buf,
    int cap,
    int timeoutMs,
  ) =>
      _waitEvent(handle, buf, cap, timeoutMs);

  /// 引擎线程是否已退出。
  bool isDone(Pointer<Opaque> handle) => _isDone(handle) != 0;

  void destroy(Pointer<Opaque> handle) => _destroy(handle);

  /// 枚举系统音频输出设备（**会话无关**：无需 handle，直接 FFI）。
  ///
  /// 返回 JSON 数组文本，例如
  /// `[{"id":"...","name":"...","rate":48000,"channels":2,"default":true,"class":"internal"}]`，
  /// 其中 `class`（a2dp|hfp|low|hdmi|usb|internal|unknown）为新版引擎可选
  /// 字段（旧版缺省，Dart 侧按 `unknown` 兼容解析）。空/失败返回 null。
  /// 调用方须捕获缺库 / 符号未导出等运行时异常（引擎侧符号与 Dart 契约
  /// 并行收敛，缺失时不可用而非崩溃）。
  String? listSinks({int cap = 16384}) {
    final buf = calloc<Uint8>(cap);
    try {
      final r = _listSinks(buf, cap);
      if (r <= 0) return null;
      return buf.cast<Utf8>().toDartString(length: r);
    } finally {
      calloc.free(buf);
    }
  }

  /// 内存播放模式频谱拉取：以 [endPosMs] 为终点取最近 [frames] 样本写
  /// [outL]/[outR]（各 frames 个 float）。返回 0 命中 / -1 越出保留窗或未解码 /
  /// -2 参数错或非内存模式会话。
  int pcmWindow(
    Pointer<Opaque> handle,
    int endPosMs,
    int frames,
    Pointer<Float> outL,
    Pointer<Float> outR,
  ) =>
      _pcmWindowFfi(handle, endPosMs, frames, outL, outR);

  /// 内存播放模式会话重建计数（seek 后 +1，Dart 丢旧帧索引）；非内存模式 -1。
  int pcmEpoch(Pointer<Opaque> handle) => _pcmEpochFfi(handle);

  /// M3：当前可用内存（MB）；<0 = 不可得（调用方回落保守下限）。
  int memAvailableMb() => _memAvailFfi();

  /// 新建 SegStore（docs/audio-memory-source.md §4）。返回句柄地址；引擎 destroy
  /// 后由 [segstoreDestroy] 释放。0 = 失败（OOM）。
  ///
  /// [totalHint] 已知总长（Content-Length），0 = 未知（随后 [segstoreSetTotal]）；
  /// [segSize] 定长段字节，0 = 默认 256 KiB；[budget] 预算，0 = 无上限。
  SegStoreHandle segstoreNew({
    int totalHint = 0,
    int segSize = 0,
    int budget = 0,
  }) {
    final p = _segstoreNew(totalHint, segSize, budget);
    return p.address;
  }

  /// 顺序填充（必须 offset == 当前 head）。返回 0 成功 / <0 错误（对齐 C 契约）。
  int segstoreFill(SegStoreHandle store, int offset, Pointer<Uint8> data, int length) =>
      _segstoreFill(Pointer<Opaque>.fromAddress(store), offset, data, length);

  /// 补充/修正已知总长（Content-Length 到达时调用；唤醒等待 EOF 的 pread）。
  void segstoreSetTotal(SegStoreHandle store, int total) =>
      _segstoreSetTotal(Pointer<Opaque>.fromAddress(store), total);

  /// 释放 SegStore（须在引擎 destroy 之后调用；可重复/传 0）。
  void segstoreDestroy(SegStoreHandle store) {
    if (store == 0) return;
    _segstoreDestroy(Pointer<Opaque>.fromAddress(store));
  }
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
  int engineMode = 0,
  int noDiskCache = 0,
  int pcmMemCapKb = 0,
}) {
  final p = calloc<EngineConfigC>();
  p.ref
    ..outputSampleRate = passthrough ? 0 : 48000
    ..outputChannels = 2
    ..bitrate = bitrate
    ..frameSizeMs = 20
    ..startOffsetMs = offsetMs
    ..skipEncoder =
        false // 播放模式由库内强制置 true
    ..limiterEnabled = true
    ..limiterThresholdDb = -1.0
    ..fftEnabled = false
    ..fftSize = 1024
    ..tempoEnabled = tempoSpeed != null || tempoPitch != null
    ..tempoSpeed = tempoSpeed ?? 1.0
    ..tempoPitch = tempoPitch ?? 0.0
    ..tempoPitchSync = true
    ..engineMode = engineMode
    ..noDiskCache = noDiskCache
    ..pcmMemCapKb = pcmMemCapKb;
  for (var i = 0; i < 10; i++) {
    p.ref.eqGains[i] = (eqGains != null && i < eqGains.length) ? eqGains[i] : 0;
  }
  p.ref.eqPreampDb = preamp;
  p.ref.normalization = normalization;
  return p;
}
