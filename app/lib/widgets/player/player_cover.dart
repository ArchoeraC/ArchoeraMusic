// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放器封面块（拆分自 player_page.dart 的 `_buildCoverBlock`）。
///
/// 封面大图 + 下方曲名/副标题（对齐原项目 PlayerData）：
/// - 缩放：播放 1.0 / 暂停 0.9（500ms 弹性过渡，对齐原版 scale-100/90）；
/// - 节拍脉冲：设置开启时鼓点命中轻微放大回弹（[pulse] 动画值驱动，
///   峰值随 [beatStrength] 区分——鼓点越猛缩放越明显）。
library;

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/netease/track.dart';
import '../common/anim.dart';
import '../list/cover_image.dart';

part 'player_cover/player_cover_view.dart';
