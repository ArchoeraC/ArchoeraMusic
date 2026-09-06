// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流媒体主页（对齐 SPlayer-Next Streaming/Index.vue）。
///
/// 顶栏：标题 + 数量统计；右侧状态点 / 服务器下拉 / 刷新 / 设置。
/// Tab：歌曲 / 专辑 / 歌手 / 歌单（懒加载缓存，切换 Tab 拉取）。
/// 状态机：无服务器 → 空态引导去设置；已配置未连接 → 错误 + 重连；
/// 已连接 → 四个 Tab 内容（歌曲列表 / 封面网格）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../settings/settings_dialog.dart';
import '../../widgets/player/s_controls.dart';
import '../../widgets/streaming/albums_tab.dart';
import '../../widgets/streaming/artists_tab.dart';
import '../../widgets/streaming/count_label.dart';
import '../../widgets/streaming/empty_state.dart';
import '../../widgets/streaming/playlists_tab.dart';
import '../../widgets/streaming/server_dropdown.dart';
import '../../widgets/streaming/songs_tab.dart';
import '../../widgets/streaming/status_dot.dart';
import '../../services/streaming/streaming_provider.dart';

part 'streaming_page/streaming_page_actions.dart';
part 'streaming_page/streaming_page_view.dart';

/// 流媒体主页（壳内分支 /streaming）。
class StreamingPage extends ConsumerStatefulWidget {
  const StreamingPage({super.key});

  @override
  ConsumerState<StreamingPage> createState() => _StreamingPageState();
}

class _StreamingPageState extends ConsumerState<StreamingPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _tab.addListener(_onTabChanged);
    // 启动时自动连接已有激活服务器（不阻塞首帧）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(streamingProvider.notifier).init();
    });
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildStreamingPage(context);
}
