// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import '../../l10n/generated/app_localizations.dart';
import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/app_prefs.dart';
import '../stores/lyrics_provider.dart';
import '../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../widgets/dialogs/comment_dialog.dart';
import '../widgets/player/cover_switcher.dart';
import '../widgets/player/playback_progress_slider.dart';
import '../widgets/player/player_controls_row.dart';
import '../widgets/player/player_background.dart';
import '../widgets/player/player_cover.dart';
import '../widgets/player/player_lyrics_block.dart';
import '../widgets/player/quality_menu.dart';
import '../widgets/player/spectrum_view.dart';
import '../widgets/common/toast.dart';
import '../widgets/common/anim.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'player/player_page_view.dart';

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
    with SingleTickerProviderStateMixin, WindowListener {
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

  /// 窗口是否处于完整全屏（进入全屏/还原按钮的图标与提示切换）。
  /// 事件驱动：window_manager 窗口事件（含系统级全屏，如 F11）同步状态，
  /// 无轮询。
  bool _isFullScreen = false;

  /// 完整全屏切换（对齐原版 FullPlayer 顶栏 Maximize/Minimize 按钮，
  /// 由 useWindowControls → Electron setFullScreen 实现，这里走
  /// window_manager.setFullScreen）。
  ///
  /// Windows 下 window_manager 不保证派发 enter/leave fullscreen 窗口事件，
  /// 若只靠 [onWindowEvent] 同步，按钮图标会停在旧态（必须关掉再打开播放页
  /// 才会经 initState 查询刷新）。这里改为：乐观置位 → 调用 → 以窗口管理器
  /// 实际状态校准，三端一致即时刷新。
  Future<void> _toggleFullscreen() async {
    final target = !_isFullScreen;
    if (mounted) setState(() => _isFullScreen = target);
    await windowManager.setFullScreen(target);
    await _syncFullScreen();
  }

  /// 以窗口管理器真实全屏状态校准本地标记（系统级全屏 / 平台事件缺失兜底）。
  Future<void> _syncFullScreen() async {
    final v = await windowManager.isFullScreen();
    if (mounted && v != _isFullScreen) {
      setState(() => _isFullScreen = v);
    }
  }

  @override
  void onWindowEvent(String eventName) {
    if (eventName == kWindowEventEnterFullScreen && !_isFullScreen) {
      setState(() => _isFullScreen = true);
    } else if (eventName == kWindowEventLeaveFullScreen && _isFullScreen) {
      setState(() => _isFullScreen = false);
    }
  }

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
    // 全屏按钮初始状态 + 监听窗口事件（进入/退出全屏时图标同步）
    windowManager.addListener(this);
    // 初始全屏状态校准：Windows 平台事件可能缺失，改为主动查询真实状态。
    unawaited(_syncFullScreen());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _hideTimer?.cancel();
    _coverPulse.dispose();
    super.dispose();
  }

  /// 当前曲目可选的音质档（KG按实际 hash 过滤；NT全档位，
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
      toast(switch (track.source) {
        'kugou' => l10n.toastLoginRequiredKugou,
        'qqmusic' => l10n.toastQqLikeSyncFailed,
        _ => l10n.toastLoginRequiredNetease,
      }, type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) => _buildPage(context);
}
