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
///   横向渐隐融入背景（对齐 SPlayer-Next 的全屏封面）。
library;

import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/netease/track.dart';
import '../common/anim.dart';
import '../list/cover_image.dart';
import 'player_shared_elements.dart';

part 'player_cover/fullscreen_cover_view.dart';
part 'player_cover/player_cover_view.dart';

/// 全屏封面右缘渗入遮罩开关（诊断 A/B，见 `docs/player-render-optimization.md`
/// §4.2d）。
///
/// 该遮罩每帧对**封面面板面积**创建一次离屏层，是全屏播放页里仅剩的
/// 「每帧 × 面积」离屏层之一。`ARCHOERA_COVER_MASK=off` 时不加遮罩（右缘
/// 露出硬边），用于在真机上测量它的帧时间占比；默认始终开启。
final bool coverMaskEnabled =
    Platform.environment['ARCHOERA_COVER_MASK']?.trim().toLowerCase() != 'off';
