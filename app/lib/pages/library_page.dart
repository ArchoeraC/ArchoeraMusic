// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../services/scanner/library_store.dart';
import '../services/scanner/local_track.dart';
import '../../l10n/l10n.dart';
import '../widgets/dialogs/comment_dialog.dart';
import '../widgets/dialogs/folder_manager.dart';
import '../widgets/dialogs/s_context_menu.dart';
import '../widgets/dialogs/s_dialog.dart';
import '../widgets/library/library_empty_state.dart';
import '../widgets/library/library_header.dart';
import '../widgets/list/song_list.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/common/toast.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'library/library_page_actions.dart';
part 'library/library_page_view.dart';

/// 音乐库页（对齐原项目 Library.vue）：本地曲目列表 + 扫描 +
/// 目录管理 + 搜索。顶栏（标题/操作行/搜索/统计/刮削）已拆到
/// [LibraryHeader]，本页只保留列表体与曲目交互。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  @override
  void initState() {
    super.initState();
    // 首次进入初始化（读扫描目录 + 载入曲库）并触发一次自动增量扫描
    // （距上次自动扫描 ≥5 分钟才执行；壳层分支切换也会触发同一入口，
    // 内部幂等 + 5 分钟窗口保证不重复扫）
    Future.microtask(
      () => ref.read(libraryStoreProvider.notifier).maybeAutoRefresh(),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    toast(msg);
  }

  @override
  Widget build(BuildContext context) => _buildLibraryPage(context);
}
