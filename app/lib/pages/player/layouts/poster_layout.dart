// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 整幅封面布局（`fullscreen`）：左侧封面铺满整页高度、右缘横向渐隐，
/// 曲目信息（标题/副标题）左对齐放在右侧歌词上方。
///
/// 几何对齐 SPlayer-Next `FullCoverLayout`：封面绘制宽度为整页的
/// [PosterPlayerLayout.coverWidthFraction]（60%），右缘的**多段非线性 alpha
/// 渐变**在该宽度内缓缓收零；文字/歌词列从整页
/// [PosterPlayerLayout.textStartFraction]（50%）处开始——渐隐尾部延伸到
/// 文字列下方，不被一条与文字对齐的竖线截断。
///
/// 该布局下**歌词不可关闭**（对齐 SPlayer：全屏封面没有隐藏歌词的入口，
/// 顶栏歌词开关禁用）：有歌词时歌词常驻右栏，无歌词时显示占位提示。
///
/// 封面画在**页面层**（顶栏/底栏背后），主体只排右栏，避免与顶栏/底部
/// 控制互相挤压。
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

  /// 封面绘制宽度占整页宽度的比例（右缘渐变在此收零；对齐 SPlayer `w-[60%]`）。
  static const double coverWidthFraction = 0.60;

  /// 文字/歌词列起点占整页宽度的比例（对齐 SPlayer 右列 `w-1/2`）。
  ///
  /// 渐隐尾部（50%→60%）延伸到文字列下方；起点处封面 alpha 已降到 ≈0.5
  /// 且继续下降，不足以明显影响可读性。
  static const double textStartFraction = 0.50;

  /// 文字/歌词列的最小宽度（窗口过窄时兜底）。
  static const double lyricsMinWidth = 340;

  @override
  String get id => layoutId;

  /// 全屏封面布局：歌词不可关闭（顶栏歌词开关禁用，见库注释）。
  @override
  bool get lyricsToggleable => false;

  /// 歌词靠左对齐：与顶栏曲目信息共享视觉左缘（封面强不对称构图下，
  /// 居中会在右栏再造一个对称中心，信息块与歌词两条轴线对不上）。
  @override
  TextAlign get lyricsAlign => TextAlign.left;

  @override
  Widget? buildBackdrop(BuildContext context, PlayerLayoutContext c) {
    if (c.fullscreenCoverWidth <= 0) return null;
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: c.fullscreenCoverWidth.clamp(0.0, c.pageWidth),
          child: RepaintBoundary(
            child: CoverSwitcher(
              coverKey: c.coverKey,
              style: c.transitionStyle,
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
        // 文字/歌词列从整页 50% 处开始（渐隐尾部延伸到其下方）。
        final coverInset =
            (c.pageWidth * textStartFraction - kPlayerPageHorizontalPadding)
                .clamp(0.0, box.maxWidth);
        final info = _PosterTrackInfo(
          hasContent: c.hasContent,
          title: c.title,
          subtitle: c.subtitle,
          l10n: c.l10n,
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
                    info,
                    const SizedBox(height: 22),
                    Expanded(
                      // 全屏封面布局歌词不可关闭：有歌词常驻；无歌词时滑出
                      // 露出居中占位（对齐 SPlayer 右栏「暂无歌词」）。
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // 占位仅在内容挂载后出现（对齐 SPlayer 的
                          // lyricMounted 条件）：进入动画期间保持素底。
                          if (c.contentMounted && !c.hasLyrics)
                            _NoLyricsHint(l10n: c.l10n),
                          PlayerLyricsSlot(
                            visible: true,
                            enabled: c.contentMounted && c.hasLyrics,
                            builder: (context) => Padding(
                              // 右栏原本留 64px，全屏封面模式下歌词偏窄；收到 24px。
                              padding: const EdgeInsets.only(right: 24),
                              child: RepaintBoundary(
                                child: PlayerLyricsBlock(
                                  hasLyrics: c.hasLyrics,
                                  lyricScale: lyricScale,
                                  textAlign: lyricsAlign,
                                  fadeEdges: true,
                                  onSeek: c.onSeekLyric,
                                  dragMs: c.dragMs,
                                ),
                              ),
                            ),
                          ),
                        ],
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

/// 无歌词时的居中占位（对齐 SPlayer 全屏封面右栏的「暂无歌词」）。
class _NoLyricsHint extends StatelessWidget {
  const _NoLyricsHint({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        l10n.commonNoLyrics,
        style: TextStyle(
          color: scheme.onSurface.withValues(alpha: 0.35),
          fontSize: 16,
        ),
      ),
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
    // 对齐 SPlayer-Next `.cover-mask-top/.cover-mask-bottom`：多段非线性
    // alpha（不是 0.5→0 的线性渐变），避免暗色渐变出现色阶/硬边。
    const stops = [0.0, 0.12, 0.25, 0.40, 0.55, 0.70, 0.85, 1.0];
    const alphas = [0.50, 0.44, 0.36, 0.27, 0.18, 0.10, 0.04, 0.0];
    List<Color> colorsOf() => [
      for (final a in alphas) Colors.black.withValues(alpha: a),
    ];
    return IgnorePointer(
      child: Column(
        children: [
          // 80px（SPlayer `h-20`）。
          Container(
            height: 80,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: colorsOf(),
                stops: stops,
              ),
            ),
          ),
          const Spacer(),
          // 192px（SPlayer `h-48`）。
          Container(
            height: 192,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: colorsOf(),
                stops: stops,
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
      padding: const EdgeInsets.only(left: 4, right: 24),
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
