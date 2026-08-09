/// 播放进度条：默认简化细条，悬停展开完整 Slider；buffering 时叠加
/// 「缓冲流动」动效。
///
/// 交互：未悬停只显示「轨道 + 播放进度」细条（不可拖），鼠标进入后
/// 切换为完整 [Slider]（可拖动 seek，对齐常见桌面播放器「悬停展开」）。
/// 缓冲态：轨道位置叠一层 Material 的 LinearProgressIndicator（自带动画，
/// 主色片段往返流动，透明背景）；此时播放进度样式降为半透明，避免
/// 实心进度条盖住流动动画。交互不拦截（IgnorePointer），缓冲中仍可拖动。
///
/// 轨道对齐：简化条/缓冲层/完整 Slider 共用同一轨道矩形
/// （[SliderThemeData.trackShape] 的几何），保证悬停切换时轨道位置
/// 不跳变；不硬编码留白，避免与实际 Slider 轨道错位。
///
/// 布局注意：外层 SizedBox(height: 48) 锁定高度——Slider 须作为**非定位**
/// 子元素决定 Stack 尺寸；若全部子元素都是 Positioned，Stack 会取
/// constraints.biggest 撑满可用区域（如 Column 剩余高度），把播放页
/// 主体/控制区挤出屏幕。
library;

import 'package:flutter/material.dart';

class PlaybackSlider extends StatefulWidget {
  const PlaybackSlider({
    super.key,
    required this.value,
    required this.max,
    required this.buffering,
    this.onChanged,
    this.onChangeEnd,
  });

  final double value;
  final double max;

  /// 缓冲中：轨道叠加流动指示条（进度样式自动降透明）。
  final bool buffering;

  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<PlaybackSlider> createState() => _PlaybackSliderState();
}

class _PlaybackSliderState extends State<PlaybackSlider> {
  /// 悬停中：显示完整 Slider（可拖动）；否则简化细条。
  bool _hovered = false;

  /// 拖拽中：保持完整 Slider 不退出（修复「拖出轨道区域即中断」）——
  /// 鼠标拖到播放条外/远处时悬停态会退出，若此时把 Slider 换回简化细条，
  /// 其手势识别器被销毁、onChangeEnd 不触发，父级 _dragMs 残留在最后位置，
  /// 造成后续交互跳转异常（对齐原版 SSlider：pointer capture 期间持续生效）。
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: SizedBox(
        // 锁定高度：保证未悬停细条与悬停 Slider 同高，布局不跳动；
        // 同时约束 Stack 尺寸（防全 Positioned 时撑满可用区域）。
        height: 48,
        child: LayoutBuilder(
          builder: (context, c) {
            final rect = _trackRect(context, c.maxWidth, c.maxHeight);
            return (_hovered || _dragging)
                ? _buildSlider(scheme, rect)
                : _buildBar(scheme, rect);
          },
        ),
      ),
    );
  }

  /// 轨道矩形（对齐 SliderThemeData.trackShape 的几何）：
  /// 水平方向按 overlay/thumb 尺寸内缩，垂直居中。
  Rect _trackRect(BuildContext context, double width, double height) {
    final st = SliderTheme.of(context);
    final overlayW = st.overlayShape?.getPreferredSize(true, false).width ??
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

  /// 悬停态：完整 Slider + 缓冲流动层。
  Widget _buildSlider(ColorScheme scheme, Rect rect) {
    return Stack(
      alignment: Alignment.center,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            // 缓冲时进度轨道降为半透明：让流动动画凸显，不被实心
            // 进度覆盖（同色叠加会看不出缓冲）。
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

  /// 未悬停态：简化细条（轨道 + 播放进度）+ 缓冲流动层。
  Widget _buildBar(ColorScheme scheme, Rect rect) {
    final max = widget.max <= 0 ? 1.0 : widget.max;
    final ratio = (widget.value / max).clamp(0.0, 1.0);
    final trackColor = scheme.onSurface.withValues(alpha: 0.12);
    final progressColor = widget.buffering
        ? scheme.primary.withValues(alpha: 0.4)
        : scheme.primary;
    return Stack(
      alignment: Alignment.center,
      children: [
        // 轨道（灰底，几何与完整 Slider 一致）
        Positioned.fromRect(
          rect: rect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: ColoredBox(color: trackColor),
          ),
        ),
        // 播放进度（主色；缓冲时半透明，露出流动动画）
        Positioned.fromRect(
          rect: Rect.fromLTWH(rect.left, rect.top, rect.width * ratio, rect.height),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: ColoredBox(color: progressColor),
          ),
        ),
        if (widget.buffering) _bufferLayer(scheme, rect),
      ],
    );
  }

  /// 缓冲流动层：Material 自带动画（主色片段往返流动），透明背景，
  /// 覆盖在轨道/进度之上（后绘制）。IgnorePointer 保证不拦截拖动。
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
