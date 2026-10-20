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
  static const double attack = 0.4;
  static const double decay = 0.88;

  double barWidth;
  double radius;
  Color color = Colors.transparent;
  SpectrumStyleRenderer style = spectrumStyleRendererFor('bars');
  bool reverse = false;
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

    style.paint(
      canvas,
      size,
      SpectrumPaintContext(
        stereo: _stereo,
        usableLen: usableLen,
        barWidth: barWidth,
        radius: radius,
        color: color,
      ),
    );
  }

  int _buildBins() {
    final channelLength = fftSize - skipLow;
    for (var i = 0; i < channelLength; i++) {
      final src = reverse ? (channelLength - 1 - i) : i;
      _stereo[i] = _display[0][fftSize - 1 - src];
      _stereo[channelLength + i] = _display[1][skipLow + src];
    }
    return channelLength * 2;
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) =>
      old.nowMs != nowMs ||
      old.barWidth != barWidth ||
      old.radius != radius ||
      old.color != color ||
      old.style.id != style.id ||
      old.reverse != reverse;
}
