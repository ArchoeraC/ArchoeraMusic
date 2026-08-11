import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/netease_api.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/app_prefs.dart';
import '../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../widgets/list/cover_grid.dart';
import '../widgets/dialogs/netease_login_dialog.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/common/toast.dart';
import '../widgets/dialogs/track_list_dialog.dart';
import '../widgets/home/action_card.dart';
import '../widgets/home/daily_hero.dart';
import '../widgets/home/section_title.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomeData {
  const _HomeData({
    this.playlists = const [],
    this.albums = const [],
    this.artists = const [],
  });

  final List<CoverItem> playlists;
  final List<CoverItem> albums;
  final List<CoverItem> artists;

  bool get loaded =>
      playlists.isNotEmpty || albums.isNotEmpty || artists.isNotEmpty;
}

class _HomePageState extends ConsumerState<HomePage> {
  _HomeData _data = const _HomeData();
  bool _loading = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _fetchAll();
  }

  Future<void> _fetchAll() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final api = ref.read(neteaseApiProvider);
      final results = await Future.wait<Object>([
        api.personalized(limit: 16),
        api.newAlbums(limit: 16),
        api.topArtists(limit: 16),
      ]);
      if (!mounted) return;
      setState(() {
        _data = _HomeData(
          playlists: results[0] as List<CoverItem>,
          albums: results[1] as List<CoverItem>,
          artists: results[2] as List<CoverItem>,
        );
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _toast(String msg) => toast(msg);

  void _openDaily() {
    final l10n = context.l10n;
    final account = ref.read(neteaseAuthProvider);
    if (account == null) {
      _toast(l10n.toastDailyRequiresLogin(l10n.platformNetease));
      showNeteaseLoginDialog(context);
      return;
    }
    showDailyRecommendDialog(context);
  }

  void _openPlaylist(CoverItem playlist) {
    showPlaylistDetailDialog(context, playlist);
  }

  void _openAlbum(CoverItem album) {
    showNeteaseAlbumDialog(context, album);
  }

  void _openArtist(CoverItem artist) {
    showNeteaseArtistDialog(context, artist);
  }

  Future<void> _playAllPlaylist(CoverItem playlist) async {
    final l10n = context.l10n;
    try {
      final detail = await ref
          .read(neteaseApiProvider)
          .playlistDetail(playlist.id);
      final tracks = detail.tracks;
      if (tracks.isEmpty) {
        _toast(l10n.toastPlaylistEmpty);
        return;
      }
      ref.read(playbackProvider.notifier).playQueue(tracks);
      _toast(l10n.toastPlayedAll(tracks.length));
    } catch (e) {
      _toast(l10n.toastPlayFailed('$e'));
    }
  }

  Future<void> _playAllAlbum(CoverItem album) async {
    final l10n = context.l10n;
    try {
      final tracks =
          await ref.read(neteaseApiProvider).albumTracks(album.id);
      if (tracks.isEmpty) {
        _toast(l10n.toastAlbumEmpty);
        return;
      }
      ref.read(playbackProvider.notifier).playQueue(tracks);
      _toast(l10n.toastPlayedAll(tracks.length));
    } catch (e) {
      _toast(l10n.toastPlayFailed('$e'));
    }
  }

  void _openRank() {
    final l10n = context.l10n;
    showKugouBrowseDialog(
      context,
      title: l10n.pageHomeRankTitle,
      loader: (ref) => ref.read(kugouApiProvider).rankList(),
      onItemTap: (ctx, rank) => showKugouRankDialog(ctx, rank),
    );
  }

  void _openPlaylistSquare() {
    final l10n = context.l10n;
    showKugouBrowseDialog(
      context,
      title: l10n.pageHomePlaylistSquare,
      loader: (ref) => ref.read(kugouApiProvider).topPlaylists(),
      onItemTap: (ctx, playlist) => showKugouPlaylistDetailDialog(ctx, playlist),
    );
  }

  void _openMoreArtists() {
    final l10n = context.l10n;
    showKugouBrowseDialog(
      context,
      title: l10n.pageHomeHotArtists,
      loader: (ref) => ref.read(neteaseApiProvider).topArtists(limit: 50),
      onItemTap: (ctx, artist) => showNeteaseArtistDialog(ctx, artist),
      artist: true,
    );
  }

  void _openMorePlaylists() {
    final l10n = context.l10n;
    showKugouBrowseDialog(
      context,
      title: l10n.pageHomePlaylists,
      loader: (ref) => ref.read(neteaseApiProvider).personalized(limit: 50),
      onItemTap: (ctx, playlist) => showPlaylistDetailDialog(ctx, playlist),
    );
  }

  void _openMoreAlbums() {
    final l10n = context.l10n;
    showKugouBrowseDialog(
      context,
      title: l10n.pageHomeNewAlbums,
      loader: (ref) => ref.read(neteaseApiProvider).newAlbums(limit: 50),
      onItemTap: (ctx, album) => showNeteaseAlbumDialog(ctx, album),
    );
  }

  String _greetingText(AppLocalizations l10n) {
    final hour = DateTime.now().hour;
    if (hour < 5) return l10n.greetingLate;
    if (hour < 12) return l10n.greetingMorning;
    if (hour < 18) return l10n.greetingAfternoon;
    return l10n.greetingEvening;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final account = ref.watch(neteaseAuthProvider);
    final coverRadius = ref.watch(appPrefsProvider).coverRadius;

    final greeting = _greetingText(l10n);
    final name = account?.nickname.isNotEmpty == true
        ? account!.nickname
        : l10n.greetingFallback;

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1240),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.pageHomeTitle,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.pageHomeGreeting(greeting, name),
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: 20),
                HomeDailyHero(
                  loggedIn: account != null,
                  title: l10n.pageHomeDaily,
                  subtitleLoggedIn: l10n.pageHomeDailyLoggedIn,
                  subtitleLoginHint: l10n.pageHomeDailyLoginHint,
                  playLabel: l10n.pageHomeDailyPlay,
                  loginLabel: l10n.pageHomeDailyLogin,
                  onPlay: _openDaily,
                ),
                const SizedBox(height: 20),
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 2.3,
                  children: [
                    HomeActionCard(
                      icon: Icons.wb_sunny_outlined,
                      title: l10n.pageHomeDaily,
                      subtitle: l10n.trackListDailyRecommendSubtitle,
                      onTap: _openDaily,
                    ),
                    HomeActionCard(
                      icon: Icons.leaderboard_outlined,
                      title: l10n.pageHomeRankTitle,
                      subtitle: l10n.pageHomeRankSubtitle,
                      onTap: _openRank,
                    ),
                    HomeActionCard(
                      icon: Icons.queue_music_outlined,
                      title: l10n.pageHomePlaylistSquare,
                      subtitle: l10n.pageHomePlaylistSquareSubtitle,
                      onTap: _openPlaylistSquare,
                    ),
                    HomeActionCard(
                      icon: Icons.mic_external_on_outlined,
                      title: l10n.commonArtists,
                      subtitle: l10n.pageHomeArtistSubtitle,
                      onTap: _openMoreArtists,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (_loading && !_data.loaded)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 80),
                    child: Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    ),
                  )
                else if (_error.isNotEmpty && !_data.loaded)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 60),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.cloud_off_outlined,
                              size: 44, color: scheme.error),
                          const SizedBox(height: 10),
                          Text(
                            l10n.pageHomeLoadFailed,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _error,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 14),
                          SButton(
                            label: l10n.commonRetry,
                            icon: Icons.refresh,
                            variant: SButtonVariant.secondary,
                            onPressed: _fetchAll,
                          ),
                        ],
                      ),
                    ),
                  )
                else ...[
                  HomeSectionTitle(
                    title: l10n.pageHomePlaylists,
                    subtitle: l10n.pageHomePlaylistsSubtitle,
                    moreLabel: l10n.commonMore,
                    onMore: _openMorePlaylists,
                  ),
                  CoverRail(
                    items: _data.playlists,
                    onTap: _openPlaylist,
                    onPlay: _playAllPlaylist,
                    radius: coverRadius,
                    cardWidth: 150,
                    height: 198,
                    loading: _loading && _data.playlists.isEmpty,
                  ),
                  const SizedBox(height: 26),
                  HomeSectionTitle(
                    title: l10n.pageHomeNewAlbums,
                    subtitle: l10n.pageHomeNewAlbumsSubtitle,
                    moreLabel: l10n.commonMore,
                    onMore: _openMoreAlbums,
                  ),
                  CoverRail(
                    items: _data.albums,
                    onTap: _openAlbum,
                    onPlay: _playAllAlbum,
                    radius: coverRadius,
                    cardWidth: 150,
                    height: 198,
                    loading: _loading && _data.albums.isEmpty,
                  ),
                  const SizedBox(height: 26),
                  HomeSectionTitle(
                    title: l10n.pageHomeHotArtists,
                    subtitle: l10n.pageHomeHotArtistsSubtitle,
                    moreLabel: l10n.commonMore,
                    onMore: _openMoreArtists,
                  ),
                  CoverRail(
                    items: _data.artists,
                    onTap: _openArtist,
                    artist: true,
                    radius: coverRadius,
                    cardWidth: 150,
                    height: 198,
                    loading: _loading && _data.artists.isEmpty,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
