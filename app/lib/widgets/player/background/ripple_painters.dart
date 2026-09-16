// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `ripple_background.dart` 的绘制器部分：GPU 着色器绘制、CPU 兜底网格引擎、
/// 涟漪数据与重绘通知。作为 `part` 共享主库私有状态（见 [RippleBackground]）。
part of 'ripple_background.dart';

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

class _Ripple {
  _Ripple(this.x, this.y, this.birth, this.speed, this.strength, this.seed);

  final double x;
  final double y;
  final double birth;
  final double speed;
  final double strength;
  final double seed;
}
