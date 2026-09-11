// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放器「水纹」背景（自绘引擎 + GPU 着色器，移植 SPlayer-Next `BackgroundRipple.vue`）。
///
/// 上游为 WebGPU/WebGL 片元着色器：对封面做多涟漪折射位移 + 波峰高光/波谷压暗。
/// Flutter 端两条路径（渲染器优先，见 docs/player-render-optimization.md）：
/// - **GPU（主路径，P2）**：`shaders/ripple.frag` 单 pass 完成折射 + 饱和 + 高光/
///   压暗 + 压暗；封面模糊/饱和在 Dart 侧**预烘焙一次**（不再每帧全屏模糊）。
///   涟漪参数以 uniform 传入，CPU 侧只更新 uniforms。
/// - **CPU（仅着色器不可用时兜底）**：网格顶点折射 + `ImageShader`（见 [_RipplePainter]）。
///
/// 切歌时旧封面与新封面按 700ms 交叉淡入（GPU 路径在着色器内 `mix` 两纹理）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import 'ripple_shader.dart';

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

  /// 无封面时的底色。
  final Color fallbackColor;

  @override
  State<RippleBackground> createState() => _RippleBackgroundState();
}

/// 饱和度颜色滤镜（对齐上游 `saturate`），供水纹与模糊背景共用。
ColorFilter saturationColorFilter(double saturation) {
  final s = saturation;
  final inv = 1 - s;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  return ColorFilter.matrix(<double>[
    inv * lr + s, inv * lg, inv * lb, 0, 0,
    inv * lr, inv * lg + s, inv * lb, 0, 0,
    inv * lr, inv * lg, inv * lb + s, 0, 0,
    0, 0, 0, 1, 0,
  ]);
}

class _Ripple {
  _Ripple(this.x, this.y, this.birth, this.speed, this.strength, this.seed);

  final double x;
  final double y;
  final double birth;
  final double speed;
  final double strength;
  final double seed;
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

  /// GPU 路径：预烘焙（模糊+饱和）的封面纹理（当前 / 交叉淡入的旧封面）。
  ui.Image? _preparedCurrent;
  ui.Image? _preparedOld;

  @override
  void initState() {
    super.initState();
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
      final cur = _current;
      if (cur != null) _prepareCover(cur, transition: false);
    }
    _repaint.notify();
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener!);
    _ticker.dispose();
    _repaint.dispose();
    _shader?.dispose();
    _preparedCurrent?.dispose();
    _preparedOld?.dispose();
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

  /// 预烘焙：封面 → 模糊 + 饱和纹理（一次，替代每帧全屏模糊）。
  Future<ui.Image?> _prepare(ui.Image src) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: widget.blurSigma,
        sigmaY: widget.blurSigma,
      )
      ..colorFilter = saturationColorFilter(widget.saturation);
    canvas.drawImage(src, Offset.zero, paint);
    final pic = recorder.endRecording();
    try {
      return await pic.toImage(src.width, src.height);
    } catch (_) {
      return null;
    } finally {
      pic.dispose();
    }
  }

  void _prepareCover(ui.Image img, {required bool transition}) {
    unawaited(() async {
      final prepared = await _prepare(img);
      if (!mounted) {
        prepared?.dispose();
        return;
      }
      if (prepared == null) return;
      final old = _preparedCurrent;
      setState(() {
        if (transition && old != null) {
          _disposeLater(_preparedOld);
          _preparedOld = old; // 转移所有权给旧槽
        } else {
          _disposeLater(_preparedOld);
          _preparedOld = null;
          _disposeLater(old);
        }
        _preparedCurrent = prepared;
      });
    }());
  }

  /// 延后一帧释放，避免当前帧仍被 sampler/绘制引用。
  void _disposeLater(ui.Image? img) {
    if (img == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => img.dispose());
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
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        final img = info.image;
        if (identical(_current, img) && _preparedCurrent != null) return;
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
        _prepareCover(img, transition: transition);
        _repaint.notify();
      },
      onError: (_, _) {},
    );
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
        _disposeLater(_preparedOld);
        _preparedOld = null;
      }
    }
    _repaint.notify();
  }

  /// 无封面时底色（供 painter 读取，避免跨类访问 protected 的 widget）。
  Color get fallbackColor => widget.fallbackColor;

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    final prepared = _preparedCurrent;
    // GPU 主路径（默认关闭，见 kEnableRippleShader）。
    if (kEnableRippleShader && shader != null && prepared != null) {
      return RepaintBoundary(
        child: CustomPaint(
          painter: _RippleShaderPainter(this, _repaint, shader),
          size: Size.infinite,
        ),
      );
    }
    // CPU 网格路径：纹理已预烘焙（模糊+饱和），无需每帧 ImageFiltered/ColorFiltered。
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _RipplePainter(this, _repaint),
            size: Size.infinite,
          ),
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

/// GPU 着色器绘制：单 pass 折射 + 饱和 + 高光/压暗 + 压暗。
class _RippleShaderPainter extends CustomPainter {
  _RippleShaderPainter(this.s, Listenable repaint, this.shader)
    : super(repaint: repaint);

  final _RippleBackgroundState s;
  final ui.FragmentShader shader;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final to = s._preparedCurrent;
    if (w <= 0 || h <= 0 || to == null) return;
    final from = s._preparedOld ?? to;
    final mix = s._preparedOld != null ? s._mix : 1.0;

    shader.setFloat(RippleUniforms.size, w);
    shader.setFloat(RippleUniforms.size + 1, h);
    shader.setFloat(RippleUniforms.darken, s.widget.darken);
    shader.setFloat(RippleUniforms.saturation, s.widget.saturation);
    shader.setFloat(RippleUniforms.imgAspect, to.width / to.height);
    shader.setFloat(RippleUniforms.mix, mix);

    final time = s._simTime;
    var n = 0;
    for (final rp in s._ripples) {
      final age = time - rp.birth;
      if (age <= 0 || age > _kRippleLifetime) continue;
      final base = RippleUniforms.ripples + n * 4;
      shader.setFloat(base, rp.x);
      shader.setFloat(base + 1, rp.y);
      shader.setFloat(base + 2, age * rp.speed); // radius
      final st = (age / 0.12).clamp(0.0, 1.0);
      final env = math.exp(-age * 0.75) * (st * st * (3 - 2 * st));
      shader.setFloat(base + 3, env * rp.strength); // amp
      shader.setFloat(RippleUniforms.seeds + n, rp.seed);
      n++;
      if (n >= kRippleShaderMaxRipples) break;
    }
    // 着色器以 `i < uCount` 掩码，超出槽位不参与；无需清零。
    shader.setFloat(RippleUniforms.count, n.toDouble());

    shader.setImageSampler(RippleUniforms.samplerFrom, from);
    shader.setImageSampler(RippleUniforms.samplerTo, to);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_RippleShaderPainter old) => false;
}

class _Repaint extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// CPU 兜底引擎：网格顶点折射 + 顶点色高光/压暗。
class _RipplePainter extends CustomPainter {
  _RipplePainter(this.s, Listenable repaint) : super(repaint: repaint);

  final _RippleBackgroundState s;

  int _cols = 0;
  int _rows = 0;
  double _w = 0;
  double _h = 0;
  Float32List _positions = Float32List(0);
  Uint16List _indices = Uint16List(0);
  Float32List _texCoords = Float32List(0);
  Int32List _lightColors = Int32List(0);
  Int32List _darkColors = Int32List(0);

  /// 目标网格密度（像素/格）：越大越省，越小越细腻。
  static const double _cellPx = 12;

  void _ensureMesh(double w, double h) {
    if (_cols > 0 && _w == w && _h == h) return;
    _w = w;
    _h = h;
    _cols = (w / _cellPx).ceil().clamp(16, 160);
    _rows = (h / _cellPx).ceil().clamp(9, 90);
    final vc = (_cols + 1) * (_rows + 1);
    final positions = Float32List(vc * 2);
    var k = 0;
    for (var j = 0; j <= _rows; j++) {
      final y = j / _rows * h;
      for (var i = 0; i <= _cols; i++) {
        positions[k++] = i / _cols * w;
        positions[k++] = y;
      }
    }
    final indices = Uint16List(_cols * _rows * 6);
    var m = 0;
    for (var j = 0; j < _rows; j++) {
      for (var i = 0; i < _cols; i++) {
        final a = j * (_cols + 1) + i;
        final b = a + 1;
        final c = a + (_cols + 1);
        final d = c + 1;
        indices[m++] = a;
        indices[m++] = b;
        indices[m++] = c;
        indices[m++] = b;
        indices[m++] = d;
        indices[m++] = c;
      }
    }
    _positions = positions;    _indices = indices;
    _texCoords = Float32List(vc * 2);
    _lightColors = Int32List(vc);
    _darkColors = Int32List(vc);
  }

  /// 逐顶点计算涟漪折射位移 / 高光，写入 [_texCoords] / [_lightColors] /
  /// [_darkColors]（公式与上游 WGSL/GLSL 一致）。
  ///
  /// 优化（P2）：① 每帧按涟漪预计算 amp（age/env/smoothstep 与顶点无关）；
  /// ② 逐顶点用 `|dw|<=0.5` 裁剪——`exp(-|dw|*48)` 在 |dw|>0.5 时≈0，跳过
  /// exp/sin。使网格路径对集显/低端 CPU 也可负担（避免全屏逐像素着色器压死核显）。
  void _computeField(double w, double h, ui.Image img) {
    final aspect = w / h;
    final imgAspect = img.width / img.height;
    final ripples = s._ripples;
    final time = s._simTime;
    final n = ripples.length;

    final rx = Float64List(n);
    final ry = Float64List(n);
    final rRadius = Float64List(n);
    final rAmp = Float64List(n);
    final rSeed = Float64List(n);
    var active = 0;
    for (var r = 0; r < n; r++) {
      final rp = ripples[r];
      final age = time - rp.birth;
      if (age <= 0 || age > _kRippleLifetime) continue;
      final st = (age / 0.12).clamp(0.0, 1.0);
      final env = math.exp(-age * 0.75) * (st * st * (3 - 2 * st));
      rx[active] = rp.x;
      ry[active] = rp.y;
      rRadius[active] = age * rp.speed;
      rAmp[active] = env * rp.strength;
      rSeed[active] = rp.seed;
      active++;
    }

    const bandCut = 0.5; // |dw|>0.5 → exp(-24)≈4e-11，可忽略
    var vi = 0;
    var k = 0;
    for (var j = 0; j <= _rows; j++) {
      final v = j / _rows;
      for (var i = 0; i <= _cols; i++) {
        final u = i / _cols;
        var ox = 0.0;
        var oy = 0.0;
        var light = 0.0;
        for (var r = 0; r < active; r++) {
          final dx = (u - rx[r]) * aspect;
          final dy = v - ry[r];
          final dc = math.sqrt(dx * dx + dy * dy);
          final dw = dc - rRadius[r];
          if (dw > bandCut || dw < -bandCut) continue;
          final band = math.exp(-dw.abs() * 48);
          final wave = math.sin(dw * 115 + rSeed[r]) * band * rAmp[r];
          final ex = dx + 0.0001;
          final ey = dy + 0.0001;
          final inv = 1 / math.sqrt(ex * ex + ey * ey);
          ox += ex * inv * wave * 0.015;
          oy += ey * inv * wave * 0.015;
          light += wave;
        }
        var tu = u + ox;
        var tv = v + oy;
        if (aspect > imgAspect) {
          tv = (tv - 0.5) * (imgAspect / aspect) + 0.5;
        } else {
          tu = (tu - 0.5) * (aspect / imgAspect) + 0.5;
        }
        _texCoords[k] = tu.clamp(0.001, 0.999);
        _texCoords[k + 1] = tv.clamp(0.001, 0.999);
        final hi = light > 0 ? (light * 0.14).clamp(0.0, 1.0) : 0.0;
        final lo = light < 0 ? (-light * 0.09).clamp(0.0, 1.0) : 0.0;
        _lightColors[vi] = (((hi * 255).round() << 24) | 0xFFFFFF);
        _darkColors[vi] = ((lo * 255).round() << 24) & 0xFFFFFFFF;
        vi++;
        k += 2;
      }
    }
  }

  void _drawImage(
    Canvas canvas,
    Rect rect,
    ui.Vertices verts,
    ui.Image img,
    double alpha,
  ) {
    final m = Float64List(16);
    m[0] = img.width.toDouble();
    m[5] = img.height.toDouble();
    m[10] = 1;
    m[15] = 1;
    final paint = Paint()
      ..filterQuality = FilterQuality.low
      ..shader = ui.ImageShader(
        img,
        TileMode.clamp,
        TileMode.clamp,
        m,
        filterQuality: FilterQuality.low,
      );
    if (alpha >= 0.999) {
      canvas.drawVertices(verts, BlendMode.srcOver, paint);
    } else {
      canvas.saveLayer(rect, Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
      canvas.drawVertices(verts, BlendMode.srcOver, paint);
      canvas.restore();
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    // 优先用预烘焙（模糊+饱和）纹理；未就绪时暂用原图。
    final img = s._preparedCurrent ?? s._current;
    if (img == null) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = s.fallbackColor,
      );
      return;
    }
    _ensureMesh(w, h);
    _computeField(w, h, img);

    final verts = ui.Vertices.raw(
      ui.VertexMode.triangles,
      _positions,
      textureCoordinates: _texCoords,
      indices: _indices,
    );
    final rect = Offset.zero & size;
    final old = s._preparedOld ?? s._old;
    if (old != null && s._mix < 0.999) {
      _drawImage(canvas, rect, verts, old, 1);
      _drawImage(canvas, rect, verts, img, s._mix);
    } else {
      _drawImage(canvas, rect, verts, img, 1);
    }
    canvas.drawVertices(
      ui.Vertices.raw(
        ui.VertexMode.triangles,
        _positions,
        colors: _lightColors,
        indices: _indices,
      ),
      BlendMode.plus,
      Paint(),
    );
    canvas.drawVertices(
      ui.Vertices.raw(
        ui.VertexMode.triangles,
        _positions,
        colors: _darkColors,
        indices: _indices,
      ),
      BlendMode.srcOver,
      Paint(),
    );
  }

  @override
  bool shouldRepaint(_RipplePainter oldDelegate) => false;
}
