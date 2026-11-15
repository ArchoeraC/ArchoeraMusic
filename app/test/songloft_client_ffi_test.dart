// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// Songloft 客户端 FFI 端到端：真实 c-shared 库 + 本机假 Songloft 服务端。
// 库未构建（或旧库缺符号）时跳过，不阻塞普通 `flutter test`。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/services/streaming/songloft/songloft_bindings.dart';
import 'package:archoera_music/services/streaming/songloft/songloft_client.dart';
import 'package:archoera_music/services/streaming/songloft/songloft_session.dart';
import 'package:archoera_music/services/streaming/streaming_types.dart';

bool _songloftFfiReady() {
  try {
    final b = SongloftBindings.instance;
    b.open;
    b.close;
    b.call;
    b.takeEvent;
    b.free;
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  final skipReason = _songloftFfiReady()
      ? null
      : 'libarchoera_subsonic 未构建或缺少 archoera_songloft_* 符号';

  group('Songloft FFI', () {
    late HttpServer server;
    late String dataDir;
    late StreamingServerConfig cfg;

    setUp(() async {
      dataDir = (await Directory.systemTemp.createTemp('songloft-test-')).path;
      SongloftSession.persistTokens = false;
      songloftCoverCacheDirOverride = '$dataDir/covers';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_handle);
      cfg = StreamingServerConfig(
        id: 'sl-test',
        name: 'Songloft',
        type: StreamingServerType.songloft,
        host: '127.0.0.1',
        port: server.port,
        username: 'alice',
        password: 'secret',
      );
    });

    tearDown(() async {
      SongloftSession.closeAll();
      await server.close(force: true);
      SongloftSession.persistTokens = true;
      songloftCoverCacheDirOverride = null;
      try {
        await Directory(dataDir).delete(recursive: true);
      } catch (_) {}
    });

    test('登录 / 目录 / 播放 / 歌词 / 封面', () async {
      final client = SongloftClient(cfg);
      final ping = await client.ping();
      expect(ping.ok, isTrue);
      expect(ping.version, '2.2.3');

      final songs = await client.listSongs(limit: 500);
      expect(songs, hasLength(1));
      final song = songs.single;
      expect(song.title, '晴天');
      expect(song.artists.single.name, '周杰伦');
      expect(song.album?.name, '叶惠美');
      expect(song.duration, 269500);
      expect(song.originalId, '7');
      expect(song.source, 'streaming');
      expect(song.quality?.bitRate, 900000);

      final url = await client.getStreamUrl('7', streamingQuality: 'high');
      expect(url, contains('/api/v1/songs/7/play'));
      expect(url, contains('format=mp3'));
      expect(url, contains('quality=320'));

      final lyrics = await client.getLyrics('7');
      expect(lyrics.lrc, contains('[00:00.000]晴天'));
      // 逐字 / 翻译 / 罗马音只取服务端自带字段。
      expect(lyrics.wordByWord, contains('<0,1000>晴'));
      expect(lyrics.wordFormat, 'yrc');
      expect(lyrics.translation, contains('Sunny day'));
      expect(lyrics.romaji, contains('qing tian'));
      // 逐字文本交给现有引擎解析（服务端给什么就用什么）。
      final groups = parseLyricGroups(
        content: lyrics.wordByWord!,
        format: lyrics.wordFormat,
      );
      expect(groups.single.original.text, '晴天');
      expect(groups.single.fragments?.map((f) => f.text).join(), '晴天');

      final session = await SongloftSession.ensure(cfg);
      final cover = await session.call('getCover', {'kind': 'song', 'id': 7});
      final path = cover['path'] as String;
      expect(path, startsWith('$dataDir/covers/sl-test/'));
      expect(File(path).existsSync(), isTrue);
      expect(await File(path).readAsBytes(),
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    }, skip: skipReason);

    test('错误码：登录失败 → StreamingAuthError', () async {
      final bad = StreamingServerConfig(
        id: 'sl-bad',
        name: 'Songloft',
        type: StreamingServerType.songloft,
        host: '127.0.0.1',
        port: server.port,
        username: 'alice',
        password: 'wrong',
      );
      final ping = await SongloftClient(bad).ping();
      expect(ping.ok, isFalse);
      expect(ping.error, contains('鉴权失败'));
    }, skip: skipReason);
  });
}

Future<void> _handle(HttpRequest req) async {
  final res = req.response;
  switch (req.uri.path) {
    case '/api/v1/version':
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'version': '2.2.3', 'full': '2.2.3+1'}));
    case '/api/v1/auth/login':
      final body = await utf8.decoder.bind(req).join();
      if (body.contains('"wrong"')) {
        res.statusCode = 401;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'error': 'invalid credentials'}));
      } else {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'access_token': 'tok-1',
          'refresh_token': 'ref-1',
          'expires_in': 3600,
        }));
      }
    case '/api/v1/songs':
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({
        'songs': [
          {
            'id': 7,
            'title': '晴天',
            'artist': '周杰伦',
            'album': '叶惠美',
            'duration': 269.5,
            'file_size': 123456,
            'format': 'flac',
            'bit_rate': 900,
            'sample_rate': 44100,
          },
        ],
        'total': 1,
        'limit': 500,
        'offset': 0,
      }));
    case '/api/v1/songs/7/lyric':
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({
        'lyric': '[00:00.000]晴天\n[00:03.000]故事的小黄花',
        'lxlyric': '[00:00.000]<0,1000>晴<1000,1000>天',
        'tlyric': '[00:00.00]Sunny day',
        'rlyric': '[00:00.00]qing tian',
      }));
    case '/api/v1/songs/7/cover':
      res.headers.contentType = ContentType('image', 'png');
      res.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    case '/api/v1/songs/facets':
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({
        'field': req.uri.queryParameters['field'] ?? 'album',
        'facets': [
          {
            'value': req.uri.queryParameters['field'] == 'artist' ? '周杰伦' : '叶惠美',
            'count': 1,
            'cover_url': '/api/v1/songs/7/cover',
          },
        ],
        'total': 1,
        'limit': 500,
        'offset': 0,
      }));
    default:
      res.statusCode = 404;
  }
  await res.close();
}

