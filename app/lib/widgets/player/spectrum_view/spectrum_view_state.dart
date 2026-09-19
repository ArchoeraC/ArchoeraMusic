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
    // elapsed 是「自 ticker 启动以来的累计时长」，直接赋值即为单调时钟；
    // 累加会让 nowMs 二次增长、帧间插值恒饱和（t=1）而失效。
    _clockMs = elapsed.inMilliseconds;
    _painter.nowMs = _clockMs;
    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    final fft = ref.watch(playbackProvider.select((s) => s.fft));
    final playing = ref.watch(playbackProvider.select((s) => s.playing));
    final prefs = ref.watch(appPrefsProvider);
    // 可见性（Offstage/TickerMode 关闭）：不可见时不 tick。否则 Consumer 仍会
    // 因播放态/位置变化重建，把 ticker 重新解除静音，白白持续出帧。
    final visible = TickerMode.valuesOf(context).enabled;

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
    final reverse = widget.reverse ?? prefs.reverseSpectrum;
    if (_painter.barWidth != barWidth ||
        _painter.color != color ||
        _painter.style != style ||
        _painter.reverse != reverse ||
        _painter.nowMs != _clockMs) {
      _painter
        ..barWidth = barWidth
        ..color = color
        ..style = style
        ..reverse = reverse
        ..nowMs = _clockMs;
      _repaint.value++;
    }
    final targetOpacity = playing
        ? widget.opacity
        : widget.opacity * (0.15 / 0.65);
    _ticker.muted = !(playing && visible);

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
        // 横向渐隐已并入 painter 的画笔 shader（_fadeShader），不再用
        // ShaderMask 离屏层（P3：减少一次合成 pass）。
        child: CustomPaint(
          size: Size(double.infinity, widget.height),
          painter: _painter,
        ),
      ),
    );
  }
}
