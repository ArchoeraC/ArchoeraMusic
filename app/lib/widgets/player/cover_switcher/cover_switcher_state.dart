// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../cover_switcher.dart';

class _CoverSwitcherState extends State<CoverSwitcher>
    with SingleTickerProviderStateMixin {
  static const _scaleLeaveMs = 200;
  static const _scaleEnterMs = 350;
  static const _slideLeaveMs = 350;
  static const _slideEnterMs = 400;

  late final AnimationController _ctrl;
  Widget _shown = const SizedBox.shrink();
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _shown = widget.child;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _scaleEnterMs),
    )..addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(CoverSwitcher old) {
    super.didUpdateWidget(old);
    if (widget.coverKey != old.coverKey) {
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
        _ctrl.stop();
        _leaving = false;
        _shown = widget.child;
        return;
      }
      _leaving = true;
      _ctrl.duration = Duration(
        milliseconds: widget.slide ? _slideLeaveMs : _scaleLeaveMs,
      );
      _ctrl.forward(from: 0);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!_leaving) return;
    _leaving = false;
    setState(() => _shown = widget.child);
    _ctrl.duration = Duration(
      milliseconds: widget.slide ? _slideEnterMs : _scaleEnterMs,
    );
    _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        final posT = _leaving
            ? Curves.ease.transform(t)
            : Curves.easeOutExpo.transform(t);
        final opT = Curves.ease.transform(t);
        return LayoutBuilder(
          builder: (context, c) {
            final width = c.maxWidth;
            final double dx;
            final double opacity;
            if (_leaving) {
              final dir = widget.next ? -1.0 : 1.0;
              dx = widget.slide ? dir * width * posT : -10.0 * posT;
              opacity = 1 - opT;
            } else if (_ctrl.isAnimating) {
              final dir = widget.next ? 1.0 : -1.0;
              dx = widget.slide ? dir * width * (1 - posT) : 10.0 * (1 - posT);
              opacity = opT;
            } else {
              dx = 0;
              opacity = 1;
            }
            return Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(dx, 0),
                child: (!_leaving && !_ctrl.isAnimating)
                    ? widget.child
                    : _shown,
              ),
            );
          },
        );
      },
    );
  }
}
