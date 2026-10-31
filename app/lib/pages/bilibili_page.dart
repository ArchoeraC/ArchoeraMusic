// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../apis/bilibili/core/request.dart'
    show BilibiliApiException, BilibiliErrorKind;
import '../apis/bilibili/core/types.dart';
import '../l10n/generated/app_localizations.dart';
import '../l10n/l10n.dart';
import '../services/netease/netease_api.dart' show CoverItem;
import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../services/source/source_platform.dart';
import '../stores/providers.dart';
import '../widgets/common/toast.dart';
import '../widgets/dialogs/track_context_menu.dart';
import '../widgets/dialogs/track_list_dialog.dart';
import '../widgets/list/cover_grid.dart';
import '../widgets/list/song_list.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/streaming/empty_state.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 哔哩哔哩资料库（隐藏路由 `/bilibili`，由账号菜单进入）。
///
/// 三个页签：
/// - 发现：新歌 / 推荐 / 热门（公开）+ 关注（需登录）；
/// - 收藏：当前账号的收藏夹，点开复用通用曲目弹窗；
/// - 历史：服务端观看历史，游标分页。
///
/// 播放前统一走 `SourcePlatform.preparePlay`，多P视频会先弹分P选择；
/// 播放与下载只使用 AAC 音频轨（见 Bilibili 源适配器）。
class BilibiliPage extends ConsumerStatefulWidget {
  const BilibiliPage({super.key});

  @override
  ConsumerState<BilibiliPage> createState() => _BilibiliPageState();
}

class _BilibiliPageState extends ConsumerState<BilibiliPage> {
  static const _sections = <String>[
    'newSongs',
    'recommendations',
    'popular',
    'following',
  ];

  String _tab = 'discover';
  String _section = 'newSongs';

  /// 上一次观察到的登录态（用于清缓存 / 按需刷新）。
  bool? _loggedIn;

  final Map<String, List<Track>> _discoverItems = {};
  final Map<String, String?> _discoverCursor = {};
  final Map<String, String> _discoverErrors = {};
  final Set<String> _discoverLoading = {};
  final Set<String> _discoverLoaded = {};

  List<BilibiliFavFolder> _folders = const [];
  bool _foldersLoading = false;
  bool _foldersLoaded = false;
  String _foldersError = '';

  final List<Track> _history = [];
  String? _historyCursor;
  bool _historyLoading = false;
  bool _historyLoaded = false;
  String _historyError = '';

  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _loadDiscovery(_section);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;

    // BilibiliApi 是 ChangeNotifier：登录/退出都会触发重建。
    final api = ref.watch(bilibiliApiProvider);
    final loggedIn = api.isLoggedIn;
    if (_loggedIn != loggedIn) {
      _loggedIn = loggedIn;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onAuthChanged(loggedIn);
      });
    }

    final nickname = api.profile?.nickname.trim() ?? '';
    final subtitle = loggedIn
        ? (nickname.isEmpty ? l10n.brandBilibili : nickname)
        : l10n.bilibiliLoginToView;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 标题 + 页签 ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.bilibiliLibraryTitle,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SSegmented<String>(
                  options: [
                    SSegmentedOption('discover', l10n.pageHomeTitle),
                    SSegmentedOption('favorites', l10n.sidebarFavorites),
                    SSegmentedOption('history', l10n.sidebarHistory),
                  ],
                  selected: _tab,
                  onChanged: _switchTab,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_tab == 'discover')
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Row(
                children: [
                  SSegmented<String>(
                    options: [
                      for (final s in _sections)
                        SSegmentedOption(s, _sectionLabel(l10n, s)),
                    ],
                    selected: _section,
                    onChanged: _switchSection,
                  ),
                  const Spacer(),
                  SButton(
                    label: l10n.commonRefresh,
                    icon: EtaIcons.refresh,
                    variant: SButtonVariant.secondary,
                    size: SButtonSize.small,
                    onPressed: _refreshCurrent,
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  // ── 内容区 ───────────────────────────────────────────────────────────

  Widget _buildContent() => switch (_tab) {
    'favorites' => _buildFavorites(),
    'history' => _buildHistory(),
    _ => _buildDiscover(),
  };

  Widget _buildDiscover() {
    final l10n = context.l10n;
    if (_section == 'following' && _loggedIn != true) {
      return StreamingEmptyState(
        icon: EtaIcons.userOutline,
        title: l10n.bilibiliFollowing,
        subtitle: l10n.bilibiliLoginToView,
        buttonLabel: l10n.navHeaderQrLogin,
        buttonIcon: EtaIcons.qrcode,
        onButton: _login,
      );
    }

    final items = _discoverItems[_section] ?? const <Track>[];
    final loading = _discoverLoading.contains(_section);
    final error = _discoverErrors[_section] ?? '';
    if (items.isEmpty) {
      if (loading) return _spinner();
      if (error.isNotEmpty) {
        return StreamingEmptyState(
          icon: EtaIcons.music2Outline,
          title: l10n.commonLoadFailed(msg: error),
          subtitleError: true,
          buttonLabel: l10n.commonRetry,
          buttonIcon: EtaIcons.refresh,
          onButton: () => _loadDiscovery(_section, append: false, force: true),
        );
      }
      return StreamingEmptyState(
        icon: EtaIcons.music2Outline,
        title: l10n.commonEmptyContent,
        buttonLabel: l10n.commonRefresh,
        buttonIcon: EtaIcons.refresh,
        onButton: _refreshCurrent,
      );
    }
    return _songList(
      items,
      hasMore: _discoverCursor[_section] != null,
      loadingMore: loading,
      key: PageStorageKey('page.bilibili.discover.$_section'),
      onReachBottom: () => _loadDiscovery(_section, append: true),
    );
  }

  Widget _buildFavorites() {
    final l10n = context.l10n;
    if (_loggedIn != true) {
      return StreamingEmptyState(
        icon: EtaIcons.starOutline,
        title: l10n.bilibiliFavoritesLogin,
        subtitle: l10n.bilibiliLoginToView,
        buttonLabel: l10n.navHeaderQrLogin,
        buttonIcon: EtaIcons.qrcode,
        onButton: _login,
      );
    }
    if (_foldersLoading && _folders.isEmpty) return _spinner();
    if (_foldersError.isNotEmpty && _folders.isEmpty) {
      return StreamingEmptyState(
        icon: EtaIcons.starOutline,
        title: l10n.commonLoadFailed(msg: _foldersError),
        subtitleError: true,
        buttonLabel: l10n.commonRetry,
        buttonIcon: EtaIcons.refresh,
        onButton: () => _loadFolders(force: true),
      );
    }
    if (_folders.isEmpty) {
      return StreamingEmptyState(
        icon: EtaIcons.starOutline,
        title: l10n.bilibiliEmptyFavorites,
        buttonLabel: l10n.commonRefresh,
        buttonIcon: EtaIcons.refresh,
        onButton: () => _loadFolders(force: true),
      );
    }
    return CoverGrid(
      items: [
        for (final folder in _folders)
          CoverItem(
            id: folder.id,
            title: folder.title,
            cover: folder.cover,
            subtitle: l10n.commonSongCountHint(count: folder.count),
            trackCount: folder.count,
            source: 'bilibili',
          ),
      ],
      onTap: (item) => _openFolder(item.id),
      onPlay: (item) => _openFolder(item.id),
      showSource: true,
    );
  }

  Widget _buildHistory() {
    final l10n = context.l10n;
    if (_loggedIn != true) {
      return StreamingEmptyState(
        icon: EtaIcons.history,
        title: l10n.bilibiliHistoryLogin,
        subtitle: l10n.bilibiliLoginToView,
        buttonLabel: l10n.navHeaderQrLogin,
        buttonIcon: EtaIcons.qrcode,
        onButton: _login,
      );
    }
    if (_history.isEmpty) {
      if (_historyLoading) return _spinner();
      if (_historyError.isNotEmpty) {
        return StreamingEmptyState(
          icon: EtaIcons.history,
          title: l10n.commonLoadFailed(msg: _historyError),
          subtitleError: true,
          buttonLabel: l10n.commonRetry,
          buttonIcon: EtaIcons.refresh,
          onButton: () => _loadHistory(force: true),
        );
      }
      return StreamingEmptyState(
        icon: EtaIcons.history,
        title: l10n.bilibiliEmptyHistory,
        buttonLabel: l10n.commonRefresh,
        buttonIcon: EtaIcons.refresh,
        onButton: () => _loadHistory(force: true),
      );
    }
    return _songList(
      _history,
      hasMore: _historyCursor != null,
      loadingMore: _historyLoading,
      key: const PageStorageKey('page.bilibili.history'),
      onReachBottom: () => _loadHistory(append: true),
    );
  }

  Widget _songList(
    List<Track> items, {
    required bool hasMore,
    required bool loadingMore,
    required Key key,
    required VoidCallback onReachBottom,
  }) {
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    return SongList(
      key: key,
      items: items,
      playingId: playingId,
      isPlaying: isPlaying,
      showAlbum: false,
      hasMore: hasMore,
      loadingMore: loadingMore,
      onReachBottom: onReachBottom,
      onPlay: _playTrack,
      onContextMenu: _onRowMenu,
    );
  }

  Widget _spinner() => const Center(
    child: SizedBox(
      width: 28,
      height: 28,
      child: CircularProgressIndicator(strokeWidth: 2.5),
    ),
  );

  String _sectionLabel(AppLocalizations l10n, String section) =>
      switch (section) {
        'recommendations' => l10n.bilibiliRecommendations,
        'popular' => l10n.bilibiliPopular,
        'following' => l10n.bilibiliFollowing,
        _ => l10n.bilibiliNewSongs,
      };

  // ── 数据加载 ─────────────────────────────────────────────────────────

  Future<void> _loadDiscovery(
    String section, {
    bool append = false,
    bool force = false,
  }) async {
    if (section == 'following' && _loggedIn != true) return;
    if (_discoverLoading.contains(section)) return;
    if (!append && !force && _discoverLoaded.contains(section)) return;
    final cursor = append ? _discoverCursor[section] : null;
    if (append && cursor == null) return;

    setState(() {
      _discoverLoading.add(section);
      _discoverErrors.remove(section);
    });
    try {
      final page = await ref
          .read(bilibiliApiProvider)
          .discovery(section, cursor: cursor);
      if (!mounted) return;
      final merged = append
          ? [...(_discoverItems[section] ?? const <Track>[])]
          : <Track>[];
      final seen = {for (final t in merged) t.id};
      for (final track in page.items) {
        if (seen.add(track.id)) merged.add(track);
      }
      setState(() {
        _discoverItems[section] = merged;
        _discoverCursor[section] = page.nextCursor;
        _discoverLoaded.add(section);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _discoverErrors[section] = _describeError(e));
    } finally {
      if (mounted) setState(() => _discoverLoading.remove(section));
    }
  }

  Future<void> _loadFolders({bool force = false}) async {
    if (_loggedIn != true || _foldersLoading) return;
    if (_foldersLoaded && !force) return;
    setState(() {
      _foldersLoading = true;
      _foldersError = '';
    });
    try {
      final folders = await ref.read(bilibiliApiProvider).favoriteFolders();
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _foldersLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _foldersError = _describeError(e));
    } finally {
      if (mounted) setState(() => _foldersLoading = false);
    }
  }

  Future<void> _loadHistory({bool append = false, bool force = false}) async {
    if (_loggedIn != true || _historyLoading) return;
    if (!append && !force && _historyLoaded) return;
    final cursor = append ? _historyCursor : null;
    if (append && cursor == null) return;

    setState(() {
      _historyLoading = true;
      _historyError = '';
    });
    try {
      final page = await ref.read(bilibiliApiProvider).history(cursor: cursor);
      if (!mounted) return;
      setState(() {
        if (!append) _history.clear();
        final seen = {for (final t in _history) t.id};
        for (final track in page.items) {
          if (seen.add(track.id)) _history.add(track);
        }
        _historyCursor = page.nextCursor;
        _historyLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _historyError = _describeError(e));
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  void _refreshCurrent() {
    switch (_tab) {
      case 'favorites':
        _loadFolders(force: true);
      case 'history':
        _loadHistory(force: true);
      default:
        _loadDiscovery(_section, force: true);
    }
  }

  void _switchTab(String tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    switch (tab) {
      case 'favorites':
        _loadFolders();
      case 'history':
        _loadHistory();
      default:
        _loadDiscovery(_section);
    }
  }

  void _switchSection(String section) {
    if (_section == section) return;
    setState(() => _section = section);
    _loadDiscovery(section);
  }

  /// 登录态变化：清空账号相关缓存，登录后按当前页签拉取。
  void _onAuthChanged(bool loggedIn) {
    setState(() {
      _folders = const [];
      _foldersLoaded = false;
      _foldersError = '';
      _history.clear();
      _historyCursor = null;
      _historyLoaded = false;
      _historyError = '';
      _discoverItems.remove('following');
      _discoverCursor.remove('following');
      _discoverErrors.remove('following');
      _discoverLoaded.remove('following');
    });
    if (!loggedIn) return;
    if (_tab == 'favorites') _loadFolders();
    if (_tab == 'history') _loadHistory();
    if (_tab == 'discover' && _section == 'following') {
      _loadDiscovery('following');
    }
  }

  // ── 操作 ─────────────────────────────────────────────────────────────

  Future<void> _login() async {
    await sourcePlatform('bilibili').login(context);
  }

  Future<void> _openFolder(String folderId) {
    final folder = _folders.where((f) => f.id == folderId).firstOrNull;
    final api = ref.read(bilibiliApiProvider);
    return showKugouTracksDialog(
      context,
      title: folder?.title ?? context.l10n.sidebarFavorites,
      subtitle: folder == null
          ? null
          : context.l10n.commonSongCountHint(count: folder.count),
      cover: folder?.cover,
      loadTracks: (_) => api.favoriteTracksAll(folderId),
    );
  }

  Future<void> _playTrack(Track track) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final platform = sourcePlatform(track.source);
      // 多P视频在这里弹分P选择；单P直接返回补齐后的 Track。
      final prepared = await platform.preparePlay(context, ref, track);
      if (!mounted || prepared == null) return;
      final url = await platform.resolvePlayUrl(ref, prepared, quality: 'hq');
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        toast(context.l10n.trackListNoPlayableSource);
        return;
      }
      await ref
          .read(playbackProvider.notifier)
          .playNow(prepared, resolvedUrl: url);
    } catch (e) {
      if (mounted) {
        toast(context.l10n.trackListPlaySourceFailed(msg: '$e'));
      }
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  void _onRowMenu(Track track, Offset global) {
    showTrackContextMenu(
      context,
      ref: ref,
      track: track,
      position: global,
      onPlay: () => _playTrack(track),
    );
  }

  String _describeError(Object error) {
    // 服务端判定会话失效：清本地登录态，页面自动回到登录引导。
    if (error is BilibiliApiException &&
        error.kind == BilibiliErrorKind.authRequired) {
      scheduleMicrotask(() {
        if (mounted) ref.read(bilibiliApiProvider).logout();
      });
    }
    return sourcePlatform('bilibili').searchErrorDetail(context.l10n, error);
  }
}
