import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../services/playback/playback_notifier.dart';
import 'ctrl_icon.dart';

/// 悬浮式音量控件（默认隐藏滑条，hover 展开）：
/// - 只显示音量图标；滑条默认收起
/// - 光标悬浮在整个音量组件上超过 800ms → 滑条展开
/// - 展开后鼠标移出且 5s 未操作 → 自动隐藏（期间重新悬浮则取消隐藏）
/// - 拖动中仅预览（引擎命令 80ms 合并、prefs 不落盘），松开落盘最终值
/// - 静音切换内置音量记忆（对齐 SPlayer-Next lastVolume；无记忆回退 0.7）
class HoverVolumeSlider extends ConsumerStatefulWidget {
  const HoverVolumeSlider({super.key, this.sliderWidth = 96});

  /// 展开时滑条的宽度（逻辑像素）。
  final double sliderWidth;

  @override
  ConsumerState<HoverVolumeSlider> createState() => _HoverVolumeSliderState();
}

class _HoverVolumeSliderState extends ConsumerState<HoverVolumeSlider> {
  /// 静音前的音量记忆（无记忆回退 0.7）。
  double _lastVolume = 0.7;

  /// 滑条目标状态（hover 800ms 后 true）。
  bool _expanded = false;

  /// 滑条是否在渲染树中（含退场动画期间）。
  ///
  /// 展开时置 true 挂载滑条；`_SlideIn` 退场动画（reverse）播放完会回调
  /// [onHidden] 再置 false 彻底移除——既保留进出场动效，又不占布局空间。
  bool _sliderMounted = false;

  Timer? _openTimer;
  Timer? _hideTimer;

  @override
  void dispose() {
    _openTimer?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }

  void _onEnter(PointerEnterEvent _) {
    // 重新悬浮：取消隐藏倒计时
    _hideTimer?.cancel();
    _openTimer?.cancel();
    // 悬浮超过 800ms 才展开（防止路过时误弹）
    _openTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      setState(() {
        _expanded = true;
        _sliderMounted = true;
      });
    });
  }

  /// 退场动画播放完（滑条完全收起）后彻底移除，不再占任何布局空间。
  void _onSliderHidden() {
    if (mounted) setState(() => _sliderMounted = false);
  }

  void _onExit(PointerExitEvent _) {
    _openTimer?.cancel();
    if (_expanded) {
      // 已展开：移出后 5s 未操作自动隐藏
      _hideTimer?.cancel();
      _hideTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _expanded = false);
      });
    }
  }

  void _toggleMute() {
    final vol = ref.read(playbackProvider.select((s) => s.volume));
    final notifier = ref.read(playbackProvider.notifier);
    if (vol <= 0.001) {
      // 静音中：恢复记忆音量
      // ignore: discarded_futures
      notifier.setVolume(_lastVolume > 0.001 ? _lastVolume : 0.7);
    } else {
      _lastVolume = vol;
      // ignore: discarded_futures
      notifier.setVolume(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final vol = ref.watch(playbackProvider.select((s) => s.volume));
    final muted = vol <= 0.001;
    return MouseRegion(
      onEnter: _onEnter,
      onExit: _onExit,
      cursor: SystemMouseCursors.click,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CtrlIcon(
            tooltip: muted ? l10n.volumeUnmute : l10n.volumeMute,
            icon: muted
                ? Icons.volume_off
                : (vol < 0.5 ? Icons.volume_down : Icons.volume_up),
            size: 22,
            onPressed: _toggleMute,
          ),
          // 滑条：hover 展开时挂载并播放水平展开动画（SizeTransition 布局
          // 随动画 0→N，收起后回调 onHidden 彻底移除——不占任何布局空间）。
          // 此前用 AnimatedContainer 宽度 0↔N 动画，在 Row 约束下会异常占
          // 位——把相邻控件（播放列表/红心）挤出、播放页整屏被挤掉，且表
          // 现为白色矩形。现由 _SlideIn 负责动画与移除，彻底避免该问题。
          if (_expanded || _sliderMounted)
            _SlideIn(
              visible: _expanded,
              onHidden: _onSliderHidden,
              child: SizedBox(
                width: widget.sliderWidth,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                  ),
                  child: Slider(
                    value: vol,
                    // 拖动中仅预览（引擎命令 80ms 合并，不打扰引擎；
                    // prefs 不落盘），松开时 setVolume 落盘最终值
                    onChanged: (v) =>
                        ref.read(playbackProvider.notifier).previewVolume(v),
                    onChangeEnd: (v) =>
                        ref.read(playbackProvider.notifier).setVolume(v),
                  ),
                ),
              ),
            ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

/// 水平进出场动画容器：展开时 SizeTransition 从音量图标向右平滑展开
/// （布局宽度 0→N 参与动画，非 transform 假动画），收起时反向收缩并在
/// 完全收起后回调 [onHidden]（供父级移除子树、不再占布局空间）。
class _SlideIn extends StatefulWidget {
  const _SlideIn({
    required this.visible,
    required this.onHidden,
    required this.child,
  });

  /// 目标可见状态：true → forward 展开，false → reverse 收起。
  final bool visible;

  /// 退场动画播放完（AnimationStatus.dismissed）时回调。
  final VoidCallback onHidden;

  final Widget child;

  @override
  State<_SlideIn> createState() => _SlideInState();
}

class _SlideInState extends State<_SlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _size;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _size =
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.addStatusListener(_onStatus);
    if (widget.visible) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_SlideIn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      if (widget.visible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) {
      widget.onHidden();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      axis: Axis.horizontal,
      // 左端固定：滑条贴着音量图标向右展开/向左收起
      alignment: Alignment.centerLeft,
      sizeFactor: _size,
      child: FadeTransition(opacity: _opacity, child: widget.child),
    );
  }
}
