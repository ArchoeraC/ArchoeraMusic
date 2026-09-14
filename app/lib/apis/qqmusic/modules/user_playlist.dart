// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM 用户歌单 / 收藏（自建歌单、收藏歌单、我喜欢）——纯 GET fcgi，无需签名。
///
/// 参考 `music-lib/qq/user_playlist.go`（AGPL-3.0）：
/// - 自建歌单：`c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss`（hostuin/sin/size）；
/// - 收藏歌单：`c.y.qq.com/fav/fcgi-bin/fcg_get_profile_order_asset.fcg`（reqtype=3）；
/// - 我喜欢：同端点 `reqtype=1`（`totalsong` / `songlist`）。
///
/// 仅需登录 Cookie（uin + key），出站为官方 `c.y.qq.com`。
library;

import '../core/request.dart';
import '../core/types.dart';

int _intOf(Object? v) =>
    v is num ? v.toInt() : (v != null ? int.tryParse('$v') ?? 0 : 0);

String _str(Object? v) => v?.toString().trim() ?? '';

/// 收藏歌单 / 我喜欢端点。
const _profileOrderUrl =
    'https://c.y.qq.com/fav/fcgi-bin/fcg_get_profile_order_asset.fcg';

/// 自建歌单端点。
const _userCreatedUrl =
    'https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss';

Map<String, dynamic> _loggedOut() => {
  'code': 301,
  'loggedIn': false,
  'message': '未登录 QM 账号',
  'playlists': const [],
  'songs': const [],
  'total': 0,
};

bool _hasLogin() {
  final cookies = qmGetQQMusicCookies();
  final uin = qmGetQQMusicUin();
  final hasKey =
      cookies['qm_keyst']?.isNotEmpty == true ||
      cookies['qqmusic_key']?.isNotEmpty == true ||
      cookies['pskey']?.isNotEmpty == true ||
      cookies['p_skey']?.isNotEmpty == true ||
      cookies['skey']?.isNotEmpty == true;
  return uin.isNotEmpty && uin != '0' && hasKey;
}

Uri _profileOrderUri(String uin, String reqtype, int page, int limit) {
  final offset = (page - 1) * limit;
  return Uri.parse(_profileOrderUrl).replace(
    queryParameters: {
      'format': 'json',
      'inCharset': 'utf8',
      'outCharset': 'utf-8',
      'platform': 'yqq.json',
      'needNewCode': '0',
      'loginUin': uin,
      'hostUin': '0',
      'notice': '0',
      'g_tk': '5381',
      'ct': '20',
      'cid': '205360956',
      'userid': uin,
      'reqtype': reqtype,
      'sin': '$offset',
      'ein': '${offset + limit - 1}',
    },
  );
}

/// 自建歌单（`fcg_user_created_diss`）。
QmModule qmUserCreatedDiss = (params) async {
  if (!_hasLogin()) return _loggedOut();
  final uin = qmGetQQMusicUin();
  final page = ((params['page'] as num?)?.toInt() ?? 1).clamp(1, 1 << 30);
  final limit = ((params['limit'] as num?)?.toInt() ?? 100).clamp(1, 100);
  final uri = Uri.parse(_userCreatedUrl).replace(
    queryParameters: {
      'hostuin': uin,
      'sin': '${(page - 1) * limit}',
      'size': '$limit',
      'format': 'json',
      'inCharset': 'utf8',
      'outCharset': 'utf-8',
    },
  );
  final json = await qmGetRaw(uri);
  if (_intOf(json['code']) != 0) {
    return {'code': 500, 'message': _str(json['message']), 'playlists': const []};
  }
  final data = json['data'] is Map ? json['data'] as Map : const {};
  final out = <Map<String, dynamic>>[];
  for (final item in (data['disslist'] as List?) ?? const []) {
    if (item is! Map) continue;
    final id = _str(item['dissid']).isNotEmpty
        ? _str(item['dissid'])
        : _str(item['tid']);
    final name = _str(item['diss_name']).isNotEmpty
        ? _str(item['diss_name'])
        : _str(item['title']);
    if (id.isEmpty || name.isEmpty) continue;
    out.add({
      'id': id,
      'name': name,
      'cover': _str(item['diss_cover']).isNotEmpty
          ? _str(item['diss_cover'])
          : _str(item['cover']),
      'trackCount': _intOf(item['song_count']) != 0
          ? _intOf(item['song_count'])
          : (_intOf(item['song_num']) != 0
                ? _intOf(item['song_num'])
                : _intOf(item['song_cnt'])),
      'creator': uin,
      'description': _str(item['diss_desc']).isNotEmpty
          ? _str(item['diss_desc'])
          : _str(item['desc']),
    });
  }
  return {'code': 200, 'loggedIn': true, 'playlists': out};
};

/// 收藏歌单（`fcg_get_profile_order_asset.fcg` reqtype=3）。
QmModule qmProfileOrderPlaylists = (params) async {
  if (!_hasLogin()) return _loggedOut();
  final uin = qmGetQQMusicUin();
  final page = ((params['page'] as num?)?.toInt() ?? 1).clamp(1, 1 << 30);
  final limit = ((params['limit'] as num?)?.toInt() ?? 100).clamp(1, 100);
  final json = await qmGetRaw(_profileOrderUri(uin, '3', page, limit));
  if (_intOf(json['code']) != 0) {
    return {'code': 500, 'message': _str(json['msg']), 'playlists': const []};
  }
  final data = json['data'] is Map ? json['data'] as Map : const {};
  final out = <Map<String, dynamic>>[];
  for (final item in (data['cdlist'] as List?) ?? const []) {
    if (item is! Map) continue;
    final id = _str(item['dissid']);
    final name = _str(item['dissname']);
    if (id.isEmpty || name.isEmpty) continue;
    out.add({
      'id': id,
      'name': name,
      'cover': _str(item['logo']),
      'trackCount': _intOf(item['songnum']),
      'creator': _str(item['nickname']).isNotEmpty
          ? _str(item['nickname'])
          : _str(item['uin']),
    });
  }
  return {'code': 200, 'loggedIn': true, 'playlists': out};
};

/// 我喜欢（`fcg_get_profile_order_asset.fcg` reqtype=1）——歌曲列表。
QmModule qmProfileOrderSongs = (params) async {
  if (!_hasLogin()) return _loggedOut();
  final uin = qmGetQQMusicUin();
  final page = ((params['page'] as num?)?.toInt() ?? 1).clamp(1, 1 << 30);
  final limit = ((params['num'] as num?)?.toInt() ?? 100).clamp(1, 100);
  final json = await qmGetRaw(_profileOrderUri(uin, '1', page, limit));
  if (_intOf(json['code']) != 0) {
    return {'code': 500, 'message': _str(json['msg']), 'songs': const []};
  }
  final data = json['data'] is Map ? json['data'] as Map : const {};
  final total = _intOf(data['totalsong']);
  final songs = <Map<String, dynamic>>[];
  for (final item in (data['songlist'] as List?) ?? const []) {
    if (item is! Map) continue;
    final d = item['data'] is Map ? item['data'] as Map : const {};
    final mid = _str(d['songmid']);
    final name = _str(d['songname']);
    if (mid.isEmpty || name.isEmpty) continue;
    final albumMid = _str(d['albummid']).isNotEmpty
        ? _str(d['albummid'])
        : _str(d['albumMid']);
    final singers = <String>[];
    for (final s in (d['singer'] as List?) ?? const []) {
      if (s is Map && _str(s['name']).isNotEmpty) singers.add(_str(s['name']));
    }
    songs.add({
      'mid': mid,
      'id': _intOf(d['songid']),
      'name': name,
      'artists': singers,
      'album': _str(d['albumname']),
      'albumMid': albumMid,
      'cover': albumMid.isEmpty
          ? ''
          : 'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg',
      'coverOriginal': albumMid.isEmpty
          ? ''
          : 'https://y.gtimg.cn/music/photo_new/T002R800x800M000$albumMid.jpg',
      'duration': _intOf(d['interval']),
      'size128': _intOf(d['size128']),
      'size320': _intOf(d['size320']),
      'sizeFlac': _intOf(d['sizeflac']),
    });
  }
  return {
    'code': 200,
    'loggedIn': true,
    'songs': songs,
    'total': total != 0 ? total : songs.length,
    'hasMore': page * limit < (total != 0 ? total : songs.length),
  };
};
