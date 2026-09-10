// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 可绑定快捷键动作注册表（动作 id / 默认绑定 / 分类 / 图标）。
///
/// 标签文案不在此处（避免服务层依赖 l10n）：由设置页按 [ShortcutAction]
/// 用 switch 解析。默认绑定仅保留原内置项，其余默认留空由用户自行绑定，
/// 避免默认冲突。
library;

import 'package:flutter/widgets.dart' show IconData;

import '../../eta/icon/eta_icons.dart';

/// 动作分类（设置页分组用）。
enum ShortcutCategory {
  playback(EtaIcons.playCircleOutline),
  seek(EtaIcons.transferHorizontal),
  volume(EtaIcons.volume),
  queue(EtaIcons.playlist),
  navigation(EtaIcons.home);

  const ShortcutCategory(this.icon);
  final IconData icon;
}

/// 可绑定动作。`name` 即持久化 id；改枚举名会丢失旧绑定。
enum ShortcutAction {
  // ── 播放控制 ──
  playPause('space', ShortcutCategory.playback, EtaIcons.playCircle),
  play('', ShortcutCategory.playback, EtaIcons.play),
  pause('', ShortcutCategory.playback, EtaIcons.pause),
  stop('', ShortcutCategory.playback, EtaIcons.stop),
  next('', ShortcutCategory.playback, EtaIcons.skipForward),
  previous('', ShortcutCategory.playback, EtaIcons.skipPrevious),
  likeToggle('', ShortcutCategory.playback, EtaIcons.heart),
  shuffleToggle('', ShortcutCategory.playback, EtaIcons.shuffle),
  repeatCycle('', ShortcutCategory.playback, EtaIcons.repeat),
  reload('', ShortcutCategory.playback, EtaIcons.refresh),

  // ── 快进 / 快退 ──
  seekBackward('arrowLeft', ShortcutCategory.seek, EtaIcons.arrowLeft),
  seekForward('arrowRight', ShortcutCategory.seek, EtaIcons.arrowRight),
  seekBackwardLong('', ShortcutCategory.seek, EtaIcons.arrowLeft),
  seekForwardLong('', ShortcutCategory.seek, EtaIcons.arrowRight),

  // ── 音量 ──
  volumeUp('ctrl+arrowUp', ShortcutCategory.volume, EtaIcons.volume),
  volumeDown('ctrl+arrowDown', ShortcutCategory.volume, EtaIcons.volume),
  muteToggle('', ShortcutCategory.volume, EtaIcons.volumeMute),

  // ── 队列 ──
  jumpToFirst('', ShortcutCategory.queue, EtaIcons.skipPrevious),
  jumpToLast('', ShortcutCategory.queue, EtaIcons.skipForward),
  clearQueue('', ShortcutCategory.queue, EtaIcons.playlist),

  // ── 导航 ──
  goHome('', ShortcutCategory.navigation, EtaIcons.home),
  goLibrary('ctrl+l', ShortcutCategory.navigation, EtaIcons.music),
  goSearch('ctrl+f', ShortcutCategory.navigation, EtaIcons.search2),
  goLiked('', ShortcutCategory.navigation, EtaIcons.heart),
  goFavorites('', ShortcutCategory.navigation, EtaIcons.heart),
  goHistory('', ShortcutCategory.navigation, EtaIcons.history),
  goDownload('', ShortcutCategory.navigation, EtaIcons.download),
  goStreaming('', ShortcutCategory.navigation, EtaIcons.serverOutline),
  openPlayer('', ShortcutCategory.navigation, EtaIcons.fullscreen),
  openSettings('', ShortcutCategory.navigation, EtaIcons.settingsOutline),
  back('escape', ShortcutCategory.navigation, EtaIcons.cornerDownLeft);

  const ShortcutAction(this.defaultBinding, this.category, this.icon);

  /// 默认绑定字符串（空 = 默认未绑定）。
  final String defaultBinding;
  final ShortcutCategory category;
  final IconData icon;

  /// 持久化 id。
  String get id => name;

  /// 导航类路由（部分动作）。
  String? get route => switch (this) {
    goHome => '/',
    goLibrary => '/library',
    goSearch => '/search',
    goLiked => '/liked',
    goFavorites => '/favorites',
    goHistory => '/history',
    goDownload => '/download',
    goStreaming => '/streaming',
    openPlayer => '/player',
    _ => null,
  };
}
