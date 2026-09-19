// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../playback_slider.dart';

class _PlaybackSliderState extends State<PlaybackSlider> {
  bool _hovered = false;
  bool _dragging = false;
  bool _barDragging = false;
  double _barValue = 0;

  /// 悬停指针相对本组件左缘的 x（用于时间提示定位）。
  double? _hoverDx;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      onHover: (e) => setState(() => _hoverDx = e.localPosition.dx),
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
    final showTip =
        widget.showTooltip && (_hovered || _dragging) && widget.max > 1;
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
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
        if (showTip) _hoverTooltip(scheme, rect),
      ],
    );
  }

  /// 悬停时间提示：按指针在轨道上的横向位置换算时间（对齐上游 timeFormat 前身）。
  Widget _hoverTooltip(ColorScheme scheme, Rect rect) {
    if (rect.width <= 0) return const SizedBox.shrink();
    final dx = _hoverDx ?? rect.center.dx;
    final t = ((dx - rect.left) / rect.width).clamp(0.0, 1.0);
    final ms = (t * widget.max).round();
    final text = formatClock(Duration(milliseconds: ms));
    final left = (dx - 30).clamp(0.0, double.infinity);
    return Positioned(
      top: 0,
      left: left,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: scheme.inverseSurface.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            text,
            style: TextStyle(fontSize: 10, color: scheme.onInverseSurface),
          ),
        ),
      ),
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
      clipBehavior: Clip.none,
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
        // 触摸拖动：细条无滑块，补一个跟随的圆点 + 时间提示（鼠标走 hover 展开）。
        if (_barDragging) ...[
          Positioned(
            left: (rect.left + rect.width * ratio - 6).clamp(
              0.0,
              double.infinity,
            ),
            top: rect.center.dy - 6,
            child: IgnorePointer(
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          if (widget.showTooltip) _hoverTooltip(scheme, rect),
        ],
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
        _hoverDx = d.localPosition.dx;
        _barValue = valueAt(d.localPosition.dx);
        setState(() => _barDragging = true);
        widget.onChanged?.call(_barValue);
      },
      onHorizontalDragUpdate: (d) {
        _hoverDx = d.localPosition.dx;
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
