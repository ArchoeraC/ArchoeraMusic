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
          'neko' => context.l10n.toastLoginRequiredNeko,
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
  // ClipRect 把毛玻璃的模糊限制在本控件范围内——否则模糊会作用到
  // 整个 backdrop 层（图片背景模式下会糊住上方全部主界面）。
  // 性能模式下 GlassBlur 走无模糊降级（child 的 Material 底色即填充）。
  return ClipRect(child: GlassBlur(sigma: 16, child: child));
}

Rect? _anchorOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// 播放条迷你信息区（迷你歌词 / 迷你频谱）高度：需容纳 11px 字号 1.2 行高
/// 的拉丁升/降部，否则英文等字形会被裁切。
const double _barInfoHeight = 15;

class _BarInfoSlot extends ConsumerWidget {
  const _BarInfoSlot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appPrefsProvider);
    final groups = ref
        .watch(currentLyricsProvider)
        .maybeWhen(data: (l) => l, orElse: () => const <LyricGroup>[]);
    // 迷你歌词优先；无歌词（或关闭播放条歌词）时退化为迷你频谱；两者都
    // 不可用 → 零尺寸（父级 AnimatedSize 收起占位，时间随之上移居中）。
    final showLyrics = prefs.barLyrics && groups.isNotEmpty;
    final showSpectrum =
        !showLyrics && prefs.barSpectrum && !prefs.performanceMode;
    if (!showLyrics && !showSpectrum) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        width: 120,
        height: _barInfoHeight,
        child: RepaintBoundary(
          child: showLyrics
              ? const BarLyricText(height: _barInfoHeight)
              : Center(
                  child: SpectrumView(
                    enabled: true,
                    height: 12,
                    barWidth: 2,
                    radius: 1,
                    color: Theme.of(context).colorScheme.primary,
                    opacity: 0.15,
                  ),
                ),
        ),
      ),
    );
  }
}

/// 播放来源小角标（对齐上游 player.showPlaybackSource）。
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }
}
