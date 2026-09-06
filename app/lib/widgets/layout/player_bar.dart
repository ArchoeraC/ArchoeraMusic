// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../services/lyrics/lyric_line.dart';
import '../../stores/app_prefs.dart';
import '../../stores/providers.dart';
import '../../stores/lyrics_provider.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../list/cover_image.dart';
import '../player/bar_lyric_text.dart';
import '../player/hover_volume_control.dart';
import '../player/playback_progress_slider.dart';
import '../player/queue_panel.dart';
import '../player/spectrum_view.dart';
import '../common/toast.dart';
import '../common/anim.dart';

part 'player_bar/player_bar_view.dart';

/// 底部播放条（对齐原项目 PlayerBar.vue，应用壳常驻，§10.7）。
///
/// 布局：顶部进度条（拖动 seek，后端重启引擎）+
/// 主体行 = 左「封面 + 曲名/副标题」（点击展开全屏播放器）+ 播放控制
/// + 右「时间 + 迷你频谱」。
class PlayerBar extends ConsumerStatefulWidget {
  const PlayerBar({super.key});

  @override
  ConsumerState<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends ConsumerState<PlayerBar> {
  /// 拖动中的进度（ms）；null = 跟随播放器实时位置。
  double? _dragMs;

  @override
  Widget build(BuildContext context) => _buildPlayerBar(context);

  void _setDragMs(double? value) {
    setState(() => _dragMs = value);
  }

  void _clearDragMs() {
    setState(() => _dragMs = null);
  }
}

/// 播放条封面：悬浮时显示遮罩 + 上箭头（暗示点击展开播放页，
/// 对齐 SPlayer-Next TrackInfo 的 group-hover 效果）。
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
              // 悬浮遮罩 + 上箭头（200ms 过渡，对齐原版 group-hover）
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
                      Icons.keyboard_arrow_up,
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

/// 播放条红心按钮（当前曲目喜欢切换；失败提示）。
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
        liked ? Icons.favorite : Icons.favorite_border,
        color: liked ? Colors.redAccent : null,
      ),
    );
  }
}
