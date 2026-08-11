/// 听歌打卡（对齐 scrobble.ts，走 clientlog 域名上报 startplay + play）
library;

import 'dart:convert';

import '../core/config.dart';
import '../core/option.dart';
import '../core/request.dart';
import '../core/types.dart';

NeteaseModule nmScrobble = (query, request) async {
  var cookie = query['cookie'] ?? '';
  if (cookie is Map) {
    cookie = {'os': 'osx', ...cookie};
  } else if (cookie is String) {
    cookie = cookie.contains('os=')
        ? cookie.replaceAll(RegExp(r'os=[^;]+'), 'os=osx')
        : '$cookie; os=osx';
  } else {
    cookie = 'os=osx';
  }
  query['cookie'] = cookie;

  final startplayData = <String, dynamic>{
    'logs': jsonEncode([
      {
        'action': 'startplay',
        'json': {
          'id': query['id'],
          'type': 'song',
          'mainsite': '1',
          'mainsiteWeb': '1',
          'content': 'id=${query['sourceid']}',
        },
      },
    ]),
  };

  final playData = <String, dynamic>{
    'logs': jsonEncode([
      {
        'action': 'play',
        'json': {
          'download': 0,
          'end': 'playend',
          'id': query['id'],
          'sourceId': query['sourceid'],
          'time': query['time'],
          'type': 'song',
          'wifi': 0,
          'source': 'list',
          'mainsite': '1',
          'mainsiteWeb': '1',
          'content': 'id=${query['sourceid']}',
        },
      },
    ]),
  };

  final option = nmCreateOption(query, 'eapi');
  option.domain = nmClientLogDomain;

  final startplay = await request('/api/feedback/weblog', startplayData, option);
  final play = await request('/api/feedback/weblog', playData, option);

  return NeteaseResponse(
    status: 200,
    body: {
      'code': 200,
      'data': 'success',
      'details': {'startplay': startplay.body, 'play': play.body},
    },
    cookie: const [],
  );
};
