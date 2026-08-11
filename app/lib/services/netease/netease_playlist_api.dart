part of 'netease_api.dart';

/// 「我喜欢」/ 歌单 / 专辑·歌手收藏域。
mixin NeteasePlaylistApi on NeteaseApiBase {
  /// 用户红心歌曲 id 列表（likelist，需登录）。
  ///
  /// **仅用于红心状态判定（Set 集合），不做展示排序**：likelist 的 ids
  /// 顺序并不保证按收藏时间排列。「我喜欢」列表的展示顺序请用 [likedSongs]
  /// （走「我喜欢的音乐」歌单，trackIds 顺序即收藏先后）。
  Future<List<String>> likedIds(String uid) async {
    final body = await _call('likelist', {'uid': uid});
    final idsRaw = body?['ids'];
    if (idsRaw is! List) return const [];
    return idsRaw
        .whereType<num>()
        .map((e) => e.toInt().toString())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 「我喜欢的音乐」歌单全量 trackIds（保序，轻量：仅 id 列表）。
  ///
  /// 顺序即收藏先后（最新在前，对齐 SPlayer-Next ensureLikedPlaylist）。
  /// 分页加载先取此 id 列表，再按需分批补 song_detail 详情。
  Future<List<String>> likedTrackIds(String uid) async {
    final playlists = await userPlaylists(uid, limit: 1);
    if (playlists.isEmpty) return const [];
    final body = await _call('playlist_detail', {'id': playlists.first.id});
    final playlist = body?['playlist'];
    if (playlist is! Map<String, dynamic>) return const [];
    final idsRaw = playlist['trackIds'];
    if (idsRaw is! List) return const [];
    return idsRaw
        .whereType<Map<String, dynamic>>()
        .map((t) => t['id']?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 用户喜欢的歌曲（「我喜欢的音乐」歌单全量，需登录）。
  ///
  /// 对齐 SPlayer-Next `user.ts` ensureLikedPlaylist：不直接用 likelist
  /// （ids 顺序不保证按收藏时间），而是拉取用户第一个自建歌单「我喜欢的
  /// 音乐」——歌单 trackIds 顺序即收藏先后（最新在前），经 [_songsByIds]
  /// 保序补全曲目详情。
  Future<List<Track>> likedSongs(String uid) async {
    return _songsByIds(await likedTrackIds(uid));
  }

  /// 分页取「我喜欢」歌曲（按歌单 trackIds 顺序）。
  ///
  /// 返回 `(tracks, total)`：tracks 为 [offset, offset+limit) 区间详情
  /// （song_detail 批量补全，保序），total 为收藏总数。收藏列表按需加载
  /// 用：首屏只补前 limit 首，滚动触底再取下一段，不一次性补全全量。
  Future<(List<Track>, int)> likedSongsPage(
    String uid, {
    required int offset,
    required int limit,
  }) async {
    final ids = await likedTrackIds(uid);
    if (ids.isEmpty) return (const <Track>[], 0);
    if (offset >= ids.length) return (const <Track>[], ids.length);
    final end = math.min(offset + limit, ids.length);
    final tracks = await _songsByIds(ids.sublist(offset, end));
    return (tracks, ids.length);
  }

  /// 按 id 批量取歌曲详情（song_detail，≤1000 ids/次），保持输入顺序。
  ///
  /// 收藏列表分页加载用：loader 已持有歌单 trackIds，按段传入补详情，
  /// 避免每页重新请求歌单详情。
  Future<List<Track>> songsDetailByIds(List<String> ids) => _songsByIds(ids);

  /// 红心 / 取消红心（对齐 SPlayer-Next like.ts：`trackId/like/time:3`）。
  /// 成功返回；失败（未登录/接口异常）抛 [NeteaseApiError]。
  Future<void> like(String id, {required bool like}) async {
    final body = await _call('like', {'id': id, 'like': like});
    final code = body?['code'];
    if (code is num && code != 200) {
      throw NeteaseApiError('like 失败 code=$code', body);
    }
  }

  /// 用户歌单列表（user_playlist；自建在前，收藏在后，含 subscribed 标记）。
  Future<List<PlaylistItem>> userPlaylists(
    String uid, {
    int limit = 200,
  }) async {
    final body = await _call('user_playlist', {'uid': uid, 'limit': limit});
    final playlist = body?['playlist'];
    if (playlist is! List) return const [];
    return playlist
        .whereType<Map<String, dynamic>>()
        .map(PlaylistItem.fromNetease)
        .toList();
  }

  /// 收藏的专辑（album_sublist，需登录）。
  Future<List<CoverItem>> albumSublist({
    int limit = 100,
    int offset = 0,
  }) async {
    final body = await _call('album_sublist', {
      'limit': limit,
      'offset': offset,
    });
    final data = body?['data'];
    if (data is! List) return const [];
    return data.whereType<Map<String, dynamic>>().map((a) {
      final artist = a['artist'] ?? a['artists'];
      final artistName = artist is Map<String, dynamic>
          ? artist['name']?.toString() ?? ''
          : '';
      return CoverItem(
        id: a['id'].toString(),
        title: a['name']?.toString() ?? '',
        cover: withPicSize(a['picUrl']?.toString()),
        subtitle: artistName,
        trackCount: (a['size'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  /// 收藏的歌手（artist_sublist，需登录）。
  Future<List<CoverItem>> artistSublist({
    int limit = 100,
    int offset = 0,
  }) async {
    final body = await _call('artist_sublist', {
      'limit': limit,
      'offset': offset,
    });
    final data = body?['data'];
    if (data is! List) return const [];
    return data.whereType<Map<String, dynamic>>().map((a) {
      final pic = a['img1v1Url'] ?? a['picUrl'];
      return CoverItem(
        id: a['id'].toString(),
        title: a['name']?.toString() ?? '',
        cover: withPicSize(pic?.toString()),
        subtitle: (a['albumSize'] as num?)?.toInt() == null
            ? ''
            : '${a['albumSize']} 张专辑',
      );
    }).toList();
  }

  /// 歌单详情：元信息 + 全量歌曲（playlist_detail 的 trackIds + song_detail
  /// 批量补全，避免只拿到前 8 首的 tracks 截断）。
  Future<NeteasePlaylistDetail> playlistDetail(String id) async {
    final body = await _call('playlist_detail', {'id': id});
    final playlist = body?['playlist'];
    if (playlist is! Map<String, dynamic>) {
      return const NeteasePlaylistDetail(meta: null, tracks: []);
    }
    // 优先用全量 trackIds；接口未返回时退化为返回的首批完整 tracks
    final idsRaw = playlist['trackIds'];
    var tracks = <Track>[];
    if (idsRaw is List && idsRaw.isNotEmpty) {
      final ids = idsRaw
          .whereType<Map<String, dynamic>>()
          .map((t) => t['id']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      tracks = await _songsByIds(ids);
    } else {
      final first = playlist['tracks'];
      if (first is List) {
        tracks = first
            .whereType<Map<String, dynamic>>()
            .map(Track.fromNeteaseSong)
            .toList();
      }
    }
    final creator = playlist['creator'];
    return NeteasePlaylistDetail(
      meta: PlaylistItem(
        id: playlist['id'].toString(),
        name: playlist['name']?.toString() ?? '',
        cover: withPicSize(playlist['coverImgUrl']?.toString()),
        trackCount: (playlist['trackCount'] as num?)?.toInt() ?? tracks.length,
        owner: creator is Map<String, dynamic>
            ? creator['nickname']?.toString()
            : null,
      ),
      tracks: tracks,
    );
  }

  /// 专辑详情曲目（album 模块，`/api/v1/album/{id}` → songs）。
  Future<List<Track>> albumTracks(String id) async {
    final body = await _call('album', {'id': id});
    final songs = body?['songs'];
    if (songs is! List) return const [];
    return songs
        .whereType<Map<String, dynamic>>()
        .map(Track.fromNeteaseSong)
        .toList();
  }

  /// 歌手热门歌曲（artists 模块，`/api/v1/artist/{id}` → hotSongs）。
  Future<List<Track>> artistHotSongs(String id) async {
    final body = await _call('artists', {'id': id});
    final songs = body?['hotSongs'];
    if (songs is! List) return const [];
    return songs
        .whereType<Map<String, dynamic>>()
        .map(Track.fromNeteaseSong)
        .toList();
  }

  /// 批量取歌曲详情（song_detail，≤1000 ids/次），**保持输入 id 顺序**返回。
  ///
  /// song_detail 接口返回顺序与请求顺序无关，这里建 id→Track 映射后按
  /// [ids] 逐个取出（无详情/下架的 id 跳过）。歌单依赖此保序语义
  /// （歌单 trackIds 顺序即收藏/收录先后）；likelist 不做展示排序。
  Future<List<Track>> _songsByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final byId = <String, Track>{};
    for (var i = 0; i < ids.length; i += 1000) {
      final chunk = ids.sublist(i, math.min(i + 1000, ids.length));
      final body = await _call('song_detail', {'ids': chunk.join(',')});
      final songs = body?['songs'];
      if (songs is List) {
        for (final s in songs.whereType<Map<String, dynamic>>()) {
          final t = Track.fromNeteaseSong(s);
          if (t.id.isNotEmpty) byId[t.id] = t;
        }
      }
    }
    return [
      for (final id in ids)
        if (byId.containsKey(id)) byId[id]!,
    ];
  }
}
