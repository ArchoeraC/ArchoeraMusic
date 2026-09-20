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

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../apis/neko/neko_client.dart';
import '../../apis/runtime.dart';
import '../netease/netease_api.dart' show CoverItem, SearchResult;
import '../netease/track.dart';
import 'neko_audio.dart';
import 'neko_types.dart';

/// 会话存储平台键（vault）。
const String kNekoSessionPlatform = 'neko';

/// Neko 音源服务。
class NekoApi extends ChangeNotifier {
  NekoApi();

  String? _token;
  NekoUser? _account;

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

  NekoClient _client() => NekoClient(baseUrl: baseUrl, token: _token);

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
  }

  /// 账号密码登录（`username` 实际为邮箱）。失败抛 [NekoApiException]。
  Future<void> loginPassword(String email, String password) async {
    final body = await _client().postJson(
      '/api/user/login',
      body: {'username': email, 'password': password},
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
        : NekoUser(id: '', username: email, email: email);
    _persistSession();
    notifyListeners();
  }

  /// 创建二维码登录会话。
  Future<NekoQrSession> qrCreate() async {
    final body = await _client().postJson('/api/user/qrlogin/create');
    _ensureSuccess(body);
    final data = body['data'];
    if (data is! Map) throw NekoApiException('二维码响应格式异常');
    final map = Map<String, dynamic>.from(data);
    return NekoQrSession(
      sessionId: map['sessionId']?.toString() ?? '',
      qrContent: map['qrContent']?.toString() ?? '',
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

  /// 解析播放 URL（Neko 音频直链，服务端支持 Range/206 拖动）。
  Future<String?> resolvePlayUrl(Track track, {String quality = 'hq'}) async {
    if (track.id.isEmpty) return null;
    return '$baseUrl/api/music/file/${track.id}';
  }

  /// 曲目文件格式（`/api/music/info/{id}` 的 `fileFormat`，如 mp3/flac/wav）。
  ///
  /// 下载时用于推断落盘扩展名（Neko 音频直链无扩展名，无法从 URL 判断）。
  /// 失败/未知返回 null（调用方回退默认扩展名）。
  Future<String?> songFormat(String id) async {
    if (id.isEmpty) return null;
    try {
      final body = await _client().getJson('/api/music/info/$id');
      if (body['success'] == true) {
        final data = body['data'];
        final format = data is Map ? data['fileFormat']?.toString() : null;
        final f = (format ?? '').trim().toLowerCase();
        if (f.isNotEmpty) return f;
      }
    } catch (_) {
      // 未知格式走默认扩展名
    }
    return null;
  }

  /// 探测音频真实扩展名（下载落盘用）。
  ///
  /// Neko 直链无扩展名且为直传原文件：优先按**文件头魔数**嗅探（对齐官方
  /// PC 客户端的扩展名判定），失败再回退 `/api/music/info` 的 `fileFormat`。
  /// 都失败返回 null（调用方用默认 `mp3`）。
  Future<String?> probeAudioExtension(String id) async {
    if (id.isEmpty) return null;
    final head = await _client().getLeadingBytes('/api/music/file/$id');
    final sniffed = sniffAudioExtension(head);
    if (sniffed != null) return sniffed;
    return songFormat(id);
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

  /// 封面路径 → 绝对地址；默认头像/空路径返回 null。
  String? _coverOf(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.contains('/avatar/default')) return null;
    return resolveUrl(path);
  }
}

/// 内部：歌手搜索结果（name + 曲目）。
class _NekoArtist {
  const _NekoArtist({
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
