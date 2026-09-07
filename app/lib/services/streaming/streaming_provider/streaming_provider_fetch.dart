part of '../streaming_provider.dart';

mixin _StreamingNotifierFetchActions on Notifier<StreamingState>, _StreamingNotifierCore {
  bool get _fetching;
  set _fetching(bool value);

  /// 拉歌曲列表（懒加载：首次或显式刷新才请求）。
  Future<void> _fetchSongsImpl({bool force = false}) async {
    final client = _client;
    if (client == null || _fetching) return;
    if (_songsLoaded && !force) return;
    _fetching = true;
    _setLoading(true);
    try {
      final songs = await client.listSongs();
      state = state.copyWith(songs: songs);
      _songsLoaded = true;
    } catch (_) {
      // 拉取失败保留旧数据；连接断开由 UI 空态提示
    } finally {
      _fetching = false;
      _setLoading(false);
    }
  }

  Future<void> _fetchAlbumsImpl({bool force = false}) async {
    final client = _client;
    if (client == null || _fetching) return;
    if (_albumsLoaded && !force) return;
    _fetching = true;
    _setLoading(true);
    try {
      final albums = await client.listAlbums();
      state = state.copyWith(albums: albums);
      _albumsLoaded = true;
    } catch (_) {
    } finally {
      _fetching = false;
      _setLoading(false);
    }
  }

  Future<void> _fetchArtistsImpl({bool force = false}) async {
    final client = _client;
    if (client == null || _fetching) return;
    if (_artistsLoaded && !force) return;
    _fetching = true;
    _setLoading(true);
    try {
      final artists = await client.listArtists();
      state = state.copyWith(artists: artists);
      _artistsLoaded = true;
    } catch (_) {
    } finally {
      _fetching = false;
      _setLoading(false);
    }
  }

  Future<void> _fetchPlaylistsImpl({bool force = false}) async {
    final client = _client;
    if (client == null || _fetching) return;
    if (_playlistsLoaded && !force) return;
    _fetching = true;
    _setLoading(true);
    try {
      final playlists = await client.listPlaylists();
      state = state.copyWith(playlists: playlists);
      _playlistsLoaded = true;
    } catch (_) {
    } finally {
      _fetching = false;
      _setLoading(false);
    }
  }

  /// 顶栏刷新：强制重拉当前数据源（可指定 tab；null = 全部）。
  Future<void> _refreshImpl({String? tab}) async {
    switch (tab) {
      case 'songs':
        await _fetchSongsImpl(force: true);
      case 'albums':
        await _fetchAlbumsImpl(force: true);
      case 'artists':
        await _fetchArtistsImpl(force: true);
      case 'playlists':
        await _fetchPlaylistsImpl(force: true);
      default:
        await Future.wait([
          _fetchSongsImpl(force: true),
          _fetchAlbumsImpl(force: true),
          _fetchArtistsImpl(force: true),
          _fetchPlaylistsImpl(force: true),
        ]);
    }
  }
}
