// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放页布局注册表。
///
/// 播放页只负责共享状态（播放/歌词/偏好）与外围 chrome（顶栏、底部控制、
/// 自动沉浸），具体排版交给 [PlayerLayout] 实现：
/// - `buildBackdrop`：页面级附加层（整幅封面等），画在背景之上、内容之下；
/// - `buildScrims`：随自动沉浸淡出的遮罩层（可空）；
/// - `buildBody`：顶栏与底部控制之间的主体；
/// - [usesDefaultBottomBar]：是否使用页面共享的底部控制区。
///
/// 新增布局只需：实现 [PlayerLayout] → 加进 [playerLayouts] → 在偏好白名单
/// （`coverLayouts`）与设置分段里登记 id。页面本身不再写 `if (layout == ...)`。
library;

import 'package:material_ui/material_ui.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/netease/track.dart';
import 'poster_layout.dart';
import 'split_layout.dart';
import 'vutron_layout.dart';

/// 播放页横向内边距（顶栏 / 主体 / 底栏共用；布局坐标换算也依赖它）。
const double kPlayerPageHorizontalPadding = 32;

/// 布局构建所需的共享状态（只读快照，布局不应修改）。
class PlayerLayoutContext {
  const PlayerLayoutContext({
    required this.current,
    required this.coverKey,
    required this.title,
    required this.subtitle,
    required this.playing,
    required this.hasContent,
    required this.hasLyrics,
    required this.showLyrics,
    required this.contentMounted,
    required this.transitionStyle,
    required this.coverLyricRatio,
    required this.autoCenterCover,
    required this.slideNext,
    required this.coverPulse,
    required this.beatStrength,
    required this.pageWidth,
    required this.pageHeight,
    required this.fullscreenCoverWidth,
    required this.chromeOpacity,
    required this.buffering,
    required this.hasSource,
    required this.onDragChanged,
    required this.onSeekEnd,
    required this.l10n,
    required this.onSeekLyric,
    required this.dragMs,
  });

  final Track? current;

  /// 当前封面身份（切歌触发 [CoverSwitcher] 动效）。
  final Object coverKey;

  final String title;
  final String subtitle;
  final bool playing;
  final bool hasContent;
  final bool hasLyrics;

  /// 用户是否开启歌词（`showLyricsInPlayer`）。
  final bool showLyrics;

  /// 重内容（背景/歌词）是否已挂载（路由进入动画结束）。
  final bool contentMounted;

  /// 切歌动效样式（`scale` / `slide` / `fade`）。
  final String transitionStyle;

  final double coverLyricRatio;
  final bool autoCenterCover;
  final bool slideNext;
  final AnimationController coverPulse;
  final double beatStrength;

  /// 整页尺寸（逻辑像素；含内边距，布局自行换算）。
  final double pageWidth;
  final double pageHeight;

  /// 整幅封面布局的封面面板宽度（整页坐标；其余布局为 0）。
  final double fullscreenCoverWidth;

  /// 顶/底 chrome 不透明度（自动沉浸隐藏时为 0）。
  final double chromeOpacity;

  /// 是否正在缓冲（布局自带的进度条用）。
  final bool buffering;

  /// 是否有可播源（无源时禁用拖动）。
  final bool hasSource;

  /// 进度条拖动中（毫秒）。
  final ValueChanged<double> onDragChanged;

  /// 进度条松手（毫秒）。
  final ValueChanged<double> onSeekEnd;

  final AppLocalizations l10n;
  final ValueChanged<int>? onSeekLyric;

  /// 拖动进度条中的目标位置（毫秒）；null = 未拖动。
  final double? dragMs;
}

/// 播放页布局契约（见库注释）。
abstract class PlayerLayout {
  const PlayerLayout();

  /// 与偏好 `coverLayout` 对应的稳定 id。
  String get id;

  /// 页面级附加层（可为空）；调用方会包一层 [IgnorePointer]。
  Widget? buildBackdrop(BuildContext context, PlayerLayoutContext c) => null;

  /// 随 chrome 一起淡出的遮罩层（可为空）。
  Widget? buildScrims(BuildContext context, PlayerLayoutContext c) => null;

  /// 主体区域。
  Widget buildBody(BuildContext context, PlayerLayoutContext c);

  /// 是否使用页面共享的底部控制区（进度 + 控制行 + 频谱）。
  ///
  /// 返回 false 的布局需要自己在主体里提供完整的播放控制（如 Vutron 经典
  /// 布局把控制放在封面下方）。
  bool get usesDefaultBottomBar => true;

  /// 歌词水平对齐（居中 / 靠左 / 靠右）。布局注册表按需覆盖：
  /// simple 列表与 AMLL 物理墙都会按此对齐。
  TextAlign get lyricsAlign => TextAlign.center;
}

/// 内建布局列表（顺序仅用于注册表遍历；设置页的展示顺序单独维护）。
const List<PlayerLayout> playerLayouts = <PlayerLayout>[
  SplitPlayerLayout(),
  PosterPlayerLayout(),
  VutronPlayerLayout(),
];

final Map<String, PlayerLayout> _layoutsById = <String, PlayerLayout>{
  for (final layout in playerLayouts) layout.id: layout,
};

/// id → 布局；未知 id 回退 `default`（旧数据/降级安全）。
PlayerLayout playerLayoutFor(String id) =>
    _layoutsById[id] ?? _layoutsById[SplitPlayerLayout.layoutId]!;
