// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../spectrum_view.dart';

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.barWidth,
    required this.radius,
    super.repaint,
  });

  static const int fftSize = 128;
  static const int pushIntervalMs = 50;
  static const int skipLow = 8;
  static const int barGap = 3;
  static const double attack = 0.4;
  static const double decay = 0.88;
  static const double _minBarHeight = 0.5;

  double barWidth;
  double radius;
  Color color = Colors.transparent;
  SpectrumStyle style = SpectrumStyle.bars;
  int nowMs = 0;

  final List<Float64List> _prev = [Float64List(fftSize), Float64List(fftSize)];
  final List<Float64List> _curr = [Float64List(fftSize), Float64List(fftSize)];
  final List<Float64List> _display = [
    Float64List(fftSize),
    Float64List(fftSize),
  ];
  final Float64List _stereo = Float64List(fftSize * 2);

  int _lastUpdateMs = 0;

  void pushFrame(FftFrame frame, int nowMs) {
    final l = frame.ldata;
    final r = frame.rdata;
    for (var i = 0; i < fftSize; i++) {
      _prev[0][i] = _curr[0][i];
      _prev[1][i] = _curr[1][i];
      _curr[0][i] = i < l.length ? _finite(l[i]) : 0.0;
      _curr[1][i] = i < r.length ? _finite(r[i]) : 0.0;
    }
    _lastUpdateMs = nowMs;
  }

  static double _finite(double v) => v.isFinite && v >= 0 ? v : 0.0;

  void reset() {
    for (final b in _prev) {
      b.fillRange(0, fftSize, 0);
    }
    for (final b in _curr) {
      b.fillRange(0, fftSize, 0);
    }
    for (final b in _display) {
      b.fillRange(0, fftSize, 0);
    }
    _stereo.fillRange(0, _stereo.length, 0);
    _lastUpdateMs = nowMs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = math
        .min((nowMs - _lastUpdateMs) / pushIntervalMs, 1.0)
        .clamp(0.0, 1.0);
    for (var c = 0; c < 2; c++) {
      final prev = _prev[c];
      final curr = _curr[c];
      final disp = _display[c];
      for (var i = 0; i < fftSize; i++) {
        final target = _finite(prev[i] + (curr[i] - prev[i]) * t);
        if (target > disp[i]) {
          disp[i] += (target - disp[i]) * attack;
        } else {
          disp[i] = disp[i] * decay + target * (1 - decay);
        }
      }
    }

    final usableLen = _buildBins();
    if (usableLen <= 0) return;

    switch (style) {
      case SpectrumStyle.bars:
        _paintBars(canvas, size, usableLen);
      case SpectrumStyle.wave:
        _paintWave(canvas, size, usableLen, mirror: true);
      case SpectrumStyle.waveUp:
        _paintWave(canvas, size, usableLen, mirror: false);
    }
  }

  int _buildBins() {
    final channelLength = fftSize - skipLow;
    for (var i = 0; i < channelLength; i++) {
      _stereo[i] = _display[0][fftSize - 1 - i];
      _stereo[channelLength + i] = _display[1][skipLow + i];
    }
    return channelLength * 2;
  }

  void _paintBars(Canvas canvas, Size size, int usableLen) {
    final slotWidth = barWidth + barGap;
    final numBars = (size.width / slotWidth).floor();
    if (numBars <= 0) return;

    final paint = Paint()..color = color;
    for (var i = 0; i < numBars; i++) {
      final startBin = (i * usableLen / numBars).floor();
      final endBin = ((i + 1) * usableLen / numBars).floor();
      final lo = math.max(0, startBin - 1);
      final hi = math.min(usableLen, math.max(endBin, startBin + 1) + 1);
      var sum = 0.0;
      for (var j = lo; j < hi; j++) {
        sum += _stereo[j];
      }
      final v = sum / (hi - lo);
      final barHeight = v * size.height;
      if (barHeight <= _minBarHeight) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            i * slotWidth,
            size.height - barHeight,
            barWidth,
            barHeight,
          ),
          Radius.circular(radius),
        ),
        paint,
      );
    }
  }

  void _paintWave(
    Canvas canvas,
    Size size,
    int usableLen, {
    required bool mirror,
  }) {
    if (usableLen <= 1 || size.width <= 0) return;
    final midY = size.height / 2;
    final amp = math.max(size.height / 2 - 2, 1.0);
    final pad = math.min(16.0, size.width * 0.05);
    final curveWidth = size.width - 2 * pad;
    if (curveWidth <= 2) return;
    final stepX = curveWidth / (usableLen - 1);

    final smoothBins = Float64List(usableLen);
    for (var i = 0; i < usableLen; i++) {
      final lo = math.max(0, i - 1);
      final hi = math.min(usableLen - 1, i + 1);
      var sum = 0.0;
      var n = 0;
      for (var j = lo; j <= hi; j++) {
        final raw = _stereo[j];
        sum += raw < 0 ? 0.0 : (raw > 1 ? 1.0 : raw);
        n++;
      }
      smoothBins[i] = sum / n;
    }

    const fadeLen = 12;
    for (var i = 0; i < fadeLen && i < usableLen; i++) {
      final k = i / fadeLen;
      smoothBins[i] *= k;
      final j = usableLen - 1 - i;
      if (j > i) {
        smoothBins[j] *= k;
      }
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, math.min(3.0, barWidth))
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    void trace(Path path, double sign) {
      path.moveTo(pad, midY + sign * smoothBins[0] * amp);
      for (var i = 0; i < usableLen - 1; i++) {
        final y = midY + sign * smoothBins[i] * amp;
        final yMid =
            midY + sign * ((smoothBins[i] + smoothBins[i + 1]) / 2) * amp;
        path.quadraticBezierTo(
          pad + i * stepX,
          y,
          pad + (i + 0.5) * stepX,
          yMid,
        );
      }
      path.lineTo(
        pad + (usableLen - 1) * stepX,
        midY + sign * smoothBins[usableLen - 1] * amp,
      );
    }

    final upper = Path();
    trace(upper, -1);
    canvas.drawPath(upper, paint);
    if (mirror) {
      final lower = Path();
      trace(lower, 1);
      canvas.drawPath(lower, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) =>
      old.nowMs != nowMs ||
      old.barWidth != barWidth ||
      old.radius != radius ||
      old.color != color ||
      old.style != style;
}
