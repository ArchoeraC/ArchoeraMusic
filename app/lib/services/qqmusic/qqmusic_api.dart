// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM（QM）播放音源服务（对齐 kugou/netease 服务形态的轻量封装）。
///
/// - 底层：apis/qqmusic（Dart 直连，musicu.fcg 明文 JSON + UA/comm 伪装）
/// - 登录：QQ 扫码 → musickey 落盘到 host sessionStore（vault
///   加密，平台键 'qqmusic'）；cookie/uin 由 request 层自动注入
/// - 搜索 / 歌单 / 专辑 / 歌手 / 榜单 → 归一为 netease 的 [Track]/[CoverItem]
/// - 播放：song_url（music.vkey.GetVkey）多音质降级；访客可播免费曲，
///   VIP/无版权曲目按接口返回语义抛 [QqApiException]（不绕过）
///
/// 本类本身不持有网络状态（缓存走 apis 层 LRU），只做解析 + 登录态通知。
library;

import 'package:flutter/foundation.dart';

import '../../apis/qqmusic/api.dart';
import '../../apis/qqmusic/core/config.dart';
import '../../apis/qqmusic/core/request.dart';
import '../netease/comment.dart';
import '../netease/netease_api.dart' show CoverItem, SearchResult;
import '../netease/track.dart';

/// QM业务异常（resolve 失败 / 登录缺失等；message 可直接展示）。
///
/// [kind]/[code] 仅在请求层归一后携带（kind=risk 表示风控/限流拦截，code 为
/// outer/inner 业务码），供界面决定本地化文案与重试策略。
class QqApiException implements Exception {
  QqApiException(this.message, {this.kind, this.outerCode, this.innerCode});

  final String message;
  final QmErrorKind? kind;
  final int? outerCode;
  final int? innerCode;

  /// 展示用错误码（优先内码，其次外码）。
  int? get code => innerCode ?? outerCode;

  @override
  String toString() => message;
}

/// **实验开关**：QM「在线收藏」（红心同步）是否启用。
///
/// 在线红心 RPC（dirid=201 族）为社区逆向、非官方文档，存在接口失效 /
/// 风控风险。开启后：
/// - 已登录 QQ 时，[QqMusicApi.likedSongs]/[likedSongmids] 拉在线红心并入；
/// - [QqMusicApi.like] 写在线红心；失败由红心控制器**回滚本地**并提示。
///
/// 无论本开关如何，**本机 QQ 红心（app 本地「我喜欢」）始终可用**，不受
/// 在线成败影响。若某端点失效：可整体置 false 关闭在线收藏（本地不受
/// 影响），并参考 favorite.dart 顶部的调研来源替换端点族。
const bool kQqFavExperimental = true;

/// QM登录资料（user_detail 归一）。
class QqMusicProfile {
  const QqMusicProfile({
    required this.userId,
    required this.nickname,
    this.avatarUrl = '',
    this.isVip = false,
    this.vipLevel = 0,
  });

  final String userId;
  final String nickname;
  final String avatarUrl;
  final bool isVip;
  final int vipLevel;
}

/// 搜索请求统一入口（QM模块协议）。
class QqMusicApi extends ChangeNotifier {
  QqMusicApi();

  /// 当前登录资料（null = 访客）；启动/登录后异步补齐。
  QqMusicProfile? _profile;
  QqMusicProfile? get profile => _profile;

  bool _profileLoading = false;

  /// 是否已登录（cookie 含 uin 与有效 key）。
  bool get isLoggedIn => qmHasQQMusicLogin();

  /// 登录 uin（未登录 '0'）。
  String get uin => qmGetQQMusicUin();

  /// 启动恢复：从持久化 cookie 拉取昵称/头像/会员（失败静默）。
  /// 由 `AuthBootstrap` 在每次启动时显式调用一次（资料不持久化）。
  Future<void> loadProfileSilently() async {
    if (_profileLoading) return;
    _profileLoading = true;
    try {
      final p = await _fetchProfile();
      if (!identical(p, _profile)) {
        _profile = p;
        notifyListeners();
      }
    } catch (_) {
      // 启动静默：网络/风控失败保持访客态
    } finally {
      _profileLoading = false;
    }
  }

  /// 拉取当前登录资料；未登录返回 null。
  Future<QqMusicProfile?> _fetchProfile() async {
    if (!isLoggedIn) return null;
    try {
      final body = await qmCall('user_detail');
      if (body is! Map) return null;
      if (body['code'] != 200 || body['loggedIn'] != true) return null;
      final p = body['profile'];
      if (p is! Map) return null;
      return QqMusicProfile(
        userId: p['userId']?.toString() ?? uin,
        nickname: p['nickname']?.toString() ?? '',
        avatarUrl: p['avatarUrl']?.toString() ?? '',
        isVip: p['isVip'] == true,
        vipLevel: (p['vipLevel'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// 登录成功 / 用户资料变更后刷新资料并通知 UI。
  Future<void> refreshProfile() async {
    final p = await _fetchProfile();
    _profile = p;
    notifyListeners();
  }

  /// 退出登录（清空持久化 cookie）。
  void logout() {
    qmClearQQMusicCookies();
    _profile = null;
    notifyListeners();
  }

  // ── QQ 扫码登录 ──────────────────────────────────────────────────────

  /// 生成 QQ 登录二维码。
  /// 返回 {key, content(data:image/...base64)}。
  Future<Map<String, dynamic>> qrKey() async {
    final body = await qmCall('login_qr_key', {'type': 'qq'});
    if (body is! Map) throw QqApiException('获取二维码失败');
    final code = body['code'];
    if (code != 200) {
      throw QqApiException('获取二维码失败: ${body['message'] ?? code}');
    }
    final key = body['key']?.toString() ?? '';
    final content = body['content']?.toString() ?? '';
    if (key.isEmpty || content.isEmpty) {
      throw QqApiException('二维码响应缺少 key/content');
    }
    return {'key': key, 'content': content, 'type': body['type'] ?? 'qq'};
  }

  /// 轮询 QQ 扫码状态：0=过期/取消 1=等待 2=已扫码待确认 4=成功（cookie 已写入）。
  /// 返回 {status, nickname?, avatarUrl?}。
  Future<Map<String, dynamic>> qrCheck(String key) async {
    final body = await qmCall('login_qr_check', {'type': 'qq', 'key': key});
    if (body is! Map) throw QqApiException('二维码状态轮询失败');
    final status = (body['status'] as num?)?.toInt() ?? 1;
    return <String, dynamic>{
      'status': status,
      'nickname': body['nickname']?.toString(),
      'avatarUrl': body['avatarUrl']?.toString(),
    };
  }

  /// 登录成功后同步资料（登录弹窗调用）。
  Future<void> afterLogin() => refreshProfile();

  // ── 搜索（对齐 Search.vue 四分类）────────────────────────────────────

  /// 搜索单曲（桌面签名协议，`musics.fcg` + `zzcSign`）。
  ///
  /// `comm.ct=19` 下发完整音质字段（`size_hires`/`size_new`/`size_dolby`/
  /// `size_dts`/`hires_*`），归一为 [Track]。
  Future<SearchResult<Track>> searchSongs(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    if (keyword.trim().isEmpty) {
      return const SearchResult(items: [], total: 0, hasMore: false);
    }
    return _guard(() async {
      final body = await qmCall('search', {
        'keywords': keyword,
        'page': page,
        'limit': limit,
        'type': 0,
      });
      final songs = _extractList(body, 'songs');
      final items = songs.map(_toTrack).toList();
      final total = _extractTotal(body);
      return SearchResult(
        items: items,
        total: total,
        hasMore: page * limit < total,
      );
    });
  }

  /// 搜索专辑（桌面签名协议，type=2）。
  Future<SearchResult<CoverItem>> searchAlbums(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    return _guard(() async {
      final body = await qmCall('search', {
        'keywords': keyword,
        'page': page,
        'limit': limit,
        'type': 2,
      });
      final raw = _extractList(body, 'albums');
      final total = _extractTotal(body);
      return SearchResult<CoverItem>(
        items: raw.map(_coverFromQq).toList(),
        total: total,
        hasMore: page * limit < total,
      );
    });
  }

  /// 搜索歌手（桌面签名协议，type=1）。
  ///
  /// 歌手单页上限较严（`num_per_page>40` 服务端返回空，见 search.dart），
  /// 这里同步收敛请求量，避免收到服务端空页。
  Future<SearchResult<CoverItem>> searchArtists(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final requestLimit = limit.clamp(1, 30);
    return _guard(() async {
      final body = await qmCall('search', {
        'keywords': keyword,
        'page': page,
        'limit': requestLimit,
        'type': 1,
      });
      final raw = _extractList(body, 'artists');
      final total = _extractTotal(body);
      return SearchResult<CoverItem>(
        items: raw
            .map(
              (a) => CoverItem(
                id: a['id']?.toString() ?? '',
                title: a['name']?.toString() ?? '',
                cover: a['cover']?.toString(),
                subtitle: a['songCount'] != null && a['albumCount'] != null
                    ? '${a['songCount']} 首 / ${a['albumCount']} 专辑'
                    : '',
                trackCount: (a['songCount'] as num?)?.toInt() ?? 0,
                source: 'qqmusic',
              ),
            )
            .toList(),
        total: total,
        hasMore: (page - 1) * requestLimit + raw.length < total,
      );
    });
  }

  /// 搜索歌单（桌面签名协议，type=3）。
  Future<SearchResult<CoverItem>> searchPlaylists(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    return _guard(() async {
      final body = await qmCall('search', {
        'keywords': keyword,
        'page': page,
        'limit': limit,
        'type': 3,
      });
      final raw = _extractList(body, 'playlists');
      final total = _extractTotal(body);
      return SearchResult<CoverItem>(
        items: raw
            .map(
              (p) => CoverItem(
                id: p['id']?.toString() ?? '',
                title: p['name']?.toString() ?? '',
                cover: p['cover']?.toString(),
                subtitle: p['creator']?.toString() ?? '',
                trackCount: (p['trackCount'] as num?)?.toInt() ?? 0,
                source: 'qqmusic',
              ),
            )
            .toList(),
        total: total,
        hasMore: page * limit < total,
      );
    });
  }

  // ── 歌单 / 专辑 / 歌手 / 榜单详情 ────────────────────────────────────

  /// 歌单全量曲目（song_list，c.y.qq.com GET）。
  Future<List<Track>> playlistTracks(String disstid, {String? cover}) async {
    final body = await qmCall('song_list', {'id': disstid});
    if (body is! Map) return const [];
    final raw = _extractList(body, 'songs');
    return raw.map((s) => _toTrack(s, cover: cover)).toList();
  }

  /// 专辑曲目（album，music.musichallAlbum.AlbumSongList）。
  Future<List<Track>> albumTracks(String albumMid) async {
    final body = await qmCall('album', {'mid': albumMid});
    if (body is! Map) return const [];
    final raw = _extractList(body, 'songs');
    return raw.map((s) => _toTrack(s, cover: qqCover(albumMid))).toList();
  }

  /// 歌手热门曲目（artist，GetSingerSongList）。
  Future<List<Track>> artistSongs(String artistMid) async {
    final body = await qmCall('artist', {'mid': artistMid, 'limit': 50});
    if (body is! Map) return const [];
    final raw = _extractList(body, 'songs');
    return raw.map(_toTrack).toList();
  }

  /// 榜单分类（topid → 名称/封面）；QM固定榜单入口。
  static const leaderboardCategories = <CoverItem>[
    CoverItem(id: '26', title: 'QM巅峰榜·流行', trackCount: 100),
    CoverItem(id: '27', title: '新歌榜', trackCount: 100),
    CoverItem(id: '62', title: '热歌榜', trackCount: 100),
    CoverItem(id: '4', title: '飙升榜', trackCount: 100),
  ];

  /// 榜单曲目（leaderboard，musicToplist.ToplistInfoServer）。
  Future<List<Track>> leaderboardTracks(String topid, {int limit = 50}) async {
    final body = await qmCall('leaderboard', {'topid': topid, 'limit': limit});
    if (body is! Map) return const [];
    final raw = _extractList(body, 'songs');
    return raw.map(_toTrack).toList();
  }

  // ── 实验性在线收藏「我喜欢」（dirid=201 社区逆向 RPC）──────────────

  /// 读「我喜欢」列表单页（favorite_list，dirid=201，登录态）。
  ///
  /// 社区 RPC 失败时回退 fcg `profile_order_songs`（纯 GET，见
  /// `modules/user_playlist.dart`），提升可用性。
  Future<Map<String, dynamic>> _favoritePage(int page, int num) async {
    try {
      final body = await qmCall('favorite_list', {'page': page, 'num': num});
      if (body is! Map) throw QqApiException('QM：收藏列表响应异常');
      final map = Map<String, dynamic>.from(body);
      final code = map['code'];
      if (code == 301 || map['loggedIn'] == false) {
        throw QqApiException('需要登录 QM账号');
      }
      if (code != 200) {
        final msg = map['message']?.toString();
        throw QqApiException(
          msg?.isNotEmpty == true ? 'QM收藏：$msg' : 'QM收藏：读取失败 code=$code',
        );
      }
      return map;
    } on QqApiException catch (e) {
      if (e.message.contains('需要登录')) rethrow;
      return _favoritePageViaFcg(page, num);
    } catch (_) {
      // 传输 / 超时 / 非 JSON 等异常也回退 fcg 稳定 GET（此前只捕获
      // QqApiException，导致网络类失败不会走上回退，与注释声明不符）。
      return _favoritePageViaFcg(page, num);
    }
  }

  /// fcg 回退：`profile_order_songs`（reqtype=1）→ 归一到 `favorite_list` 形状。
  Future<Map<String, dynamic>> _favoritePageViaFcg(int page, int num) async {
    final body = await _guard(
      () => qmCall('profile_order_songs', {'page': page, 'num': num}),
    );
    final raw = body is Map
        ? Map<String, dynamic>.from(body)
        : const <String, dynamic>{};
    final code = raw['code'];
    if (code == 301 || raw['loggedIn'] == false) {
      throw QqApiException('需要登录 QM账号');
    }
    if (code != 200) {
      final msg = raw['message']?.toString();
      throw QqApiException(
        msg?.isNotEmpty == true ? 'QM收藏：$msg' : 'QM收藏：读取失败 code=$code',
      );
    }
    final songs = (raw['songs'] as List?) ?? const [];
    final mapped = songs.whereType<Map>().map((s) {
      final artists = (s['artists'] as List?) ?? const [];
      return <String, dynamic>{
        'mid': s['mid'],
        'id': s['id'],
        'name': s['name'],
        'artists': artists.map((n) => {'name': '$n'}).toList(),
        'album': s['album'],
        'albumMid': s['albumMid'],
        'cover': s['cover'],
        'coverOriginal': s['coverOriginal'],
        'mediaMid': s['mediaMid'],
        'duration': s['duration'],
        'size128': s['size128'],
        'size320': s['size320'],
        'sizeFlac': s['sizeFlac'],
      };
    }).toList();
    return {
      'code': 200,
      'loggedIn': true,
      'songs': mapped,
      'total': raw['total'],
      'hasMore': raw['hasMore'],
    };
  }

  /// 循环翻页收集全部收藏歌曲。
  Future<List<Track>> likedSongs() async {
    final tracks = <Track>[];
    var page = 1;
    while (page <= 60) {
      final body = await _favoritePage(page, 100);
      final songs = _extractList(body, 'songs');
      tracks.addAll(songs.map(_toTrack));
      if (body['hasMore'] != true || songs.length < 100) break;
      page++;
    }
    return tracks;
  }

  /// 轻量红心 songmid 集合（翻页只取 mid，不构造 Track；红心状态判定用，
  /// 对齐KG likedHashSet / NT likedIds 语义）。
  Future<Set<String>> likedSongmids() async {
    final mids = <String>{};
    var page = 1;
    while (page <= 60) {
      final body = await _favoritePage(page, 100);
      final songs = _extractList(body, 'songs');
      for (final s in songs) {
        final mid = (s['mid'] ?? '').toString();
        if (mid.isNotEmpty) mids.add(mid);
      }
      if (body['hasMore'] != true || songs.length < 100) break;
      page++;
    }
    return mids;
  }

  /// 用户歌单库（自建歌单 + 收藏歌单 + 我喜欢总数），供收藏页展示。
  ///
  /// 走 `fcgi` GET（见 `modules/user_playlist.dart`）；未登录返回空。
  Future<
    ({
      List<CoverItem> created,
      List<CoverItem> collected,
      int likedTotal,
      String likedCover,
    })
  >
  userLibrary() async {
    final created = await _playlistList('user_created_diss');
    final collected = await _playlistList('profile_order_playlists');
    final likedRaw = await _guard(
      () => qmCall('profile_order_songs', {'num': 1}),
    );
    final liked = likedRaw is Map
        ? Map<String, dynamic>.from(likedRaw)
        : const <String, dynamic>{};
    final total = (liked['total'] as num?)?.toInt() ?? 0;
    // 「我喜欢」无独立封面：取第一首收藏曲的专辑封面（对齐 music-lib/qq 的
    // fetchFavoriteSongsPlaylistSummary：cover = songs[0].Cover）。
    var likedCover = '';
    final likedSongs = liked['songs'];
    if (likedSongs is List &&
        likedSongs.isNotEmpty &&
        likedSongs.first is Map) {
      likedCover = (likedSongs.first as Map)['cover']?.toString() ?? '';
    }
    return (
      created: created,
      collected: collected,
      likedTotal: total,
      likedCover: likedCover,
    );
  }

  Future<List<CoverItem>> _playlistList(String module) async {
    final bodyRaw = await _guard(() => qmCall(module, {'limit': 100}));
    final body = bodyRaw is Map
        ? Map<String, dynamic>.from(bodyRaw)
        : const <String, dynamic>{};
    final raw = body['playlists'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(
          (m) => CoverItem(
            id: '${m['id'] ?? ''}',
            title: '${m['name'] ?? ''}',
            cover: m['cover']?.toString(),
            subtitle: '${m['creator'] ?? ''}',
            trackCount: (m['trackCount'] as num?)?.toInt() ?? 0,
            source: 'qqmusic',
          ),
        )
        .toList();
  }

  /// 红心 / 取消红心（登录态，社区逆向 dirid=201 写接口，**实验性**）。
  ///
  /// - [mid]：songmid（红心键）；
  /// - [songId]：QQ 歌曲数字 id（`Track.id`）。写接口按 songid 操作，
  ///   缺失时抛可读错误（不猜测、不静默跳过）。
  /// - 失败抛 [QqApiException]（message 可展示；由红心控制器回滚本地）。
  Future<void> like(String mid, {required bool like, String? songId}) async {
    if (mid.trim().isEmpty) {
      throw QqApiException('QM：缺少 songmid，无法收藏');
    }
    final sid = songId?.trim() ?? '';
    if (sid.isEmpty || int.tryParse(sid) == null) {
      throw QqApiException('QM：缺少歌曲数字 id（songId），无法${like ? '收藏' : '取消收藏'}');
    }
    final body = await qmCall(like ? 'favorite_add' : 'favorite_remove', {
      'songId': sid,
      'mid': mid,
    });
    if (body is! Map) throw QqApiException('QM：收藏操作响应异常');
    final code = body['code'];
    if (code == 301 || body['loggedIn'] == false) {
      throw QqApiException('需要登录 QM账号');
    }
    if (code != 200 || body['ok'] != true) {
      final msg = body['message']?.toString();
      throw QqApiException(
        msg?.isNotEmpty == true ? 'QM收藏失败：$msg' : 'QM收藏失败（实验接口未确认）',
      );
    }
  }

  // ── 播放 URL（GetVkey 直链 + 音质降级）──────────────────────────────

  /// 解析 QQ 曲目可播放 URL。
  ///
  /// [quality] 为档位（lq/sq/hq/lossless/hi-res），缺省 hq；解析内部按
  /// 高→低顺位自动降级。访客可播免费曲；VIP/无版权按接口语义抛
  /// [QqApiException]（message 走既有 error 呈现，明确"需登录/会员"）。
  Future<String?> resolvePlayUrl(Track track, {String quality = 'hq'}) async {
    final q = track.qqmusic;
    final mid = q?.mid.isNotEmpty == true
        ? q!.mid
        : (track.id.isNotEmpty ? track.id : null);
    if (mid == null) {
      throw QqApiException('QM：缺少 songmid，无法解析播放链接');
    }
    final body = await qmCall('song_url', {
      'mid': mid,
      'mediaMid': q?.mediaMid ?? '',
      'level': quality,
    });
    if (body is! Map) throw QqApiException('QM：播放链接解析失败');
    if (body['code'] != 200) {
      final msg = body['message']?.toString();
      throw QqApiException(
        msg?.isNotEmpty == true ? 'QM：$msg' : 'QM：未能获取可播放链接',
      );
    }
    final data = body['data'];
    if (data is List && data.isNotEmpty) {
      final first = data.first;
      if (first is Map) {
        final url = first['url']?.toString() ?? '';
        if (url.isNotEmpty) return url;
      }
    }
    throw QqApiException('QM：未能获取可播放链接（可能需要登录/VIP 或无版权）');
  }

  // ── 评论 ────────────────────────────────────────────────────────────

  /// QQ 歌曲评论（`music.globalComment.CommentRead`）。
  ///
  /// 官方接口**读取需登录态**（访客返回 `request.code=10000` 空列表），
  /// 未登录由调用方先引导登录。[hot] 热门 / 最新两 Tab。
  Future<NeteaseCommentPage> songComments(
    String mid, {
    int page = 1,
    int limit = 20,
    bool hot = false,
  }) async {
    if (mid.isEmpty) {
      return NeteaseCommentPage(
        list: const [],
        total: 0,
        page: page,
        limit: limit,
      );
    }
    return _guard(() async {
      final body = await qmCall('comment', {
        'id': mid,
        'type': hot ? 'hot' : 'new',
        'page': page,
        'limit': limit,
      });
      final raw = _extractList(body, 'comments');
      return NeteaseCommentPage(
        list: raw.map(_toComment).toList(),
        total: _extractTotal(body),
        page: page,
        limit: limit,
      );
    });
  }

  /// QQ 评论项 → [NeteaseComment]（`CmId/Nick/Avatar/Content/PraiseNum/PubTime/SubComments`）。
  static NeteaseComment _toComment(Map<String, dynamic> c) {
    final avatar = c['Avatar']?.toString() ?? '';
    final pubTime = int.tryParse('${c['PubTime'] ?? ''}') ?? 0;
    final subs = c['SubComments'];
    return NeteaseComment(
      id: c['CmId']?.toString() ?? '',
      userName: c['Nick']?.toString() ?? '',
      avatar: avatar.isEmpty ? null : avatar,
      text: c['Content']?.toString() ?? '',
      likedCount: (c['PraiseNum'] as num?)?.toInt() ?? 0,
      time: pubTime > 0 ? pubTime * 1000 : null,
      replyTotal: subs is List ? subs.length : 0,
      reply: subs is List
          ? subs
                .whereType<Map>()
                .map((m) => _toComment(Map<String, dynamic>.from(m)))
                .toList()
          : const [],
    );
  }

  // ── 解析辅助 ─────────────────────────────────────────────────────────

  /// 搜索等模块调用后的归一：把请求层错误转成带 kind/code 的 [QqApiException]，
  /// 让搜索页能区分「风控/限流」「网络」与普通业务错误并给出可读文案。
  Never _rethrow(Object err) {
    if (err is QqApiException) throw err;
    if (err is QmRequestException) {
      throw QqApiException(
        err.message,
        kind: err.kind,
        outerCode: err.outer,
        innerCode: err.inner,
      );
    }
    throw QqApiException('$err');
  }

  /// 包裹一次 QQ 模块调用（搜索等），统一错误归一。
  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (err) {
      _rethrow(err);
    }
  }

  /// 归一歌曲 map → [Track]（封面统一升级 https，避免 `//`/`http://` 显示不出）。
  Track _toTrack(Map<String, dynamic> song, {String? cover}) {
    final coverField = song['cover'];
    final coverOriginal = song['coverOriginal'];
    return Track.fromQqMusicSong(<String, dynamic>{
      ...song,
      if (coverField != null) 'cover': qmNormalizeCover(coverField.toString()),
      if (coverOriginal != null)
        'coverOriginal': qmNormalizeCover(coverOriginal.toString()),
    }, cover: cover == null ? null : qmNormalizeCover(cover));
  }

  /// QQ 搜索条目 → [CoverItem]（专辑）。
  CoverItem _coverFromQq(Map<String, dynamic> a) => CoverItem(
    id: a['id']?.toString() ?? '',
    title: a['name']?.toString() ?? '',
    cover: a['cover']?.toString(),
    subtitle: a['artist']?.toString() ?? '',
    trackCount: (a['trackCount'] as num?)?.toInt() ?? 0,
    source: 'qqmusic',
  );

  static List<Map<String, dynamic>> _extractList(Object? body, String key) {
    if (body is! Map) return const [];
    final raw = body[key];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  static int _extractTotal(Object? body) {
    if (body is! Map) return 0;
    final t = body['total'];
    if (t is num) return t.toInt();
    return int.tryParse('$t') ?? 0;
  }
}
