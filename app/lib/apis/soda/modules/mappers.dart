// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水响应 → 主项目归一 map 的共享映射（对齐 QQ `_mapSong/_mapAlbum/…`）。
library;

import '../core/config.dart';

int sodaInt(Object? v) =>
    v is num ? v.toInt() : (v == null ? 0 : int.tryParse('$v') ?? 0);

/// `url_cover` → 官方图片直链（`p3-luna.douyinpic.com`）。
String sodaImageUrl(Object? img, {String suffix = '~c5_375x375.jpg'}) {
  if (img is! Map) return '';
  final uri = (img['uri'] ?? '').toString().trim();
  final prefix = (img['template_prefix'] ?? '').toString().trim();
  if (uri.isNotEmpty && prefix.isNotEmpty) {
    return '$sodaImageBase$uri~$prefix-resize:960:960.png';
  }
  final urls = img['urls'];
  var cover = (urls is List && urls.isNotEmpty) ? '${urls.first}' : '';
  if (uri.isNotEmpty && !cover.contains(uri)) cover += uri;
  if (cover.isEmpty) return '';
  if (suffix.isNotEmpty && !cover.contains('~')) cover += suffix;
  return cover;
}

/// 歌手名列表（去空）。
List<String> sodaArtistNames(Object? artists) {
  if (artists is! List) return const [];
  return artists
      .whereType<Map>()
      .map((a) => (a['name'] ?? '').toString().trim())
      .where((n) => n.isNotEmpty)
      .toList();
}

/// 时长归一到毫秒（上游 >1000 视为毫秒，否则视为秒）。
int sodaDurationMs(Object? v) {
  final n = sodaInt(v);
  if (n <= 0) return 0;
  return n > 1000 ? n : n * 1000;
}

/// 是否会员曲（`label_info`：VIP 独占播放/下载或独占音质）。
bool sodaIsVip(Object? label) {
  if (label is! Map) return false;
  if (label['only_vip_playable'] == true || label['only_vip_download'] == true) {
    return true;
  }
  for (final key in const [
    'quality_only_vip_can_play',
    'quality_only_vip_can_download',
  ]) {
    final v = label[key];
    if (v is List && v.isNotEmpty) return true;
  }
  final qualityMap = label['quality_map'];
  if (qualityMap is Map) {
    for (final policy in qualityMap.values) {
      if (policy is! Map) continue;
      for (final slot in const ['play_detail', 'download_detail']) {
        final detail = policy[slot];
        if (detail is Map && detail['need_vip'] == true) return true;
      }
    }
  }
  return false;
}

Map<String, dynamic> sodaMapTrack(Map track) {
  final album = track['album'] is Map ? track['album'] as Map : const {};
  final names = sodaArtistNames(track['artists']);
  final bitRates =
      (track['bit_rates'] as List?)?.whereType<Map>().toList() ?? const [];
  var bitRate = 0;
  var lossless = false;
  for (final b in bitRates) {
    final q = '${b['quality'] ?? ''}'.toLowerCase();
    if (q.contains('lossless') ||
        q.contains('flac') ||
        q.contains('hires') ||
        q.contains('spatial')) {
      lossless = true;
    }
    final br = sodaInt(b['br']);
    if (br > bitRate) bitRate = br;
  }
  return <String, dynamic>{
    'id': '${track['id'] ?? ''}',
    'name': track['name'] ?? '',
    'artist': names.join(' / '),
    'artists': names,
    'album': album['name'] ?? '',
    'albumId': '${album['id'] ?? ''}',
    'duration': sodaDurationMs(track['duration']),
    'cover': sodaImageUrl(album['url_cover']),
    'vip': sodaIsVip(track['label_info']),
    'bitRate': bitRate,
    'lossless': lossless,
  };
}

Map<String, dynamic> sodaMapAlbum(Map album) => <String, dynamic>{
  'id': '${album['id'] ?? ''}',
  'name': album['name'] ?? '',
  'artist': sodaArtistNames(album['artists']).join(' / '),
  'cover': sodaImageUrl(album['url_cover'], suffix: '~c5_300x300.jpg'),
  'trackCount': sodaInt(album['count_tracks']),
  'company': album['company'] ?? '',
};

Map<String, dynamic> sodaMapPlaylist(Map pl) {
  final owner = pl['owner'] is Map ? pl['owner'] as Map : const {};
  final stats = pl['stats'] is Map ? pl['stats'] as Map : const {};
  return <String, dynamic>{
    'id': '${pl['id'] ?? ''}',
    'name': pl['title'] ?? pl['public_title'] ?? '',
    'cover': sodaImageUrl(pl['url_cover'], suffix: '~c5_300x300.jpg'),
    'creator': owner['public_name'] ?? owner['nickname'] ?? '',
    'desc': pl['desc'] ?? '',
    'trackCount': sodaInt(pl['count_tracks']),
    'playCount': sodaInt(pl['play_count'] ?? stats['count_played']),
  };
}
