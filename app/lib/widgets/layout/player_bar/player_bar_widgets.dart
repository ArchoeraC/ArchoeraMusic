// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../player_bar.dart';

class _BarCover extends StatefulWidget {
  const _BarCover({this.cover, this.onTap});

  final String? cover;
  final VoidCallback? onTap;

  @override
  State<_BarCover> createState() => _BarCoverState();
}

class _BarCoverState extends State<_BarCover> {
  static const _size = 40.0;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              CoverImage(
                cover: widget.cover,
                width: _size,
                height: _size,
                radius: 8,
                iconSize: 22,
              ),
              AnimatedOpacity(
                opacity: _hovered ? 1 : 0,
                duration: animDuration(
                  context,
                  const Duration(milliseconds: 200),
                ),
                curve: Curves.easeOut,
                child: Container(
                  width: _size,
                  height: _size,
                  color: Colors.black.withValues(alpha: 0.4),
                  child: const Center(
                    child: Icon(
                      EtaIcons.upSmall,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarLikeButton extends ConsumerStatefulWidget {
  const _BarLikeButton({required this.track});

  final Track track;

  @override
  ConsumerState<_BarLikeButton> createState() => _BarLikeButtonState();
}

class _BarLikeButtonState extends ConsumerState<_BarLikeButton> {
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await ref.read(likeControllerProvider).toggle(widget.track);
      if (!ok && mounted) {
        toast(switch (widget.track.source) {
          'kugou' => context.l10n.toastLoginRequiredKugou,
          'qqmusic' => context.l10n.toastQqLikeSyncFailed,
          _ => context.l10n.toastLoginRequiredNetease,
        }, type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final liked = ref.watch(likeControllerProvider).isLiked(widget.track);
    return IconButton(
      tooltip: liked ? context.l10n.commonUnlike : context.l10n.commonLike,
      onPressed: _toggle,
      icon: Icon(
        liked ? EtaIcons.heart : EtaIcons.heartOutline,
        color: liked ? Colors.redAccent : null,
      ),
    );
  }
}

Widget _glass(bool imageMode, {required Widget child}) {
  if (!imageMode) return child;
  // ClipRect 把 BackdropFilter 的模糊限制在本控件范围内——否则模糊会作用到
  // 整个 backdrop 层（图片背景模式下会糊住上方全部主界面）。
  return ClipRect(
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: child,
    ),
  );
}

Rect? _anchorOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

class _BarInfoArea extends ConsumerWidget {
  const _BarInfoArea();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appPrefsProvider);
    final groups = ref
        .watch(currentLyricsProvider)
        .maybeWhen(data: (l) => l, orElse: () => const <LyricGroup>[]);
    if (prefs.barLyrics && groups.isNotEmpty) {
      return BarLyricText(height: 12);
    }
    return SpectrumView(
      enabled: prefs.barSpectrum,
      height: 12,
      barWidth: 2,
      radius: 1,
      color: Theme.of(context).colorScheme.primary,
      opacity: 0.15,
    );
  }
}
