/// QM「我喜欢」（红心收藏，dirid=201）模块——**实验性**（社区逆向 RPC）。
///
/// QQ 音乐把「♥ / 我喜欢」实现为一个**特殊目录歌单 dirid=201**（非普通
/// disstid 歌单）。本模块按社区 OSS 逆向实现三个操作：
///
/// - 读列表：`music.srfDissInfo.DissInfo / CgiGetDiss`（`disstid:0` +
///   `dirid:201` + `enc_host_uin`），响应 `songlist / total_song_num /
///   hasmore`；
/// - 红心：`music.musicasset.PlaylistDetailWrite / AddSonglist`
///   （`dirId:201, v_songInfo:[{songType:0, songId:<songid>}]`）；
/// - 取消红心：`music.musicasset.PlaylistDetailWrite / DelSonglist`（同上）。
///
/// ## 调研来源（2026-09-05 检索，均为近期活跃仓库）
/// 1. `ylw1997/touchFish` `src/api/qqmusic.ts`（Mac 菜单栏 QQ 音乐播放器；
///   该文件最近提交 2026-08-24）：`getMyFavorite` dirid=201 读列表、
///   `addSongsToPlaylist/removeSongsFromPlaylist` dirId=201 增删；
/// 2. `L-1124/QQMusicApi`（Python 封装库；`qqmusic_api/modules/user.py`
///   `get_fav_song` dirid=201 读列表，最近提交 2026-08-05），响应模型
///   `qqmusic_api/models/songlist.py` 证实 `songlist/total_song_num/hasmore`。
///
/// ## 风险与降级（诚实声明）
/// - 该 RPC 族为**社区逆向、非官方文档**，接口/参数可能随版本失效；
/// - 调用方（QqMusicApi/红心控制器）已做「实验开关 + 失败回滚 + 本地红心
///   兜底」：在线收藏失败只影响本次在线同步，不影响本机红心；
/// - 未付费/VIP 语义不在此模块处理（仅增删红心收藏，不绕过任何付费）。
library;

import 'dart:convert';
import 'dart:io';

import '../core/config.dart';
import '../core/credential.dart';
import '../core/request.dart';
import '../core/types.dart';

/// 我喜欢的歌曲特殊目录 id（全账号固定）。
const int _kLikeDirId = 201;

int _numOf(dynamic v) =>
    v is num ? v.toInt() : (v != null ? int.tryParse('$v') ?? 0 : 0);

int _firstOf(dynamic list) =>
    list is List && list.isNotEmpty ? _numOf(list.first) : 0;

/// 把 dirid=201 列表条目归一为与 search/album/artist 相同的歌曲对象结构
/// （id/mid/name/artists/artist/album/albumMid/duration/mediaMid/pay/size*），
/// 便于上层统一走 [Track.fromQqMusicSong]。
Map<String, dynamic> _mapSong(Map<String, dynamic> song) {
  final singer = song['singer'] as List?;
  final album = song['album'];
  final file = song['file'];
  final albumMap = album is Map ? Map<String, dynamic>.from(album) : const {};
  final fileMap = file is Map ? Map<String, dynamic>.from(file) : const {};
  final pay = song['pay'];
  final payMap = pay is Map ? Map<String, dynamic>.from(pay) : const {};
  final priceAlbum = (payMap['price_album'] as num?)?.toInt() ?? 0;
  final payMonth = (payMap['pay_month'] as num?)?.toInt() ?? 0;
  return <String, dynamic>{
    'id': '${song['id'] ?? ''}',
    'mid': song['mid'] ?? song['songmid'] ?? '',
    'name': song['name'] ?? song['title'] ?? '',
    'artist': qmFormatSingerName(singer),
    'artists': singer ?? const [],
    'album': albumMap['name'] ?? albumMap['title'] ?? '',
    'albumMid': albumMap['mid'] ?? song['albummid'] ?? song['albumMid'] ?? '',
    'duration': ((song['interval'] as num?) ?? 0) * 1000,
    'mediaMid': fileMap['media_mid'] ?? song['strMediaMid'] ?? '',
    'pay': {
      'payalbum': payMonth == 0 && priceAlbum > 0 ? 1 : 0,
      'payplay': (payMap['pay_play'] as num?)?.toInt() ?? 0,
    },
    'size128': _numOf(fileMap['size_128mp3']),
    'size320': _numOf(fileMap['size_320mp3']),
    'sizeApe': _numOf(fileMap['size_ape']),
    'sizeFlac': _numOf(fileMap['size_flac']),
    'sizeOgg': _numOf(fileMap['size_192ogg']),
    'sizeHiRes': _firstOf(fileMap['size_new']),
  };
}

/// 解析当前登录账号的 enc_host_uin（euin）。
///
/// 优先使用持久化 cookie（扫码登录凭据里的 encryptUin 已映射为 'euin'）；
/// 缺失时兜底 profile homepage 接口（对齐 touchFish `getEuin`）；仍取不到
/// 返回 ''，由上层决定是否继续（部分服务端版本不传也可读）。
Future<String> _resolveEncHostUin() async {
  final cookies = qmGetQQMusicCookies();
  for (final k in const ['euin', 'encrypt_uin', 'encryptUin', 'enc_host_uin']) {
    final v = (cookies[k] ?? '').trim();
    if (v.isNotEmpty) return v;
  }
  final uin = qmGetQQMusicUin();
  if (uin.isEmpty || uin == '0') return '';
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final url =
          'https://c6.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg'
          '?ct=20&cv=4747474&cid=205360838&userid=$uin&format=json';
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', qmWebUa);
      req.headers.set('Referer', 'https://y.qq.com/');
      final cookieStr = qmSessionToCookieHeader(cookies);
      if (cookieStr != null) req.headers.set('Cookie', cookieStr);
      final res = await req.close().timeout(const Duration(seconds: 8));
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final data =
          jsonDecode(utf8.decode(bytes, allowMalformed: true)) as Map;
      final creator = (data['data'] as Map?)?['creator'];
      if (creator is Map) {
        final euin = creator['encrypt_uin']?.toString() ?? '';
        if (euin.isNotEmpty) return euin;
      }
    } finally {
      client.close();
    }
  } catch (_) {
    // 网络/风控失败 → 空（上层降级不传 enc_host_uin）
  }
  return '';
}

/// 读「我喜欢」列表（dirid=201，分页）。
///
/// 入参：`page`（1 起）/ `num`（每页条数，默认 50）。
/// 返回 `{code:200, songs:[...归一歌曲], total, hasMore}`。
/// 未登录（uin=0 / 无 key）返回 `{code:301, message}`。
Future<Map<String, dynamic>> _listFavorites(QmParams params) async {
  final cookies = qmGetQQMusicCookies();
  final uin = qmGetQQMusicUin();
  final hasKey = (cookies['qm_keyst']?.isNotEmpty == true ||
      cookies['qqmusic_key']?.isNotEmpty == true ||
      cookies['pskey']?.isNotEmpty == true ||
      cookies['p_skey']?.isNotEmpty == true ||
      cookies['skey']?.isNotEmpty == true);
  if (uin.isEmpty || uin == '0' || !hasKey) {
    return <String, dynamic>{
      'code': 301,
      'loggedIn': false,
      'message': '未登录 QM 账号',
      'songs': const [],
      'total': 0,
      'hasMore': false,
    };
  }
  final page = ((params['page'] as num?)?.toInt() ?? 1).clamp(1, 1 << 30);
  final perPage = ((params['num'] as num?)?.toInt() ?? 50).clamp(1, 100);
  final euin = await _resolveEncHostUin();
  final data = await qmRequest<Map<String, dynamic>>(
    'music.srfDissInfo.DissInfo',
    'CgiGetDiss',
    <String, dynamic>{
      'disstid': 0,
      'dirid': _kLikeDirId,
      'tag': true,
      'song_begin': (page - 1) * perPage,
      'song_num': perPage,
      'userinfo': true,
      'orderlist': true,
      if (euin.isNotEmpty) 'enc_host_uin': euin,
    },
    session: false,
  );
  final songlist = (data['songlist'] as List?) ?? const [];
  final songs = songlist
      .whereType<Map>()
      .map((m) => _mapSong(Map<String, dynamic>.from(m)))
      .where((s) => (s['mid'] as String).isNotEmpty)
      .toList();
  final totalNum = data['total_song_num'];
  final hasMore = (data['hasmore'] is num &&
          (data['hasmore'] as num).toInt() == 1) ||
      (totalNum is num && (page * perPage) < totalNum.toInt());
  return <String, dynamic>{
    'code': 200,
    'loggedIn': true,
    'songs': songs,
    'total': totalNum is num ? totalNum.toInt() : songs.length,
    'hasMore': hasMore,
  };
}

/// 写操作（红心 / 取消红心，dirId=201）。
Future<Map<String, dynamic>> _writeFavorite(
  QmParams params, {
  required bool add,
}) async {
  final cookies = qmGetQQMusicCookies();
  final uin = qmGetQQMusicUin();
  final hasKey = (cookies['qm_keyst']?.isNotEmpty == true ||
      cookies['qqmusic_key']?.isNotEmpty == true ||
      cookies['pskey']?.isNotEmpty == true ||
      cookies['p_skey']?.isNotEmpty == true ||
      cookies['skey']?.isNotEmpty == true);
  if (uin.isEmpty || uin == '0' || !hasKey) {
    return <String, dynamic>{
      'code': 301,
      'loggedIn': false,
      'ok': false,
      'message': '未登录 QM 账号',
    };
  }
  final songId = int.tryParse('${params['songId'] ?? ''}') ?? 0;
  if (songId <= 0) {
    return <String, dynamic>{
      'code': 400,
      'ok': false,
      'message': '缺少有效 songId（QQ 红心写接口按 songid 而非 songmid 操作）',
    };
  }
  final data = await qmRequest<Map<String, dynamic>>(
    'music.musicasset.PlaylistDetailWrite',
    add ? 'AddSonglist' : 'DelSonglist',
    <String, dynamic>{
      'dirId': _kLikeDirId,
      'v_songInfo': <Map<String, dynamic>>[
        <String, dynamic>{'songType': 0, 'songId': songId},
      ],
    },
    session: false,
  );
  // 成功语义对齐社区实现：result.updateTime 非空 = 服务端已接受本次变更。
  final result = data['result'];
  final ok = result is Map && result['updateTime'] != null;
  return <String, dynamic>{
    'code': 200,
    'loggedIn': true,
    'ok': ok,
    'message': ok ? '' : 'QQ 音乐收藏写接口未确认（result.updateTime 缺失）',
  };
}

/// 读「我喜欢」列表。
QmModule qmFavoriteList = (params) => _listFavorites(params);

/// 红心（加入「我喜欢」dir 201）。
QmModule qmFavoriteAdd = (params) => _writeFavorite(params, add: true);

/// 取消红心（从「我喜欢」dir 201 移除）。
QmModule qmFavoriteRemove = (params) => _writeFavorite(params, add: false);
