// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 通用在线曲目右键菜单（搜索 / 我喜欢 / 历史 / 歌单详情等共用）。
///
/// 菜单项：播放 / 下一首播放 / 收藏切换 / 查看评论（在线曲目）+
/// 页面专属 [extra]。页面可通过 [onToggleLike] 定制收藏行为
/// （如「我喜欢」页取消收藏时从列表移除该行）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apis/runtime.dart';
import '../../services/downloader/download_controller.dart';
import '../../services/netease/netease_api.dart';
import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../../stores/providers.dart';
import '../../l10n/l10n.dart';
import 'comment_dialog.dart';
import '../common/glass_surface.dart';
import 'kugou_login_button.dart';
import 'netease_login_dialog.dart';
import 's_context_menu.dart';
import 's_dialog.dart';
import 'track_detail_dialog.dart';
import 'track_list_dialog.dart';
import '../common/toast.dart';

part 'track_context_menu/track_context_menu_menu.dart';
part 'track_context_menu/track_context_menu_download.dart';
