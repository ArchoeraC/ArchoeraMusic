// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../spectrum_view.dart';

class _SpectrumViewState extends ConsumerState<SpectrumView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _clockMs = 0;

  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  late final _SpectrumPainter _painter;
  FftFrame? _lastPushed;

  @override
  void initState() {
    super.initState();
    _painter = _SpectrumPainter(
      barWidth: 4,
      radius: widget.radius,
      repaint: _repaint,
    );
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _repaint.dispose();
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    _clockMs += elapsed.inMilliseconds;
    _painter.nowMs = _clockMs;
    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    final fft = ref.watch(playbackProvider.select((s) => s.fft));
    final playing = ref.watch(playbackProvider.select((s) => s.playing));
    final prefs = ref.watch(appPrefsProvider);

    final enabled =
        (widget.enabled ?? prefs.enableSpectrum) && !prefs.performanceMode;
    if (!enabled) {
      _ticker.muted = true;
      return SizedBox(width: double.infinity, height: widget.height);
    }

    final barWidth = widget.barWidth ?? prefs.spectrumBarWidth.toDouble();
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final style =
        widget.style ?? SpectrumStyle.fromStorage(prefs.spectrumStyle);
    if (_painter.barWidth != barWidth ||
        _painter.color != color ||
        _painter.style != style ||
        _painter.nowMs != _clockMs) {
      _painter
        ..barWidth = barWidth
        ..color = color
        ..style = style
        ..nowMs = _clockMs;
      _repaint.value++;
    }
    final targetOpacity = playing
        ? widget.opacity
        : widget.opacity * (0.15 / 0.65);
    _ticker.muted = !playing;

    if (fft == null) {
      if (_lastPushed != null) {
        _lastPushed = null;
        _painter.reset();
        _repaint.value++;
      }
    } else if (!identical(_lastPushed, fft)) {
      _lastPushed = fft;
      _painter.pushFrame(fft, _clockMs);
      _repaint.value++;
    }

    return RepaintBoundary(
      child: AnimatedOpacity(
        opacity: targetOpacity,
        duration: animDuration(context, const Duration(milliseconds: 300)),
        curve: Curves.easeOut,
        child: ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Color(0x00000000),
              Color(0x99FFFFFF),
              Color(0xFFFFFFFF),
              Color(0xFFFFFFFF),
              Color(0x99FFFFFF),
              Color(0x00000000),
            ],
            stops: [0.0, 0.05, 0.12, 0.88, 0.95, 1.0],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: CustomPaint(
            size: Size(double.infinity, widget.height),
            painter: _painter,
          ),
        ),
      ),
    );
  }
}
