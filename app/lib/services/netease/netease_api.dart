/// 网易云 API 传输层：`call(name, params)` 返回网易云原始响应体
/// （`{result: {...}}` / `{data: [...]}`），由 [NeteaseApi] 统一解析。
///
/// 实现：`ApisNeteaseCaller`（纯 Dart 直连，apis 包全量移植，不经侧车）。
library;

import 'dart:math' as math;

import '../../apis/lyric/types.dart';
import '../../apis/lyric/utils.dart';
import '../../apis/netease/api.dart' show nmClearNeteaseCookies;
import 'comment.dart';
import 'track.dart';

abstract class NeteaseCaller {
  Future<Map<String, dynamic>?> call(String name, Map<String, dynamic> params);
}

/// 网易云接口业务异常（code != 200 等；对齐原项目 NeteaseApiError）。
class NeteaseApiError implements Exception {
  NeteaseApiError(this.message, [this.body]);

  final String message;
  final Map<String, dynamic>? body;

  @override
  String toString() => message;
}

/// 搜索结果（对齐原项目 apis/search 的 `SearchResult<T>`）。
class SearchResult<T> {
  const SearchResult({
    required this.items,
    required this.total,
    required this.hasMore,
  });

  final List<T> items;
  final int total;
  final bool hasMore;
}

/// 封面卡片（专辑 / 歌手 / 歌单搜索结果，对齐原项目 `CoverItem`）。
class CoverItem {
  const CoverItem({
    required this.id,
    required this.title,
    this.cover,
    this.subtitle = '',
    this.trackCount = 0,
  });

  final String id;
  final String title;
  final String? cover;
  final String subtitle;
  final int trackCount;
}

/// 音质档位 → 网易云 song_url level 参数（对齐原项目 NETEASE_LEVEL）。
const neteaseLevels = <String, String>{
  'lq': 'standard',
  'sq': 'higher',
  'hq': 'exhigh',
  'lossless': 'lossless',
  'hi-res': 'hires',
};

/// 网易云 API 封装：解析 + 业务方法，传输层由 [NeteaseCaller] 决定
/// （侧车 RPC 或 Dart 原生直连）。
///
/// 对应原项目 `src/apis/search/netease.ts` + `src/apis/song/netease.ts`；
/// caller 返回网易云原始响应体（`{result: {...}}` / `{data: [...]}`）。
class NeteaseApi {
  NeteaseApi(this._caller);

  final NeteaseCaller _caller;

  Future<Map<String, dynamic>?> _call(String name, Map<String, dynamic> params) =>
      _caller.call(name, params);

  /// cloudsearch type 编码（对齐原项目）。
  static const _typeSongs = 1;
  static const _typeAlbums = 10;
  static const _typeArtists = 100;
  static const _typePlaylists = 1000;

  /// 搜索歌曲（cloudsearch type=1）。
  Future<SearchResult<Track>> searchSongs(
    String keyword, {
    int offset = 0,
    int limit = 50,
  }) =>
      _search(
        keyword: keyword,
        type: _typeSongs,
        offset: offset,
        limit: limit,
        countKey: 'songCount',
        parse: _parseSongs,
      );

  /// 搜索专辑（cloudsearch type=10）。
  Future<SearchResult<CoverItem>> searchAlbums(
    String keyword, {
    int offset = 0,
    int limit = 50,
  }) =>
      _search(
        keyword: keyword,
        type: _typeAlbums,
        offset: offset,
        limit: limit,
        countKey: 'albumCount',
        parse: _parseAlbums,
      );

  /// 搜索歌手（cloudsearch type=100）。
  Future<SearchResult<CoverItem>> searchArtists(
    String keyword, {
    int offset = 0,
    int limit = 50,
  }) =>
      _search(
        keyword: keyword,
        type: _typeArtists,
        offset: offset,
        limit: limit,
        countKey: 'artistCount',
        parse: _parseArtists,
      );

  /// 搜索歌单（cloudsearch type=1000）。
  Future<SearchResult<CoverItem>> searchPlaylists(
    String keyword, {
    int offset = 0,
    int limit = 50,
  }) =>
      _search(
        keyword: keyword,
        type: _typePlaylists,
        offset: offset,
        limit: limit,
        countKey: 'playlistCount',
        parse: _parsePlaylists,
      );

  /// 统一 cloudsearch 调用与分页元数据（hasMore = offset + len < total）。
  Future<SearchResult<T>> _search<T>({
    required String keyword,
    required int type,
    required int offset,
    required int limit,
    required String countKey,
    required List<T> Function(Map<String, dynamic> result) parse,
  }) async {
    final body = await _call('cloudsearch', {
      'keywords': keyword,
      'type': type,
      'offset': offset,
      'limit': limit,
    });
    final result = body?['result'];
    if (result is! Map<String, dynamic>) {
      return SearchResult(items: const [], total: 0, hasMore: false);
    }
    final items = parse(result);
    final total = (result[countKey] as num?)?.toInt() ?? items.length;
    return SearchResult(
      items: items,
      total: total,
      hasMore: offset + items.length < total,
    );
  }

  /// 解析歌曲搜索结果（对齐 songsToTracks）。
  static List<Track> _parseSongs(Map<String, dynamic> result) {
    final songs = result['songs'];
    if (songs is! List) return const [];
    return songs
        .whereType<Map<String, dynamic>>()
        .map(Track.fromNeteaseSong)
        .toList();
  }

  /// 解析专辑搜索结果（对齐 albumToCover）。
  static List<CoverItem> _parseAlbums(Map<String, dynamic> result) {
    final albums = result['albums'];
    if (albums is! List) return const [];
    return albums.whereType<Map<String, dynamic>>().map((album) {
      final artists = (album['artists'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((a) => a['name']?.toString() ?? '')
          .join(' / ');
      return CoverItem(
        id: album['id'].toString(),
        title: album['name']?.toString() ?? '',
        cover: withPicSize(album['picUrl']?.toString()),
        subtitle: artists,
        trackCount: (album['size'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  /// 解析歌手搜索结果（对齐 artistToCover）。
  static List<CoverItem> _parseArtists(Map<String, dynamic> result) {
    final artists = result['artists'];
    if (artists is! List) return const [];
    return artists.whereType<Map<String, dynamic>>().map((artist) {
      final pic = artist['img1v1Url'] ?? artist['picUrl'];
      return CoverItem(
        id: artist['id'].toString(),
        title: artist['name']?.toString() ?? '',
        cover: withPicSize(pic?.toString()),
        trackCount: (artist['albumSize'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  /// 解析歌单搜索结果（对齐 playlistToCover）。
  static List<CoverItem> _parsePlaylists(Map<String, dynamic> result) {
    final playlists = result['playlists'];
    if (playlists is! List) return const [];
    return playlists.whereType<Map<String, dynamic>>().map((playlist) {
      return CoverItem(
        id: playlist['id'].toString(),
        title: playlist['name']?.toString() ?? '',
        cover: withPicSize(playlist['coverImgUrl']?.toString()),
        subtitle: playlist['creator']?['nickname']?.toString() ?? '',
        trackCount: (playlist['trackCount'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  /// 解析网易云 Track 的可播放 URL（song_url，对齐 resolveNeteaseUrl）。
  ///
  /// [quality] 为档位键（lq/sq/hq/lossless/hi-res），默认 hq（对齐原项目
  /// 默认 songLevel）。按用户偏好从高到低**自动降级**（如 lossless 失败 →
  /// hq → sq → lq），并**拒绝试听片段**（freeTrialInfo 非空 = 60s 试听，
  /// 对齐 SPlayer-Next fetchNeteasePlaySource 的 freeTrialInfo 过滤）。
  /// 全部档位失败 / VIP / 无版权时返回 null。
  Future<String?> resolvePlayUrl(String id, {String quality = 'hq'}) async {
    // 音质档位序（低 → 高）；从用户偏好档位开始向下降级尝试
    const order = ['lq', 'sq', 'hq', 'lossless', 'hi-res'];
    final start = order.indexOf(quality);
    if (start < 0) return null;
    for (var i = start; i >= 0; i--) {
      final q = order[i];
      try {
        final body = await _call('song_url', {
          'id': id,
          'level': neteaseLevels[q] ?? 'exhigh',
        });
        final data = body?['data'];
        if (data is! List || data.isEmpty) continue;
        final first = data.first;
        if (first is! Map<String, dynamic>) continue;
        final url = first['url']?.toString();
        if (url == null || url.isEmpty) continue;
        // 试听片段拒绝：非 VIP 账号 VIP 曲目返回带 freeTrialInfo 的 60s 片段
        final trial = first['freeTrialInfo'];
        if (trial != null && trial != false) continue;
        return url;
      } catch (_) {
        // 网络错误继续降级
      }
    }
    return null;
  }

  // ── 登录 / 会话 ──────────────────────────────────────────────

  /// 当前登录账号（login_status）；未登录返回 null。
  ///
  /// 需要登录态接口（每日推荐/我喜欢）先经 [ensureAnonymous] 匿名注册，
  /// 再按需 [loginQr*] 扫码登录。
  Future<NeteaseAccount?> loginStatus() async {
    final body = await _call('login_status', const {});
    final data = body?['data'];
    if (data is! Map<String, dynamic>) return null;
    final profile = data['profile'];
    final account = data['account'];
    if (profile is! Map<String, dynamic>) return null;
    return NeteaseAccount(
      userId: profile['userId']?.toString() ?? '',
      nickname: profile['nickname']?.toString() ?? '',
      avatarUrl: profile['avatarUrl']?.toString(),
      vip: (profile['vipType'] as num?)?.toInt() != 0 ||
          (account is Map<String, dynamic> &&
              (account['vipType'] as num?)?.toInt() != 0),
    );
  }

  /// 注册/获取匿名态（register_anonimous）：无登录态也可用推荐类接口。
  Future<void> ensureAnonymous() async {
    await _call('register_anonimous', const {});
  }

  /// 二维码登录第一步：获取 unikey（后续生成二维码 + 轮询 [loginQrCheck]）。
  Future<String> loginQrKey() async {
    final body = await _call('login_qr_key', const {});
    return body?['data']?['unikey']?.toString() ?? '';
  }

  /// 二维码登录内容（qrurl 即扫码内容）。
  Future<String> loginQrCreate(String key) async {
    final body = await _call('login_qr_create', {'key': key});
    return body?['data']?['qrurl']?.toString() ?? '';
  }

  /// 二维码轮询结果；[NeteaseQrStatus.code]：801 待扫码 / 802 待确认 /
  /// 800 已过期 / 803 已确认（登录成功，cookie 已写回会话）。
  Future<NeteaseQrStatus> loginQrCheck(String key) async {
    final body = await _call('login_qr_check', {'key': key});
    final code = (body?['code'] as num?)?.toInt() ?? -1;
    return NeteaseQrStatus(code: code, message: body?['message']?.toString() ?? '');
  }

  /// 登出（logout，清空会话 cookie）。
  Future<void> logout() async {
    await _call('logout', const {});
    nmClearNeteaseCookies();
  }

  // ── 发现 / 推荐（主页） ──────────────────────────────────────

  /// 推荐歌单（personalized，无需登录，对齐原版首页「推荐歌单」）。
  Future<List<CoverItem>> personalized({int limit = 30}) async {
    final body = await _call('personalized', {'limit': limit});
    final list = body?['result'];
    if (list is! List) return const [];
    return list.whereType<Map<String, dynamic>>().map((p) {
      final creator = p['creator'];
      return CoverItem(
        id: p['id'].toString(),
        title: p['name']?.toString() ?? '',
        cover: withPicSize(p['picUrl']?.toString()),
        subtitle: p['copywriter']?.toString() ??
            (creator is Map<String, dynamic>
                ? creator['nickname']?.toString() ?? ''
                : ''),
        trackCount: (p['trackCount'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  /// 每日推荐歌曲（recommend_songs，需登录；未登录返回空）。
  Future<List<Track>> recommendSongs() async {
    final body = await _call('recommend_songs', const {});
    final songs = body?['data']?['dailySongs'];
    if (songs is! List) return const [];
    return songs
        .whereType<Map<String, dynamic>>()
        .map(Track.fromNeteaseSong)
        .toList();
  }

  /// 热门歌手（top_artists，无需登录）。
  Future<List<CoverItem>> topArtists({int limit = 12}) async {
    final body = await _call('top_artists', {'limit': limit});
    final artists = body?['artists'];
    if (artists is! List) return const [];
    return artists.whereType<Map<String, dynamic>>().map((a) {
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

  /// 新碟上架（album_new，无需登录）。
  Future<List<CoverItem>> newAlbums({int limit = 12}) async {
    final body = await _call('album_new', {'limit': limit});
    final raw = body?['albums'] ?? body?['data']?['albums'];
    final albums = raw is List ? raw : const [];
    return albums.whereType<Map<String, dynamic>>().map((a) {
      final artist = a['artist'] ?? a['artists'];
      final artistName = artist is Map<String, dynamic>
          ? artist['name']?.toString() ?? ''
          : artist is List && artist.isNotEmpty && artist.first is Map<String, dynamic>
              ? (artist.first as Map<String, dynamic>)['name']?.toString() ?? ''
              : '';
      return CoverItem(
        id: a['id'].toString(),
        title: a['name']?.toString() ?? '',
        cover: withPicSize(a['picUrl']?.toString() ?? a['blurPicUrl']?.toString()),
        subtitle: artistName,
        trackCount: (a['size'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  // ── 我喜欢 / 歌单 ────────────────────────────────────────────

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

  /// 用户喜欢的歌曲（「我喜欢的音乐」歌单全量，需登录）。
  ///
  /// 对齐 SPlayer-Next `user.ts` ensureLikedPlaylist：不直接用 likelist
  /// （ids 顺序不保证按收藏时间），而是拉取用户第一个自建歌单「我喜欢的
  /// 音乐」——歌单 trackIds 顺序即收藏先后（最新在前），经 [playlistDetail]
  /// 保序补全曲目详情。
  Future<List<Track>> likedSongs(String uid) async {
    final playlists = await userPlaylists(uid, limit: 1);
    if (playlists.isEmpty) return const [];
    final detail = await playlistDetail(playlists.first.id);
    return detail.tracks;
  }

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
  Future<List<PlaylistItem>> userPlaylists(String uid, {int limit = 200}) async {
    final body = await _call('user_playlist', {'uid': uid, 'limit': limit});
    final playlist = body?['playlist'];
    if (playlist is! List) return const [];
    return playlist
        .whereType<Map<String, dynamic>>()
        .map(PlaylistItem.fromNetease)
        .toList();
  }

  /// 收藏的专辑（album_sublist，需登录）。
  Future<List<CoverItem>> albumSublist({int limit = 100, int offset = 0}) async {
    final body = await _call('album_sublist', {'limit': limit, 'offset': offset});
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
  Future<List<CoverItem>> artistSublist({int limit = 100, int offset = 0}) async {
    final body = await _call('artist_sublist', {'limit': limit, 'offset': offset});
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

  // ── 歌曲评论 ────────────────────────────────────────────────

  /// 热门评论（comment_hot，无需登录）。
  Future<NeteaseCommentPage> songHotComments(
    String id, {
    int page = 1,
    int limit = 20,
  }) =>
      _comments(hot: true, id: id, page: page, limit: limit);

  /// 最新评论（comment_music，分页）。
  Future<NeteaseCommentPage> songComments(
    String id, {
    int page = 1,
    int limit = 20,
  }) =>
      _comments(hot: false, id: id, page: page, limit: limit);

  /// 发表评论（comment_add，需登录）。
  /// 成功返回；失败（未登录 / 重复评论 code 505 等）抛 [NeteaseApiError]。
  Future<void> sendComment(String id, String content) async {
    final body = await _call('comment_add', {'id': id, 'content': content});
    final code = body?['code'];
    if (code is num && code != 200) {
      throw NeteaseApiError('发送评论失败 code=$code', body);
    }
  }

  /// 统一评论拉取与归一化（对齐 getNeteaseComments + normalizeNeteaseCommentPage）。
  Future<NeteaseCommentPage> _comments({
    required bool hot,
    required String id,
    required int page,
    required int limit,
  }) async {
    final body = await _call(hot ? 'comment_hot' : 'comment_music', {
      'id': id,
      'limit': limit,
      'offset': (page - 1) * limit,
    });
    final map = body ?? const <String, dynamic>{};
    final rawList =
        (map[hot ? 'hotComments' : 'comments'] ?? map['data']?['comments']);
    final list = <NeteaseComment>[];
    if (rawList is List) {
      for (final raw in rawList) {
        if (raw is! Map<String, dynamic>) continue;
        final item = _normalizeComment(raw);
        if (item != null) list.add(item);
      }
    }
    final total =
        (map['total'] ?? map['data']?['totalCount'] ?? list.length) as num? ??
            list.length;
    return NeteaseCommentPage(
      list: list,
      total: total.toInt(),
      page: page,
      limit: limit,
    );
  }

  /// 归一化单条评论（对齐 normalizeNeteaseComment）。
  static NeteaseComment? _normalizeComment(Map<String, dynamic> raw) {
    final id = raw['commentId']?.toString() ??
        raw['beRepliedCommentId']?.toString();
    final text = raw['content']?.toString().trim() ?? '';
    if (id == null || id.isEmpty || text.isEmpty) return null;
    final user = raw['user'];
    final location = raw['ipLocation'];
    final replyRaw = raw['beReplied'];
    final reply = replyRaw is List
        ? replyRaw
            .whereType<Map<String, dynamic>>()
            .map(_normalizeComment)
            .whereType<NeteaseComment>()
            .toList()
        : const <NeteaseComment>[];
    return NeteaseComment(
      id: id,
      userId: user is Map<String, dynamic>
          ? user['userId']?.toString()
          : null,
      userName: user is Map<String, dynamic>
          ? user['nickname']?.toString() ?? ''
          : '',
      avatar: user is Map<String, dynamic>
          ? user['avatarUrl']?.toString()
          : null,
      text: text,
      time: (raw['time'] as num?)?.toInt(),
      location: location is Map<String, dynamic>
          ? location['location']?.toString()
          : null,
      likedCount: (raw['likedCount'] as num?)?.toInt() ?? 0,
      replyTotal: (raw['replyCount'] as num?)?.toInt() ?? 0,
      reply: reply,
    );
  }

  /// 匹配当前 [track] 的网易云歌曲 id（对齐 findNeteaseId）：
  /// 网易云源直接用 id；异源用「标题 + 歌手」关键词 cloudsearch +
  /// [pickBestCandidate] 挑最匹配项；找不到返回 null。
  Future<String?> findNeteaseCommentId(Track track) async {
    if (track.source == 'netease' && track.id.isNotEmpty) return track.id;
    final keyword = [
      track.title,
      track.artists.map((a) => a.name).join(' '),
    ]
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join(' ');
    if (keyword.isEmpty) return null;
    final res = await searchSongs(keyword, limit: 20);
    final candidates = res.items
        .map(
          (t) => LyricCandidate<String>(
            name: t.title,
            artist: t.artistNames,
            album: t.album?.name,
            duration: t.duration,
            extra: t.id,
          ),
        )
        .toList();
    return pickBestCandidate(candidates, track)?.extra;
  }
}

/// 网易云登录账号（login_status profile 子集）。
class NeteaseAccount {
  const NeteaseAccount({
    required this.userId,
    required this.nickname,
    this.avatarUrl,
    this.vip = false,
  });

  final String userId;
  final String nickname;
  final String? avatarUrl;
  final bool vip;
}

/// 二维码登录轮询结果。
class NeteaseQrStatus {
  const NeteaseQrStatus({required this.code, required this.message});

  /// 801 待扫码 / 802 待确认 / 800 已过期 / 803 已确认。
  final int code;
  final String message;

  bool get scanned => code == 802;
  bool get expired => code == 800;
  bool get confirmed => code == 803;
}

/// 歌单详情（元信息 + 歌曲）。
class NeteasePlaylistDetail {
  const NeteasePlaylistDetail({required this.meta, required this.tracks});

  final PlaylistItem? meta;
  final List<Track> tracks;
}
