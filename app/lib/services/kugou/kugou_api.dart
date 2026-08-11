/// 酷狗 API 封装（Dart 直连，对齐 apis/kugou + KuGouMusicApi）。
///
/// - 搜索：mobilecdn.kugou.com（带封面，http）→ 兜底 songsearch.kugou.com
/// - 取 URL：gateway.kugou.com/v5/url（android 签名 + key + 真实 dfid）
///   [dfid] 进程级缓存，status=2（需验证）时重新 register_dev 重试一次
/// - 歌词：lyrics.kugou.com 两步走（search → download），krc 用
///   XOR+zlib 解码（对齐 lx-music 的 KRC 逻辑）
///
/// 音质切换：按 SPlayer-Next 档位（lq/sq/hq/lossless/hi-res）映射 KG 品质
/// 链（128k/320k/flac/flac24bit），命中档位缺 hash 或请求失败时自动降级。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../apis/runtime.dart';
import '../netease/netease_api.dart' show CoverItem, SearchResult;
import '../netease/track.dart';
import 'kugou_crypto.dart';
import 'kugou_parse.dart';
import 'kugou_request.dart';
import 'kugou_types.dart';

export 'kugou_parse.dart';
export 'kugou_types.dart';

/// 会话在宿主会话存储中的平台键。
const _kugouSessionPlatform = 'kugou';

/// 酷狗 API 封装。
class KugouApi extends ChangeNotifier {
  KugouApi() {
    session = _restoreSession();
    // 启动恢复会话时异步补齐头像/昵称（旧会话可能未存 avatarUrl）
    if (session != null) {
      unawaited(refreshUserInfo());
    }
  }

  /// 进程级设备标识（register_dev 返回；v5/url 前置条件，随机 dfid
  /// 会被服务端拒为「需要验证」）。
  String? _dfid;

  /// 进程级设备 MID（v5/url 签名用）。
  late final String _mid = kgCalcMid(kgRandomString(16));

  /// 登录会话（扫码成功 → token/userid；v5/url 注入后即可拿 VIP 曲目）。
  KugouSession? session;

  /// 是否已登录。
  bool get isLoggedIn => session != null;

  /// 从宿主会话存储恢复（跨重启保留登录态）。
  KugouSession? _restoreSession() {
    final saved = getRuntime().sessionStore.get(_kugouSessionPlatform);
    if (saved.isEmpty) return null;
    final session = KugouSession.fromJson(saved);
    if (session.token.isEmpty || session.userid.isEmpty) return null;
    return session;
  }

  /// 保存登录会话（扫码成功后调用；落盘到宿主会话存储，重启保留）。
  void saveSession(String token, String userid, {String? nickname}) {
    session = KugouSession(token: token, userid: userid, nickname: nickname);
    _likeListId = null;
    getRuntime().sessionStore.save(_kugouSessionPlatform, session!.toJson());
    notifyListeners();
  }

  /// 拉取用户详情并更新会话（user_detail：nickname / avatarUrl）。
  /// 登录后或启动恢复会话后调用；失败静默（头像回退昵称首字）。
  Future<void> refreshUserInfo() async {
    final current = session;
    if (current == null) return;
    try {
      final info = await kgGetMyInfo(
        token: current.token,
        userid: current.userid,
        dfid: await _getDfid(),
        mid: _mid,
      );
      final pic = info['pic']?.toString();
      final nick = info['nickname']?.toString();
      if ((pic == null || pic.isEmpty) && (nick == null || nick.isEmpty)) {
        return; // 无有效更新
      }
      session = KugouSession(
        token: current.token,
        userid: current.userid,
        nickname: nick == null || nick.isEmpty ? current.nickname : nick,
        avatarUrl: pic == null || pic.isEmpty ? current.avatarUrl : pic,
      );
      getRuntime().sessionStore.save(_kugouSessionPlatform, session!.toJson());
      notifyListeners();
    } catch (_) {
      // 头像获取失败不影响播放功能，静默
    }
  }

  /// 清除登录会话。
  void clearSession() {
    session = null;
    _likeListId = null;
    getRuntime().sessionStore.clear(_kugouSessionPlatform);
    notifyListeners();
  }

  Future<String> _getDfid() async {
    final cached = _dfid;
    if (cached != null) return cached;
    _dfid = await kgRegisterDevice(mid: _mid);
    return _dfid!;
  }

  // ─── 扫码登录 ─────────────────────────────────────────────────────

  /// 生成登录二维码 key（UI 用它拼 `$kgQrLoginPage?qrcode=$key` 出图）。
  Future<String> qrKey() => kgQrKey(mid: _mid);

  /// 轮询扫码状态。返回 {status, token, userid, nickname}：
  /// 0=过期 / 1=等待 / 2=待确认 / 4=成功（成功后调用 [saveSession]）。
  Future<Map<String, dynamic>> qrCheck(String key) => kgQrCheck(key, mid: _mid);

  // ─── 搜索 ─────────────────────────────────────────────────────────

  /// 搜索歌曲（mobilecdn → 兜底 songsearch）。
  ///
  /// 返回 [Track]（source == 'kugou'，含 kugou 品质信息）。
  Future<SearchResult<Track>> searchSongs(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    if (keyword.isEmpty) {
      return SearchResult(items: const [], total: 0, hasMore: false);
    }
    try {
      final result = await _searchMobile(keyword, page, limit);
      if (result.items.isNotEmpty) return result;
    } catch (_) {
      // 主路径失败，兜底旧接口
    }
    return _searchLegacy(keyword, page, limit);
  }

  /// 下载前补齐酷狗 hash 链：按 title 重新 mobilecdn 搜索，把匹配条目的
  /// 高音质 hash（320k/flac/flac24bit）合并进 [track]（原 hash 优先，缺档补上）。
  /// 历史/收藏/歌单等入口恢复的旧 Track 可能只有 128k hash，直接下载会被
  /// 静默降级；此方法保证下载能用上最高可用音质。已完整或无匹配返回 null。
  Future<Track?> enrichKugouHashes(Track track) async {
    final kugou = track.kugou;
    if (kugou == null || track.title.trim().isEmpty) return null;
    const wanted = ['flac24bit', 'flac', '320k', '128k'];
    if (wanted.every((k) => (kugou.hashes[k] ?? '').isNotEmpty)) return null;

    final result = await searchSongs(track.title.trim(), page: 1, limit: 20);
    Track? best;
    final curHash = kugou.hash.toLowerCase();
    final curId = track.id.toLowerCase();
    // 1) 音频级 hash 精确匹配（最稳，不会下错版本）
    for (final t in result.items) {
      final info = t.kugou;
      if (info == null) continue;
      final h = info.hash.toLowerCase();
      if (h.isNotEmpty && (h == curHash || h == curId)) {
        best = t;
        break;
      }
    }
    // 2) 标题 + 歌手规范化匹配（原 hash 可能来自旧数据源/不同接口）
    if (best == null) {
      String norm(String s) => s.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      final nt = norm(track.title);
      final na = norm(track.artistNames);
      for (final t in result.items) {
        if (t.kugou == null) continue;
        if (norm(t.title) == nt && norm(t.artistNames) == na) {
          best = t;
          break;
        }
      }
    }
    final src = best?.kugou;
    if (best == null || src == null) return null;

    final newHashes = <String, String>{};
    final newSizes = <String, int>{};
    for (final k in wanted) {
      final old = kugou.hashes[k];
      newHashes[k] = (old != null && old.isNotEmpty)
          ? old
          : (src.hashes[k] ?? '');
      final os = kugou.sizes[k];
      newSizes[k] = (os != null && os > 0) ? os : (src.sizes[k] ?? 0);
    }
    final info = KugouTrackInfo(
      hash: kugou.hash,
      hashes: newHashes,
      sizes: newSizes,
      fileid: kugou.fileid,
      albumId: kugou.albumId,
      mixSongId: kugou.mixSongId,
      sort: kugou.sort,
    );
    return track.copyWithKugou(info);
  }

  Future<SearchResult<Track>> _searchMobile(
    String keyword,
    int page,
    int limit,
  ) async {
    final uri = Uri.parse(kgMobilecdnUrl).replace(
      queryParameters: {
        'keyword': keyword,
        'page': '$page',
        'pagesize': '$limit',
        'format': 'json',
        'showtype': '1',
      },
    );
    final body = await kgGet(uri);
    final data = body is Map<String, dynamic> ? body['data'] : null;
    final info = data is Map<String, dynamic> ? data['info'] : null;
    final raw = info is List ? info : const [];
    final total = (data is Map<String, dynamic> ? data['total'] : null);
    final totalNum = total is num
        ? total.toInt()
        : (total != null ? int.tryParse(total.toString()) ?? 0 : 0);

    final items = <Track>[];
    final seen = <String>{};
    void push(Map<String, dynamic> song) {
      final key = '${song['audio_id']}_${song['hash']}';
      if (seen.contains(key)) return;
      seen.add(key);
      items.add(Track.fromKugouSong(song));
    }

    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      push(item);
      final group = item['group'];
      if (group is List) {
        for (final sub in group) {
          if (sub is Map<String, dynamic>) push(sub);
        }
      }
    }
    return SearchResult(
      items: items,
      total: totalNum > 0 ? totalNum : items.length,
      hasMore: items.length >= limit,
    );
  }

  Future<SearchResult<Track>> _searchLegacy(
    String keyword,
    int page,
    int limit,
  ) async {
    final uri = Uri.parse(kgSearchUrl).replace(
      queryParameters: {
        'keyword': keyword,
        'page': '$page',
        'pagesize': '$limit',
        'userid': '0',
        'clientver': '',
        'platform': 'WebFilter',
        'filter': '2',
        'iscorrection': '1',
        'privilege_filter': '0',
        'area_code': '1',
      },
    );
    final body = await kgGet(uri);
    final data = body is Map<String, dynamic> ? body['data'] : null;
    final lists = data is Map<String, dynamic> ? data['lists'] : null;
    final raw = lists is List ? lists : const [];
    final total = (data is Map<String, dynamic> ? data['total'] : null);
    final totalNum = total is num
        ? total.toInt()
        : (total != null ? int.tryParse(total.toString()) ?? 0 : 0);

    final items = <Track>[];
    final seen = <String>{};
    void push(Map<String, dynamic> song) {
      final key = '${song['Audioid']}_${song['FileHash']}';
      if (seen.contains(key)) return;
      seen.add(key);
      items.add(Track.fromKugouSong(song));
    }

    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      push(item);
      final grp = item['Grp'];
      if (grp is List) {
        for (final sub in grp) {
          if (sub is Map<String, dynamic>) push(sub);
        }
      }
    }
    return SearchResult(
      items: items,
      total: totalNum > 0 ? totalNum : items.length,
      hasMore: items.length >= limit,
    );
  }

  // ─── 取 URL（音质切换） ───────────────────────────────────────────

  /// 解析可播放 URL（gateway.kugou.com/v5/url）。
  ///
  /// [quality] 为 SPlayer-Next 档位（lq/sq/hq/lossless/hi-res），按
  /// KugouTrackInfo 品质链降级尝试；全部失败或无资源返回 null。
  Future<String?> resolvePlayUrl(
    KugouTrackInfo info, {
    String quality = 'hq',
  }) async {
    const chains = <String, List<String>>{
      'lq': ['128k'],
      'sq': ['320k', '128k'],
      'hq': ['320k', '128k'],
      'lossless': ['flac', '320k', '128k'],
      'hi-res': ['flac24bit', 'flac', '320k', '128k'],
    };
    for (final q in chains[quality] ?? const <String>[]) {
      final hash = info.hashes[q];
      final qualityParam = KugouTrackInfo.qualityParam(q);
      if (hash == null || hash.isEmpty || qualityParam == null) continue;
      try {
        final url = await _tryUrl(hash, qualityParam);
        if (url != null) return url;
      } catch (_) {
        // 网络错误继续降级
      }
    }
    return null;
  }

  /// 单档 URL 请求（dfid 用 register_dev 真实值，对齐 MoeKouMusic 后端
  /// 先 /register/dev 再 /song/url 的链路；status=2 需验证时换新 dfid
  /// 重试一次）。
  Future<String?> _tryUrl(
    String hash,
    String qualityParam, {
    bool retried = false,
  }) async {
    final dfid = await _getDfid();
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final hashLc = hash.toLowerCase();

    final params = <String, dynamic>{
      ...kgSongUrlBase,
      'dfid': dfid,
      'mid': _mid,
      'uuid': '-',
      'appid': kgLiteAppid,
      'clienttime': ts,
      'hash': hashLc,
      'quality': qualityParam,
    };
    // 登录态注入 token/userid（对齐 request.js defaultParams：
    // `if (token) token; if (userid && userid !== 0) userid`）
    final uid = session?.userid ?? '';
    final token = session?.token ?? '';
    if (token.isNotEmpty) params['token'] = token;
    if (uid.isNotEmpty && uid != '0') params['userid'] = uid;
    params['key'] = kgSignKey(
      hashLc,
      _mid,
      int.tryParse(uid) ?? 0,
      kgLiteAppid,
      salt: kgLiteKeySalt,
    );
    params['signature'] = kgSignature(params, salt: kgLiteSignSalt);

    final uri = Uri.parse('$kgSongUrl?${kgQueryString(params)}');
    final body = await kgGet(
      uri,
      headers: {
        'User-Agent': kgAndroidUa,
        'x-router': 'trackercdn.kugou.com',
        'dfid': dfid,
        'clienttime': '$ts',
        'mid': _mid,
        'kg-rc': '1',
        'kg-thash': '5d816a0',
        'kg-rec': '1',
        'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
      },
    );
    if (body is! Map<String, dynamic>) return null;

    final status = (body['status'] as num?)?.toInt() ?? 0;
    if (status == 1) {
      final urls = body['url'];
      if (urls is List && urls.isNotEmpty) {
        final first = urls.first?.toString() ?? '';
        if (first.isNotEmpty) return first;
      }
      return null;
    }
    if (status == 2 && !retried) {
      // 本次请求需要验证：重新注册拿新 dfid 再试一次
      _dfid = null;
      return _tryUrl(hashLc, qualityParam, retried: true);
    }
    return null;
  }

  // ─── 歌词 ─────────────────────────────────────────────────────────

  /// 歌词：hash + 歌名 + 时长（秒）三元组匹配（KG 特有）。
  Future<KugouLyric?> lyric({
    required String hash,
    String name = '',
    int? durationSeconds,
  }) async {
    final seconds = durationSeconds ?? 0;
    final searchUri = Uri.parse(kgLyricSearchUrl).replace(
      queryParameters: {
        'ver': '1',
        'man': 'yes',
        'client': 'pc',
        'lrctxt': '1',
        'keyword': name,
        'hash': hash,
        'timelength': '$seconds',
      },
    );
    final searchResp = await kgGet(searchUri, headers: kgLyricHeaders);
    if (searchResp is! Map<String, dynamic>) return null;
    final candidates = searchResp['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final cand = candidates.first;
    if (cand is! Map<String, dynamic>) return null;

    final id = cand['id']?.toString() ?? '';
    final accesskey = cand['accesskey']?.toString() ?? '';
    if (id.isEmpty || accesskey.isEmpty) return null;
    final krctype = (cand['krctype'] as num?)?.toInt() ?? 0;
    final contenttype = (cand['contenttype'] as num?)?.toInt() ?? 0;
    final fmt = krctype == 1 && contenttype != 1 ? 'krc' : 'lrc';

    final dlUri = Uri.parse(kgLyricDownloadUrl).replace(
      queryParameters: {
        'ver': '1',
        'client': 'pc',
        'charset': 'utf8',
        'id': id,
        'accesskey': accesskey,
        'fmt': fmt,
      },
    );
    final dl = await kgGet(dlUri, headers: kgLyricHeaders);
    if (dl is! Map<String, dynamic>) return null;
    final content = dl['content']?.toString() ?? '';
    if (content.isEmpty) return null;

    if (dl['fmt']?.toString() == 'krc') {
      return decodeKrc(content);
    }
    return KugouLyric(
      lrc: utf8.decode(base64.decode(content), allowMalformed: true),
    );
  }

  /// 歌曲评论（mcomment commentsv2/getCommentWithLike；无需登录）。
  ///
  /// [hash] 为歌曲 hash；返回分页评论。评论条目的 `replys` 首个作为
  /// 引用回复（kgCommentFromKg 递归解析）。
  Future<KugouCommentPage> songComments(
    String hash, {
    int page = 1,
    int pagesize = 20,
  }) async {
    if (hash.isEmpty) throw KgApiException('缺少歌曲 hash，无法获取评论');
    final resp = await kgComments(hash, page: page, pagesize: pagesize);
    final listRaw = resp['list'];
    final list = listRaw is List
        ? listRaw
              .whereType<Map<String, dynamic>>()
              .map(kgCommentFromKg)
              .toList()
        : const <KugouComment>[];
    return KugouCommentPage(
      list: list,
      total: (resp['count'] as num?)?.toInt() ?? 0,
      page: page,
      limit: pagesize,
    );
  }

  // ─── 网关模块（对齐 KuGouMusicApi module/*.js，概念版 lite） ───────

  /// 网关请求快捷入口（注入设备与登录态，缺省 dfid='-'）。
  Future<dynamic> _gateway(
    String path, {
    required String method,
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    String baseUrl = 'https://gateway.kugou.com',
    bool encryptKey = false,
  }) => kgGateway(
    path,
    method: method,
    query: query,
    body: body,
    headers: headers,
    baseUrl: baseUrl,
    encryptKey: encryptKey,
    mid: _mid,
    token: session?.token,
    userid: session?.userid,
  );

  /// 每日推荐（需登录；未登录抛异常提示）。
  Future<List<Track>> everydayRecommend() async {
    if (session == null) {
      throw KgApiException('每日推荐需要登录酷狗账号');
    }
    final resp = await _gateway(
      '/everyday_song_recommend',
      method: 'POST',
      query: {'platform': 'ios'},
      headers: {'x-router': 'everydayrec.service.kugou.com'},
    );
    // 歌曲列表在 data.song_list（实测 gateway 响应统一包在 data 内）；
    // 保留顶层读取作兼容兜底
    final data = resp is Map ? resp['data'] : null;
    final list = data is Map
        ? (data['song_list'] ?? resp['song_list'])
        : (resp is Map ? resp['song_list'] : null);
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(kgTrackFromKgPlain)
        .where((t) => t.kugou != null)
        .toList();
  }

  /// 推荐歌单（categoryId 0=推荐，其余分类 id 走 /v2/special_recommend）。
  Future<List<CoverItem>> topPlaylists({
    int categoryId = 0,
    int page = 1,
    int pagesize = 30,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final resp = await _gateway(
      '/v2/special_recommend',
      method: 'POST',
      body: {
        // 对齐 top_playlist.js：body 内用标准版 appid/clientver（与 lite 注入的 query 并存）
        'appid': 1005,
        'mid': _mid,
        'clientver': 20489,
        'platform': 'android',
        'clienttime': ts,
        'userid': int.tryParse(session?.userid ?? '') ?? 0,
        'module_id': 1,
        'page': page,
        'pagesize': pagesize,
        'key': kgSignParamsKey('$ts'),
        'special_recommend': {
          'withtag': 1,
          'withsong': 1,
          'sort': 1,
          'ugc': 1,
          'is_selected': 0,
          'withrecommend': 1,
          'area_code': 1,
          'categoryid': categoryId,
        },
        'req_multi': 1,
        'retrun_min': 5,
        'return_special_falg': 1,
      },
      headers: {'x-router': 'specialrec.service.kugou.com'},
    );
    // 歌单列表在 data.special_list（实测 gateway 响应统一包在 data 内）；
    // 保留顶层读取作兼容兜底
    final data = resp is Map ? resp['data'] : null;
    final list = data is Map
        ? (data['special_list'] ?? resp['special_list'])
        : (resp is Map ? resp['special_list'] : null);
    if (list is! List) return const [];
    return list.whereType<Map<String, dynamic>>().map((p) {
      final id = p['global_collection_id']?.toString() ?? '';
      return CoverItem(
        id: id,
        title: p['specialname']?.toString() ?? '',
        cover: kgFillCover(p['flexible_cover']?.toString(), 300),
        subtitle: p['intro']?.toString() ?? '',
      );
    }).toList();
  }

  /// 歌单详情（v3/get_list_info）。
  Future<Map<String, dynamic>?> playlistDetail(String id) async {
    final resp = await _gateway(
      '/v3/get_list_info',
      method: 'POST',
      body: {
        'data': [
          {'global_collection_id': id},
        ],
        'userid': int.tryParse(session?.userid ?? '') ?? 0,
        'token': session?.token ?? '',
      },
      headers: {'x-router': 'pubsongs.kugou.com'},
    );
    final data = resp is Map ? resp['data'] : null;
    if (data is List && data.isNotEmpty && data.first is Map) {
      return Map<String, dynamic>.from(data.first as Map);
    }
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  /// 公开歌单全量歌曲（playlist_track_all；60/页循环拉满，最多 [max] 首）。
  Future<List<Track>> playlistTracksAll(String id, {int max = 300}) async {
    const pagesize = 60;
    final all = <Track>[];
    var page = 1;
    while (all.length < max) {
      final resp = await _gateway(
        '/pubsongs/v2/get_other_list_file_nofilt',
        method: 'GET',
        query: {
          'area_code': 1,
          'begin_idx': (page - 1) * pagesize,
          'plat': 1,
          'type': 1,
          'mode': 1,
          'personal_switch': 1,
          'extend_fields': 'abtags,hot_cmt,popularization',
          'pagesize': pagesize,
          'global_collection_id': id,
        },
      );
      // 歌曲与 list_info 在 data 内（实测 gateway 响应统一包在 data 内）
      final data = resp is Map ? resp['data'] : null;
      final songs = data is Map
          ? (data['songs'] ?? resp['songs'])
          : (resp is Map ? resp['songs'] : null);
      if (songs is! List || songs.isEmpty) break;
      all.addAll(
        songs
            .whereType<Map<String, dynamic>>()
            .map(kgTrackFromKgPlain)
            .where((t) => t.kugou != null),
      );
      final listInfo = data is Map
          ? (data['list_info'] ?? resp['list_info'])
          : (resp is Map ? resp['list_info'] : null);
      final total = listInfo is Map ? listInfo['count'] : null;
      final totalNum = total is num
          ? total.toInt()
          : int.tryParse('$total') ?? 0;
      if (songs.length < pagesize) break;
      if (totalNum > 0 && all.length >= totalNum) break;
      page++;
    }
    return all;
  }

  /// 私有歌单（用户歌单/"我喜欢"）歌曲单页。
  ///
  /// 返回 `(tracks, total)`：tracks 为当页歌曲，**保持接口返回顺序**
  /// （最新收藏在前）。[gid] 非空时走公开歌单接口
  /// `/pubsongs/v2/get_other_list_file_nofilt`（global_collection_id，
  /// 按「最新收藏在前」稳定分页，对齐 MoeKoeMusic /playlist/track/all
  /// 方案）；该 id 无法用于公开接口（实为 listid）时回退个人接口
  /// `/v4/get_list_all_file`。两种接口均不按 sort 排序——sort 字段在
  /// 部分条目缺失/不稳定，依赖它会打乱接口顺序。
  Future<(List<Track>, int)> playlistTracksNewPage(
    String listid, {
    String? gid,
    int page = 1,
    int pagesize = 60,
  }) async {
    if (session == null) return (const <Track>[], 0);
    if (gid != null && gid.isNotEmpty) {
      try {
        return await _playlistTracksByGid(gid, page: page, pagesize: pagesize);
      } catch (_) {
        // 该 id 无法用于公开歌单接口（实为 listid 或接口异常）→ 回退个人接口
      }
    }
    return _playlistTracksByListid(listid, page: page, pagesize: pagesize);
  }

  /// 公开歌单接口单页（get_other_list_file_nofilt，GET + android 签名）。
  ///
  /// 对齐 KuGouMusicApi playlist_track_all.js：begin_idx 分页 + plat/mode/
  /// personal_switch/extend_fields；歌曲在 `data.songs`，总数在
  /// `data.list_info.count`。条目字段（name="歌手 - 歌名" 合并名、
  /// relate_goods 档位）由 [kgTrackFromKgPlain] 的 preferMergedName 处理。
  Future<(List<Track>, int)> _playlistTracksByGid(
    String gid, {
    required int page,
    required int pagesize,
  }) async {
    final resp = await _gateway(
      '/pubsongs/v2/get_other_list_file_nofilt',
      method: 'GET',
      query: {
        'begin_idx': (page - 1) * pagesize,
        'plat': 1,
        'type': 1,
        'mode': 1,
        'personal_switch': 1,
        'extend_fields': 'abtags,hot_cmt,popularization',
        'pagesize': pagesize,
        'global_collection_id': gid,
      },
    );
    final data = resp is Map ? resp['data'] : null;
    final songs = data is Map ? data['songs'] : null;
    final tracks = songs is List
        ? songs
              .whereType<Map<String, dynamic>>()
              .map((s) => kgTrackFromKgPlain(s, preferMergedName: true))
              .where((t) => t.kugou != null)
              .toList()
        : const <Track>[];
    final listInfo = data is Map ? data['list_info'] : null;
    final totalRaw = listInfo is Map ? listInfo['count'] : null;
    final total = totalRaw is num
        ? totalRaw.toInt()
        : int.tryParse('$totalRaw') ?? tracks.length;
    return (tracks, total);
  }

  /// 个人歌单接口单页（get_list_all_file，POST + listid）。
  Future<(List<Track>, int)> _playlistTracksByListid(
    String listid, {
    required int page,
    required int pagesize,
  }) async {
    final resp = await _gateway(
      '/v4/get_list_all_file',
      method: 'POST',
      body: {
        'listid': listid,
        'userid': session!.userid,
        'area_code': 1,
        'show_relate_goods': 0,
        'pagesize': pagesize,
        'allplatform': 1,
        'show_cover': 1,
        'type': 0,
        'token': session!.token,
        'page': page,
      },
      headers: {'x-router': 'cloudlist.service.kugou.com'},
    );
    final data = resp is Map ? resp['data'] : null;
    // v4/get_list_all_file 歌曲在 data.info（非 data.songs），
    // 总数在 data.count（非 data.total）
    final songs = data is Map ? data['info'] : null;
    final tracks = <Track>[];
    if (songs is List) {
      tracks.addAll(
        songs
            .whereType<Map<String, dynamic>>()
            .map(kgTrackFromKgPlain)
            .where((t) => t.kugou != null),
      );
    }
    final totalRaw = data is Map ? data['count'] : null;
    final total = totalRaw is num
        ? totalRaw.toInt()
        : int.tryParse('$totalRaw') ?? tracks.length;
    return (tracks, total);
  }

  /// 私有歌单（用户歌单/"我喜欢"）全量歌曲。
  ///
  /// 60/页循环翻页至接口返回的 count（总数），无硬上限——「我喜欢」
  /// 可上千首，此前默认截断 300 首导致列表不完整。[gid] 非空时走公开
  /// 歌单接口（顺序稳定），否则回退 listid 个人接口。
  Future<List<Track>> playlistTracksAllNew(String listid, {String? gid}) async {
    const pagesize = 60;
    final all = <Track>[];
    var page = 1;
    // 安全上限：60 首/页 × 200 页 = 12000 首，防接口异常时死循环
    while (page <= 200) {
      final (tracks, total) = await playlistTracksNewPage(
        listid,
        gid: gid,
        page: page,
        pagesize: pagesize,
      );
      if (tracks.isEmpty) break;
      all.addAll(tracks);
      if (tracks.length < pagesize) break;
      if (total > 0 && all.length >= total) break;
      page++;
    }
    return all;
  }

  /// 「我喜欢」歌曲分页（供收藏列表按需加载；每页保持接口顺序，
  /// 最新收藏在前，见 [playlistTracksNewPage]）。
  Future<(List<Track>, int)> likedTracksPage({
    int page = 1,
    int pagesize = 60,
  }) async {
    final gid = await likeGid();
    final listid = await likeListId();
    if (gid == null && listid == null) return (const <Track>[], 0);
    return playlistTracksNewPage(
      listid ?? gid!,
      gid: gid,
      page: page,
      pagesize: pagesize,
    );
  }

  /// 「我喜欢」红心 hash 集合（轻量）。
  ///
  /// 分页循环只取 hash，不保留完整 Track 快照——LikeController 全量
  /// 同步红心状态时避免一次性构造并持有全部曲目对象（GC 友好）。
  Future<Set<String>> likedHashSet() async {
    final gid = await likeGid();
    final listid = await likeListId();
    if (gid == null && listid == null) return const {};
    const pagesize = 60;
    final hashes = <String>{};
    var page = 1;
    // 安全上限：60 首/页 × 200 页 = 12000 首，防接口异常时死循环
    while (page <= 200) {
      final (tracks, total) = await playlistTracksNewPage(
        listid ?? gid!,
        gid: gid,
        page: page,
        pagesize: pagesize,
      );
      if (tracks.isEmpty) break;
      for (final t in tracks) {
        final h = t.kugou?.hash ?? t.id;
        if (h.isNotEmpty) hashes.add(h);
      }
      if (tracks.length < pagesize) break;
      if (total > 0 && hashes.length >= total) break;
      page++;
    }
    return hashes;
  }

  /// 用户歌单列表（v7/get_all_list，需登录）。
  Future<List<CoverItem>> userPlaylists({int pagesize = 500}) async {
    if (session == null) return const [];
    final resp = await _gateway(
      '/v7/get_all_list',
      method: 'POST',
      query: {
        'plat': 1,
        'userid': int.tryParse(session!.userid) ?? 0,
        'token': session!.token,
      },
      body: {
        'userid': session!.userid,
        'token': session!.token,
        'total_ver': 979,
        'type': 2,
        'page': 1,
        'pagesize': pagesize,
      },
      headers: {'x-router': 'cloudlist.service.kugou.com'},
    );
    final data = resp is Map ? resp['data'] : null;
    final info = data is Map ? data['info'] : null;
    if (info is! List) return const [];
    return info.whereType<Map<String, dynamic>>().map((p) {
      final id = p['listid']?.toString() ?? '';
      return CoverItem(
        id: id,
        title: p['name']?.toString() ?? '',
        cover: kgFillCover(p['cover']?.toString(), 300),
        subtitle: p['list_create_userid']?.toString() ?? '',
      );
    }).toList();
  }

  /// 拉取酷狗用户曲库并按归属分类（创建的歌单 / 收藏的歌单 / 收藏的专辑）。
  ///
  /// 对齐 MoeKoeMusic Library.vue 对 `/v7/get_all_list` 的解析：
  /// - `list_create_userid == 登录 userid` 或 `name == '我喜欢'` → 创建的歌单；
  /// - 其余按 `authors` 字段区分「收藏的歌单」（无）与「收藏的专辑」（有）。
  /// 详情 id 取 `list_create_gid` 优先 / `global_collection_id` 兜底。
  /// 保留 [userPlaylists]（id=listid）供「我喜欢」播放链路使用。
  Future<KugouLibrary> userLibrary() async {
    final s = session;
    if (s == null) return const KugouLibrary(items: []);
    final resp = await _gateway(
      '/v7/get_all_list',
      method: 'POST',
      query: {
        'plat': 1,
        'userid': int.tryParse(s.userid) ?? 0,
        'token': s.token,
      },
      body: {
        'userid': s.userid,
        'token': s.token,
        'total_ver': 979,
        'type': 2,
        'page': 1,
        'pagesize': 500,
      },
      headers: {'x-router': 'cloudlist.service.kugou.com'},
    );
    final data = resp is Map ? resp['data'] : null;
    final info = data is Map ? data['info'] : null;
    if (info is! List) return const KugouLibrary(items: []);
    final mine = s.userid;
    final items = <KugouLibraryItem>[];
    for (final p in info.whereType<Map<String, dynamic>>()) {
      final name = p['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final isMine =
          p['list_create_userid']?.toString() == mine || name == '我喜欢';
      final isAlbum = p['authors'] != null;
      // 详情 id：公开歌单用 global_collection_id 系列；「我喜欢」为个人
      // 歌单，无公开 id 时兜底 listid（点击走 likedTracks 个人链路）
      final id =
          p['list_create_gid']?.toString() ??
          p['global_collection_id']?.toString() ??
          (name == '我喜欢' ? p['listid']?.toString() ?? '' : '');
      if (id.isEmpty) continue;
      items.add(
        KugouLibraryItem(
          type: isMine
              ? KugouLibraryType.createdPlaylist
              : isAlbum
              ? KugouLibraryType.collectedAlbum
              : KugouLibraryType.collectedPlaylist,
          id: id,
          title: name,
          cover: kgFillCover(p['pic']?.toString(), 300),
          trackCount: p['count'] is num ? (p['count'] as num).toInt() : 0,
          listid: p['listid']?.toString(),
        ),
      );
    }
    // 「我喜欢」置顶（对齐 MoeKoeMusic sort 优先）
    items.sort((a, b) {
      final al = a.title == '我喜欢' ? -1 : 0;
      final bl = b.title == '我喜欢' ? -1 : 0;
      return al - bl;
    });
    return KugouLibrary(items: items);
  }

  /// 「我喜欢」歌单 listid（进程内缓存；未找到返回 null）。
  String? _likeListId;

  /// 查找「我喜欢」歌单 listid（对齐 MoeKoeMusic Library.vue 约定：
  /// 用户歌单里 `name == '我喜欢'`）。
  Future<String?> likeListId() async {
    final cached = _likeListId;
    if (cached != null) return cached;
    final playlists = await userPlaylists();
    final like = playlists.where((p) => p.title == '我喜欢').toList();
    _likeListId = like.isEmpty ? null : like.first.id;
    return _likeListId;
  }

  /// 「我喜欢」歌单公开 id（进程内缓存；无公开 id 返回 null）。
  String? _likeGid;

  /// 查找「我喜欢」歌单的公开 id（list_create_gid / global_collection_id，
  /// 对齐 MoeKoeMusic Library.vue：打开歌单用 global_collection_id 调
  /// `/playlist/track/all` 公开接口，分页顺序稳定「最新收藏在前」）。
  /// 账号数据缺失公开 id 时返回 null（调用方回退 listid 个人接口）。
  Future<String?> likeGid() async {
    final cached = _likeGid;
    if (cached != null) return cached;
    final lib = await userLibrary();
    final like = lib.items.where((p) => p.title == '我喜欢').toList();
    final item = like.isEmpty ? null : like.first;
    // userLibrary 的 id 已 gid 优先；与 listid 相同说明无公开 id
    final gid = item != null && item.id != item.listid ? item.id : null;
    _likeGid = gid;
    return gid;
  }

  /// 清除「我喜欢」listid/gid 缓存（登录态/歌单变更后调用）。
  void invalidateLikeListId() {
    _likeListId = null;
    _likeGid = null;
  }

  /// 「我喜欢」歌曲列表：优先用公开 id 走公开歌单接口
  /// （get_other_list_file_nofilt，顺序稳定「最新收藏在前」，对齐
  /// MoeKoeMusic /playlist/track/all 方案）；无公开 id 时回退
  /// listid + playlist_track_all_new 个人接口。
  Future<List<Track>> likedTracks() async {
    final gid = await likeGid();
    final listid = await likeListId();
    if (gid == null && listid == null) return const [];
    return playlistTracksAllNew(listid ?? gid!, gid: gid);
  }

  /// 添加歌曲到「我喜欢」（对齐 KuGouMusicApi playlist_tracks_add.js）。
  ///
  /// 参数：`userid, token, listid, list_ver:0, type:0, slow_upload:1,
  /// scene:'false;null', data:[{number, name, hash, size, sort, timelen,
  /// bitrate, album_id, mixsongid}]`，query 带 `last_time/last_area`。
  Future<void> addToLike(Track track) async {
    final s = session;
    if (s == null) throw KgApiException('需要登录酷狗账号');
    final listid = await likeListId();
    if (listid == null) throw KgApiException('未找到「我喜欢」歌单');
    final hash = track.kugou?.hash ?? '';
    if (hash.isEmpty) throw KgApiException('缺少歌曲 hash，无法添加');
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _gateway(
      '/cloudlist.service/v6/add_song',
      method: 'POST',
      query: {
        'last_time': clienttime,
        'last_area': 'gztx',
        'userid': s.userid,
        'token': s.token,
      },
      body: {
        'userid': s.userid,
        'token': s.token,
        'listid': listid,
        'list_ver': 0,
        'type': 0,
        'slow_upload': 1,
        'scene': 'false;null',
        'data': [
          {
            'number': 1,
            'name': track.title,
            'hash': hash,
            'size': 0,
            'sort': 0,
            'timelen': 0,
            'bitrate': 0,
            'album_id': track.kugou?.albumId ?? 0,
            'mixsongid': track.kugou?.mixSongId ?? 0,
          },
        ],
      },
    );
  }

  /// 从「我喜欢」移除歌曲（对齐 KuGouMusicApi playlist_tracks_del.js）。
  ///
  /// 参数：`listid, userid, data:[{fileid}], type:0, token, list_ver:0`，
  /// header `x-router: cloudlist.service.kugou.com`。[fileid] 取自歌单条目
  /// （playlistTracksAllNew 返回的 Track.kugou.fileid）。搜索结果等来源的
  /// 曲目无 fileid 字段，此时按 hash 从「我喜欢」歌单反查补全。
  Future<void> removeFromLike(Track track) async {
    final s = session;
    if (s == null) throw KgApiException('需要登录酷狗账号');
    final listid = await likeListId();
    if (listid == null) throw KgApiException('未找到「我喜欢」歌单');
    var fileid = track.kugou?.fileid;
    if (fileid == null) {
      // 搜索结果无 fileid：反查「我喜欢」歌单，用 hash 匹配补全
      final hash = track.kugou?.hash ?? '';
      if (hash.isEmpty) throw KgApiException('缺少歌曲 hash，无法移除');
      final liked = await playlistTracksAllNew(listid);
      for (final t in liked) {
        if (t.kugou?.hash == hash && t.kugou?.fileid != null) {
          fileid = t.kugou!.fileid;
          break;
        }
      }
      if (fileid == null) throw KgApiException('缺少歌曲 fileid，无法移除');
    }
    await _gateway(
      '/v4/delete_songs',
      method: 'POST',
      body: {
        'listid': listid,
        'userid': s.userid,
        'data': [
          {'fileid': fileid},
        ],
        'type': 0,
        'token': s.token,
        'list_ver': 0,
      },
      headers: {'x-router': 'cloudlist.service.kugou.com'},
    );
  }

  /// 排行榜列表（ocean/v6/rank/list，带部分歌曲）。
  Future<List<CoverItem>> rankList() async {
    final resp = await _gateway(
      '/ocean/v6/rank/list',
      method: 'GET',
      query: {'plat': 2, 'withsong': 1, 'parentid': 0},
    );
    final data = resp is Map ? resp['data'] : null;
    final info = data is Map ? data['info'] : null;
    if (info is! List) return const [];
    return info.whereType<Map<String, dynamic>>().map((r) {
      final id = r['rankid']?.toString() ?? '';
      return CoverItem(
        id: id,
        title: r['rankname']?.toString() ?? '',
        // imgurl 含 {size} 占位，需 kgFillCover 填充（否则图片 URL 失效）
        cover: kgFillCover(
          r['imgurl']?.toString() ??
              r['img_9']?.toString() ??
              r['bannerurl']?.toString() ??
              r['banner_9']?.toString() ??
              r['banner']?.toString(),
          300,
        ),
        subtitle: r['intro']?.toString() ?? '',
      );
    }).toList();
  }

  /// 榜单歌曲（openapi/kmr/v2/rank/audio）。
  Future<List<Track>> rankTracks(
    String rankId, {
    int page = 1,
    int pagesize = 60,
  }) async {
    final resp = await _gateway(
      '/openapi/kmr/v2/rank/audio',
      method: 'POST',
      body: {
        'show_portrait_mv': 1,
        'show_type_total': 1,
        'filter_original_remarks': 1,
        'area_code': 1,
        'pagesize': pagesize,
        'rank_cid': 0,
        'type': 1,
        'page': page,
        'rank_id': rankId,
      },
      headers: {'kg-tid': '369'},
    );
    final data = resp is Map ? resp['data'] : null;
    final list = data is Map ? data['songlist'] : null;
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((s) {
          // hash 嵌套在 deprecated 内（对齐 MoeKoeMusic formatArtistTracks 结构）
          final deprecated = s['deprecated'];
          final item = <String, dynamic>{
            if (deprecated is Map) ...Map<String, dynamic>.from(deprecated),
            ...s,
          };
          return kgTrackFromKgPlain(item);
        })
        .where((t) => t.kugou != null)
        .toList();
  }

  /// 新碟上架（musicadservice/v1/mobile_newalbum_sp；chn/eur/jpn/kor 合并）。
  Future<List<CoverItem>> newAlbums({int page = 1, int pagesize = 30}) async {
    final resp = await _gateway(
      '/musicadservice/v1/mobile_newalbum_sp',
      method: 'POST',
      body: {
        'apiver': 20,
        'token': session?.token ?? '',
        'page': page,
        'pagesize': pagesize,
        'withpriv': 1,
      },
    );
    final data = resp is Map ? resp['data'] : null;
    if (data is! Map) return const [];
    final items = <CoverItem>[];
    for (final key in const ['chn', 'eur', 'jpn', 'kor']) {
      final list = data[key];
      if (list is! List) continue;
      for (final a in list.whereType<Map<String, dynamic>>()) {
        final id = a['albumid']?.toString() ?? '';
        if (id.isEmpty) continue;
        items.add(
          CoverItem(
            id: id,
            title: a['albumname']?.toString() ?? '',
            cover: kgFillCover(a['imgurl']?.toString(), 300),
            subtitle: a['singername']?.toString() ?? '',
            trackCount: a['songcount'] is num ? a['songcount']!.toInt() : 0,
          ),
        );
      }
    }
    return items;
  }

  /// 专辑详情（kmr/v2/albums，返回 data[0]）。
  Future<Map<String, dynamic>?> albumDetail(String albumId) async {
    final resp = await _gateway(
      '/kmr/v2/albums',
      method: 'POST',
      body: {
        'data': [
          {'album_id': albumId},
        ],
        'is_buy': 0,
        'fields':
            'album_id,album_name,publish_date,sizable_cover,intro,language,is_publish,heat,type,quality,authors,exclusive,author_name,trans_param',
      },
      headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '255'},
    );
    final data = resp is Map ? resp['data'] : null;
    if (data is List && data.isNotEmpty && data.first is Map) {
      return Map<String, dynamic>.from(data.first as Map);
    }
    return null;
  }

  /// 专辑歌曲（openapi.kugou.com/v1/album_audio/lite）。
  Future<List<Track>> albumTracks(
    String albumId, {
    int page = 1,
    int pagesize = 60,
  }) async {
    final resp = await _gateway(
      '/v1/album_audio/lite',
      method: 'POST',
      body: {
        'album_id': albumId,
        'is_buy': '',
        'page': page,
        'pagesize': pagesize,
      },
      headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '255'},
    );
    final data = resp is Map ? resp['data'] : null;
    final songs = data is Map ? data['songs'] : null;
    if (songs is! List) return const [];
    return songs
        .whereType<Map<String, dynamic>>()
        .map((s) {
          final audioInfo = s['audio_info'];
          final base = s['base'];
          final albumInfo = s['album_info'];
          final hash = audioInfo is Map
              ? audioInfo['hash']?.toString() ?? ''
              : '';
          final item = <String, dynamic>{
            'hash': hash,
            'audio_name': base is Map
                ? base['audio_name']?.toString() ?? ''
                : '',
            'author_name': base is Map
                ? base['author_name']?.toString() ?? ''
                : '',
            'album_name': albumInfo is Map
                ? albumInfo['album_name']?.toString() ?? ''
                : '',
            'duration': audioInfo is Map ? audioInfo['duration'] : null,
            'hash_320': audioInfo is Map ? audioInfo['hash_320'] : null,
            'hash_flac': audioInfo is Map ? audioInfo['hash_flac'] : null,
            if (s['trans_param'] is Map) 'trans_param': s['trans_param'],
          };
          return kgTrackFromKgPlain(item);
        })
        .where((t) => t.kugou != null)
        .toList();
  }

  /// 歌手详情（kmr/v3/author）。
  Future<Map<String, dynamic>?> artistDetail(String authorId) async {
    final resp = await _gateway(
      '/kmr/v3/author',
      method: 'POST',
      body: {'author_id': authorId},
      headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '36'},
    );
    final data = resp is Map ? resp['data'] : null;
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  /// 歌手单曲（openapi.kugou.com/kmr/v1/audio_group/author）。
  Future<List<Track>> artistAudios(
    String authorId, {
    String sort = 'hot', // 'hot' 最热 / 'new' 最新
    int page = 1,
    int pagesize = 60,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final resp = await _gateway(
      '/kmr/v1/audio_group/author',
      method: 'POST',
      body: {
        'appid': 1005,
        'clientver': 20489,
        'mid': _mid,
        'clienttime': ts,
        'key': kgSignParamsKey('$ts'),
        'author_id': authorId,
        'pagesize': pagesize,
        'page': page,
        'sort': sort == 'hot' ? 1 : 2,
        'area_code': 'all',
      },
      headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '220'},
      baseUrl: 'https://openapi.kugou.com',
    );
    final data = resp is Map ? resp['data'] : null;
    final list = data is Map
        ? data['songlist']
        : data is List
        ? data
        : null;
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(kgTrackFromKgPlain)
        .where((t) => t.kugou != null)
        .toList();
  }

  /// 歌手专辑（openapi.kugou.com/kmr/v1/author/albums）。
  Future<List<CoverItem>> artistAlbums(
    String authorId, {
    String sort = 'new', // 'hot' 最热 / 'new' 最新
    int page = 1,
    int pagesize = 30,
  }) async {
    final resp = await _gateway(
      '/kmr/v1/author/albums',
      method: 'POST',
      body: {
        'author_id': authorId,
        'pagesize': pagesize,
        'page': page,
        'sort': sort == 'hot' ? 3 : 1,
        'category': 1,
        'area_code': 'all',
      },
      headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '36'},
    );
    final data = resp is Map ? resp['data'] : null;
    final list = data is Map
        ? data['album_list']
        : data is List
        ? data
        : null;
    if (list is! List) return const [];
    return list.whereType<Map<String, dynamic>>().map((a) {
      final id = a['album_id']?.toString() ?? '';
      return CoverItem(
        id: id,
        title: a['album_name']?.toString() ?? '',
        cover: kgFillCover(a['sizable_cover']?.toString(), 300),
        subtitle: a['publish_date']?.toString() ?? '',
        trackCount: a['song_count'] is num ? a['song_count']!.toInt() : 0,
      );
    }).toList();
  }

  /// 分类搜索（对齐 KuGouMusicApi search.js：song/album/author/special）。
  ///
  /// 返回泛型：type == 'song' 时 items 为 [Track]，其余为 [CoverItem]。
  Future<SearchResult<Object>> searchByType(
    String keyword, {
    String type = 'song',
    int page = 1,
    int pagesize = 30,
  }) async {
    final resp = await _gateway(
      '/${type == 'song' ? 'v3' : 'v1'}/search/$type',
      method: 'GET',
      query: {
        'albumhide': 0,
        'iscorrection': 1,
        'keyword': keyword,
        'nocollect': 0,
        'page': page,
        'pagesize': pagesize,
        'platform': 'AndroidFilter',
      },
      headers: {'x-router': 'complexsearch.kugou.com'},
      baseUrl: 'https://complexsearch.kugou.com',
    );
    final data = resp is Map ? resp['data'] : null;
    final lists = data is Map ? data['lists'] : null;
    final total = data is Map ? data['total'] : null;
    final totalNum = total is num ? total.toInt() : int.tryParse('$total') ?? 0;
    if (lists is! List) {
      return SearchResult(items: const [], total: totalNum, hasMore: false);
    }
    final items = <Object>[];
    if (type == 'song') {
      for (final s in lists.whereType<Map<String, dynamic>>()) {
        // gateway /v3/search/song 返回 PascalCase + Duration(ms) + Image 封面
        final hash = s['FileHash']?.toString() ?? s['hash']?.toString() ?? '';
        if (hash.isEmpty) continue;
        final name = kgDecodeName(
          (s['SongName'] ?? s['OriSongName'] ?? '').toString(),
        );
        final author = s['SingerName']?.toString() ?? '';
        final hashes = <String, String>{'128k': hash};
        void add(String key, Object? h) {
          final hs = h?.toString() ?? '';
          if (hs.isNotEmpty) hashes[key] = hs;
        }

        add('320k', s['HQFileHash']);
        add('flac', s['SQFileHash']);
        add('flac24bit', s['ResFileHash']);
        final cover = s['Image']?.toString();
        items.add(
          Track(
            id: s['AudioId']?.toString() ?? hash,
            title: name,
            artists: author.isEmpty ? const [] : kugouArtists(author),
            album: null,
            duration: kgDurationMs(s['Duration']),
            cover: kgFillCover(cover, 300),
            source: 'kugou',
            kugou: KugouTrackInfo(hash: hash, hashes: hashes, sizes: const {}),
          ),
        );
      }
    } else {
      for (final c in lists.whereType<Map<String, dynamic>>()) {
        final id =
            (c['SpecialID'] ??
                    c['AlbumID'] ??
                    c['AuthorID'] ??
                    c['albumid'] ??
                    c['authorid'])
                ?.toString() ??
            '';
        if (id.isEmpty) continue;
        final title =
            (c['specialname'] ??
                    c['albumname'] ??
                    c['authorname'] ??
                    c['AuthorName'] ??
                    c['AlbumName'])
                ?.toString() ??
            '';
        final coverTpl = (c['img'] ?? c['imgurl'] ?? c['Avatar'] ?? c['ImgUrl'])
            ?.toString();
        items.add(
          CoverItem(
            id: id,
            title: title,
            cover: kgFillCover(coverTpl, 300),
            subtitle: type == 'special'
                ? (c['nickname']?.toString() ?? '')
                : type == 'album'
                ? (c['singername']?.toString() ??
                      c['SingerName']?.toString() ??
                      '')
                : '',
          ),
        );
      }
    }
    return SearchResult(
      items: items,
      total: totalNum > 0 ? totalNum : items.length,
      hasMore: items.length >= pagesize,
    );
  }
}
