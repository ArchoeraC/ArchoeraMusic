// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 整幅封面布局（`fullscreen`）：左侧封面铺满整页高度、右缘横向渐隐，
/// 曲目信息（标题/副标题）左对齐放在右侧歌词上方。
///
/// 参考 SPlayer-Next 的全屏封面：封面画在**页面层**（顶栏/底栏背后），
/// 主体只排右栏，避免与顶栏/底部控制互相挤压。
library;

import 'package:material_ui/material_ui.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../widgets/player/cover_switcher.dart';
import '../../../widgets/player/player_cover.dart';
import '../../../widgets/player/player_lyrics_block.dart';
import '../../../widgets/player/player_lyrics_slot.dart';
import 'player_layout.dart';

class PosterPlayerLayout extends PlayerLayout {
  const PosterPlayerLayout();

  static const String layoutId = 'fullscreen';

  /// 左侧封面占整页宽度的比例。
  static const double coverWidthFraction = 0.56;

  /// 右侧信息/歌词区的最小宽度（窗口过窄时收缩封面）。
  static const double lyricsMinWidth = 340;

  @override
  String get id => layoutId;

  @override
  Widget? buildBackdrop(BuildContext context, PlayerLayoutContext c) {
    if (c.fullscreenCoverWidth <= 0) return null;
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: c.fullscreenCoverWidth,
          child: RepaintBoundary(
            child: CoverSwitcher(
              coverKey: c.coverKey,
              slide: c.transitionStyle == 'slide',
              next: c.slideNext,
              child: PlayerFullscreenCover(cover: c.current?.cover),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget? buildScrims(BuildContext context, PlayerLayoutContext c) =>
      const _PosterScrims();

  @override
  Widget buildBody(BuildContext context, PlayerLayoutContext c) {
    return LayoutBuilder(
      builder: (context, box) {
        final lyricScale = (MediaQuery.sizeOf(context).height / 1080).clamp(
          0.85,
          1.6,
        );
        final coverInset =
            (c.fullscreenCoverWidth - kPlayerPageHorizontalPadding).clamp(
              0.0,
              box.maxWidth,
            );
        return RepaintBoundary(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: coverInset),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 2),
                    _PosterTrackInfo(
                      hasContent: c.hasContent,
                      title: c.title,
                      subtitle: c.subtitle,
                      l10n: c.l10n,
                    ),
                    const SizedBox(height: 22),
                    Expanded(
                      child: PlayerLyricsSlot(
                        visible: c.showLyrics,
                        enabled: c.contentMounted && c.hasLyrics,
                        builder: (context) => Padding(
                          padding: const EdgeInsets.only(right: 64),
                          child: RepaintBoundary(
                            child: PlayerLyricsBlock(
                              hasLyrics: c.hasLyrics,
                              lyricScale: lyricScale,
                              textAlign: lyricsAlign,
                              onSeek: c.onSeekLyric,
                              dragMs: c.dragMs,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 整幅封面布局的顶/底渐变遮罩（对齐原版 cover-mask）。
///
/// 该布局下封面铺满整页，顶栏与底部控件直接压在封面上，用轻微黑色渐变
/// 保证图标与文字在亮色封面上也可读；不拦截任何指针事件。
class _PosterScrims extends StatelessWidget {
  const _PosterScrims();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Column(
        children: [
          Container(
            height: 104,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.45),
                  Colors.black.withValues(alpha: 0),
                ],
              ),
            ),
          ),
          const Spacer(),
          Container(
            height: 220,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.55),
                  Colors.black.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 整幅封面布局下的曲目信息（右栏顶部，左对齐）。
///
/// 只保留标题与副标题，不附加来源/音质等额外信息；字号随窗口高度缩放，
/// 让标题在整幅封面旁仍有接近原版 PlayerData 的层级感。
class _PosterTrackInfo extends StatelessWidget {
  const _PosterTrackInfo({
    required this.hasContent,
    required this.title,
    required this.subtitle,
    required this.l10n,
  });

  final bool hasContent;
  final String title;
  final String subtitle;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vh = MediaQuery.sizeOf(context).height;
    final titleSize = (vh / 1080 * 30).clamp(22.0, 34.0);
    final subSize = (vh / 1080 * 15).clamp(12.0, 17.0);
    final heading = !hasContent
        ? l10n.playerPageNotPlaying
        : (title.isEmpty ? l10n.playerBarUntitled : title);
    final sub = hasContent ? subtitle : l10n.playerPageLoadHint;
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontSize: titleSize,
              height: 1.2,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: subSize,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
