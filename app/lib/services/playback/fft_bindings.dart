import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'engine_paths.dart';
import 'fft_frame.dart';

typedef _FftCreateNative = Pointer<Opaque> Function(Int32, Int32);
typedef _FftCreateDart = Pointer<Opaque> Function(int, int);
typedef _FftSetEnabledNative = Void Function(Pointer<Opaque>, Int32);
typedef _FftSetEnabledDart = void Function(Pointer<Opaque>, int);
typedef _FftProcessFrameNative =
    Void Function(Pointer<Opaque>, Pointer<Float>, Pointer<Float>, Int32);
typedef _FftProcessFrameDart =
    void Function(Pointer<Opaque>, Pointer<Float>, Pointer<Float>, int);
typedef _FftNormStereoNative = Void Function(
    Pointer<Opaque>, Pointer<Float>, Pointer<Float>, Int32);
typedef _FftNormStereoDart = void Function(
    Pointer<Opaque>, Pointer<Float>, Pointer<Float>, int);
typedef _FftTakeBeatStrengthNative = Float Function(Pointer<Opaque>);
typedef _FftTakeBeatStrengthDart = double Function(Pointer<Opaque>);
typedef _FftDestroyNative = Void Function(Pointer<Opaque>);
typedef _FftDestroyDart = void Function(Pointer<Opaque>);

/// FFT 分析器（FFI 封装 audio-engine 的 fft.c → libfft.so）。
///
/// 前端渲染契约与 C 引擎一致：`fft_get_spectrum_norm_stereo` 输出 128 bins，
/// 对数映射 80~2000Hz，归一化 [0,1]（§10.1）。桌面端 Flutter 直连引擎读
/// 原始 PCM 后在此完成频谱分析（FFT 客户端化，不再经侧车 fd4 通道）。
///
/// 拉模式（§10.1）：PcmAnalyzer 按播放位置从本地 PCM 索引取「以当前位置为
/// 终点的最近 fftSize 样本」后调 [processFrame] 直算一帧——语义对齐 Electron
/// Rust 端 analyze()（环形缓冲取最新样本），不依赖 C 侧流式累积器
/// （fft_process_multi 供实时播放线程持续喂样本用）。
class FftAnalyzer {
  FftAnalyzer({
    this.sampleRate = 48000,
    this.fftSize = 2048,
    this.bins = 128,
  }) {
    final lib = DynamicLibrary.open(EnginePaths.libfftPath());
    _create = lib.lookupFunction<_FftCreateNative, _FftCreateDart>('fft_create');
    _setEnabled =
        lib.lookupFunction<_FftSetEnabledNative, _FftSetEnabledDart>('fft_set_enabled');
    _processFrame =
        lib.lookupFunction<_FftProcessFrameNative, _FftProcessFrameDart>('fft_process_frame');
    _norm = lib.lookupFunction<_FftNormStereoNative, _FftNormStereoDart>(
        'fft_get_spectrum_norm_stereo');
    _takeBeatStrength = lib.lookupFunction<_FftTakeBeatStrengthNative,
        _FftTakeBeatStrengthDart>('fft_take_beat_strength');
    _destroy = lib.lookupFunction<_FftDestroyNative, _FftDestroyDart>('fft_destroy');

    _handle = _create(sampleRate, fftSize);
    if (_handle == nullptr) {
      throw StateError('fft_create 失败 (sampleRate=$sampleRate, fftSize=$fftSize)');
    }
    // fft_create 默认 disabled，必须显式启用
    _setEnabled(_handle, 1);
    _inL = calloc<Float>(fftSize);
    _inR = calloc<Float>(fftSize);
    _outL = calloc<Float>(bins);
    _outR = calloc<Float>(bins);
  }

  final int sampleRate;
  final int fftSize;
  final int bins;

  late final _FftCreateDart _create;
  late final _FftSetEnabledDart _setEnabled;
  late final _FftProcessFrameDart _processFrame;
  late final _FftNormStereoDart _norm;
  late final _FftTakeBeatStrengthDart _takeBeatStrength;
  late final _FftDestroyDart _destroy;

  late final Pointer<Opaque> _handle;
  late final Pointer<Float> _inL;
  late final Pointer<Float> _inR;
  late final Pointer<Float> _outL;
  late final Pointer<Float> _outR;
  bool _disposed = false;

  /// 复用的归一化输出缓冲（避免每帧新建 List，减少 GC；消费方须同步拷贝，
  /// 见 SpectrumView.pushFrame）。
  final Float64List _outLd = Float64List(128);
  final Float64List _outRd = Float64List(128);

  /// 直接计算一帧频谱（拉模式）：[left]/[right] 为已按源声道布局下混的
  /// 每声道样本（窗口终点 = 当前音频位置），[samples] 为窗口内样本数
  /// （≤ fftSize；不足 fftSize 时 C 侧尾部补零）。
  ///
  /// 输入样本须在本次调用期间保持有效（同步拷入 C 缓冲），随后输出复用
  /// [FftFrame.ldata]/[FftFrame.rdata] 缓冲，返回后下一帧调用会覆盖。
  FftFrame processFrame(Float64List left, Float64List right, int samples) {
    assert(!_disposed, 'FftAnalyzer 已销毁');
    _outLd.fillRange(0, bins, 0);
    _outRd.fillRange(0, bins, 0);
    if (samples <= 0) {
      // 无有效数据：输出静音帧
      return FftFrame(ldata: _outLd, rdata: _outRd);
    }
    if (samples > fftSize) samples = fftSize;
    final lv = _inL.asTypedList(samples);
    final rv = _inR.asTypedList(samples);
    for (var i = 0; i < samples; i++) {
      lv[i] = left[i]; // Float32List 赋值时自动截断为 float
      rv[i] = right[i];
    }
    _processFrame(_handle, _inL, _inR, samples);
    // 脉冲检测结果与频谱同帧取走（C 侧 detect_beat，低/中/高频能量突增
    // 的加权综合强度 0~1，封面脉冲按强度区分大小）
    final beatStrength = _takeBeatStrength(_handle);
    _norm(_handle, _outL, _outR, bins);
    final outL = _outL.asTypedList(bins);
    final outR = _outR.asTypedList(bins);
    for (var i = 0; i < bins; i++) {
      _outLd[i] = outL[i];
      _outRd[i] = outR[i];
    }
    return FftFrame(ldata: _outLd, rdata: _outRd, beatStrength: beatStrength);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _destroy(_handle);
    calloc.free(_inL);
    calloc.free(_inR);
    calloc.free(_outL);
    calloc.free(_outR);
  }
}
