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
  static const int skipLow = 8;
  static const double attack = 0.4;
  static const double decay = 0.88;

  double barWidth;
  double radius;
  Color color = Colors.transparent;
  SpectrumStyleRenderer style = spectrumStyleRendererFor('bars');
  bool reverse = false;

  /// 是否绘制峰值保持线（由偏好控制，默认关）。
  bool showPeak = false;
  int nowMs = 0;

  final List<Float64List> _prev = [Float64List(fftSize), Float64List(fftSize)];
  final List<Float64List> _curr = [Float64List(fftSize), Float64List(fftSize)];
  final List<Float64List> _display = [
    Float64List(fftSize),
    Float64List(fftSize),
  ];
  final Float64List _stereo = Float64List(fftSize * 2);
  final Float64List _peakL = Float64List(fftSize);
  final Float64List _peakR = Float64List(fftSize);
  bool _hasPeak = false;

  /// 实测帧间隔（ms）：由 [FftFrame.intervalMs] 播种、按实际到达间隔平滑，
  /// 随引擎事件档位（50/300/1000ms）自适应。
  double _intervalMs = spectrumDefaultIntervalMs;
  int _lastUpdateMs = 0;
  int _lastPaintMs = 0;

  void pushFrame(FftFrame frame, int nowMs) {
    final l = frame.ldata;
    final r = frame.rdata;
    for (var i = 0; i < fftSize; i++) {
      _prev[0][i] = _curr[0][i];
      _prev[1][i] = _curr[1][i];
      _curr[0][i] = i < l.length ? _finite(l[i]) : 0.0;
      _curr[1][i] = i < r.length ? _finite(r[i]) : 0.0;
      _peakL[i] = i < frame.lpeak.length ? _finite(frame.lpeak[i]) : 0.0;
      _peakR[i] = i < frame.rpeak.length ? _finite(frame.rpeak[i]) : 0.0;
    }
    _hasPeak = frame.lpeak.isNotEmpty || frame.rpeak.isNotEmpty;
    final measured = _lastUpdateMs > 0 ? nowMs - _lastUpdateMs : 0;
    _intervalMs = updateSpectrumInterval(
      _intervalMs,
      measured,
      configuredMs: frame.intervalMs.toDouble(),
    );
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
    _peakL.fillRange(0, fftSize, 0);
    _peakR.fillRange(0, fftSize, 0);
    _hasPeak = false;
    _lastUpdateMs = nowMs;
    _lastPaintMs = nowMs;
    _intervalMs = spectrumDefaultIntervalMs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = spectrumInterpolationProgress(nowMs, _lastUpdateMs, _intervalMs);
    final dtMs = _lastPaintMs > 0
        ? (nowMs - _lastPaintMs).toDouble()
        : spectrumFrameMs;
    _lastPaintMs = nowMs;
    final attackK = spectrumAttackFactor(dtMs, attack: attack);
    final decayK = spectrumDecayFactor(dtMs, decay: decay);
    for (var c = 0; c < 2; c++) {
      final prev = _prev[c];
      final curr = _curr[c];
      final disp = _display[c];
      for (var i = 0; i < fftSize; i++) {
        final target = _finite(prev[i] + (curr[i] - prev[i]) * t);
        if (target > disp[i]) {
          disp[i] += (target - disp[i]) * attackK;
        } else {
          disp[i] = disp[i] * decayK + target * (1 - decayK);
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
    _drawPeakLine(canvas, size);
  }

  /// 峰值保持线：引擎算好，UI 只按双声道拼接布局描线（不做 DSP）。
  void _drawPeakLine(Canvas canvas, Size size) {
    if (!showPeak || !_hasPeak) return;
    final channelLength = fftSize - skipLow;
    final total = channelLength * 2;
    if (total <= 1) return;
    final path = Path();
    for (var i = 0; i < total; i++) {
      final isLeft = i < channelLength;
      final src = isLeft ? (reverse ? (channelLength - 1 - i) : i) : i - channelLength;
      final v = isLeft
          ? _peakL[fftSize - 1 - src]
          : _peakR[skipLow + src];
      final x = size.width * i / (total - 1);
      final y = size.height - v.clamp(0.0, 1.0) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
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
      old.reverse != reverse ||
      old.showPeak != showPeak;
}
