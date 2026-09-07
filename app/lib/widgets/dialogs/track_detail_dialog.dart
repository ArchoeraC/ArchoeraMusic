// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 媒体详细信息弹窗（右键菜单「媒体详细信息」）。
///
/// 合并 SPlayer-Next PlayerData 的音质详情（编码/采样率/位深/比特率/声道）
/// 与 TagEditorDialog 的路径/文件大小字段：展示曲目标题、歌手、专辑、时长、
/// 来源平台、KG音质档、音频技术信息（流媒体服务器返回）与本地路径/大小。
library;

import 'package:flutter/material.dart';

import '../../services/netease/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../utils/format.dart';
import '../list/cover_image.dart';
import 's_dialog.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'track_detail_dialog/track_detail_dialog_view.dart';

/// 弹出媒体详细信息弹窗。
void showTrackDetailDialog(BuildContext context, {required Track track}) {
  SDialog.show(
    context,
    title: context.l10n.menuTrackDetail,
    width: 420,
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.commonClose),
      ),
    ],
    child: _TrackDetailBody(track: track),
  );
}
