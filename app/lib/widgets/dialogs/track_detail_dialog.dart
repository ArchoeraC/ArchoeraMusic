// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 媒体详细信息弹窗（右键菜单「媒体详细信息」）。
///
/// 合并音质详情（编码/采样率/位深/比特率/声道）
/// 与 TagEditorDialog 的路径/文件大小字段：展示曲目标题、歌手、专辑、时长、
/// 来源平台、KG音质档、音频技术信息（流媒体服务器返回）与本地路径/大小。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/track.dart';
import '../../services/source/source_platform.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../utils/format.dart';
import '../list/cover_image.dart';
import '../player/s_controls.dart';
import 's_dialog.dart';
import 'tag_editor_dialog.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'track_detail_dialog/track_detail_dialog_view.dart';

/// 弹出媒体详细信息弹窗。
///
/// 「编辑元数据」按钮由音源注册表决定是否显示（`SourcePlatform.canEditMetadata`；
/// 目前仅本地文件源支持），点击后关闭本弹窗并打开 [showTagEditorDialog]。
void showTrackDetailDialog(BuildContext context, {required Track track}) {
  final l10n = context.l10n;
  final canEdit = sourcePlatform(track.source).canEditMetadata(track);
  SDialog.show(
    context,
    title: l10n.menuTrackDetail,
    width: 420,
    actions: [
      if (canEdit)
        SButton(
          label: l10n.menuEditTags,
          icon: EtaIcons.editOutline,
          variant: SButtonVariant.secondary,
          onPressed: () {
            // 先关闭详情弹窗再打开编辑弹窗，避免两层弹窗叠加。
            Navigator.of(context).pop();
            Future<void>.microtask(() {
              if (context.mounted) showTagEditorDialog(context, track: track);
            });
          },
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(l10n.commonClose),
      ),
    ],
    child: _TrackDetailBody(track: track),
  );
}
