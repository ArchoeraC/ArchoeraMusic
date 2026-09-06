// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../playback_slider.dart';

class _PlaybackSliderState extends State<PlaybackSlider> {
  bool _hovered = false;
  bool _dragging = false;
  bool _barDragging = false;
  double _barValue = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: SizedBox(
        height: 48,
        child: LayoutBuilder(
          builder: (context, c) {
            final rect = _trackRect(context, c.maxWidth, c.maxHeight);
            return (_hovered || _dragging) && !_barDragging
                ? _buildSlider(scheme, rect)
                : _buildBar(scheme, rect);
          },
        ),
      ),
    );
  }

  Rect _trackRect(BuildContext context, double width, double height) {
    final st = SliderTheme.of(context);
    final overlayW =
        st.overlayShape?.getPreferredSize(true, false).width ??
        (st.thumbShape?.getPreferredSize(true, false).width ?? 24.0);
    final trackH = st.trackHeight ?? 4.0;
    final trackW = (width - overlayW).clamp(0.0, double.infinity);
    return Rect.fromLTWH(
      (overlayW - trackH) / 2,
      (height - trackH) / 2,
      trackW,
      trackH,
    );
  }

  Widget _buildSlider(ColorScheme scheme, Rect rect) {
    return Stack(
      alignment: Alignment.center,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: widget.buffering
                ? scheme.primary.withValues(alpha: 0.35)
                : null,
          ),
          child: Slider(
            value: widget.value,
            max: widget.max,
            onChangeStart: (v) => setState(() => _dragging = true),
            onChangeEnd: (v) {
              setState(() => _dragging = false);
              widget.onChangeEnd?.call(v);
            },
            onChanged: widget.onChanged,
          ),
        ),
        if (widget.buffering) _bufferLayer(scheme, rect),
      ],
    );
  }

  Widget _buildBar(ColorScheme scheme, Rect rect) {
    final max = widget.max <= 0 ? 1.0 : widget.max;
    final ratio = (widget.value / max).clamp(0.0, 1.0);
    final trackColor = scheme.onSurface.withValues(alpha: 0.12);
    final progressColor = widget.buffering
        ? scheme.primary.withValues(alpha: 0.4)
        : scheme.primary;

    double valueAt(double dx) {
      final t = ((dx - rect.left) / rect.width).clamp(0.0, 1.0);
      return t * max;
    }

    void endBarDrag(double v) {
      if (!_barDragging) return;
      setState(() => _barDragging = false);
      widget.onChangeEnd?.call(v);
    }

    final stack = Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fromRect(
          rect: rect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: ColoredBox(color: trackColor),
          ),
        ),
        Positioned.fromRect(
          rect: Rect.fromLTWH(
            rect.left,
            rect.top,
            rect.width * ratio,
            rect.height,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: ColoredBox(color: progressColor),
          ),
        ),
        if (widget.buffering) _bufferLayer(scheme, rect),
      ],
    );
    if (widget.onChanged == null && widget.onChangeEnd == null) return stack;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        final v = valueAt(d.localPosition.dx);
        widget.onChanged?.call(v);
        widget.onChangeEnd?.call(v);
      },
      onHorizontalDragStart: (d) {
        _barValue = valueAt(d.localPosition.dx);
        setState(() => _barDragging = true);
        widget.onChanged?.call(_barValue);
      },
      onHorizontalDragUpdate: (d) {
        _barValue = valueAt(d.localPosition.dx);
        widget.onChanged?.call(_barValue);
      },
      onHorizontalDragEnd: (d) => endBarDrag(valueAt(d.localPosition.dx)),
      onHorizontalDragCancel: () => endBarDrag(_barValue),
      child: stack,
    );
  }

  Widget _bufferLayer(ColorScheme scheme, Rect rect) {
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            minHeight: rect.height,
            color: scheme.primary,
            backgroundColor: Colors.transparent,
          ),
        ),
      ),
    );
  }
}
