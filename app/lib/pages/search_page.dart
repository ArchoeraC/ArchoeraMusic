// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../apis/qqmusic/core/request.dart' show QmErrorKind;
import '../services/netease/netease_api.dart';
import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../services/qqmusic/qqmusic_api.dart' show QqApiException;
import '../stores/app_prefs.dart';
import '../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../widgets/list/cover_grid.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/dialogs/s_context_menu.dart';
import '../widgets/common/toast.dart';
import '../widgets/list/song_list.dart';
import '../widgets/dialogs/track_context_menu.dart';
import '../widgets/dialogs/track_list_dialog.dart';
import '../widgets/search/search_empty_state.dart';
import '../widgets/search/search_error_state.dart';
import '../widgets/search/search_source_state.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'search/search_page_actions.dart';
part 'search/search_page_fetch.dart';
part 'search/search_page_models.dart';
part 'search/search_page_view.dart';

/// 搜索页（对齐原项目 Search.vue）。
///
/// 4 个 Tab（歌曲 / 专辑 / 歌手 / 歌单），各 Tab 独立分页状态：
/// 关键词变化清空重拉（offset 0），触底 append 下一页（PAGE_SIZE=50）。
/// 点击歌曲 → 侧车 song_url 解析播放 URL → PlaybackNotifier.load 完整转码播放。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage>
    with SingleTickerProviderStateMixin {
  static const _pageSize = 50;

  /// 单 tab 累计条数上限：超过即截断并停 more（防无限加载撑爆内存）。
  static const _maxTabItems = 300;

  late final TabController _tabs;

  _TabState<Track> _songs = const _TabState();
  _TabState<CoverItem> _albums = const _TabState();
  _TabState<CoverItem> _artists = const _TabState();
  _TabState<CoverItem> _playlists = const _TabState();

  String _query = '';
  String _error = '';

  /// 搜索平台（'netease' / 'kugou' / 'qqmusic' / 'all' 聚合）。
  String _platform = 'netease';

  /// 聚合搜索（'all'）：**songs** tab 各平台分页游标。
  final Map<String, _AggState> _songAgg = {
    for (final p in _aggPlatforms) p: _AggState(),
  };

  /// 聚合搜索（'all'）：**albums/artists/playlists** tab 各平台分页游标。
  final Map<_SearchTab, Map<String, _AggState>> _coverAgg = {};

  /// 来源失败后的退避闸门（防连打触发更强风控）。
  final SearchSourceCooldown _sourceCooldown = SearchSourceCooldown();

  Map<String, _AggState> _coverAggFor(_SearchTab tab) =>
      _coverAgg.putIfAbsent(tab, () {
        return {for (final p in _aggPlatforms) p: _AggState()};
      });

  /// 是否正在解析播放源（防连点）。
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery.trim();
    _tabs = TabController(length: 4, vsync: this);
    _tabs.addListener(_onTabChanged);
    if (_query.isNotEmpty) {
      unawaited(_fetch(append: false));
    }
  }

  @override
  void didUpdateWidget(SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 路由 query 变化（NavHeader 新搜索）：重置并按新关键词重拉
    final q = widget.initialQuery.trim();
    if (q != oldWidget.initialQuery.trim() && q != _query) {
      _query = q;
      _resetAll();
      if (_query.isNotEmpty) unawaited(_fetch(append: false));
    }
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  _SearchTab get _tab =>
      _SearchTab.values[_tabs.index.clamp(0, _SearchTab.values.length - 1)];

  _TabState<dynamic> get _currentState => switch (_tab) {
    _SearchTab.songs => _songs,
    _SearchTab.albums => _albums,
    _SearchTab.artists => _artists,
    _SearchTab.playlists => _playlists,
  };

  /// 当前 tab 首页加载中。
  bool get _initialLoading => _currentState.loading && !_currentState.loaded;

  /// 当前 tab 已加载且为空。
  bool get _emptyResult => _currentState.loaded && _currentState.items.isEmpty;

  @override
  Widget build(BuildContext context) => _buildPage(context);
}