// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 默认布局：封面 + 歌词左右分栏（宽度按 `coverLyricRatio`）。
///
/// 与加入布局注册表之前逐像素一致：封面卡片按左栏比例居中（无歌词时自动
/// 居中位移），右侧歌词槽负责滑入/滑出与卸载。
library;

import 'package:material_ui/material_ui.dart';

import '../../../widgets/common/anim.dart';
import '../../../widgets/player/cover_switcher.dart';
import '../../../widgets/player/player_cover.dart';
import '../../../widgets/player/player_lyrics_block.dart';
import '../../../widgets/player/player_lyrics_slot.dart';
import 'player_layout.dart';

class SplitPlayerLayout extends PlayerLayout {
  const SplitPlayerLayout();

  static const String layoutId = 'default';

  @override
  String get id => layoutId;

  @override
  Widget buildBody(BuildContext context, PlayerLayoutContext c) {
    return LayoutBuilder(
      builder: (context, box) {
        // 歌词字号/行高按窗口高度自适应（与布局无关）。
        final lyricScale = (MediaQuery.sizeOf(context).height / 1080).clamp(
          0.85,
          1.6,
        );
        final coverByWidth = box.maxWidth * c.coverLyricRatio * 0.85;
        final coverByHeight = box.maxHeight * 0.5;
        final size =
            (coverByWidth < coverByHeight ? coverByWidth : coverByHeight).clamp(
              180.0,
              520.0,
            );
        // 无歌词时封面自动居中。
        final coverCentered =
            c.autoCenterCover && !(c.showLyrics && c.hasLyrics);
        final coverBlock = PlayerCoverBlock(
          size: size,
          current: c.current,
          hasContent: c.hasContent,
          title: c.title,
          subtitle: c.subtitle,
          playing: c.playing,
          pulse: c.coverPulse,
          beatStrength: c.beatStrength,
          l10n: c.l10n,
        );
        // 歌词块由 PlayerLyricsSlot 管理显隐/滑入滑出（进入动画结束后才挂载，
        // 对齐原版 lyricMounted；关闭时向下滑出并在动画结束后卸载）。
        return RepaintBoundary(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                width: box.maxWidth * c.coverLyricRatio,
                child: AnimatedSlide(
                  offset: coverCentered
                      ? const Offset(11 / 18, 0)
                      : Offset.zero,
                  duration: animDuration(
                    context,
                    const Duration(milliseconds: 600),
                  ),
                  curve: Curves.easeOutCubic,
                  child: Align(
                    alignment: Alignment.center,
                    child: RepaintBoundary(
                      child: CoverSwitcher(
                        coverKey: c.coverKey,
                        slide: c.transitionStyle == 'slide',
                        next: c.slideNext,
                        child: coverBlock,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: box.maxWidth * (1 - c.coverLyricRatio),
                child: PlayerLyricsSlot(
                  visible: c.showLyrics,
                  enabled: c.contentMounted && c.hasLyrics,
                  builder: (context) => Padding(
                    padding: const EdgeInsets.only(right: 64),
                    child: RepaintBoundary(
                      child: PlayerLyricsBlock(
                        hasLyrics: c.hasLyrics,
                        lyricScale: lyricScale,
                        onSeek: c.onSeekLyric,
                        dragMs: c.dragMs,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
