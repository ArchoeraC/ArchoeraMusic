// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放器「水纹」背景（自绘引擎 + GPU 着色器）。
///
/// 上游为 WebGPU/WebGL 片元着色器：对封面做多涟漪折射位移 + 波峰高光/波谷压暗。
/// Flutter 端两条路径（渲染器优先，见 docs/player-render-optimization.md）：
/// - **GPU（主路径，P2）**：`shaders/ripple.frag` 单 pass 完成折射 + 饱和 + 高光/
///   压暗 + 压暗；封面模糊/饱和在 Dart 侧**预烘焙一次**（不再每帧全屏模糊）。
///   涟漪参数以 uniform 传入，CPU 侧只更新 uniforms。
/// - **CPU（仅着色器不可用时兜底）**：网格顶点折射 + `ImageShader`（见 [_RipplePainter]）。
///
/// 切歌时旧封面与新封面按 700ms 交叉淡入（GPU 路径在着色器内 `mix` 两纹理）。
///
/// 拆为静态层（[RippleStaticLayer]：预烘焙封面纹理及生命周期）与动态层
/// （`ripple_dynamic_layer.dart`：涟漪模拟/绘制），本文件负责解析封面、
/// 驱动涟漪与组合两层。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import 'ripple_shader.dart';
import 'ripple_static_layer.dart';

part 'ripple_dynamic_layer.dart';

/// 同时存活的涟漪上限（对齐上游 MAX_RIPPLES）。
const int _kMaxRipples = 48;

/// 单个涟漪存活时长（秒，对齐上游 RIPPLE_LIFETIME）。
const double _kRippleLifetime = 6.0;

/// 涟漪生成的平均间隔（秒，对齐上游 MEAN_INTERVAL）。
const double _kMeanInterval = 0.18;

/// 切歌交叉淡入时长（毫秒，对齐上游 TRANSITION_MS）。
const double _kTransitionMs = 700;

/// 全屏播放器水纹背景。 [cover] 为封面地址（http(s)/file:///本地路径）。
class RippleBackground extends StatefulWidget {
  const RippleBackground({
    super.key,
    this.cover,
    this.playing = true,
    this.speed = 3,
    this.animate = true,
    this.blurSigma = 14,
    this.saturation = 1.3,
    this.darken = 0.5,
    this.renderScale = 1.0,
    this.fallbackColor = const Color(0xFF141420),
  });

  /// 封面地址；为空时只渲染 [fallbackColor]。
  final String? cover;

  /// 是否播放中（暂停时涟漪降为慢速漂移，对齐上游）。
  final bool playing;

  /// 涟漪速度（对齐上游 playerBgRippleSpeed，默认 3）。
  final double speed;

  /// 是否运行动画（性能模式下置 false，停表呈现静态帧）。
  final bool animate;

  /// 整体模糊半径（px，对齐上游 blur(10px)）。
  final double blurSigma;

  /// 饱和度（对齐上游 saturate(1.3)）。
  final double saturation;

  /// 压暗叠加强度（0~1，对齐上游 rgba(0,0,0,0.5)）。
  final double darken;

  /// CPU 动态层离屏渲染尺度（opt-in，R1 实验开关，见
  /// docs/runtime-resource-optimization.md §4.1）。
  ///
  /// 默认 `1.0`（与旧行为逐字节一致，不产生额外分配）；当 `< 0.999` 时，CPU
  /// 网格路径先在 `Size(w*scale, h*scale)` 的离屏 `Picture` 中计算并同步光栅化，
  /// 再 `drawImageRect` 放大贴回全屏，以降低填充率与网格成本。取值在使用时夹到
  /// `[0.25, 1.0]`。GPU 着色器路径暂不感知该参数（见 `_RippleShaderPainter`）。
  final double renderScale;

  /// 无封面时的底色。
  final Color fallbackColor;

  @override
  State<RippleBackground> createState() => _RippleBackgroundState();
}

class _RippleBackgroundState extends State<RippleBackground>
    with SingleTickerProviderStateMixin {
  final _Repaint _repaint = _Repaint();
  late final Ticker _ticker;

  final List<_Ripple> _ripples = [];
  double _nextSpawn = 0;
  int _rand = 0x51f15e;
  double _simTime = 0;
  int _lastUs = 0;

  ui.Image? _current;
  ui.Image? _old;
  double _mix = 1;
  bool _transitioning = false;
  double _transitionProgress = 0;

  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// GPU 路径：着色器实例（着色器加载成功后非空）。
  ui.FragmentShader? _shader;

  /// 静态层：预烘焙（模糊+饱和）封面纹理及生命周期。
  late final RippleStaticLayer _static;

  /// 低分辨率动态层缓存图（仅 [RippleBackground.renderScale] < 1 时使用）。
  /// 每帧换新、旧图延后一帧释放（复用 [RippleStaticLayer.disposeLater]）。
  ui.Image? _smallImage;

  @override
  void initState() {
    super.initState();
    _static = RippleStaticLayer(
      isMounted: () => mounted,
      rebuild: setState,
      blurSigma: widget.blurSigma,
      saturation: widget.saturation,
    );
    _ticker = createTicker(_tick);
    _resetRipples();
    _resolveCover();
    if (widget.animate) _ensureTicker();
    if (kEnableRippleShader) _loadShader();
  }

  @override
  void didUpdateWidget(RippleBackground old) {
    super.didUpdateWidget(old);
    if (old.cover != widget.cover) _resolveCover();
    if (old.animate != widget.animate) {
      if (widget.animate) {
        _ensureTicker();
      } else if (_ticker.isActive) {
        _ticker.stop();
      }
    }
    // 模糊/饱和度变化 → 预烘焙封面需重做（仅 GPU 路径用）。
    if (old.blurSigma != widget.blurSigma ||
        old.saturation != widget.saturation) {
      _static
        ..blurSigma = widget.blurSigma
        ..saturation = widget.saturation;
      final cur = _current;
      if (cur != null) _static.prepareCover(cur, transition: false);
    }
    _repaint.notify();
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener!);
    _ticker.dispose();
    _repaint.dispose();
    _shader?.dispose();
    _static.dispose();
    _smallImage?.dispose();
    super.dispose();
  }

  void _ensureTicker() {
    if (!widget.animate || _ticker.isActive) return;
    _lastUs = 0;
    _ticker.start();
  }

  // ── GPU 着色器 ───────────────────────────────────────────────────────

  Future<void> _loadShader() async {
    final program = await RippleShaderLoader.load();
    if (!mounted || program == null) return;
    setState(() => _shader = program.fragmentShader());
  }

  // ── 封面解析 ─────────────────────────────────────────────────────────

  ImageProvider? _providerFor(String? cover) {
    if (cover == null || cover.isEmpty) return null;
    if (cover.startsWith('http')) return NetworkImage(cover);
    final path = cover.startsWith('file://') ? cover.substring(7) : cover;
    final file = File(path);
    if (!file.existsSync()) return null;
    return FileImage(file);
  }

  void _resolveCover() {
    _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
    final cover = widget.cover;
    final provider = _providerFor(cover);
    if (provider == null) {
      _current = null;
      _old = null;
      _mix = 1;
      _repaint.notify();
      return;
    }
    final listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      final img = info.image;
      if (identical(_current, img) && _static.current != null) return;
      var transition = false;
      if (!widget.animate) {
        _old = null;
        _mix = 1;
      } else if (_current != null && !identical(_current, img)) {
        _old = _current;
        _beginTransition();
        transition = true;
      }
      _current = img;
      _static.prepareCover(img, transition: transition);
      _repaint.notify();
    }, onError: (_, _) {});
    _listener = listener;
    _stream = provider.resolve(ImageConfiguration.empty)..addListener(listener);
  }

  // ── 涟漪模拟（对齐上游）──────────────────────────────────────────────

  double _random() {
    _rand = (_rand * 1664525 + 1013904223) & 0xFFFFFFFF;
    return _rand / 0x100000000;
  }

  double _nextInterval() =>
      -_kMeanInterval * math.log(1 - math.min(_random(), 0.999999));

  _Ripple _createRipple(double birth) => _Ripple(
    _random(),
    _random(),
    birth,
    0.12 + _random() * 0.1,
    0.8 + _random() * 0.8,
    _random() * math.pi * 2,
  );

  void _resetRipples() {
    _rand = 0x51f15e;
    _ripples.clear();
    _simTime = 0;
    _nextSpawn = _random() * _kMeanInterval;
  }

  void _updateRipples(double time) {
    while (time >= _nextSpawn) {
      if (_ripples.length < _kMaxRipples) _ripples.add(_createRipple(time));
      _nextSpawn += _nextInterval();
    }
    for (var i = _ripples.length - 1; i >= 0; i--) {
      if (time - _ripples[i].birth > _kRippleLifetime) _ripples.removeAt(i);
    }
  }

  void _beginTransition() {
    _transitioning = true;
    _transitionProgress = 0;
    _mix = 0;
    _ensureTicker();
  }

  void _tick(Duration elapsed) {
    final us = elapsed.inMicroseconds;
    if (_lastUs == 0) {
      _lastUs = us;
      return;
    }
    var dt = (us - _lastUs) / 1000000.0;
    _lastUs = us;
    if (dt <= 0) return;
    if (dt > 0.05) dt = 0.05; // 夹紧长帧，避免涟漪跳变
    final speed = widget.playing ? math.max(widget.speed, 0.1) / 3 : 0.04;
    _simTime += dt * speed;
    _updateRipples(_simTime);
    if (_transitioning) {
      _transitionProgress += dt;
      _mix = (_transitionProgress / (_kTransitionMs / 1000)).clamp(0.0, 1.0);
      if (_mix >= 1) {
        _transitioning = false;
        // 交叉淡入结束：旧封面纹理可释放。
        _static.releaseOld();
      }
    }
    _repaint.notify();
  }

  /// 无封面时底色（供 painter 读取，避免跨类访问 protected 的 widget）。
  Color get fallbackColor => widget.fallbackColor;

  /// 夹到 `[0.25, 1.0]` 的动态层渲染尺度（见 [RippleBackground.renderScale]）。
  double get _renderScale => widget.renderScale.clamp(0.25, 1.0).toDouble();

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    final prepared = _static.current;
    // GPU 主路径（默认关闭，见 kEnableRippleShader）。
    if (kEnableRippleShader && shader != null && prepared != null) {
      return RepaintBoundary(
        child: CustomPaint(
          painter: _RippleShaderPainter(this, _repaint, shader),
          size: Size.infinite,
        ),
      );
    }
    // CPU 网格路径：预烘焙纹理已含模糊+饱和，直接用；未就绪（或测试环境）时
    // 回退到原图 + 每帧滤镜，保证观感一致。
    Widget paint = CustomPaint(
      painter: _RipplePainter(this, _repaint),
      size: Size.infinite,
    );
    if (prepared == null) {
      paint = _static.wrapFallback(paint);
    }
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          paint,
          if (widget.darken > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: widget.darken),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
