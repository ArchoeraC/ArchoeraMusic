// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../services/scanner/library_store.dart';
import '../../services/scanner/local_track.dart';
import '../../services/scraper/scrape_controller.dart';
import '../../stores/app_prefs.dart';
import '../../stores/data_dir.dart';
import '../common/anim.dart';
import '../common/toast.dart';
import '../dialogs/folder_manager.dart';
import '../dialogs/s_dialog.dart';
import '../player/s_controls.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'library_header/library_header_actions.dart';
part 'library_header/library_header_view.dart';

/// 音乐库页顶栏：标题 + 状态区 + 操作行（播放全部 / 扫描 / 刮削 / 更多）
/// + 搜索框。
///
/// 从 LibraryPage.build 拆出：自读 store/scrape 状态，目录/统计/刮削等
/// 对话框与偏好读写都在本组件内完成，页面只剩列表体（降低嵌套深度）。
class LibraryHeader extends ConsumerWidget {
  const LibraryHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _buildLibraryHeader(context, ref);
}
