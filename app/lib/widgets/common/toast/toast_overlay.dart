// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../toast.dart';

extension _ToastOverlayView on ToastOverlay {
  Widget _buildToastOverlay(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          top: 24,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: ListenableBuilder(
              listenable: toastController,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in toastController.items)
                    _ToastItemView(key: ValueKey(item.id), item: item),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ToastItemView extends StatefulWidget {
  const _ToastItemView({super.key, required this.item});

  final ToastItem item;

  @override
  State<_ToastItemView> createState() => _ToastItemViewState();
}

class _ToastItemViewState extends State<_ToastItemView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  late final CurvedAnimation _in = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
  );
  late final CurvedAnimation _out = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeIn,
    reverseCurve: Curves.easeIn,
  );

  bool get _leaving => widget.item.leaving;
  bool _noAnim = false;

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
    toastController.addListener(_onControllerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if ((MediaQuery.maybeDisableAnimationsOf(context) ?? false) &&
        _ctrl.value < 1) {
      _ctrl.value = 1;
    }
  }

  @override
  void dispose() {
    toastController.removeListener(_onControllerChanged);
    _ctrl.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_leaving) {
      if (_noAnim) {
        toastController.remove(widget.item.id);
        return;
      }
      if (!_ctrl.isAnimating && _ctrl.value >= 1) {
        _ctrl.reverse().then((_) {
          if (mounted) toastController.remove(widget.item.id);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _noAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final v = _leaving ? _out.value : _in.value;
        final dy = _leaving ? -16 * (1 - v) : 16 * (1 - v);
        return Opacity(
          opacity: v,
          child: Transform.translate(offset: Offset(0, dy), child: child),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: scheme.surfaceBright,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _borderColor, width: 1.2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_typeIcon, size: 16, color: _iconColor),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.item.message,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const Color _warnColor = Color(0xFF6B4A1F);

  IconData get _typeIcon => switch (widget.item.type) {
    ToastType.success => Icons.check_circle_outline,
    ToastType.error => Icons.error_outline,
    ToastType.warning => Icons.warning_amber_outlined,
    ToastType.default_ || ToastType.info => Icons.info_outline,
  };

  Color get _iconColor {
    final scheme = Theme.of(context).colorScheme;
    return switch (widget.item.type) {
      ToastType.warning => _warnColor,
      ToastType.error => scheme.error,
      ToastType.success ||
      ToastType.default_ ||
      ToastType.info => scheme.primary,
    };
  }

  Color get _borderColor {
    final scheme = Theme.of(context).colorScheme;
    return switch (widget.item.type) {
      ToastType.success => scheme.primary.withValues(alpha: 0.55),
      ToastType.warning => _warnColor,
      ToastType.error => scheme.error.withValues(alpha: 0.6),
      ToastType.default_ ||
      ToastType.info => scheme.primary.withValues(alpha: 0.45),
    };
  }
}
