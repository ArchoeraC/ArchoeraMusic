// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放器「流体」背景（对齐上游 AMLL `MeshGradientRenderer`）。
///
/// 上游为 WebGL：每首歌随机一个双三次 Hermite 控制点网格（subdiv=50），顶点阶段
/// 形变封面后再经片元绕 (0.2,0.2) 旋转（时间+音量）、按 `1-音量` 缩放、dither、
/// 晕影，最后按切歌 alpha 0→1.1 交叉淡入。
///
/// Flutter 端：
/// - 每首歌把 Hermite 网格**一次性前向栅格化**为位移贴图（[buildFluidWarpMesh]
///   + [bakeFluidWarpImage]），片元只做查表/旋转/缩放（`shaders/fluid.frag`）；
/// - 封面压到 32×32 并做完色调/盒式模糊（[processFluidCover]）后作为纹理；
/// - 每个「曲目状态」持有一对（位移图, 封面）与 alpha，交叉淡入时按序叠加绘制，
///   与上游多 `meshStates` 依次合成的结果一致；
/// - 支持流速、渲染比例、帧率上限、暂停冻结、低频节拍脉动（`playerBgBeat`）。
///
/// 着色器不可用 / 环境变量关闭 / 测试环境时回退「预烘焙封面直铺」，不崩不空。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/playback/playback_notifier.dart';
import '../../list/cover_image.dart';
import 'fluid_cover.dart';
import 'fluid_mesh.dart';
import 'fluid_shader.dart';

/// 流体背景最终只用 `kFluidCoverSize`（32×32）纹理；解码到 64 做一次廉价
/// 超采样即可，**绝不能**整幅解码（`processFluidCover` 会把整幅 RGBA 读出来）。
const int kFluidCoverDecodePx = 64;

/// 低频脉冲的 attack / decay 平滑系数（对齐上游 `BASS_ATTACK` / `BASS_DECAY`）。
const double kFluidBassAttack = 0.45;
const double kFluidBassDecay = 0.14;

/// 低频音量映射常量（对齐上游 `toAmllLowFreqVolume`：`1 + pulse * 2.4`）。
const double kFluidVolumeBase = 1;
const double kFluidVolumeRange = 2.4;

/// 低频脉冲频段与权重（对齐上游 `audioFeatures.ts` 的 `getBassPulse`）。
const double _kBassMinFreq = 80;
const double _kBassMaxFreq = 180;
const double _kBassThreshold = 0.16;
const double _kBassGain = 2.2;
const double _kBassCurve = 1.05;
const double _kBassPeakMix = 0.45;
const double _kBassHighBinWeight = 0.65;
const double _kFftMinFreq = 80;
const double _kFftMaxFreq = 2000;
const int _kFftBins = 128;

double _clamp01(double v) => v.clamp(0.0, 1.0).toDouble();

/// 上游 `getBassPulse`：从 128 段对数频谱（双声道）提取 80~180Hz 脉冲强度 0~1。
double fluidBassPulse(List<double> left, List<double> right) {
  if (left.isEmpty || right.isEmpty) return 0;
  final start = _bassBinStart;
  final end = _bassBinEnd;
  if (start >= end) return 0;

  var sum = 0.0;
  var peak = 0.0;
  var weightSum = 0.0;
  final count = end - start;
  for (var i = start; i < end; i++) {
    final position = count <= 1 ? 0.0 : (i - start) / (count - 1);
    final weight = 1 - position * (1 - _kBassHighBinWeight);
    final value = ((i < left.length ? left[i] : 0.0) +
            (i < right.length ? right[i] : 0.0)) /
        2;
    sum += value * value * weight;
    peak = math.max(peak, value);
    weightSum += weight;
  }
  final rms = math.sqrt(sum / math.max(1, weightSum));
  final energy = rms * (1 - _kBassPeakMix) + peak * _kBassPeakMix;
  final normalized = math.max(0, (energy - _kBassThreshold) / (1 - _kBassThreshold));
  return _clamp01(math.pow(normalized, _kBassCurve).toDouble() * _kBassGain);
}

double _binEdge(int index) {
  final logMin = math.log(_kFftMinFreq);
  final logMax = math.log(_kFftMaxFreq);
  return math.exp(logMin + (logMax - logMin) * index / _kFftBins);
}

final int _bassBinStart = () {
  for (var i = 0; i < _kFftBins; i++) {
    final lo = _binEdge(i);
    final hi = _binEdge(i + 1);
    if (hi > _kBassMinFreq && lo < _kBassMaxFreq) return i;
  }
  return 0;
}();

final int _bassBinEnd = () {
  var end = 0;
  for (var i = 0; i < _kFftBins; i++) {
    final lo = _binEdge(i);
    final hi = _binEdge(i + 1);
    if (hi > _kBassMinFreq && lo < _kBassMaxFreq) end = i + 1;
  }
  return end;
}();

double _easeInOutSine(double x) => -(math.cos(math.pi * x) - 1) / 2;

/// 单个曲目状态的（位移图 + 预烘焙封面 + 淡入 alpha）。
class _FluidState {
  _FluidState({required this.warp, required this.cover});

  final ui.Image warp;
  final ui.Image cover;
  double alpha = 0;
}

/// 全屏播放器流体背景。
class FluidBackground extends ConsumerStatefulWidget {
  const FluidBackground({
    super.key,
    this.cover,
    this.playing = true,
    this.animate = true,
    this.flowSpeed = 4,
    this.renderScale = 0.5,
    this.fps = 30,
    this.freezeOnPause = false,
    this.beat = false,
  });

  /// 封面地址（http(s)/file:///本地路径）；为空时只铺底色。
  final String? cover;

  /// 是否播放中（配合 [freezeOnPause] 决定是否冻结流动）。
  final bool playing;

  /// 是否运行动画（性能模式下置 false，停表呈现静态帧）。
  final bool animate;

  /// 流动速度（对齐上游 `playerBgFlowSpeed`，默认 4）。
  final double flowSpeed;

  /// 渲染比例（对齐上游 `playerBgRenderScale`，默认 0.5）。
  final double renderScale;

  /// 帧率上限（对齐上游 `playerBgFps`，默认 30）。
  final int fps;

  /// 暂停时冻结流动（对齐上游 `playerBgFreezeOnPause`，默认 false）。
  final bool freezeOnPause;

  /// 低频节拍脉动（对齐上游 `playerBgBeat`，默认 false）。
  final bool beat;

  @override
  ConsumerState<FluidBackground> createState() => _FluidBackgroundState();
}

class _FluidBackgroundState extends ConsumerState<FluidBackground>
    with SingleTickerProviderStateMixin {
  final _Repaint _repaint = _Repaint();
  late final Ticker _ticker;

  ui.FragmentShader? _shader;
  final List<_FluidState> _states = [];
  ui.Image? _staticCover;

  int _version = 0;
  int _lastTickUs = 0;
  int _lastFrameUs = 0;
  double _frameTimeMs = 0;
  double _volume = 0.1;
  double _smoothedPulse = 0;
  FftFrame? _lastFft;

  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _smallImage;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _resolveCover();
    if (widget.animate) _ensureTicker();
    if (kEnableFluidShader) _loadShader();
  }

  @override
  void didUpdateWidget(FluidBackground old) {
    super.didUpdateWidget(old);
    if (old.cover != widget.cover) _resolveCover();
    if (old.animate != widget.animate) {
      if (widget.animate) {
        _ensureTicker();
      } else if (_ticker.isActive) {
        _ticker.stop();
        _settleStatic();
      }
    }
    if (old.beat && !widget.beat) {
      _smoothedPulse = 0;
      _lastFft = null;
      _volume = 0.1;
    }
    _repaint.notify();
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener!);
    _ticker.dispose();
    _repaint.dispose();
    _shader?.dispose();
    for (final s in _states) {
      s.warp.dispose();
      s.cover.dispose();
    }
    _staticCover?.dispose();
    _smallImage?.dispose();
    super.dispose();
  }

  void _ensureTicker() {
    if (!widget.animate || _ticker.isActive) return;
    _lastTickUs = 0;
    _lastFrameUs = 0;
    _ticker.start();
  }

  /// 静态模式：立即完成所有淡入并丢弃旧状态（性能模式停表时用）。
  void _settleStatic() {
    if (_states.isEmpty) return;
    for (var i = 0; i < _states.length - 1; i++) {
      _states[i].warp.dispose();
      _states[i].cover.dispose();
    }
    _states.removeRange(0, _states.length - 1);
    _states.last.alpha = 1.1;
    _repaint.notify();
  }

  Future<void> _loadShader() async {
    final program = await FluidShaderLoader.load();
    if (!mounted || program == null) return;
    setState(() => _shader = program.fragmentShader());
  }

  // ── 封面解析与预烘焙 ─────────────────────────────────────────────────

  ImageProvider? _providerFor(String? cover) {
    // 只解码到 64px：最终纹理是 32×32，整幅解码纯属浪费（且 processFluidCover
    // 会 toByteData 读整幅 RGBA，尺寸越大会成倍放大瞬时内存）。
    return coverImageProvider(cover, decodeWidth: kFluidCoverDecodePx);
  }

  void _resolveCover() {
    final version = ++_version; // 使仍在处理中的旧封面失效
    _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
    final provider = _providerFor(widget.cover);
    if (provider == null) return;
    final listener = ImageStreamListener(
      (info, _) => unawaited(_handleCoverImage(info.image, version)),
      onError: (_, _) {},
    );
    _listener = listener;
    _stream = provider.resolve(ImageConfiguration.empty)..addListener(listener);
  }

  Future<void> _handleCoverImage(ui.Image img, int version) async {
    // flutter test 的 fake-async / 软件光栅化无法保证 toByteData / drawVertices，
    // 统一跳过，测试只验证构建不崩。
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    ByteData? bytes;
    try {
      bytes = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    } catch (_) {
      bytes = null;
    }
    if (bytes == null || !mounted || version != _version) return;
    final processed = processFluidCover(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      img.width,
      img.height,
    );
    final cover = await decodeFluidCover(processed);
    if (!mounted || version != _version) {
      cover.dispose();
      return;
    }

    ui.Image? warp;
    if (kEnableFluidShader) {
      warp = bakeFluidWarpImage(buildFluidWarpMesh(pickFluidControlPoints()));
    }
    if (!mounted || version != _version) {
      cover.dispose();
      warp?.dispose();
      return;
    }

    setState(() {
      if (warp != null) {
        final state = _FluidState(warp: warp, cover: cover);
        if (!widget.animate) {
          state.alpha = 1.1;
          for (final old in _states) {
            old.warp.dispose();
            old.cover.dispose();
          }
          _states.clear();
        }
        _states.add(state);
        _staticCover?.dispose();
        _staticCover = null;
      } else if (_states.isEmpty) {
        // 着色器/位移图不可用：退化为预烘焙封面直铺。
        _staticCover?.dispose();
        _staticCover = cover;
      } else {
        cover.dispose();
      }
    });
  }

  // ── 帧循环 ───────────────────────────────────────────────────────────

  void _tick(Duration elapsed) {
    final us = elapsed.inMicroseconds;
    if (_lastTickUs == 0) {
      _lastTickUs = us;
      _lastFrameUs = us;
      return;
    }
    final intervalUs = (1000000 / widget.fps).round();
    final delta = us - _lastTickUs;
    if (delta < intervalUs) return;
    final frameDeltaMs = (us - _lastFrameUs) / 1000.0;
    if (frameDeltaMs <= 0) return;
    _lastFrameUs = us;
    _lastTickUs = us - (delta % intervalUs);

    var changed = false;
    final flowing = widget.playing || !widget.freezeOnPause;
    if (flowing && widget.flowSpeed > 0) {
      _frameTimeMs += frameDeltaMs * widget.flowSpeed;
      changed = true;
    }
    if (_updateVolume()) changed = true;
    if (_advanceAlphas(frameDeltaMs)) changed = true;
    if (changed) _repaint.notify();
  }

  /// 更新低频音量（返回是否变化）。未开节拍恒为 0.1（对齐上游）。
  bool _updateVolume() {
    if (!widget.beat) {
      if (_volume == 0.1) return false;
      _volume = 0.1;
      return true;
    }
    // 暂停时保留上次音量（对齐上游停止采集但不重置）。
    if (!widget.playing) return false;
    final fft = ref.read(playbackProvider).fft;
    if (fft == null || identical(fft, _lastFft)) return false;
    _lastFft = fft;
    final pulse = fluidBassPulse(fft.ldata, fft.rdata);
    final factor = pulse > _smoothedPulse ? kFluidBassAttack : kFluidBassDecay;
    _smoothedPulse += factor * (pulse - _smoothedPulse);
    final next = (kFluidVolumeBase + _clamp01(_smoothedPulse) * kFluidVolumeRange) /
        10;
    if ((next - _volume).abs() < 1e-6) return false;
    _volume = next;
    return true;
  }

  /// 推进淡入 alpha（返回是否变化）。
  bool _advanceAlphas(double frameDeltaMs) {
    if (_states.isEmpty) return false;
    var changed = false;
    final newest = _states.last;
    if (newest.alpha < 1.1) {
      newest.alpha = math.min(1.1, newest.alpha + frameDeltaMs / 500.0);
      changed = true;
    }
    if (newest.alpha >= 1.1 && _states.length > 1) {
      for (var i = 0; i < _states.length - 1; i++) {
        _states[i].warp.dispose();
        _states[i].cover.dispose();
      }
      _states.removeRange(0, _states.length - 1);
      changed = true;
    }
    return changed;
  }

  double get _renderScale => widget.renderScale.clamp(0.25, 2.0).toDouble();

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _FluidPainter(this, _repaint, _shader),
        size: Size.infinite,
      ),
    );
  }
}

class _Repaint extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _FluidPainter extends CustomPainter {
  _FluidPainter(this.s, Listenable repaint, this.shader)
    : super(repaint: repaint);

  final _FluidBackgroundState s;
  final ui.FragmentShader? shader;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final scale = s._renderScale;
    // 默认（scale≈1）：直绘。scale≠1 时先画进低/高分辨率离屏再缩放贴回。
    if (scale < 0.999 || scale > 1.001) {
      // flutter test 的 fake-async 无法光栅化 toImageSync（会得空白图）→ 直绘。
      if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        ui.Image? small;
        try {
          small = _renderSmall(w, h, scale);
        } catch (_) {
          small = null;
        }
        if (small != null) {
          final prev = s._smallImage;
          s._smallImage = small;
          canvas.drawImageRect(
            small,
            Rect.fromLTWH(
              0,
              0,
              small.width.toDouble(),
              small.height.toDouble(),
            ),
            Offset.zero & size,
            Paint()..filterQuality = FilterQuality.low,
          );
          if (prev != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => prev.dispose());
          }
          return;
        }
      }
    }
    _paintContent(canvas, size);
  }

  ui.Image? _renderSmall(double w, double h, double scale) {
    final smallW = math.max(1, (w * scale).round());
    final smallH = math.max(1, (h * scale).round());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    _paintContent(canvas, Size(smallW.toDouble(), smallH.toDouble()));
    final pic = recorder.endRecording();
    try {
      return pic.toImageSync(smallW, smallH);
    } finally {
      pic.dispose();
    }
  }

  void _paintContent(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    // 着色器不可用 / 尚无可绘制状态：退化为最新预烘焙封面直铺。
    final shader = this.shader;
    if (shader == null || s._states.isEmpty) {
      _paintFallback(canvas, size);
      return;
    }
    final angle = (s._frameTimeMs / 10000 + s._volume) * 2;
    final sinAngle = math.sin(angle);
    final cosAngle = math.cos(angle);
    for (final state in s._states) {
      shader.setFloat(FluidUniforms.size, w);
      shader.setFloat(FluidUniforms.size + 1, h);
      shader.setFloat(FluidUniforms.aspect, w / h);
      shader.setFloat(FluidUniforms.volume, s._volume);
      shader.setFloat(FluidUniforms.sinAngle, sinAngle);
      shader.setFloat(FluidUniforms.cosAngle, cosAngle);
      shader.setFloat(
        FluidUniforms.alpha,
        _easeInOutSine(_clamp01(state.alpha)),
      );
      shader.setImageSampler(FluidUniforms.samplerWarp, state.warp);
      shader.setImageSampler(FluidUniforms.samplerCover, state.cover);
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    }
  }

  void _paintFallback(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    for (final state in s._states) {
      final a = _easeInOutSine(_clamp01(state.alpha));
      if (a <= 0.001) continue;
      _drawCover(canvas, rect, state.cover, a);
    }
    final staticCover = s._staticCover;
    if (s._states.isEmpty && staticCover != null) {
      _drawCover(canvas, rect, staticCover, 1);
    }
  }

  void _drawCover(Canvas canvas, Rect rect, ui.Image img, double alpha) {
    final paint = Paint()..filterQuality = FilterQuality.low;
    if (alpha >= 0.999) {
      _drawImageRect(canvas, rect, img, paint);
    } else {
      canvas.saveLayer(rect, Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
      _drawImageRect(canvas, rect, img, paint);
      canvas.restore();
    }
  }

  void _drawImageRect(Canvas canvas, Rect rect, ui.Image img, Paint paint) {
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      rect,
      paint,
    );
  }

  @override
  bool shouldRepaint(_FluidPainter oldDelegate) => false;
}
