// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 音源服务（实验性，标识 `neko`）。
///
/// 与 NT/KG/QM 并列的第四个在线音源，但协议完全不同：统一 REST +
/// 不透明 token（无签名/加密）。本类聚合登录会话、搜索、收藏（我喜欢）、
/// 歌单、播放 URL 与歌词，供各页面 provider 复用。
///
/// **边界**：只做登录（账号密码 + 二维码），不接入注册 / 邮箱验证码 /
/// 滑块验证 / VIP 开通等付费能力。
///
/// 登录态（token + 用户资料）经 [SessionStore]（vault，平台键 `'neko'`）
/// 加密落盘；服务器地址存偏好（`source.neko.baseUrl`，非机密）。服务器
/// 地址变化时旧 token 不通用，[restore] 会丢弃旧会话。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../apis/neko/neko_client.dart';
import '../../apis/runtime.dart';
import '../netease/netease_api.dart' show CoverItem, SearchResult;
import '../netease/track.dart';
import 'neko_audio.dart';
import 'neko_quality.dart';
import 'neko_types.dart';

/// 会话存储平台键（vault）。
const String kNekoSessionPlatform = 'neko';

/// Neko 音源服务。
class NekoApi extends ChangeNotifier {
  NekoApi({NekoClient Function(String baseUrl, String? token)? clientFactory})
    : _clientFactory = clientFactory ?? _defaultClient;

  final NekoClient Function(String baseUrl, String? token) _clientFactory;

  static NekoClient _defaultClient(String baseUrl, String? token) =>
      NekoClient(baseUrl: baseUrl, token: token);

  String? _token;
  NekoUser? _account;

  /// 头像缓存破坏版本（进程内唯一；换图后 URL 变化以绕过 CDN/HTTP 缓存）。
  final int _avatarVersion = DateTime.now().millisecondsSinceEpoch;

  /// 当前登录账号（null = 未登录）。
  NekoUser? get account => _account;

  /// 是否已登录（持有 token）。
  bool get isLoggedIn => _token != null && _token!.isNotEmpty;

  /// 当前登录用户 id（未登录为空串；缓存键用）。
  String get userId => _account?.id ?? '';

  /// 服务器地址（固定站点，不对外暴露为可设置项；归一化后无尾斜杠）。
  String get baseUrl => kDefaultNekoBaseUrl;

  /// 资源绝对地址（封面 / 音频）。
  String resolveUrl(String pathOrUrl) =>
      NekoClient(baseUrl: baseUrl).resolveUrl(pathOrUrl);

  NekoClient _client() => _clientFactory(baseUrl, _token);

  static void _ensureSuccess(Map<String, dynamic> body) {
    if (body['success'] == true) return;
    throw NekoApiException(
      body['message']?.toString() ??
          body['error']?.toString() ??
          '请求失败',
    );
  }

  // ── 登录会话 ──────────────────────────────────────────────────

  /// 启动恢复登录态（bootstrap 调用）。服务器地址变化 → 丢弃旧会话。
  Future<void> restore() async {
    final store = getRuntime().sessionStore;
    final s = store.get(kNekoSessionPlatform);
    final token = s['token'];
    if (token == null || token.isEmpty) {
      _token = null;
      _account = null;
      notifyListeners();
      return;
    }
    if ((s['baseUrl'] ?? '') != baseUrl) {
      // 服务器变更：旧 token 不通用，清掉避免持续 401。
      store.clear(kNekoSessionPlatform);
      _token = null;
      _account = null;
      notifyListeners();
      return;
    }
    _token = token;
    _account = NekoUser.fromSessionMap(s);
    notifyListeners();
    // 服务端资料（昵称 / VIP）可能已变：启动后静默刷新一次（失败不影响已恢复的登录态）。
    unawaited(refreshAccount());
  }

  /// 拉取当前登录用户资料（`GET /api/user/info`）并落盘。
  ///
  /// 服务端自 `786d68e` 起提供该接口；客户端只持久化 token，昵称/VIP 等启动时
  /// 以服务端为准，避免本地缓存过期（对齐官方 Web 端 `userStore`）。
  /// 未登录 / 服务端未升级（404） / 离线时静默返回，不抛错。
  Future<void> refreshAccount() async {
    final token = _token;
    if (token == null || token.isEmpty) return;
    try {
      final body = await _client().getJson('/api/user/info');
      if (body['success'] != true) return;
      final data = body['data'];
      final userRaw = data is Map ? data['user'] : null;
      if (userRaw is! Map) return;
      _account = NekoUser.fromJson(Map<String, dynamic>.from(userRaw));
      _persistSession();
      notifyListeners();
    } catch (_) {
      // 静默：离线 / 服务端未提供该接口时保留本地会话
    }
  }

  /// 账号密码登录（字段名 `email`，服务端自 `3de61c7` 起只认该字段）。
  /// 失败抛 [NekoApiException]。
  Future<void> loginPassword(String email, String password) async {
    final body = await _client().postJson(
      '/api/user/login',
      body: {'email': email, 'password': password},
    );
    if (body['success'] != true) {
      throw NekoApiException(body['message']?.toString() ?? '登录失败');
    }
    final data = body['data'];
    final token = data is Map ? data['token']?.toString() : null;
    if (token == null || token.isEmpty) {
      throw NekoApiException('登录响应缺少 token');
    }
    final userRaw = data is Map ? data['user'] : null;
    _token = token;
    _account = userRaw is Map
        ? NekoUser.fromJson(Map<String, dynamic>.from(userRaw))
        : NekoUser(id: '', nickname: '', email: email);
    _persistSession();
    notifyListeners();
    // 资料（昵称 / VIP / userId）以服务端为准；头像地址依赖 userId，
    // 登录响应缺 id 时靠这里补齐。
    unawaited(refreshAccount());
  }

  /// 创建二维码登录会话。
  ///
  /// 服务端「21.1 破坏性变更」起返回**渲染好的 [NekoQrSession.qrImage]**，
  /// 不再返回可自绘的 `qrContent`。
  Future<NekoQrSession> qrCreate() async {
    final body = await _client().postJson('/api/user/qrlogin/create');
    _ensureSuccess(body);
    final data = body['data'];
    if (data is! Map) throw NekoApiException('二维码响应格式异常');
    final map = Map<String, dynamic>.from(data);
    return NekoQrSession(
      sessionId: map['sessionId']?.toString() ?? '',
      qrImage: map['qrImage']?.toString() ?? '',
      expiresIn: (map['expiresIn'] as num?)?.toInt() ?? 180,
    );
  }

  /// 订阅二维码状态（SSE）。`confirmed` 时自动落盘登录态并通知 UI。
  Stream<NekoQrStatus> qrWatch(String sessionId) async* {
    final stream = _client().sse(
      '/api/user/qrlogin/status?sessionId=${Uri.encodeQueryComponent(sessionId)}',
    );
    await for (final ev in stream) {
      if (ev.event != 'status') continue;
      NekoQrStatus status;
      try {
        final decoded = jsonDecode(ev.data);
        if (decoded is! Map) continue;
        status = NekoQrStatus.fromJson(Map<String, dynamic>.from(decoded));
      } catch (_) {
        continue;
      }
      if (status.state == NekoQrState.confirmed &&
          status.token != null &&
          status.token!.isNotEmpty) {
        _token = status.token;
        if (status.user != null) _account = status.user;
        _persistSession();
        notifyListeners();
        // 资料（昵称 / VIP）以服务端为准；含 userId 的头像地址依赖它。
        unawaited(refreshAccount());
      }
      yield status;
      if (status.state == NekoQrState.confirmed ||
          status.state == NekoQrState.canceled ||
          status.state == NekoQrState.expired) {
        return;
      }
    }
  }

  /// 退出登录（Neko 无登出接口：仅清本地会话）。
  void logout() {
    _token = null;
    _account = null;
    getRuntime().sessionStore.clear(kNekoSessionPlatform);
    notifyListeners();
  }

  void _persistSession() {
    final token = _token;
    final account = _account;
    if (token == null || token.isEmpty) {
      getRuntime().sessionStore.clear(kNekoSessionPlatform);
      return;
    }
    getRuntime().sessionStore.save(kNekoSessionPlatform, {
      'token': token,
      'baseUrl': baseUrl,
      ...(account?.toSessionMap() ?? const <String, String>{}),
    });
  }

  // ── 搜索 ─────────────────────────────────────────────────────

  /// 单曲搜索（模糊匹配，服务端上限约 50 条、无分页）。
  Future<SearchResult<Track>> searchSongs(
    String query, {
    int page = 1,
    int limit = 50,
  }) async {
    final body = await _client().postJson(
      '/api/music/search',
      body: {'query': query},
    );
    // 无匹配时服务端返回 HTTP 200 + `success:false, results:null`，
    // 视为空结果（而非失败）；真正的参数错误走 HTTP 400。
    final results = body['results'];
    if (results == null && body['success'] != true) {
      return const SearchResult(items: [], total: 0, hasMore: false);
    }
    final items = _tracksFrom(results);
    return SearchResult(items: items, total: items.length, hasMore: false);
  }

  /// 歌单搜索。
  Future<SearchResult<CoverItem>> searchPlaylists(
    String query, {
    int page = 1,
    int limit = 50,
  }) async {
    final body = await _client().postJson(
      '/api/playlists/search',
      body: {'query': query},
    );
    // 无匹配时 `results:null`（同单曲搜索）→ 空结果。
    final list = body['results'];
    if (list == null && body['success'] != true) {
      return const SearchResult(items: [], total: 0, hasMore: false);
    }
    final items = <CoverItem>[];
    if (list is List) {
      for (final e in list.whereType<Map>()) {
        final p = NekoPlaylist.fromJson(Map<String, dynamic>.from(e));
        if (p.id.isEmpty) continue;
        items.add(
          CoverItem(
            id: p.id,
            title: p.name,
            cover: _coverOf(p.firstMusicCover),
            subtitle: p.creator ?? '',
            trackCount: p.musicCount,
            source: 'neko',
          ),
        );
      }
    }
    return SearchResult(items: items, total: items.length, hasMore: false);
  }

  /// 歌手搜索（服务端只返回**单个**最佳匹配 + 其曲目）。
  Future<SearchResult<CoverItem>> searchArtists(
    String query, {
    int page = 1,
    int limit = 50,
  }) async {
    final artist = await _fetchArtist(query);
    if (artist == null) {
      return const SearchResult(items: [], total: 0, hasMore: false);
    }
    final name = artist.name;
    if (name.isEmpty) {
      return const SearchResult(items: [], total: 0, hasMore: false);
    }
    return SearchResult(
      items: [
        CoverItem(
          id: name,
          title: name,
          cover: _coverOf(artist.firstCover),
          trackCount: artist.musicCount,
          source: 'neko',
        ),
      ],
      total: 1,
      hasMore: false,
    );
  }

  /// Neko 无专辑接口（专辑仅作为歌曲字段）；返回空结果。
  Future<SearchResult<CoverItem>> searchAlbums(
    String query, {
    int page = 1,
    int limit = 50,
  }) async => const SearchResult(items: [], total: 0, hasMore: false);

  /// 歌手全部曲目（歌手详情弹窗用）。
  Future<List<Track>> artistTracks(String name) async {
    final artist = await _fetchArtist(name);
    return artist?.tracks ?? const [];
  }

  Future<_NekoArtist?> _fetchArtist(String query) async {
    final body = await _client().postJson(
      '/api/artists/search',
      body: {'query': query},
    );
    // 未命中时服务端返回 artist.name 为空（而非错误）→ 交由调用方处理为空。
    final raw = body['artist'];
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final name = map['name']?.toString() ?? '';
    if (name.isEmpty) return null;
    final tracks = _tracksFrom(map['musicList']);
    return _NekoArtist(
      name: name,
      musicCount: (map['musicCount'] as num?)?.toInt() ?? tracks.length,
      tracks: tracks,
      firstCover: tracks.isEmpty ? null : tracks.first.cover,
    );
  }

  // ── 我喜欢（收藏单曲）──────────────────────────────────────────

  /// 在线「我喜欢」曲目（全量，服务端无分页）。
  Future<List<Track>> likedTracks() async {
    final body = await _client().getJson('/api/user/favorites');
    _ensureSuccess(body);
    return _tracksFrom(body['favorites']);
  }

  /// 在线「我喜欢」id 集合（红心同步用，不构造 Track）。
  Future<Set<String>> likedIds() async {
    final body = await _client().getJson('/api/user/favorites');
    _ensureSuccess(body);
    final out = <String>{};
    final list = body['favorites'];
    if (list is List) {
      for (final e in list.whereType<Map>()) {
        final id = e['id']?.toString();
        if (id != null && id.isNotEmpty) out.add(id);
      }
    }
    return out;
  }

  /// 收藏 / 取消收藏单曲。
  Future<void> like(String id, {required bool like}) async {
    if (id.isEmpty) throw NekoApiException('缺少曲目 id');
    final body = like
        ? await _client().postJson(
            '/api/user/favorites',
            body: {
              'musicIds': [id],
            },
          )
        : await _client().deleteJson('/api/user/favorites/$id');
    _ensureSuccess(body);
  }

  // ── 歌单 / 收藏歌单 ──────────────────────────────────────────

  /// 用户曲库：自建歌单 + 收藏歌单（收藏页一次拉取填充各 tab）。
  Future<NekoUserLibrary> userLibrary() async {
    final createdBody = await _client().getJson('/api/user/playlists');
    _ensureSuccess(createdBody);
    final created = _playlistsFrom(createdBody['playlists']);
    // 收藏歌单失败不影响自建歌单展示。
    var collected = const <NekoPlaylist>[];
    try {
      final fav = await _client().getJson('/api/user/favorite-playlists');
      if (fav['success'] == true) {
        collected = _playlistsFrom(fav['playlists']);
      }
    } catch (_) {
      // 忽略：仅收藏歌单 tab 为空
    }
    return NekoUserLibrary(
      createdPlaylists: created,
      collectedPlaylists: collected,
      isVip: createdBody['isVip'] == true,
    );
  }

  /// 在线的收藏歌单曲目（收藏页「我喜欢」之外的收藏歌单详情）。
  Future<List<Track>> favoritePlaylistTracks(String playlistId) async {
    final body = await _client().getJson(
      '/api/user/favorite-playlists/$playlistId',
    );
    _ensureSuccess(body);
    return _tracksFrom(body['music']);
  }

  /// 歌单曲目（`/api/user/playlist/music/{id}`，公开接口）。
  Future<List<Track>> playlistTracks(String playlistId) async {
    final body = await _client().getJson(
      '/api/user/playlist/music/$playlistId',
    );
    _ensureSuccess(body);
    return _tracksFrom(body['musicList']);
  }

  // ── 播放 / 歌词 ──────────────────────────────────────────────

  /// 音质解析结果缓存（`/api/music/file/{id}` → 站内固定媒体地址）。
  ///
  /// 后端该接口已由 `302` 改为 `200 + JSON data.url`，且受防重放保护：真实
  /// 媒体地址固定、可被 CDN 缓存，解析一次即可供播放 / seek / 重试复用
  /// （对齐官方 PC 端 `MusicUrlResolver` 的进程内缓存）。
  final Map<String, _NekoMediaUrl> _mediaUrls = {};
  static const Duration _mediaUrlTtl = Duration(minutes: 10);

  /// 用带 nonce 的普通请求换取真实媒体直链；失败 / 无地址返回 null。
  Future<String?> _resolveMediaUrl(String id, String quality) async {
    if (id.isEmpty) return null;
    final key = '$id|$quality';
    final cached = _mediaUrls[key];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.url;
    }
    final body = await _client().getJson(
      '/api/music/file/$id',
      query: {'quality': nekoQualityParam(quality)},
    );
    if (body['success'] != true) return null;
    final data = body['data'];
    final raw = data is Map ? data['url']?.toString() : null;
    if (raw == null || raw.isEmpty) return null;
    final url = resolveUrl(raw);
    _mediaUrls[key] = _NekoMediaUrl(url, DateTime.now().add(_mediaUrlTtl));
    return url;
  }

  /// 解析播放 URL（真实媒体直链，服务端支持 Range/206 拖动）。
  ///
  /// 服务端「可选音质流」起 `/api/music/file/{id}` 不再 302，而是返回
  /// `200 + JSON data.url`（且需防重放 nonce）；因此这里先用带 nonce 的请求
  /// 换取站内固定媒体地址，再交给引擎 / 下载器拉流（媒体地址可重复访问、
  /// 不需要 nonce）。
  /// [quality] 为本项目统一档位键，经 [nekoQualityParam] 映射到服务端四档；
  /// 请求高于歌曲实际最高音质时服务端按原始最高音质封顶。
  Future<String?> resolvePlayUrl(Track track, {String quality = 'hq'}) async {
    if (track.id.isEmpty) return null;
    try {
      return await _resolveMediaUrl(track.id, quality);
    } catch (_) {
      return null;
    }
  }

  /// 歌曲实际最高音质（`/api/music/info/{id}` 的 `maxQuality`）。
  ///
  /// 服务端自「可选音质流」起返回该字段；未升级 / 无字段 / 请求失败 / 离线
  /// 一律返回 null（调用方按全档位展示，实际取流时仍由服务端按原始最高封顶）。
  Future<String?> fetchMaxQuality(String id) async {
    if (id.isEmpty) return null;
    try {
      final body = await _client().getJson('/api/music/info/$id');
      final data = body['data'];
      final raw = data is Map ? data['maxQuality'] : null;
      return normalizeNekoQuality(raw?.toString());
    } catch (_) {
      return null;
    }
  }

  /// 探测音频真实扩展名（下载落盘用）。
  ///
  /// Neko 直链无扩展名：按**文件头魔数**嗅探（对齐官方 PC 客户端的扩展名
  /// 判定）。先换取真实媒体地址（`/api/music/file` 已改为 JSON），再对该媒体
  /// 直链做 Range 嗅探。[quality] 与取流档位一致——`standard`/`hq` 为服务端
  /// 转码 MP3，`sq`/`hires` 为原始容器（可能 FLAC），档位不同扩展名可能不同。
  Future<String?> probeAudioExtension(String id, {String quality = 'hq'}) async {
    if (id.isEmpty) return null;
    try {
      final url = await _resolveMediaUrl(id, quality);
      if (url == null) return null;
      final head = await _client().getLeadingBytes(url);
      return sniffAudioExtension(head);
    } catch (_) {
      return null;
    }
  }

  /// 歌词（LRC 文本；无歌词返回 null）。
  Future<String?> lyricText(String id) async {
    if (id.isEmpty) return null;
    try {
      final body = await _client().getJson('/api/music/lyrics/$id');
      if (body['success'] == true) {
        final data = body['data'];
        if (data is String && data.trim().isNotEmpty) return data;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── 评论 ─────────────────────────────────────────────────────

  /// 歌曲评论（`GET /api/comments?musicId=&page=&pageSize=`，无需登录）。
  ///
  /// 服务端返回顶层楼层（含每层回复）分页；[musicId] 即 Neko 歌曲 id。
  Future<NekoCommentPage> songComments(
    String musicId, {
    int page = 1,
    int pageSize = 20,
  }) async {
    const empty = NekoCommentPage(
      list: [],
      total: 0,
      page: 1,
      pageSize: 20,
      hasMore: false,
    );
    if (musicId.isEmpty) return empty;
    final body = await _client().getJson(
      '/api/comments',
      query: {'musicId': musicId, 'page': '$page', 'pageSize': '$pageSize'},
    );
    _ensureSuccess(body);
    final data = body['data'];
    if (data is! Map) return empty;
    return NekoCommentPage.fromData(Map<String, dynamic>.from(data));
  }

  /// 发表评论 / 回复（`POST /api/comments`，需登录）。
  ///
  /// [parentId] 非空表示回复（回复再回复仍归入同一楼层）。服务端限制：
  /// 内容 ≤500 字、同用户 5 秒间隔（超频时抛带 message 的 [NekoApiException]）。
  Future<void> sendComment(
    String musicId,
    String content, {
    String? parentId,
  }) async {
    if (musicId.isEmpty) throw NekoApiException('缺少曲目 id');
    final body = await _client().postJson(
      '/api/comments',
      body: {
        'musicId': int.tryParse(musicId) ?? musicId,
        'content': content,
        if (parentId != null && parentId.isNotEmpty)
          'parentId': int.tryParse(parentId) ?? parentId,
      },
    );
    _ensureSuccess(body);
  }

  /// 删除评论（`DELETE /api/comments?id=`，需登录）。
  ///
  /// 服务端只允许删自己的评论（管理员令牌可删任意一条）；删楼层会连带删除
  /// 该楼层下的全部回复。
  Future<void> deleteComment(String id) async {
    if (id.isEmpty) throw NekoApiException('缺少评论 id');
    final body = await _client().deleteJson(
      '/api/comments',
      query: {'id': id},
    );
    _ensureSuccess(body);
  }

  // ── 解析辅助 ─────────────────────────────────────────────────

  List<Track> _tracksFrom(Object? list) {
    final out = <Track>[];
    if (list is List) {
      for (final e in list.whereType<Map>()) {
        final t = Track.fromNekoSong(
          Map<String, dynamic>.from(e),
          baseUrl: baseUrl,
        );
        if (t.id.isNotEmpty) out.add(t);
      }
    }
    return out;
  }

  List<NekoPlaylist> _playlistsFrom(Object? list) {
    final out = <NekoPlaylist>[];
    if (list is List) {
      for (final e in list.whereType<Map>()) {
        final p = NekoPlaylist.fromJson(Map<String, dynamic>.from(e));
        if (p.id.isNotEmpty) out.add(p);
      }
    }
    return out;
  }

  /// 用户头像地址（`GET /api/user/avatar/{userId}`，返回图片文件、无需鉴权）。
  ///
  /// [userId] 为空返回 null（调用方走首字母占位）。服务端头像地址固定、换图后
  /// URL 不变，会命中 CDN/HTTP 缓存显示旧图；这里附加**每次启动唯一**的版本
  /// 参数（对齐官方 Web 端 `?v=` 做法），保证新头像能取回。
  String? userAvatarUrl(String? userId) {
    final id = userId?.trim() ?? '';
    if (id.isEmpty) return null;
    return resolveUrl('/api/user/avatar/$id?v=$_avatarVersion');
  }

  /// 封面路径 → 绝对地址；默认头像/空路径返回 null。
  String? _coverOf(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.contains('/avatar/default')) return null;
    return resolveUrl(path);
  }
}

/// 内部：媒体直链缓存项（`/api/music/file` 解析结果，进程内短 TTL）。
class _NekoMediaUrl {
  const _NekoMediaUrl(this.url, this.expiresAt);

  final String url;
  final DateTime expiresAt;
}

/// 内部：歌手搜索结果（name + 曲目）。
class _NekoArtist {  const _NekoArtist({
    required this.name,
    required this.musicCount,
    required this.tracks,
    this.firstCover,
  });

  final String name;
  final int musicCount;
  final List<Track> tracks;
  final String? firstCover;
}
