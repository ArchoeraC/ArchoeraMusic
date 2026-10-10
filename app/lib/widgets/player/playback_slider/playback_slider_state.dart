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

  /// 时间提示渲染在**最近 Overlay** 中：可溢出进度条/播放条容器，从而与
  /// 轨道拉开间距，且不改变容器尺寸（气泡定位见 [_buildOverlayTip]）。
  final OverlayPortalController _tipController = OverlayPortalController(
    debugLabel: 'playback-progress-tip',
  );

  /// 最近一次布局算得的轨道矩形（Overlay 气泡据此换算时间并定位）。
  Rect _trackRect = Rect.zero;

  /// 时间提示当前是否应显示（悬停 / 拖动中，且进度可换算）。
  bool get _tipVisible =>
      widget.showTooltip &&
      widget.max > 1 &&
      (_hovered || _dragging || _barDragging);

  /// 依当前状态显示/隐藏 Overlay 时间提示。仅在事件回调中调用（不得在
  /// build/布局期间调用 [OverlayPortalController.show]/[hide]）。
  void _syncTip() {
    if (_tipVisible) {
      _tipController.show();
    } else if (_tipController.isShowing) {
      _tipController.hide();
    }
  }

  /// 整活模式是否激活（进度条反向：从右向左填充、拖点映射同步反向）。
  bool get _prank => aprilFoolsActiveNotifier.value;

  @override
  Widget build(BuildContext context) {
    // 整活模式切换时重建整条进度条（含时间提示映射）。
    return ValueListenableBuilder<bool>(
      valueListenable: aprilFoolsActiveNotifier,
      builder: (BuildContext context, bool _, Widget? _) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _tipController,
      overlayChildBuilder: _buildOverlayTip,
      child: MouseRegion(
        onEnter: (_) {
          setState(() => _hovered = true);
          _syncTip();
        },
        onExit: (_) {
          setState(() => _hovered = false);
          _syncTip();
        },
        onHover: (e) => setState(() => _hoverDx = e.localPosition.dx),
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          height: 48,
          child: LayoutBuilder(
            builder: (context, c) {
              // 缓存轨道矩形供 Overlay 气泡复用（不在 build 中触发重建）。
              final rect = _trackRect = _trackRectFor(
                context,
                c.maxWidth,
                c.maxHeight,
              );
              return (_hovered || _dragging) && !_barDragging
                  ? _buildSlider(scheme, rect)
                  : _buildBar(scheme, rect);
            },
          ),
        ),
      ),
    );
  }

  Rect _trackRectFor(BuildContext context, double width, double height) {
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

  /// Overlay 时间提示：按指针在轨道上的横向位置换算时间；若
  /// [PlaybackSlider.tooltipLyric] 提供且有对应歌词，则在时间旁一并显示
  /// 该时刻的歌词行——悬停即「定位歌词」，便于拖动前确认落点。
  ///
  /// 用 [OverlayChildLayoutInfo.childPaintTransform] 把气泡放进 Overlay，
  /// 使其可位于进度条上方容器之外（不撑高/撑宽任何容器）。
  Widget _buildOverlayTip(BuildContext context, OverlayChildLayoutInfo info) {
    final rect = _trackRect;
    if (!_tipVisible ||
        rect.width <= 0 ||
        info.childPaintTransform.determinant() == 0) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final ratio = widget.max <= 0
        ? 0.0
        : (widget.value / widget.max).clamp(0.0, 1.0);
    // 拖动中按滑块值定位（拖动时不再有 hover 事件，_hoverDx 会滞后）；
    // 悬停按指针位置；细条触摸拖动按拖动位置。
    final double dx;
    if (_barDragging) {
      dx = _hoverDx ?? (rect.left + rect.width * ratio);
    } else if (_dragging) {
      dx = rect.left + rect.width * ratio;
    } else {
      dx = _hoverDx ?? rect.center.dx;
    }
    final t = ((dx - rect.left) / rect.width).clamp(0.0, 1.0);
    // 整活模式：指针 x 对应的实际进度 = 反向映射（与拖动/填充一致）。
    final valueT = _prank ? 1.0 - t : t;
    final ms = (valueT * widget.max).round();
    final text = formatClock(Duration(milliseconds: ms));
    final lyric = widget.tooltipLyric?.call(ms.toDouble());
    return Transform(
      transform: info.childPaintTransform,
      // 与进度条同尺寸的坐标盒：气泡在盒内按指针居中、贴边夹取，垂直方向
      // 允许落在盒顶之上（Overlay 不裁剪）。
      child: SizedBox(
        width: info.childSize.width,
        height: info.childSize.height,
        child: IgnorePointer(
          child: CustomSingleChildLayout(
            delegate: _HoverTipLayout(dx: dx, trackTop: rect.top),
            child: _buildTipBubble(scheme, text, lyric),
          ),
        ),
      ),
    );
  }

  /// 时间 +（可选）歌词的单行气泡。
  Widget _buildTipBubble(ColorScheme scheme, String text, String? lyric) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.inverseSurface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: TextStyle(fontSize: 10, color: scheme.onInverseSurface),
          ),
          if (lyric != null) ...[
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                lyric,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onInverseSurface.withValues(alpha: 0.75),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSlider(ColorScheme scheme, Rect rect) {
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        _maybeMirror(
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: widget.buffering
                  ? scheme.primary.withValues(alpha: 0.35)
                  : null,
            ),
            child: Slider(
              value: widget.value,
              max: widget.max,
              onChangeStart: (v) {
                setState(() => _dragging = true);
                _syncTip();
              },
              onChangeEnd: (v) {
                setState(() => _dragging = false);
                _syncTip();
                widget.onChangeEnd?.call(v);
              },
              onChanged: widget.onChanged,
            ),
          ),
        ),
        if (widget.buffering) _bufferLayer(scheme, rect),
      ],
    );
  }

  /// 整活模式下水平镜像控件：填充从右缘开始、拖动方向同步反向，
  /// 命中测试跟随镜像（[Transform.transformHitTests] = true）保证手感一致。
  Widget _maybeMirror(Widget child) {
    if (!_prank) return child;
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..setEntry(0, 0, -1.0),
      transformHitTests: true,
      child: child,
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
      return (_prank ? 1.0 - t : t) * max;
    }

    // 进度填充矩形：整活模式下从右缘向左生长。
    Rect progressRect() {
      final filled = rect.width * ratio;
      final left = _prank ? rect.left + rect.width - filled : rect.left;
      return Rect.fromLTWH(left, rect.top, filled, rect.height);
    }

    // 当前进度的横向位置（拖动圆点用）。
    double valueDx() => _prank
        ? rect.left + rect.width * (1 - ratio)
        : rect.left + rect.width * ratio;

    void endBarDrag(double v) {
      if (!_barDragging) return;
      setState(() => _barDragging = false);
      _syncTip();
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
          rect: progressRect(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: ColoredBox(color: progressColor),
          ),
        ),
        if (widget.buffering) _bufferLayer(scheme, rect),
        // 触摸拖动：细条无滑块，补一个跟随的圆点（时间提示走 Overlay）。
        if (_barDragging)
          Positioned(
            left: (valueDx() - 6).clamp(0.0, double.infinity),
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
        _syncTip();
        widget.onChanged?.call(_barValue);
      },
      onHorizontalDragUpdate: (d) {
        _hoverDx = d.localPosition.dx;
        _barValue = valueAt(d.localPosition.dx);
        // 拖动位置变化需让 Overlay 气泡跟随：更新即触发重建。
        setState(() {});
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

/// 悬停时间气泡定位：以指针 x 居中，并夹取在轨道宽度内，避免贴边被裁。
///
/// 气泡宽度由内容（时间 + 可能的一行歌词）决定，故不能在外部预设偏移，
/// 交由布局委托按实际子尺寸回正；垂直方向让气泡底边落在轨道顶边上方
/// [_tooltipTrackGap] 处（允许为负，气泡落在盒顶之上，由 Overlay 承载）。
class _HoverTipLayout extends SingleChildLayoutDelegate {
  const _HoverTipLayout({required this.dx, required this.trackTop});

  /// 指针相对本组件左缘的 x。
  final double dx;

  /// 轨道顶边相对本组件顶部的 y。
  final double trackTop;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxLeft = (size.width - childSize.width).clamp(0.0, double.infinity);
    final left = (dx - childSize.width / 2).clamp(0.0, maxLeft);
    final top = trackTop - _tooltipTrackGap - childSize.height;
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_HoverTipLayout oldDelegate) =>
      oldDelegate.dx != dx || oldDelegate.trackTop != trackTop;
}

/// 悬停时间气泡底边与轨道顶边之间的间距。
const double _tooltipTrackGap = 10;
