// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水单曲：SEO `seo_track`（元数据 + KRC 逐字歌词 + `url_player_info`）
/// 与 `PlayInfo` 取流（官方 VOD）。
///
/// - `seo_track`：`GET beta-luna.douyin.com/luna/h5/seo_track?track_id=&device_platform=web`
///   （免登录、免签名，实测）；返回 `seo_track.track` / `lyric.content`(KRC) /
///   `track_player.url_player_info`。
/// - `play_info`：`GET <url_player_info>`（`vod-luna.douyin.com` 官方 VOD）→
///   `Result.Data.PlayInfoList[]`，取最高码率 `MainPlayUrl` + `PlayAuth`。
library;

import 'dart:convert';

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';
import 'mappers.dart';

String _statusMessage(Map<String, dynamic> resp) {
  final info = resp['status_info'];
  if (info is Map) {
    final msg = info['status_msg'];
    if (msg != null && '$msg'.isNotEmpty) return '$msg';
  }
  return 'soda api error';
}

String _lyricOf(Map seo, Map resp) {
  final inSeo = seo['lyric'];
  if (inSeo is Map && '${inSeo['content'] ?? ''}'.isNotEmpty) {
    return '${inSeo['content']}';
  }
  final top = resp['lyric'];
  return (top is Map) ? '${top['content'] ?? ''}' : '';
}

/// 解析 `track_player.video_model`（JSON 串）→ 多档直链。
List<Map<String, dynamic>> _parseVideoModel(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  try {
    final vm = jsonDecode(raw);
    if (vm is! Map) return const [];
    final list = vm['video_list'];
    if (list is! List) return const [];
    return list.whereType<Map>().map((v) {
      final m = v['video_meta'] is Map ? v['video_meta'] as Map : const {};
      return <String, dynamic>{
        'quality': '${m['quality'] ?? ''}',
        'bitrate': sodaInt(m['bitrate']),
        'codec': '${m['codec_type'] ?? ''}',
        'sampleRate': sodaInt(m['audio_sample_rate']),
        'size': sodaInt(m['size']),
        'url': '${v['main_url'] ?? ''}',
        'backupUrl': '${v['backup_url'] ?? ''}',
      };
    }).toList();
  } catch (_) {
    return const [];
  }
}

/// 单曲：元数据 + 逐字歌词 + 多档直链（`video_model`）。
SodaModule sodaSeoTrack = (params) async {
  final id = '${params['id'] ?? ''}';
  if (id.isEmpty) return {'code': 400, 'message': 'id required'};

  final uri = Uri.parse('$sodaApiBase/luna/h5/seo_track').replace(
    queryParameters: <String, String>{
      ...sodaPcAppParams(),
      'track_id': id,
    },
  );
  final resp = await sodaGetJson(uri, headers: const {'User-Agent': sodaPcAppUa});

  final status = sodaInt(resp['status_code']);
  if (status != 0) return {'code': status, 'message': _statusMessage(resp)};

  final seo = resp['seo_track'] is Map
      ? resp['seo_track'] as Map
      : const <dynamic, dynamic>{};
  final track = seo['track'] is Map
      ? seo['track'] as Map
      : const <dynamic, dynamic>{};
  final player = resp['track_player'] is Map
      ? resp['track_player'] as Map
      : const <dynamic, dynamic>{};

  if ('${track['id'] ?? ''}'.isEmpty) {
    return {'code': 404, 'message': 'seo_track missing track id'};
  }
  final vmType = sodaInt(player['video_model_type']);
  return {
    'code': 200,
    'track': sodaMapTrack(track),
    'lyric': _lyricOf(seo, resp),
    'playerInfoUrl': '${player['url_player_info'] ?? ''}',
    'qualities': _parseVideoModel(player['video_model']),
    'videoModelType': vmType,
    // 2 = 试听片段（付费曲未购/未登录）
    'isFull': vmType != 2,
  };
};

/// 从 `url_player_info` 拉取并挑选最高码率直链。
SodaModule sodaPlayInfo = (params) async {
  final url = '${params['url'] ?? ''}';
  if (url.isEmpty) return {'code': 400, 'message': 'url required'};

  final resp = await sodaGetJson(
    Uri.parse(url),
    headers: const {'User-Agent': sodaPcUa},
  );
  final result = resp['Result'];
  final data = (result is Map && result['Data'] is Map)
      ? result['Data'] as Map
      : const <dynamic, dynamic>{};
  final list = data['PlayInfoList'];
  if (list is! List || list.isEmpty) {
    final meta = resp['ResponseMetadata'];
    final err = (meta is Map && meta['Error'] is Map)
        ? (meta['Error'] as Map)['Message']
        : null;
    return {'code': 404, 'message': err ?? 'no audio stream'};
  }

  final infos = list.whereType<Map>().toList()
    ..sort((a, b) => sodaInt(b['Bitrate']).compareTo(sodaInt(a['Bitrate'])));
  final best = infos.first;
  final main = '${best['MainPlayUrl'] ?? ''}';
  final backup = '${best['BackupPlayUrl'] ?? ''}';
  return {
    'code': 200,
    'url': main.isNotEmpty ? main : backup,
    'playAuth': '${best['PlayAuth'] ?? ''}',
    'quality': '${best['Quality'] ?? ''}',
    'format': '${best['Format'] ?? ''}',
    'bitrate': sodaInt(best['Bitrate']),
    'size': sodaInt(best['Size']),
    'duration': sodaInt(best['Duration']),
  };
};
