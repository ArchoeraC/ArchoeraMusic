import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/lyrics/lyric_line.dart';
import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/app_prefs.dart';
import '../stores/lyrics_provider.dart';
import '../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../widgets/list/cover_image.dart';
import '../widgets/dialogs/comment_dialog.dart';
import '../widgets/player/cover_switcher.dart';
import '../widgets/player/ctrl_icon.dart';
import '../widgets/player/hover_volume_control.dart';
import '../widgets/player/lyrics_view.dart';
import '../widgets/player/playback_progress_slider.dart';
import '../widgets/player/quality_menu.dart';
import '../widgets/player/queue_panel.dart';
import '../widgets/player/spectrum_view.dart';
import '../widgets/common/toast.dart';
import '../widgets/common/anim.dart';

/// 全屏播放器覆盖层（对齐原项目 FullPlayer/index.vue）。
///
/// 入口：点击底部播放条封面/标题区（`/player` 顶层路由，盖住整个壳）。
/// 布局：顶部（关闭 + 曲名 + 音质）→ 主体（封面 + 歌词区左右分栏，
/// §10.2 LyricsView）→ 频谱 → 进度条 → 控制。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with SingleTickerProviderStateMixin {
  /// 拖动中的进度（ms）；null = 跟随播放器实时位置。
  double? _dragMs;

  /// 切歌方向（slide 样式用）：播放顺序递增 = 下一首（新封面从右进），
  /// 递减 = 上一首（从左进）。对齐原版 watch(playIndex) 判定。
  bool _slideNext = true;

  /// 底部播放控件（进度条+控制区）是否可见。事件驱动：鼠标移动/点击/
  /// 滚轮任意操作都会重置 5 秒倒计时（监听 PointerHover 事件，非轮询），
  /// 倒计时结束后淡出控件。
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// 封面节拍脉冲动画：鼓点命中 → forward(from: 0) 驱动 1 → 1.03 → 1 回弹。
  /// 脉冲检测在 C 引擎（fft.c detect_beat 三频段）完成，Dart 侧消费
  /// FftFrame.beatStrength（0~1）区分脉冲大小。
  late final AnimationController _coverPulse;

  /// 最近一次脉冲强度（0~1；脉冲按此缩放幅度，无脉冲帧不更新）。
  double _lastBeatStrength = 1;

  void _pokeControls() {
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _coverPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _coverPulse.dispose();
    super.dispose();
  }

  /// 当前曲目可选的音质档（酷狗按实际 hash 过滤；网易云全档位，
  /// VIP 限制由解析层决定）。
  static List<String> _availableLevels(Track? track) {
    const levels = ['lq', 'sq', 'hq', 'lossless', 'hi-res'];
    if (track == null) return const ['hq'];
    if (track.source == 'kugou' && track.kugou != null) {
      return levels.where((l) => track.kugou!.hashFor(l) != null).toList();
    }
    return levels;
  }

  /// 红心切换（当前曲目；失败提示）。
  Future<void> _toggleLike(Track track) async {
    final l10n = context.l10n;
    final ok = await ref.read(likeControllerProvider).toggle(track);
    if (!ok && mounted) {
      toast(
        track.source == 'kugou' ? l10n.toastLoginRequiredKugou : l10n.toastLoginRequiredNetease,
        type: ToastType.error,
      );
    }
  }

  /// 节拍脉冲增量：0→0.5 冲至峰值，0.5→1 回落到 0。峰值随脉冲强度
  /// 区分（[beatStrength] 0~1）：弱脉冲（~0.25）≈0.6%，强脉冲（1.0）
  /// ≈2.4%——鼓点越猛缩放越明显，高频合成音瞬态也有小幅脉冲。
  double _pulseDelta(double t) {
    final peak = 0.002 + 0.022 * _lastBeatStrength;
    if (t <= 0.5) return peak * (t / 0.5);
    return peak * (1 - (t - 0.5) / 0.5);
  }

  // ── 主体分区（缩减 build 嵌套，按职责拆分）────────────────

  /// 封面块：封面大图 + 下方曲名/副标题（对齐 PlayerData）。
  ///
  /// 缩放：播放 1.0 / 暂停 0.9（对齐原版 PlayerCover scale-100/scale-90，
  /// 500ms 弹性过渡），之上叠加节拍脉冲（设置开启时鼓点命中轻微放大回弹）。
  Widget _buildCoverBlock({
    required double size,
    required ColorScheme colorScheme,
    required Track? current,
    required bool hasContent,
    required String? title,
    required String? subtitle,
    required AppLocalizations l10n,
    required bool playing,
  }) {
    final theme = Theme.of(context);
    final cover = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: CoverImage(
        cover: current?.cover,
        width: size,
        height: size,
        radius: 24,
        iconSize: 110,
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedScale(
          scale: playing ? 1.0 : 0.9,
          duration: animDuration(context, const Duration(milliseconds: 500)),
          curve: Curves.easeOutBack,
          child: AnimatedBuilder(
            animation: _coverPulse,
            builder: (context, child) => Transform.scale(
              scale: 1 + _pulseDelta(_coverPulse.value),
              child: child,
            ),
            child: cover,
          ),
        ),
        const SizedBox(height: 20),
        // 曲名（标题缺失时显示占位，不回退 source 的本地绝对路径/在线 URL）
        Text(
          hasContent
              ? (title ?? l10n.playerBarUntitled)
              : l10n.playerPageNotPlaying,
          style: theme.textTheme.titleLarge,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        // 副标题（歌手等）
        Text(
          hasContent ? (subtitle ?? '') : l10n.playerPageLoadHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// 歌词区（当前行居中高亮 + 点击 seek）：Consumer 独立订阅位置/
  /// 歌词/样式，50ms 更新只重建本区。
  Widget _buildLyricsBlock({
    required bool hasLyrics,
    required double lyricScale,
    required PlaybackNotifier notifier,
    required bool hasSource,
    required ColorScheme colorScheme,
  }) {
    if (!hasLyrics) {
      return Center(
        child: Icon(
          Icons.lyrics_outlined,
          size: 64,
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
        ),
      );
    }
    return ClipRect(
      child: Consumer(
        builder: (context, ref, _) {
          final pos = ref.watch(
            playbackProvider.select((s) => s.position.inMilliseconds),
          );
          final groups = ref
              .watch(currentLyricsProvider)
              .maybeWhen(data: (l) => l, orElse: () => const <LyricGroup>[]);
          final prefs = ref.watch(appPrefsProvider);
          return LyricsView(
            groups: groups,
            positionMs: pos,
            fontSize: prefs.lyricFontSize * lyricScale,
            lineHeight: prefs.lyricLineHeight * lyricScale,
            playedColor: Color(prefs.lyricPlayedColor),
            unplayedColor: Color(prefs.lyricUnplayedColor),
            showTranslation: prefs.showTranslation,
            onSeek: hasSource
                ? (ms) => notifier.seek(Duration(milliseconds: ms))
                : null,
          );
        },
      ),
    );
  }

  /// 底部控制区：左组（红心）- 中组（播放键居中）- 右组（播放列表）。
  Widget _buildControlsRow({
    required ColorScheme colorScheme,
    required AppLocalizations l10n,
    required PlaybackNotifier notifier,
    required bool hasContent,
    required bool hasQueue,
    required bool canLike,
    required bool liked,
    required Track? current,
    required bool shuffle,
    required String repeatMode,
    required bool playing,
    required bool buffering,
  }) {
    return Row(
      children: [
        // 左组（左对齐）：红心
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              if (canLike)
                CtrlIcon(
                  tooltip: liked ? l10n.commonUnlike : l10n.commonLike,
                  icon: liked ? Icons.favorite : Icons.favorite_border,
                  size: 24,
                  color: liked ? Colors.redAccent : colorScheme.onSurfaceVariant,
                  onPressed: () => _toggleLike(current!),
                ),
            ],
          ),
        ),
        // 中组：控制行 随机 | 上一首 | 播放 | 下一首 | 循环
        SizedBox(
          width: 380,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CtrlIcon(
                tooltip: shuffle ? l10n.queueShuffleOff : l10n.queueShuffle,
                icon: Icons.shuffle,
                size: 20,
                color: shuffle ? colorScheme.primary : colorScheme.onSurfaceVariant,
                onPressed: hasContent ? notifier.toggleShuffle : null,
              ),
              const SizedBox(width: 12),
              CtrlIcon(
                tooltip: l10n.commonPrevious,
                icon: Icons.skip_previous,
                size: 26,
                color: colorScheme.onSurface,
                onPressed: hasQueue ? notifier.playPrevious : null,
              ),
              const SizedBox(width: 14),
              // 播放/暂停：主轴中心（透明底 + 填充圆 icon）
              Tooltip(
                message: buffering
                    ? l10n.commonLoading
                    : (playing ? l10n.commonPause : l10n.commonPlay),
                child: InkResponse(
                  radius: 28,
                  onTap: hasContent && !buffering ? notifier.toggle : null,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(
                          playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          size: 48,
                          color: colorScheme.primary.withValues(
                            alpha: buffering ? 0.35 : 1,
                          ),
                        ),
                        if (buffering)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              CtrlIcon(
                tooltip: l10n.commonNext,
                icon: Icons.skip_next,
                size: 26,
                color: colorScheme.onSurface,
                onPressed: hasQueue ? notifier.playNext : null,
              ),
              const SizedBox(width: 12),
              CtrlIcon(
                tooltip: repeatMode == 'list'
                    ? l10n.queueRepeatList
                    : l10n.queueRepeatOne,
                icon: repeatMode == 'one' ? Icons.repeat_one : Icons.repeat,
                size: 20,
                color: colorScheme.primary,
                onPressed: hasContent ? notifier.cycleRepeatMode : null,
              ),
            ],
          ),
        ),
        // 右组（右对齐）：音量（滑条 + 静音）→ 播放列表
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // 音量：悬浮式控件（hover 800ms 展开滑条，5s 未操作自动
              // 收起；独立 Consumer 订阅，拖动不重建整页）
              const HoverVolumeSlider(sliderWidth: 104),
              CtrlIcon(
                tooltip: l10n.playerBarPlaylist,
                icon: Icons.queue_music,
                size: 24,
                onPressed: hasQueue
                    ? () => QueuePanel.show(context, style: QueuePanelStyle.slide)
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final notifier = ref.read(playbackProvider.notifier);
    // 选择性订阅：播放位置/FFT 每 50ms 变化，顶层 watch 整个状态会让整页
    // 20Hz 全量重建（相对 Electron 卡顿的主因）。这里只订阅低频字段，
    // 位置/时长下沉到各自的 Consumer（进度行 / 歌词区）。
    final hasSource = ref.watch(
      playbackProvider.select((s) => s.source != null),
    );
    final source = ref.watch(playbackProvider.select((s) => s.source));
    final current = ref.watch(playbackProvider.select((s) => s.track));
    final title = ref.watch(playbackProvider.select((s) => s.title));
    final subtitle = ref.watch(playbackProvider.select((s) => s.subtitle));
    final quality = ref.watch(playbackProvider.select((s) => s.quality));
    final buffering = ref.watch(playbackProvider.select((s) => s.buffering));
    final playing = ref.watch(playbackProvider.select((s) => s.playing));
    final shuffle = ref.watch(playbackProvider.select((s) => s.shuffle));
    final repeatMode = ref.watch(playbackProvider.select((s) => s.repeatMode));
    final hasQueue = ref.watch(playbackProvider.select((s) => s.hasQueue));
    // 有内容 = 引擎源（在播/加载）或有恢复的现场（会话记忆恢复的暂停队列，
    // source 为 null 但队列/位置就绪）：播放/切歌/模式切换应可用。
    final hasContent = hasSource || hasQueue;
    // 切歌方向（slide 样式用）：队列索引递增 = 下一首，递减 = 上一首。
    // 在切歌（封面 key 变化）之前先于队列索引变化触发，方向先就位。
    ref.listen(playbackProvider.select((s) => s.queueIndex), (prev, next) {
      if (prev != null && prev != next) {
        _slideNext = next > prev;
      }
    });
    // 封面节拍脉冲：消费 C 引擎脉冲强度（FftFrame.beatStrength，0~1，
    // 位置事件驱动 50ms 更新）。强度 > 0 才触发动画（不 setState 不重建
    // 页面）；回调内实时读偏好——性能模式/开关关闭时直接跳过。
    ref.listen(playbackProvider.select((s) => s.fft), (prev, next) {
      final p = ref.read(appPrefsProvider);
      if (!p.coverBeatScale || p.performanceMode) return;
      final strength = next?.beatStrength ?? 0;
      if (strength <= 0) return;
      _lastBeatStrength = strength;
      _coverPulse.forward(from: 0);
    });
    final canLike =
        current != null &&
        (current.source == 'netease' || current.source == 'kugou');
    final liked = canLike
        ? ref.watch(likeControllerProvider).isLiked(current)
        : false;

    // 播放器内歌词显示偏好（顶栏歌词开关 + 设置页「播放器内歌词」共用）。
    final prefs = ref.watch(appPrefsProvider);
    final showLyrics = prefs.showLyricsInPlayer;
    final transitionStyle = prefs.transitionStyle;
    final hasLyrics = ref
        .watch(currentLyricsProvider)
        .maybeWhen(data: (l) => l.isNotEmpty, orElse: () => false);

    return Scaffold(
      // 事件驱动（无轮询）：鼠标移动/点击/滚轮都会重置底部控件的
      // 5 秒隐藏倒计时；行为用 translucent 让整页（含无命中子件区域）
      // 都能收到事件。
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerHover: (_) => _pokeControls(),
        onPointerDown: (_) => _pokeControls(),
        onPointerSignal: (_) => _pokeControls(),
        child: Stack(
          children: [
            // 背景渐变（对齐 FullPlayer PlayerBackground：暗色氛围）。
            // 终点色用 AppChromeColors.playerBackground（恒为面板实底）——
            // 播放界面完全不跟随图片背景设定，image 风格下也不半透明透出背景图。
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colorScheme.primary.withValues(alpha: 0.28),
                      Theme.of(
                            context,
                          ).extension<AppChromeColors>()?.playerBackground ??
                          colorScheme.surface,
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    // 顶部：关闭 + 音质（曲名信息放封面下方，对齐原版顶栏）
                    SizedBox(
                      height: 56,
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: l10n.playerBarCollapsePlayer,
                            onPressed: () => context.pop(),
                            icon: const Icon(Icons.keyboard_arrow_down),
                            iconSize: 32,
                          ),
                          const SizedBox(width: 4),
                          // 歌词开关（对齐 FullPlayer 顶栏：有歌词可切换，
                          // 无歌词禁用；开 = 主色高亮）
                          Tooltip(
                            message: showLyrics ? l10n.playerBarHideLyrics : l10n.playerBarShowLyrics,
                            child: InkResponse(
                              radius: 24,
                              onTap: hasLyrics
                                  ? () => ref
                                        .read(appPrefsProvider.notifier)
                                        .setShowLyricsInPlayer(!showLyrics)
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Icon(
                                  Icons.lyrics_outlined,
                                  size: 26,
                                  color:
                                      (showLyrics
                                              ? colorScheme.primary
                                              : colorScheme.onSurfaceVariant)
                                          .withValues(
                                            alpha: hasLyrics ? 1 : 0.35,
                                          ),
                                ),
                              ),
                            ),
                          ),
                          const Spacer(),
                          // 歌曲评论（仅网易云/酷狗源，与红心同条件）
                          if (canLike)
                            Tooltip(
                              message: l10n.menuComment,
                              child: IconButton(
                                onPressed: () =>
                                    showCommentDialog(context, track: current),
                                icon: const Icon(Icons.mode_comment_outlined),
                              ),
                            ),
                          // 音质选择（右侧）
                          if (current != null)
                            QualityMenu(
                              levels: _availableLevels(current),
                              current: quality,
                              onSelected: notifier.setQuality,
                            ),
                        ],
                      ),
                    ),
                    // 主体：左 45% 封面 + 曲目信息、右 55% 歌词区
                    // （对齐原版 FullPlayer 左右分栏；保留自适应缩放）
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, c) {
                          // 封面自适应：min(左区 85%, 主体高 50%)，下限 180
                          // （对齐原版 clamp(200px, 85%, 50vh)：随窗口放大，
                          // 最大化下封面同样变大，不封死 320）
                          final coverByWidth = c.maxWidth * 0.45 * 0.85;
                          final coverByHeight = c.maxHeight * 0.5;
                          final size =
                              (coverByWidth < coverByHeight
                                      ? coverByWidth
                                      : coverByHeight)
                                  .clamp(180.0, 520.0);
                          // 歌词字号/行高按窗口高度自适应（对齐原版
                          // calc(fontSize / 1080 * 100vh)：基准 1080 高 = 1x，
                          // 最大化下歌词同样放大；下限防缩得过小）
                          final lyricScale =
                              (MediaQuery.sizeOf(context).height / 1080).clamp(
                                0.85,
                                1.6,
                              );

                          // 封面切换动效身份（对齐原版 :key="track.id"）：
                          // 在线曲目用 平台/曲目 id（与标题同帧更新）；
                          // 本地文件无 track，用 source（文件路径）作 key。
                          final coverKey = current != null
                              ? '${current.source}/${current.id}'
                              : 'local:$source';

                          // 封面块：封面大图 + 下方曲目信息（对齐 PlayerData）
                          final coverBlock = _buildCoverBlock(
                            size: size,
                            colorScheme: colorScheme,
                            current: current,
                            hasContent: hasContent,
                            title: title,
                            subtitle: subtitle,
                            l10n: l10n,
                            playing: playing,
                          );

                          // 歌词区（当前行居中高亮 + 点击 seek；数据源
                          // currentLyricsProvider：平台 lyric 层（纯 Dart
                          // 直连）→ parseLrc → 时间轴有序行；「播放器内歌词」
                          // 偏好开关控制显示；字号/行距/颜色走「设置 → 歌词」）
                          // 用 Consumer 独立订阅播放位置/歌词数据/样式，
                          // 50ms 位置更新只重建歌词区，不波及页面其余部分。
                          final lyricsBlock = _buildLyricsBlock(
                            hasLyrics: hasLyrics,
                            lyricScale: lyricScale,
                            notifier: notifier,
                            hasSource: hasSource,
                            colorScheme: colorScheme,
                          );

                          // 封面/歌词分栏：歌词开 = 左 45% 封面 + 右 55% 歌词；
                          // 关/无歌词 = 封面滑向居中（对齐原版 coverCentered 的
                          // transition-transform duration-600 easeOutCubic），
                          // 歌词区同步淡出。用 Stack + AnimatedSlide /
                          // AnimatedOpacity 保证位移与淡出平滑过渡而非硬切。
                          // 动画子树的 repaint 隔离：封面/歌词各自独立图层，
                          // 位移/淡出只合成缓存图层，不与频谱 60fps 重绘互相
                          // 污染（消除切换歌词时的轻微卡顿）。
                          return RepaintBoundary(
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned(
                                  top: 0,
                                  bottom: 0,
                                  left: 0,
                                  width: c.maxWidth * 0.45,
                                  child: AnimatedSlide(
                                    offset: showLyrics && hasLyrics
                                        ? Offset.zero
                                        : const Offset(11 / 18, 0),
                                    duration: animDuration(
                                        context,
                                        const Duration(milliseconds: 600)),
                                    curve: Curves.easeOutCubic,
                                    child: Align(
                                      alignment: Alignment.center,
                                      child: RepaintBoundary(
                                        child: CoverSwitcher(
                                          coverKey: coverKey,
                                          slide: transitionStyle == 'slide',
                                          next: _slideNext,
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
                                  width: c.maxWidth * 0.55,
                                  child: IgnorePointer(
                                    ignoring: !showLyrics || !hasLyrics,
                                    child: AnimatedOpacity(
                                      duration: animDuration(
                                          context,
                                          const Duration(milliseconds: 600)),
                                      curve: Curves.easeOutCubic,
                                      opacity: (showLyrics && hasLyrics)
                                          ? 1
                                          : 0,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          right: 64,
                                        ),
                                        child: RepaintBoundary(
                                          child: lyricsBlock,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    // 状态提示（引擎会话 ID 为内部调试信息，不展示）
                    Text(
                      !hasContent ? l10n.playerPageLoadHint : (buffering ? l10n.playerBarBuffering : ''),
                      style: theme.textTheme.bodySmall,
                    ),
                    // 底部叠加层：频谱垫底，控件浮在频谱之上（控件原生透明，
                    // 重叠不遮挡频谱；5 秒无操作控件淡出，事件驱动不轮询）
                    Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.bottomCenter,
                      children: [
                        // 频谱垫底（对齐 FullPlayer BottomSpectrum；
                        // RepaintBoundary 隔离 60fps 重绘，不拖累动画帧）。
                        // 控件显示时压暗频谱、隐藏时恢复，避免视觉打架。
                        AnimatedOpacity(
                          opacity: _controlsVisible ? 0.4 : 1,
                          duration: animDuration(
                              context, const Duration(milliseconds: 300)),
                          curve: Curves.easeOut,
                          child: RepaintBoundary(
                            child: SizedBox(
                              width: double.infinity,
                              height: 90,
                              child: SpectrumView(height: 90),
                            ),
                          ),
                        ),
                        // 底部播放控件（进度条 + 控制区）叠在频谱上方
                        AnimatedOpacity(
                          opacity: _controlsVisible ? 1 : 0,
                          duration: animDuration(
                              context, const Duration(milliseconds: 300)),
                          curve: Curves.easeOut,
                          child: IgnorePointer(
                            ignoring: !_controlsVisible,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 进度条（全宽）+ 时间：独立订阅位置/时长，
                                // 50ms 更新只重建本行，不波及封面/歌词等区域
                                PlaybackProgressSlider(
                                  showTimes: true,
                                  textStyle: theme.textTheme.bodySmall,
                                  dragMs: _dragMs,
                                  buffering: buffering,
                                  enabled: hasSource,
                                  onDragChanged: (v) =>
                                      setState(() => _dragMs = v),
                                  onSeekEnd: (_) =>
                                      setState(() => _dragMs = null),
                                ),
                                const SizedBox(height: 4),
                                // 控制区：左组（红心）- 中组（控制行，播放键居中）-
                                // 右组（播放列表）。透明底、不凸显控件样式。
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: _buildControlsRow(
                                    colorScheme: colorScheme,
                                    l10n: l10n,
                                    notifier: notifier,
                                    hasContent: hasContent,
                                    hasQueue: hasQueue,
                                    canLike: canLike,
                                    liked: liked,
                                    current: current,
                                    shuffle: shuffle,
                                    repeatMode: repeatMode,
                                    playing: playing,
                                    buffering: buffering,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
