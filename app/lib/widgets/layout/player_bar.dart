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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final notifier = ref.read(playbackProvider.notifier);
    final prefs = ref.watch(appPrefsProvider);
    // 选择性订阅低频字段（播放位置/FFT 每 50ms 更新，不重建播放条本体）
    final hasSource =
        ref.watch(playbackProvider.select((s) => s.source != null));
    final track = ref.watch(playbackProvider.select((s) => s.track));
    final title = ref.watch(playbackProvider.select((s) => s.title));
    final subtitle = ref.watch(playbackProvider.select((s) => s.subtitle));
    final buffering = ref.watch(playbackProvider.select((s) => s.buffering));
    final playing = ref.watch(playbackProvider.select((s) => s.playing));
    final hasQueue = ref.watch(playbackProvider.select((s) => s.hasQueue));
    // 有内容 = 引擎源（在播/加载）或有恢复的现场（会话记忆恢复的暂停队列，
    // source 为 null 但队列/位置就绪）：此时播放/切歌/打开播放页都应可用。
    final hasContent = hasSource || hasQueue;
    final floating = prefs.floatingPlayerBar;
    // 图片背景风格（有效时）：播放条恢复毛玻璃——0.7 高不透明底色
    // + BackdropFilter 模糊（对齐原版 footer 播放栏 blur16）；纯色风格
    // 走实底，不包模糊层
    final imageMode =
        prefs.appearanceStyle == 'image' && prefs.backgroundImage != null;
    // 播放条底色走扩展色（image 模式 = surfaceBright/0.7，纯色 = 面板实底）
    final chrome = Theme.of(context).extension<AppChromeColors>()!;

    // 内容：顶部进度条 + 主体行（两种模式共用，仅容器不同）
    // 注：source 可能为 null（播放条退出动画期间），文本做空串兜底
    final bar = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 22,
          // 进度条独立订阅位置/时长：50ms 更新只重建滑块，不重建整条
          child: PlaybackProgressSlider(
            dragMs: _dragMs,
            buffering: buffering,
            enabled: hasSource,
            onDragChanged: (v) => setState(() => _dragMs = v),
            onSeekEnd: (_) => setState(() => _dragMs = null),
          ),
        ),
        SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                // 左：封面（点击展开全屏播放器）+ 曲名/副标题（仅封面可点）
                Expanded(
                  child: Row(
                    children: [
                      Tooltip(
                        message: l10n.playerBarOpenPlayer,
                        child: _BarCover(
                          cover: track?.cover,
                          onTap: hasContent
                              ? () => context.push('/player')
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              // 标题缺失时不回退 source（引擎转码源=本地
                              // 绝对路径/在线 URL，不该作为展示标题）
                              title ?? l10n.playerBarUntitled,
                              style: theme.textTheme.titleSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              hasContent
                                  ? (buffering
                                        ? l10n.playerBarBuffering
                                        : (subtitle ?? ''))
                                  : l10n.playerBarIdleHint,
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 三键（居中主轴）：上一首/播放暂停/下一首。
                // 左右两侧均为弹性栏，保证三键严格居中。
                IconButton(
                  tooltip: l10n.commonPrevious,
                  onPressed: hasQueue
                      ? notifier.playPrevious
                      : null,
                  icon: const Icon(Icons.skip_previous),
                ),
                IconButton(
                  tooltip: buffering ? l10n.commonLoading : l10n.playerBarPlayPause,
                  onPressed: hasContent && !buffering ? notifier.toggle : null,
                  icon: buffering
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(playing ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  tooltip: l10n.commonNext,
                  onPressed: hasQueue
                      ? notifier.playNext
                      : null,
                  icon: const Icon(Icons.skip_next),
                ),
                // 右栏（弹性，右对齐）：时间与频谱 → 播放列表 → 红心
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 时间 + 迷你频谱
                        SizedBox(
                          width: 150,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              // 时间（独立订阅位置/时长，50ms 只重建本行）
                              Consumer(
                                builder: (context, ref, _) {
                                  final s = ref.watch(playbackProvider.select(
                                    (s) => (pos: s.position,
                                        dur: s.duration)));
                                  return Text(
                                    '${formatClock(s.pos)} / ${formatClock(s.dur)}',
                                    style: theme.textTheme.bodySmall,
                                  );
                                },
                              ),
                              const SizedBox(height: 4),
                              // 时间下方：播放条歌词（开关开且有歌词）→
                              // 迷你歌词；否则迷你频谱（barSpectrum 独立开关）
                              const SizedBox(
                                width: 120,
                                height: 12,
                                child: _BarInfoArea(),
                              ),
                            ],
                          ),
                        ),
                        // 音量：悬浮式控件（hover 800ms 展开滑条、5s 未操作
                        // 自动收起；独立 Consumer 订阅，不重建播放条本体）
                        const HoverVolumeSlider(sliderWidth: 72),
                        // 播放列表（锚定浮层，对齐顶栏账号菜单动效）
                        Builder(
                          builder: (btnCtx) => IconButton(
                            tooltip: l10n.playerBarPlaylist,
                            onPressed: hasQueue
                                ? () => QueuePanel.show(
                                      context,
                                      style: QueuePanelStyle.popup,
                                      anchor: _anchorOf(btnCtx),
                                    )
                                : null,
                            icon: const Icon(Icons.queue_music),
                          ),
                        ),
                        // 红心（当前曲目喜欢切换；仅可登录平台曲目显示）
                        if (track != null &&
                            (track.source == 'netease' ||
                                track.source == 'kugou'))
                          _BarLikeButton(track: track),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    // 内容容器（两种模式共用）
    final content = floating
        // 悬浮模式：底部居中圆角胶囊（阴影 + 毛玻璃/面板实底）
        //
        // 注意：不能用 Center 包裹——bottomNavigationBar 给子项的约束是
        // maxHeight = 窗口剩余高度，Center 无尺寸因子会撑满整窗（主界面被
        // 挤出、只剩播放条）；用 Align(heightFactor: 1) 把高度锁为内容高度，
        // 水平仍全宽居中。
        ? Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
            child: Align(
              alignment: Alignment.bottomCenter,
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Container(
                  // 阴影放在裁剪/模糊层外，避免被圆角裁剪掉
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  // image 模式毛玻璃：ClipRRect 先裁剪圆角，BackdropFilter
                  // 再模糊下方主界面（对齐原版 footer blur16）
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: _glass(imageMode, child: Material(
                      color: chrome.playerBarBackground,
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                        side: BorderSide(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.12)),
                      ),
                      child: SafeArea(top: false, child: bar),
                    )),
                  ),
                ),
              ),
            ),
          )
        // 默认模式：全宽停靠条（image 模式毛玻璃，纯色面板实底）
        : _glass(imageMode, child: Material(
            color: chrome.playerBarBackground,
            elevation: 8,
            child: SafeArea(child: bar),
          ));

    // 未播放时隐藏播放条（不占底部空间）；用 AnimatedSwitcher 做
    // 进入/退出动效（高度收缩 + 淡入淡出，对齐原版 PlayerBar 过渡）
    // 可见条件：有引擎源（source）或有恢复的现场（queue 非空，如「会话记忆」
    // 恢复的暂停会话——source 为 null 但队列/位置已就绪，播放条应显示）。
    final showBar = hasSource || hasQueue;
    return AnimatedSwitcher(
      duration: animDuration(context, const Duration(milliseconds: 250)),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.bottomCenter, // 底部对齐：向上展开/向下收起
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: showBar
          ? KeyedSubtree(
              key: const ValueKey('player-bar'),
              child: content,
            )
          : const SizedBox.shrink(key: ValueKey('player-bar-hidden')),
    );
  }
}

/// 播放条毛玻璃包裹层：image 模式下对下方主界面做 blur16 模糊（对齐原版
/// global.css footer 播放栏 backdrop-filter: blur(16px)）；纯色风格直通实底。
Widget _glass(bool imageMode, {required Widget child}) {
  if (!imageMode) return child;
  return BackdropFilter(
    filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
    child: child,
  );
}

/// 取触发按钮的全局矩形（锚定浮层用；未布局/脱离时返回 null）。
Rect? _anchorOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached) return null;
  return box.localToGlobal(Offset.zero) & box.size;
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
                duration: animDuration(context, const Duration(milliseconds: 200)),
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
      final ok = await ref
          .read(likeControllerProvider)
          .toggle(widget.track);
      if (!ok && mounted) {
        toast(
          widget.track.source == 'kugou'
              ? context.l10n.toastLoginRequiredKugou
              : context.l10n.toastLoginRequiredNetease,
          type: ToastType.error,
        );
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

/// 播放条时间下方的信息区（独立 Consumer 子树，避免位置/歌词高频更新
/// 重建播放条本体）：
///  - 「播放条歌词」开且当前曲有歌词 → 迷你歌词（原文 + 可选翻译，溢出滚动）
///  - 否则 → 迷你频谱（「播放条频谱」独立开关，与播放页频谱解耦）
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
      opacity: 0.15, // 迷你态弱化（对齐原版 0.65/0.15）
    );
  }
}
