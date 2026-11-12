// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/generated/app_localizations.dart';
import '../app/player_theme.dart';
import '../services/netease/track.dart';
import '../services/source/source_platform.dart';
import '../services/lyrics/lyric_line.dart';
import '../services/playback/sleep_timer.dart';
import '../utils/format.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/app_prefs.dart';
import '../stores/lyrics_provider.dart';
import '../stores/player_route_animation.dart';
import '../stores/providers.dart';
import '../stores/window_full_screen.dart';
import '../theme/app_theme.dart';
import '../../l10n/l10n.dart';
import '../widgets/dialogs/comment_dialog.dart';
import '../widgets/dialogs/sleep_timer_dialogs.dart';
import '../widgets/player/playback_progress_slider.dart';
import '../widgets/player/player_controls_row.dart';
import '../widgets/player/player_layout_switcher.dart';
import '../widgets/player/player_shared_elements.dart';
import '../widgets/player/background/player_background.dart';
import '../widgets/player/quality_menu.dart';
import '../widgets/player/spectrum_view.dart';
import '../widgets/common/toast.dart';
import '../widgets/common/anim.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

import 'player/layouts/player_layout.dart';
import 'player/layouts/poster_layout.dart';

part 'player/player_page_view.dart';

/// 全屏播放器覆盖层（对齐原项目 FullPlayer/index.vue）。
///
/// 入口：点击底部播放条封面/标题区（`/player` 顶层路由，盖住整个壳）。
/// 布局：顶部（关闭 + 曲名 + 音质）→ 主体（封面 + 歌词区左右分栏，
/// §10.2 LyricsView）→ 频谱 → 进度条 → 控制。
/// `coverLayout: fullscreen` 时封面改铺满左侧整页、曲目信息移到歌词上方；
/// `coverLayout: vutron` 为 VutronMusic 经典布局（左封面 + 信息/进度/控制，
/// 右歌词，控制不再使用共享底栏）。具体排版由 `player/layouts/` 的注册表实现。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with SingleTickerProviderStateMixin {
  /// 拖动中的进度（ms）；null = 跟随播放器实时位置。
  double? _dragMs;

  /// 布局切换共享元素边界（按布局 id 缓存；同一布局内 GlobalKey 稳定）。
  final Map<String, PlayerSharedElementKeys> _sharedElementKeys = {};

  PlayerSharedElementKeys _keysForLayout(String layoutId) => _sharedElementKeys
      .putIfAbsent(layoutId, () => PlayerSharedElementKeys(layoutId));

  /// 切歌方向（slide 样式用）：播放顺序递增 = 下一首（新封面从右进），
  /// 递减 = 上一首（从左进）。对齐原版 watch(playIndex) 判定。
  bool _slideNext = true;

  /// 底部播放控件（进度条+控制区）是否可见。事件驱动：鼠标移动/点击/
  /// 滚轮任意操作都会重置 5 秒倒计时（监听 PointerHover 事件，非轮询），
  /// 倒计时结束后淡出控件。
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// 指针是否在播放页窗口内（自动沉浸：离开窗口立即隐藏顶/底栏）。
  bool _pointerInside = true;

  /// 路由进入动画是否已完成：完成前不挂载重内容（歌词块、背景的水纹 / 流体
  /// 层），对齐原版 FullPlayer 的 `lyricMounted` 与 `visualizerMounted`
  /// （均在 `@after-enter` 之后才挂载）。播放页背景本身（预览层）从第一帧就
  /// 挂载，普通 chrome（顶栏 / 封面 / 控件）不受影响。
  bool _contentMounted = false;

  /// 退出动画是否进行中：收起时暂停水纹/流体的逐帧渲染，只保留最后一帧，
  /// 把帧预算让给壳层重排 + 路由下滑，避免收起卡顿。
  bool _closing = false;

  /// 当前 `ModalRoute` 的进入/退出动画（在 [didChangeDependencies] 绑定，
  /// 状态变更驱动 [_contentMounted]；同时写入 provider 供壳层驱动收起动效）。
  Animation<double>? _routeAnimation;

  /// 播放页路由动画写入器（dispose 时不能再经 ref 获取，initState 缓存）。
  PlayerRouteAnimationNotifier? _routeAnimNotifier;

  /// 封面节拍脉冲动画：鼓点命中 → forward(from: 0) 驱动 1 → 1.03 → 1 回弹。
  /// 脉冲检测在引擎侧完成（Dart 只消费 FftFrame.beatStrength，0~1）。
  late final AnimationController _coverPulse;

  /// 最近一次脉冲强度（0~1；脉冲按此缩放幅度，无脉冲帧不更新）。
  double _lastBeatStrength = 1;

  /// 窗口是否处于完整全屏（进入全屏/还原按钮的图标与提示切换）。
  ///
  /// 由进程级 [windowFullScreenProvider] 提供：**只由窗口事件更新**，页面挂载 /
  /// 卸载不再读取那个会跨线程阻塞的原生 getter（Windows 下最多等 5s，
  /// 快速关闭→重开会导致整个应用卡死）。
  bool get _isFullScreen => ref.watch(windowFullScreenProvider);

  /// 完整全屏切换（对齐原版 FullPlayer 顶栏 Maximize/Minimize 按钮）。
  ///
  /// 乐观置位 + 原生写入下沉到 [WindowFullScreenNotifier.toggle]；实际状态仍由
  /// 窗口事件校准（含系统级全屏，如 F11）。
  Future<void> _toggleFullscreen() async {
    ref.read(windowFullScreenProvider.notifier).toggle();
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
    // 全屏按钮状态由 windowFullScreenProvider 提供（进程级单次注册原生监听），
    // 页面挂载路径上不再有任何原生窗口调用。
    // 缓存路由动画写入器（dispose 时不能再经 ref 获取）。
    _routeAnimNotifier = ref.read(playerRouteAnimationProvider.notifier);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 绑定所在路由的进入/退出动画：驱动重内容（背景/歌词）挂载时机，并写入
    // provider 供壳层驱动主页收缩/展开（同一控制器 → 同帧同步）。
    final animation = ModalRoute.of(context)?.animation;
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
      _routeAnimation = animation;
      _routeAnimation?.addStatusListener(_onRouteAnimationStatus);
    }
    // 延后到帧末，避免在构建期修改壳层正在监听的 provider。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _routeAnimNotifier?.set(_routeAnimation);
      _syncContentMounted();
    });
  }

  /// 以当前路由动画状态校准 [_contentMounted]（幂等）。
  ///
  /// 只在进入动画完成后置真；退出时保持内容挂载直到路由销毁。
  void _syncContentMounted() {
    final status = _routeAnimation?.status;
    final closing = status == AnimationStatus.reverse;
    if (closing != _closing) {
      setState(() => _closing = closing);
    }
    if (status == AnimationStatus.completed && !_contentMounted) {
      setState(() => _contentMounted = true);
    }
  }

  /// 路由转场状态 → 重内容挂载态（进入完成才挂载背景/歌词）与退出暂停。
  void _onRouteAnimationStatus(AnimationStatus status) {
    if (!mounted) return;
    final closing = status == AnimationStatus.reverse;
    if (closing != _closing) {
      setState(() => _closing = closing);
    }
    if (status == AnimationStatus.completed && !_contentMounted) {
      setState(() => _contentMounted = true);
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    // 清空路由动画（壳层恢复折叠态）；旧实例不能清掉新实例刚写入的动画。
    _routeAnimNotifier?.clear(_routeAnimation);
    _hideTimer?.cancel();
    _coverPulse.dispose();
    super.dispose();
  }

  /// 当前曲目可选的音质档（**由音源注册表裁剪**）：KG 按品质 hash、Neko 按
  /// `maxQuality`、其余源全档；差异全部封装在 [SourcePlatform.availableQualities]
  /// 及其异步 `maxQualityProvider` 内。
  List<String> _availableLevels(Track? track) {
    if (track == null) return const ['hq'];
    final platform = sourcePlatform(track.source);
    final maxAsync = platform.maxQualityProvider(track);
    final maxQuality = maxAsync == null
        ? null
        : ref.watch(maxAsync).maybeWhen(data: (v) => v, orElse: () => null);
    return platform.availableQualities(track, maxQuality: maxQuality);
  }

  /// 红心切换（当前曲目；失败提示）。
  Future<void> _toggleLike(Track track) async {
    final l10n = context.l10n;
    final ok = await ref.read(likeControllerProvider).toggle(track);
    if (!ok && mounted) {
      toast(likeFailedTextFor(track.source, l10n), type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 切歌方向（slide 样式）与封面节拍：在 ConsumerState 的 build 内注册，
    // 避免放进子 Builder 时 debug 模式触发 ref.listen 的 build 断言。
    ref.listen(playbackProvider.select((s) => s.queueIndex), (prev, next) {
      if (prev != null && prev != next) {
        _slideNext = next > prev;
      }
    });
    ref.listen(playbackProvider.select((s) => s.fft), (prev, next) {
      final p = ref.read(appPrefsProvider);
      if (!p.coverBeatScale || p.performanceMode) return;
      final strength = next?.beatStrength ?? 0;
      if (strength <= 0) return;
      _lastBeatStrength = strength;
      _coverPulse.forward(from: 0);
    });
    // 播放页固定暗色主题：背景恒为暗色体系，前景（文字/图标/歌词等）
    // 不随应用浅色模式反色。见 [playerThemeProvider]。
    return Theme(
      data: ref.watch(playerThemeProvider),
      child: Builder(builder: (context) => _buildPage(context)),
    );
  }
}
