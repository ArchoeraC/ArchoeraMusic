// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../player_bar.dart';

extension _PlayerBarView on _PlayerBarState {
  Widget _buildPlayerBar(BuildContext context) {
    final theme = Theme.of(context);
    final notifier = ref.read(playbackProvider.notifier);
    final prefs = ref.watch(appPrefsProvider);
    // 选择性订阅低频字段（播放位置/FFT 每 50ms 更新，不重建播放条本体）
    final hasSource = ref.watch(
      playbackProvider.select((s) => s.source != null),
    );
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

    final bar = _buildBarContent(
      context: context,
      theme: theme,
      notifier: notifier,
      track: track,
      title: title,
      subtitle: subtitle,
      buffering: buffering,
      playing: playing,
      hasSource: hasSource,
      hasQueue: hasQueue,
      hasContent: hasContent,
    );

    final content = floating
        ? _buildFloatingPlayerBar(
            theme: theme,
            chrome: chrome,
            imageMode: imageMode,
            bar: bar,
          )
        : _buildDockedPlayerBar(chrome: chrome, imageMode: imageMode, bar: bar);

    // 未播放时隐藏播放条（不占底部空间）；用 AnimatedSwitcher 做
    // 进入/退出动效（对齐原版 MainLayout.vue 的 PlayerBar 过渡：底部
    // translate-y-full 滑入/滑出，enter 300ms ease-out、leave 反向 ease-in）。
    // 可见条件：有引擎源（source）或有恢复的现场（queue 非空，如「会话记忆」
    // 恢复的暂停会话——source 为 null 但队列/位置已就绪，播放条应显示）。
    final showBar = hasSource || hasQueue;
    return AnimatedSwitcher(
      duration: animDuration(context, const Duration(milliseconds: 300)),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SlideTransition(
        // 从自身高度 100% 下方滑入（对齐原版 translate-y-full）；
        // 悬浮层底部定位，滑出即超出窗口底部被裁掉。
        position: Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: showBar
          ? KeyedSubtree(key: const ValueKey('player-bar'), child: content)
          : const SizedBox.shrink(key: ValueKey('player-bar-hidden')),
    );
  }
}
