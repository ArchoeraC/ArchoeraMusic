/// 流媒体主页（对齐 SPlayer-Next Streaming/Index.vue）。
///
/// 顶栏：标题 + 数量统计；右侧状态点 / 服务器下拉 / 刷新 / 设置。
/// Tab：歌曲 / 专辑 / 歌手 / 歌单（懒加载缓存，切换 Tab 拉取）。
/// 状态机：无服务器 → 空态引导去设置；已配置未连接 → 错误 + 重连；
/// 已连接 → 四个 Tab 内容（歌曲列表 / 封面网格）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/netease/netease_api.dart';
import '../../core/netease/track.dart';
import '../../core/playback/playback_notifier.dart';
import '../../core/streaming/streaming_client.dart';
import '../../core/streaming/streaming_models.dart';
import '../../core/streaming/streaming_provider.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../settings/settings_dialog.dart';
import '../widgets/cover_grid.dart';
import '../widgets/s_controls.dart';
import '../widgets/song_list.dart';
import '../widgets/track_context_menu.dart';

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

  void _onTabChanged() {
    if (_tab.indexIsChanging) return;
    _fetchCurrent();
  }

  void _fetchCurrent() {
    final n = ref.read(streamingProvider.notifier);
    switch (_tab.index) {
      case 0:
        n.fetchSongs();
      case 1:
        n.fetchAlbums();
      case 2:
        n.fetchArtists();
      default:
        n.fetchPlaylists();
    }
  }

  void _refreshCurrent() {
    final n = ref.read(streamingProvider.notifier);
    switch (_tab.index) {
      case 0:
        n.refresh(tab: 'songs');
      case 1:
        n.refresh(tab: 'albums');
      case 2:
        n.refresh(tab: 'artists');
      default:
        n.refresh(tab: 'playlists');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(streamingProvider);

    // 连接成功 → 自动拉取当前 Tab 数据
    ref.listen(streamingProvider.select((s) => s.connected), (_, connected) {
      if (connected) _fetchCurrent();
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 顶栏 ─────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(
                      l10n.sidebarStreaming,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (state.activeServer != null) ...[
                      const SizedBox(width: 12),
                      _CountLabel(
                        index: _tab.index,
                        state: state,
                        l10n: l10n,
                      ),
                    ],
                  ],
                ),
              ),
              if (state.activeServer != null) ...[
                _StatusDot(state: state, scheme: scheme),
                const SizedBox(width: 10),
                _ServerDropdown(state: state),
                const SizedBox(width: 8),
                SButton(
                  label: '',
                  icon: Icons.refresh,
                  variant: SButtonVariant.secondary,
                  size: SButtonSize.medium,
                  circle: true,
                  loading: state.loading,
                  onPressed: (state.connected && !state.loading)
                      ? _refreshCurrent
                      : null,
                ),
                const SizedBox(width: 8),
                SButton(
                  label: '',
                  icon: Icons.settings_outlined,
                  variant: SButtonVariant.secondary,
                  size: SButtonSize.medium,
                  circle: true,
                  onPressed: () => showSettingsDialog(
                    context,
                    category: SettingsCategory.mediaSource,
                  ),
                ),
              ],
            ],
          ),
        ),
        // ── Tab ──────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TabBar(
            controller: _tab,
            isScrollable: false,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: l10n.streamingTabsSongs),
              Tab(text: l10n.streamingTabsAlbums),
              Tab(text: l10n.streamingTabsArtists),
              Tab(text: l10n.streamingTabsPlaylists),
            ],
          ),
        ),
        const Divider(height: 1),
        // ── 内容状态机 ────────────────────────────────────────
        Expanded(child: _buildContent(state, l10n, scheme)),
      ],
    );
  }

  Widget _buildContent(
    StreamingState state,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    // 未配置任何服务器
    if (state.servers.isEmpty) {
      return _EmptyState(
        icon: Icons.dns_outlined,
        title: l10n.streamingEmptyNoServer,
        subtitle: l10n.streamingEmptyAddHint,
        buttonLabel: l10n.streamingEmptyGoToSettings,
        onButton: () => showSettingsDialog(
          context,
          category: SettingsCategory.mediaSource,
        ),
      );
    }
    // 已配置但未连接
    if (!state.connected) {
      return _EmptyState(
        icon: Icons.link_off,
        title: l10n.streamingEmptyNotConnected,
        subtitle: state.connectionError ??
            state.activeServer?.name ??
            l10n.streamingServerDisconnected,
        subtitleError: state.connectionError != null,
        buttonLabel: l10n.streamingServerConnect,
        buttonLoading: state.connecting,
        onButton: () => ref.read(streamingProvider.notifier).connect(),
      );
    }
    // 已连接：四个 Tab 内容（IndexedStack 保留滚动位置）
    return IndexedStack(
      index: _tab.index,
      children: const [
        _SongsTab(),
        _AlbumsTab(),
        _ArtistsTab(),
        _PlaylistsTab(),
      ],
    );
  }
}

/// 顶栏数量统计（跟随当前 Tab）。
class _CountLabel extends StatelessWidget {
  const _CountLabel({required this.index, required this.state, required this.l10n});

  final int index;
  final StreamingState state;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String text;
    switch (index) {
      case 0:
        text = l10n.streamingTotalSongs(state.songs.length);
      case 1:
        text = l10n.streamingTotalAlbums(state.albums.length);
      case 2:
        text = l10n.streamingTotalArtists(state.artists.length);
      default:
        text = l10n.streamingTotalPlaylists(state.playlists.length);
    }
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12.5,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
      ),
    );
  }
}

/// 连接状态点（绿=已连接 / 红=连接出错 / 琥珀=待连接）。
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.state, required this.scheme});

  final StreamingState state;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final color = state.connected
        ? const Color(0xFF34C759)
        : (state.connectionError != null && !state.connecting)
            ? scheme.error
            : const Color(0xFFFFB340);
    return Tooltip(
      message: state.connected
          ? (state.serverVersion != null
              ? '${context.l10n.streamingServerConnected} · v${state.serverVersion}'
              : context.l10n.streamingServerConnected)
          : (state.connecting
                ? context.l10n.commonLoading
                : context.l10n.streamingServerDisconnected),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 4),
          ],
        ),
      ),
    );
  }
}

/// 服务器下拉（切换激活服务器）。
class _ServerDropdown extends ConsumerWidget {
  const _ServerDropdown({required this.state});

  final StreamingState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final activeId = state.activeServerId ?? '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(100),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: state.servers.any((s) => s.id == activeId) ? activeId : null,
          isDense: true,
          borderRadius: BorderRadius.circular(10),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
          icon: Icon(Icons.arrow_drop_down, color: scheme.onSurfaceVariant),
          onChanged: state.connecting
              ? null
              : (id) {
                  if (id == null || id == activeId) return;
                  ref.read(streamingProvider.notifier).setActiveServer(id);
                },
          items: [
            for (final s in state.servers)
              DropdownMenuItem(
                value: s.id,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 空态 / 错误态通用组件。
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleError = false,
    this.buttonLabel,
    this.buttonLoading = false,
    this.onButton,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool subtitleError;
  final String? buttonLabel;
  final bool buttonLoading;
  final VoidCallback? onButton;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.onSurfaceVariant.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: subtitleError
                      ? scheme.error
                      : scheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
            ],
            if (buttonLabel != null) ...[
              const SizedBox(height: 16),
              SButton(
                label: buttonLabel!,
                icon: Icons.link,
                variant: SButtonVariant.primary,
                size: SButtonSize.medium,
                loading: buttonLoading,
                onPressed: onButton,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 歌曲 Tab：播放全部 + 本地过滤搜索 + 歌曲列表。
class _SongsTab extends ConsumerStatefulWidget {
  const _SongsTab();

  @override
  ConsumerState<_SongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends ConsumerState<_SongsTab> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Track> _filtered(List<Track> songs) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return songs;
    return songs
        .where((t) =>
            t.title.toLowerCase().contains(q) ||
            t.artistNames.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(streamingProvider);
    final playback = ref.watch(playbackProvider);
    final songs = state.songs;
    final filtered = _filtered(songs);
    final notifier = ref.read(playbackProvider.notifier);

    void playList(List<Track> list, Track start) {
      final idx = list.indexWhere((t) => t.id == start.id);
      notifier.playQueue(list, startIndex: idx < 0 ? 0 : idx);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 操作栏：播放全部 + 搜索
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
          child: Row(
            children: [
              SButton(
                label: l10n.commonPlayAll,
                icon: Icons.play_arrow,
                variant: SButtonVariant.primary,
                size: SButtonSize.small,
                onPressed: songs.isEmpty
                    ? null
                    : () => notifier.playQueue(songs),
              ),
              const Spacer(),
              SizedBox(
                width: 200,
                child: SInput(
                  controller: _searchCtrl,
                  hintText: l10n.commonSearch,
                  prefixIcon: Icons.search,
                  clearable: true,
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ],
          ),
        ),
        if (songs.isEmpty && !state.loading)
          Expanded(
            child: Center(
              child: Text(
                l10n.streamingEmptyNoResults,
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ),
            ),
          )
        else
          Expanded(
            child: SongList(
              items: filtered,
              playingId: playback.trackId,
              isPlaying: playback.playing,
              showSource: false,
              onPlay: (t) => playList(filtered, t),
              onContextMenu: (t, pos) => showTrackContextMenu(
                context,
                ref: ref,
                track: t,
                position: pos,
                onPlay: () => playList(filtered, t),
              ),
            ),
          ),
      ],
    );
  }
}

/// 专辑 Tab：封面网格。
class _AlbumsTab extends ConsumerWidget {
  const _AlbumsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final albums = ref.watch(streamingProvider.select((s) => s.albums));
    final loading = ref.watch(streamingProvider.select((s) => s.loading));

    if (albums.isEmpty && !loading) {
      return Center(
        child: Text(
          l10n.streamingEmptyNoResults,
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    return CoverGrid(
      items: [
        for (final a in albums)
          CoverItem(
            id: a.id,
            title: a.name,
            cover: a.cover,
            subtitle: a.artist ?? '',
            trackCount: a.trackCount ?? 0,
          ),
      ],
      loading: loading,
      onTap: (item) => context.push('/streaming/album/${Uri.encodeComponent(item.id)}'),
      onPlay: (item) {
        final all = albums;
        final idx = all.indexWhere((a) => a.id == item.id);
        if (idx < 0) return;
        _playAlbum(ref, all[idx]);
      },
    );
  }
}

/// 歌手 Tab：圆形头像网格。
class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final artists = ref.watch(streamingProvider.select((s) => s.artists));
    final loading = ref.watch(streamingProvider.select((s) => s.loading));

    if (artists.isEmpty && !loading) {
      return Center(
        child: Text(
          l10n.streamingEmptyNoResults,
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    return CoverGrid(
      items: [
        for (final a in artists)
          CoverItem(
            id: a.id,
            title: a.name,
            cover: a.avatar,
            subtitle: a.albumCount != null
                ? l10n.streamingArtistAlbums(a.albumCount!)
                : '',
          ),
      ],
      loading: loading,
      artist: true,
      onTap: (item) =>
          context.push('/streaming/artist/${Uri.encodeComponent(item.id)}'),
    );
  }
}

/// 歌单 Tab：封面网格。
class _PlaylistsTab extends ConsumerWidget {
  const _PlaylistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final playlists = ref.watch(streamingProvider.select((s) => s.playlists));
    final loading = ref.watch(streamingProvider.select((s) => s.loading));

    if (playlists.isEmpty && !loading) {
      return Center(
        child: Text(
          l10n.streamingEmptyNoResults,
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    return CoverGrid(
      items: [
        for (final p in playlists)
          CoverItem(
            id: p.id,
            title: p.name,
            cover: p.cover,
            subtitle: p.owner ?? '',
            trackCount: p.trackCount ?? 0,
          ),
      ],
      loading: loading,
      onTap: (item) =>
          context.push('/streaming/playlist/${Uri.encodeComponent(item.id)}'),
      onPlay: (item) {
        final all = playlists;
        final idx = all.indexWhere((p) => p.id == item.id);
        if (idx < 0) return;
        _playPlaylist(ref, all[idx]);
      },
    );
  }
}

/// 播放整张专辑（进入专辑页拉取后播放）。
Future<void> _playAlbum(WidgetRef ref, StreamingAlbum album) async {
  final cfg = ref.read(streamingProvider).activeServer;
  if (cfg == null) return;
  try {
    final songs = await StreamingClient(cfg).getAlbumSongs(album.id);
    if (songs.isEmpty) return;
    ref.read(playbackProvider.notifier).playQueue(songs);
  } catch (_) {
    // 失败静默（详情页可完整播放）
  }
}

/// 播放整个歌单。
Future<void> _playPlaylist(WidgetRef ref, StreamingPlaylist playlist) async {
  final cfg = ref.read(streamingProvider).activeServer;
  if (cfg == null) return;
  try {
    final songs = await StreamingClient(cfg).getPlaylistSongs(playlist.id);
    if (songs.isEmpty) return;
    ref.read(playbackProvider.notifier).playQueue(songs);
  } catch (_) {
    // 失败静默
  }
}
