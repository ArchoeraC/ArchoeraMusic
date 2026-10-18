// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放器封面块（拆分自 player_page.dart 的 `_buildCoverBlock`）。
///
/// 两种呈现：
/// - `default` 左右分栏：[PlayerCoverBlock] 封面大图 + 下方曲名/副标题
///   （对齐原项目 PlayerData）；播放时 1.0 / 暂停 0.9（500ms 弹性过渡，
///   对齐原版 scale-100/90），设置开启时鼓点命中轻微放大回弹
///   （[PlayerCoverBlock.pulse] 动画值驱动，峰值随
///   [PlayerCoverBlock.beatStrength] 区分——鼓点越猛缩放越明显）；
/// - `fullscreen` 整幅封面：[PlayerFullscreenCover] 铺满左侧整列，右缘
///   横向渐隐融入背景（对齐原项目 FullPlayer 的全屏封面）。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/netease/track.dart';
import '../common/anim.dart';
import '../list/cover_image.dart';
import 'player_cover/cover_mask_shader.dart';

part 'player_cover/fullscreen_cover_view.dart';
part 'player_cover/player_cover_view.dart';
