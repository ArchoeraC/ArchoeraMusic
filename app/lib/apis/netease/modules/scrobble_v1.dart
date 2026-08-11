/// 听歌打卡 - NCBL 加密版（对齐 scrobble_v1.ts）
library;

import '../core/ncbl.dart';
import '../core/request.dart';
import '../core/types.dart';

NeteaseModule nmScrobbleV1 = (query, request) async {
  final songId = int.tryParse('${query['id']}') ?? 0;
  if (songId <= 0) {
    return NeteaseResponse(
      status: 400,
      body: {'code': 400, 'msg': '缺少有效的 id (歌曲ID)'},
      cookie: const [],
    );
  }
  final playTime = int.tryParse('${query['time']}') ?? 0;
  if (playTime <= 0) {
    return NeteaseResponse(
      status: 400,
      body: {'code': 400, 'msg': '缺少有效的 time (播放时长)'},
      cookie: const [],
    );
  }

  final totalTime = int.tryParse('${query['total'] ?? playTime}') ?? playTime;
  final sourceId = '${query['sourceid'] ?? query['sourceId'] ?? ''}';
  final sourceName = query['source'] is String ? query['source'] as String : 'list';
  final rawCookie = query['cookie'] ?? '';
  final cookieObj = nmNcblParseCookie(rawCookie);
  cookieObj['os'] = 'pc';
  final ctx = nmNcblExtractContext(cookieObj);
  if ((ctx.auth['token'] ?? '').isEmpty) {
    return NeteaseResponse(
      status: 401,
      body: {'code': 401, 'msg': '缺少 MUSIC_U 鉴权令牌'},
      cookie: const [],
    );
  }

  final song = <String, dynamic>{
    'id': songId,
    'name': query['name'] is String ? query['name'] as String : '',
    'artist': query['artist'] is String ? query['artist'] as String : '',
    'bitrate': int.tryParse('${query['bitrate'] ?? 320}') ?? 320,
    'level': query['level'] is String ? query['level'] as String : 'exhigh',
    'vip': query['vip'] == 'true' || query['vip'] == true,
    'time': totalTime,
  };
  final source = <String, dynamic>{
    'id': sourceId.isNotEmpty ? sourceId : '$songId',
    'type': 'track',
    'name': sourceName,
  };
  final metaJson = nmNcblBuildMetaJson(ctx);
  final cookieStr = nmNcblBuildCookieStr(ctx);
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final played = playTime < totalTime ? playTime : totalTime;
  final plvBody = nmBuildRecords([
    (time: ts, action: '_plv', data: nmBuildPlv(ctx, song, source)),
  ]);
  final pldBody = nmBuildRecords([
    (time: ts, action: '_pld', data: nmBuildPld(ctx, song, source, played)),
  ]);

  try {
    final plv = await nmNcblDoUpload(ctx, metaJson, plvBody, cookieStr);
    if (!plv.success) {
      final rate = plv.respBody['data']?['rate'];
      return NeteaseResponse(
        status: 502,
        body: {
          'code': 502,
          'msg': 'PLV 上报失败${rate != null ? ' (rate=$rate)' : ''}',
          'details': plv.respBody,
        },
        cookie: const [],
      );
    }

    final pld = await nmNcblDoUpload(ctx, metaJson, pldBody, cookieStr);
    if (!pld.success) {
      return NeteaseResponse(
        status: 502,
        body: {
          'code': 502,
          'msg': 'PLV 成功但 PLD 失败',
          'details': {'plv': plv.respBody, 'pld': pld.respBody},
        },
        cookie: const [],
      );
    }

    return NeteaseResponse(
      status: 200,
      body: {
        'code': 200,
        'data': 'scrobble_v1 上报成功',
        'details': {
          'plv': {'fileName': plv.fileName, 'payloadSize': plv.payload.length},
          'pld': {'fileName': pld.fileName, 'payloadSize': pld.payload.length},
        },
      },
      cookie: const [],
    );
  } catch (err) {
    return NeteaseResponse(
      status: 502,
      body: {'code': 502, 'msg': '请求异常: $err'},
      cookie: const [],
    );
  }
};

/// 对齐 ncbl.ts buildPlv——构造 PLV（开始播放）上报记录数据
Map<String, dynamic> nmBuildPlv(
  NcblContext ctx,
  Map<String, dynamic> song,
  Map<String, dynamic> source,
) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'mode': 'circulation',
    'download': 0,
    'alg': '',
    'status': 'front',
    'id': '${song['id']}',
    'bitrate': song['bitrate'],
    'type': 'song',
    'is_listentogether': 0,
    'source': source['name'],
    'is_heart': 0,
    'resource_ratio': '',
    'resource_time': song['time'],
    'musiceffect_id': '',
    'app_mode': 2,
    'bitrate_level': song['level'],
    '_addrefer':
        '[F:63][$now#933#${ctx.app['version']}#${ctx.app['versionCode']}#c9156c3][e][2][23][cell_pc_songlist_song:2|page_pc_songlist_songflow|page_mine_like_music][${song['id']}:song:x:x|:::|${source['id']}:list::]',
    '_multirefers': [
      '[F:26][s][18][_ai]',
      '[F:26][s][12][_ai]',
      '[F:63][$now#933#${ctx.app['version']}#${ctx.app['versionCode']}#c9156c3][e][2][8][cell_pc_main_tab_entrance:6|page_pc_main_tab][我喜欢的音乐:spm::|:::]',
      '[F:26][s][5][_ai]',
      '[F:26][s][0][_ai]',
    ],
    'vipType': ctx.auth['vipType'],
    'fee': 1,
    'file': 4,
    'rightSource': 0,
    'sourceId': source['id'],
    'sourcetype': source['type'],
    'libra_abt': '',
    'channel': ctx.app['channel'],
    'curStartChannel': '',
  };
}

/// 对齐 ncbl.ts buildPld——构造 PLD（播放完成）上报记录数据
Map<String, dynamic> nmBuildPld(
  NcblContext ctx,
  Map<String, dynamic> song,
  Map<String, dynamic> source,
  int played,
) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'mode': 'circulation',
    'download': 0,
    'alg': '',
    'status': 'front',
    'id': '${song['id']}',
    'time': played,
    'type': 'song',
    'is_listentogether': 0,
    'source': source['name'],
    'is_heart': 0,
    'realtime': played,
    'resource_ratio': '',
    'resource_time': song['time'],
    'musiceffect_id': '1001',
    'app_mode': 1,
    'lyriceffect': 'default',
    'displayMode': 'classic',
    'bitrate': song['bitrate'],
    'bitrate_level': song['level'],
    '_addrefer':
        '[F:63][$now#616#${ctx.app['version']}#${ctx.app['versionCode']}#c9156c3][e][2][92][btn_pc_cover_play|cell_pc_songlist_song:6|page_pc_songlist_songflow|page_mine_like_music][:::|${song['id']}:song:x:x|:::|${source['id']}:list::]',
    '_multirefers': [
      '[F:26][s][87][_ai]',
      '[F:26][s][81][_ai]',
      '[F:26][s][75][_ai]',
      '[F:26][s][69][_ai]',
      '[F:26][s][63][_ai]',
    ],
    'vipType': ctx.auth['vipType'],
    'fee': 8,
    'file': 4,
    'rightSource': 0,
    'sourceId': source['id'],
    'sourcetype': source['type'],
    'end': 'interrupt',
    'libra_abt': '',
    'channel': ctx.app['channel'],
    'curStartChannel': '',
  };
}
