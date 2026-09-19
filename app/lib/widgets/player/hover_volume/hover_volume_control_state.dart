// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../hover_volume_control.dart';

class _HoverVolumeSliderState extends ConsumerState<HoverVolumeSlider> {
  double _lastVolume = 0.7;
  bool _expanded = false;
  bool _sliderMounted = false;

  Timer? _openTimer;
  Timer? _hideTimer;

  @override
  void dispose() {
    _openTimer?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }

  /// 点按展开滑条并重置自动隐藏（点击展开没有 hover 退出事件，用定时器收起）。
  void _expand() {
    _openTimer?.cancel();
    _hideTimer?.cancel();
    if (!_expanded || !_sliderMounted) {
      setState(() {
        _expanded = true;
        _sliderMounted = true;
      });
    }
    _hideTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _expanded = false);
    });
  }

  void _onEnter(PointerEnterEvent _) {
    _hideTimer?.cancel();
    _openTimer?.cancel();
    _openTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      setState(() {
        _expanded = true;
        _sliderMounted = true;
      });
    });
  }

  void _onSliderHidden() {
    if (mounted) setState(() => _sliderMounted = false);
  }

  void _onExit(PointerExitEvent _) {
    _openTimer?.cancel();
    if (_expanded) {
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
      notifier.setVolume(_lastVolume > 0.001 ? _lastVolume : 0.7);
    } else {
      _lastVolume = vol;
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
                ? EtaIcons.volumeOff
                : (vol < 0.5 ? EtaIcons.volumeMute : EtaIcons.volume),
            size: 22,
            // 收起时点按 = 展开滑条；展开时点按 = 静音切换（鼠标/触摸通用）。
            onPressed: _expanded ? _toggleMute : _expand,
          ),
          if (_expanded || _sliderMounted)
            _SlideIn(
              visible: _expanded,
              onHidden: _onSliderHidden,
              child: SizedBox(
                width: widget.sliderWidth,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                  ),
                  child: Slider(
                    value: vol,
                    onChanged: (v) {
                      // 拖动期间不自动收起。
                      _hideTimer?.cancel();
                      ref.read(playbackProvider.notifier).previewVolume(v);
                    },
                    onChangeEnd: (v) {
                      ref.read(playbackProvider.notifier).setVolume(v);
                      _expand(); // 重新计时自动收起（无 hover 退出时也生效）
                    },
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

class _SlideIn extends StatefulWidget {
  const _SlideIn({
    required this.visible,
    required this.onHidden,
    required this.child,
  });

  final bool visible;
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
    _size = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
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
      alignment: Alignment.centerLeft,
      sizeFactor: _size,
      child: FadeTransition(opacity: _opacity, child: widget.child),
    );
  }
}
