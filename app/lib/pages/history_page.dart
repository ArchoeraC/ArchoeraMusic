// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/history/history_store.dart';
import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../widgets/dialogs/s_context_menu.dart';
import '../widgets/dialogs/s_dialog.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/list/song_list.dart';
import '../widgets/common/toast.dart';
import '../widgets/dialogs/track_context_menu.dart';

part 'history/history_page_actions.dart';
part 'history/history_page_view.dart';

/// 历史页（对齐原项目 History.vue）。
///
/// 本地存储（HistoryStore，同曲去重置顶，上限 500）：
/// 标题 + 总数 + 播放全部 + 清空 + 列表（时间倒序）；点击行播放，
/// 右键可单条移除。
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  List<HistoryEntry> _entries = const [];
  bool _loading = true;
  bool _resolving = false;

  /// 历史变更订阅（IndexedStack 下页面常驻，订阅后任何 record/remove/
  /// clear/trim 即时重载——事件驱动，无轮询/高频监听）。
  StreamSubscription<HistoryChangedEvent>? _changesSub;

  /// 突发变更合并（连播快速切歌时只重载一次，避免逐首整表重读）。
  bool _reloadScheduled = false;

  @override
  void initState() {
    super.initState();
    _changesSub = HistoryStore.changes.on<HistoryChangedEvent>().listen(
      (_) => _scheduleReload(),
    );
    _load();
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    super.dispose();
  }

  void _setReloadScheduled(bool value) {
    _reloadScheduled = value;
  }

  void _applyLoadedEntries(List<HistoryEntry> entries) {
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  void _setResolving(bool value) {
    setState(() => _resolving = value);
  }

  void _toast(String msg) => toast(msg);

  List<Track> get _tracks => _entries.map((e) => e.track).toList();

  @override
  Widget build(BuildContext context) => _buildHistoryPage(context);
}
