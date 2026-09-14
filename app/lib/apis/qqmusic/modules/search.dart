// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM 搜索（签名桌面协议）——`musics.fcg` + `zzcSign`，覆盖四类。
///
/// 统一走 `music.search.SearchCgiService / DoSearchForQQMusicDesktop`：
/// - `comm.ct=19` 下发完整音质字段（`size_hires`/`size_new`/`size_dolby`/
///   `size_dts`/`hires_*`），供上层精确档位；
/// - `search_type`：0 单曲 / 1 歌手 / 2 专辑 / 3 歌单；
/// - 响应体按类分列（`body.{song,singer,album,songlist}.list`）。
///
/// 单页硬上限：`num_per_page>50` 服务端直接返回空（实测），歌手更严（>40 空）。
/// 签名只覆盖请求体，调用方需保证签名串与实际发送字节一致（见 core/sign.dart）。
///
/// 来源：协议事实参考 baka-plugins `plugins/qq.js`（无许可证，未复制其表达）。
library;

import 'dart:convert';
import 'dart:math';

import '../core/config.dart';
import '../core/request.dart';
import '../core/sign.dart';
import '../core/types.dart';

String _secureUrl(String? url) =>
    (url ?? '').replaceFirst(RegExp('^http:'), 'https:');

String _stripHighlight(String? text) =>
    (text ?? '').replaceAll(RegExp(r'</?em>'), '');

int _numOf(dynamic v) =>
    v is num ? v.toInt() : (v != null ? int.tryParse('$v') ?? 0 : 0);

/// 桌面 comm：`ct=19` 取全量音质；`guid`/`wid` 为公开客户端常量。
///
/// 已登录时注入 `uin/qq/authst/tmeLoginType=2`（对齐 core/request.dart 的
/// 移动 comm 组装；未登录为访客 `uin=0`/`tmeLoginType=0`）。
Map<String, dynamic> _desktopComm() {
  final cookies = qmGetQQMusicCookies();
  final uin = qmGetQQMusicUin();
  final musicKey = cookies['qm_keyst'] ?? cookies['qqmusic_key'];
  final loggedIn = uin != '0' && musicKey != null && musicKey.isNotEmpty;
  return <String, dynamic>{
    '_channelid': '0',
    '_os_version': '6.2.9200-2',
    'ct': '19',
    'cv': '2151',
    'guid': '1F70E520B2EAA7D25E11760783C53CA9',
    'patch': '118',
    'psrf_access_token_expiresAt': 0,
    'psrf_qqaccess_token': '',
    'psrf_qqopenid': '',
    'psrf_qqunionid': '',
    'tmeAppID': 'qqmusic',
    'tmeLoginType': loggedIn ? 2 : 0,
    'uin': loggedIn ? uin : '0',
    'wid': '7223299733393904640',
    if (loggedIn) ...<String, dynamic>{'qq': uin, 'authst': musicKey},
  };
}

/// 桌面 searchid：32 位随机 hex（大写）+ 5 位随机数字（对齐 `qq.js:327`）。
String _genSearchId() {
  const hex = '0123456789abcdef';
  final rnd = Random();
  final buf = StringBuffer();
  for (var i = 0; i < 32; i++) {
    buf.write(hex[rnd.nextInt(16)]);
  }
  return '${buf.toString().toUpperCase()}'
      '${rnd.nextInt(100000).toString().padLeft(5, '0')}';
}

/// 瞬时错误重试次数与退避（对齐 core/request.dart；风控不重试）。
const int _maxRetry = 2;
const int _retryBackoffMs = 300;

Future<void> _delay(int ms) => Future.delayed(Duration(milliseconds: ms));

/// 发起一次签名桌面搜索，返回 `SearchCgiService.data`（含 `body`/`meta`）。
///
/// 非零外层/内层码按 `core/request.dart` 语义归一：`2001` 归风控 [QmErrorKind.risk]，
/// 其余归 [QmErrorKind.code]；`meta.is_filter<0`（额外验证过滤为空）亦归风控。
Future<Map<String, dynamic>> _desktopSearch(
  String keywords,
  int page,
  int limit,
  int searchType,
) async {
  final body = <String, dynamic>{
    'comm': _desktopComm(),
    'music.search.SearchCgiService': <String, dynamic>{
      'module': 'music.search.SearchCgiService',
      'method': 'DoSearchForQQMusicDesktop',
      'param': <String, dynamic>{
        'grp': 1,
        'num_per_page': limit.clamp(1, 50),
        'page_num': page,
        'query': keywords,
        'remoteplace': 'txt.newclient.top',
        'search_type': searchType,
        'searchid': _genSearchId(),
      },
    },
  };
  final sign = qmZzcSign(jsonEncode(body));
  final url = '$qmDesktopApiUrl?sign=$sign';

  // 瞬时错误自动重试（带退避）；风控（2001 / is_filter<0）**不重试**，
  // 其余非零业务码退避重试后再抛（对齐 core/request.dart 语义）。
  Object? lastErr;
  for (var attempt = 0; attempt <= _maxRetry; attempt++) {
    try {
      final data = await qmPostRaw(
        body,
        url: url,
        extraHeaders: const {'User-Agent': 'QQMusic 14090508(android 12)'},
      );
      final node = data['music.search.SearchCgiService'];
      final nodeMap = node is Map ? node : const <String, dynamic>{};
      final outer = _numOf(data['code']);
      final inner = _numOf(nodeMap['code']);
      if (outer == 0 && inner == 0) {
        final nodeData = nodeMap['data'];
        final dataMap = nodeData is Map
            ? Map<String, dynamic>.from(nodeData)
            : const <String, dynamic>{};
        final metaRaw = dataMap['meta'];
        final metaMap = metaRaw is Map ? metaRaw : const <String, dynamic>{};
        final filter = metaMap['is_filter'];
        if (filter is num && filter.toInt() < 0) {
          throw QmRequestException(
            'QM搜索触发额外验证/风控过滤（meta.is_filter=$filter），已停止自动重试',
            kind: QmErrorKind.risk,
            outer: outer,
            inner: qmRiskInnerCode,
          );
        }
        return dataMap;
      }
      final risk = outer == qmRiskInnerCode || inner == qmRiskInnerCode;
      throw QmRequestException(
        risk
            ? 'QM搜索被拦截：请求过于频繁或触发风控（outer=$outer inner=$inner）'
            : 'QM搜索失败（outer=$outer inner=$inner）',
        kind: risk ? QmErrorKind.risk : QmErrorKind.code,
        outer: outer,
        inner: inner,
      );
    } on QmRequestException catch (e) {
      // risk 立即抛（不重试）；code 耗尽重试后抛。
      if (e.kind == QmErrorKind.risk || attempt >= _maxRetry) rethrow;
      lastErr = e;
    } catch (err) {
      lastErr = err;
      if (attempt >= _maxRetry) break;
    }
    await _delay(_retryBackoffMs * (attempt + 1));
  }
  throw QmRequestException(
    'QM搜索网络请求失败: $lastErr',
    kind: QmErrorKind.transient,
    retryable: false,
  );
}

/// 取分列节点（`body.<key>.list`）为可写 Map 列表。
List<Map<String, dynamic>> _listOf(Object? node) {
  if (node is! Map) return const [];
  final list = node['list'];
  if (list is! List) return const [];
  return list.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
}

Map<String, dynamic> _mapSong(Map song) {
  final singer = song['singer'] as List?;
  final album = song['album'];
  final file = song['file'];
  final albumMap = album is Map ? album : const <String, dynamic>{};
  final fileMap = file is Map ? file : const <String, dynamic>{};
  final pay = song['pay'];
  final payMap = pay is Map ? pay : const <String, dynamic>{};
  final payPlay = (payMap['pay_play'] as num?)?.toInt() ?? 0;
  final priceAlbum = (payMap['price_album'] as num?)?.toInt() ?? 0;
  final payMonth = (payMap['pay_month'] as num?)?.toInt() ?? 0;
  final albumMid = albumMap['mid'] ?? '';
  final albumPmid = albumMap['pmid'] ?? '';
  final pictureMid = albumMid.isNotEmpty ? albumMid : albumPmid;
  final sizeNew = fileMap['size_new'];
  final sizeHires = _numOf(fileMap['size_hires']);
  final sizeHiRes = sizeHires > 0
      ? sizeHires
      : (sizeNew is List && sizeNew.isNotEmpty ? _numOf(sizeNew.first) : 0);

  final artists = singer ?? const [];
  return <String, dynamic>{
    'id': '${song['id'] ?? ''}',
    'mid': song['mid'] ?? '',
    'name': song['title'] ?? '',
    'artist': qmFormatSingerName(singer),
    'artists': artists,
    'album': albumMap['name'] ?? albumMap['title'] ?? '',
    'albumMid': albumMid,
    'duration': ((song['interval'] as num?) ?? 0) * 1000,
    'mediaMid': fileMap['media_mid'] ?? '',
    'pay': {
      'payalbum': payMonth == 0 && priceAlbum > 0 ? 1 : 0,
      'payplay': payPlay,
    },
    'size128': _numOf(fileMap['size_128mp3']),
    'size320': _numOf(fileMap['size_320mp3']),
    'sizeApe': _numOf(fileMap['size_ape']),
    'sizeFlac': _numOf(fileMap['size_flac']),
    'sizeOgg': _numOf(fileMap['size_192ogg']),
    'sizeHiRes': sizeHiRes,
    'hiResSampleRate': _numOf(fileMap['hires_sample']),
    'hiResBitDepth': _numOf(fileMap['hires_bitdepth']),
    'cover': pictureMid.isEmpty
        ? ''
        : 'https://y.gtimg.cn/music/photo_new/T002R300x300M000$pictureMid.jpg',
    'coverOriginal': pictureMid.isEmpty
        ? ''
        : 'https://y.gtimg.cn/music/photo_new/T002R800x800M000$pictureMid.jpg',
  };
}

Map<String, dynamic> _mapAlbum(Map album) {
  final singerList = album['singer_list'] as List?;
  return <String, dynamic>{
    'id': '${album['albumID'] ?? album['albumMID'] ?? ''}',
    'name': album['albumName'] ?? '',
    'cover': _secureUrl(album['albumPic']?.toString()),
    'artist': album['singerName'] ?? qmFormatSingerName(singerList),
    'artistMid': album['singerMID'] ?? '',
    'trackCount': _numOf(album['song_count']),
  };
}

Map<String, dynamic> _mapArtist(Map artist) => <String, dynamic>{
  'id': artist['singerMID'] ?? '${artist['singerID'] ?? ''}',
  'name': _stripHighlight(artist['singerName']?.toString()),
  'cover': _secureUrl(artist['singerPic']?.toString()),
  'albumCount': _numOf(artist['albumNum']),
  'songCount': _numOf(artist['songNum']),
};

Map<String, dynamic> _mapPlaylist(Map playlist) {
  final creator = playlist['creator'];
  final creatorMap = creator is Map ? creator : const <String, dynamic>{};
  return <String, dynamic>{
    'id': '${playlist['dissid'] ?? ''}',
    'name': _stripHighlight(playlist['dissname']?.toString()),
    'cover': _secureUrl(playlist['imgurl']?.toString()),
    'creator': creatorMap['name'] ?? '',
    'trackCount': _numOf(playlist['song_count']),
    'playCount': _numOf(playlist['listennum']),
  };
}

/// 类型码（桌面协议）：0 单曲 / 1 歌手 / 2 专辑 / 3 歌单。
QmModule qmSearch = (params) async {
  final keywords = params['keywords'] as String?;
  final page = (params['page'] as num?)?.toInt() ?? 1;
  final limit = (params['limit'] as num?)?.toInt() ?? 30;
  final type = (params['type'] as num?)?.toInt() ?? 0;

  if (keywords == null || keywords.isEmpty) {
    return {'code': 400, 'total': 0, 'message': 'keywords required'};
  }

  final data = await _desktopSearch(keywords, page, limit, type);
  final meta = data['meta'];
  final metaMap = meta is Map ? meta : const <String, dynamic>{};
  final body = data['body'];
  final bodyMap = body is Map ? body : const <String, dynamic>{};
  final total = _numOf(metaMap['sum'] ?? metaMap['estimate_sum']);

  switch (type) {
    case 0:
      return {
        'code': 200,
        'total': total,
        'songs': _listOf(bodyMap['song']).map(_mapSong).toList(),
      };
    case 1:
      return {
        'code': 200,
        'total': total,
        'artists': _listOf(bodyMap['singer']).map(_mapArtist).toList(),
      };
    case 2:
      return {
        'code': 200,
        'total': total,
        'albums': _listOf(bodyMap['album']).map(_mapAlbum).toList(),
      };
    case 3:
      return {
        'code': 200,
        'total': total,
        'playlists': _listOf(bodyMap['songlist']).map(_mapPlaylist).toList(),
      };
    default:
      return {
        'code': 400,
        'total': 0,
        'message': 'unsupported search type: $type',
      };
  }
};
