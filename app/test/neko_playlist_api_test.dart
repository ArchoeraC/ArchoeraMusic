// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 歌单写操作单测：校验请求方法 / 路径 / body（对齐官方 PC 端
/// `apiclient.cpp` 的 `/api/user/playlist/*` 形态）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/neko/neko_client.dart';
import 'package:archoera_music/services/neko/neko_api.dart';

/// 记录请求的 NekoClient 桩。
class _RecordingClient extends NekoClient {
  _RecordingClient() : super(baseUrl: 'http://test');

  final List<({String method, String path, Object? body})> calls = [];
  Map<String, dynamic> response = const {'success': true};

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add((method: 'GET', path: path, body: null));
    return response;
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, {Object? body}) async {
    calls.add((method: 'POST', path: path, body: body));
    return response;
  }

  @override
  Future<Map<String, dynamic>> deleteJson(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add((method: 'DELETE', path: path, body: null));
    return response;
  }
}

Map<String, dynamic> _body(Object? body) => switch (body) {
  Map() => Map<String, dynamic>.from(body),
  String() => Map<String, dynamic>.from(jsonDecode(body) as Map),
  _ => const {},
};

void main() {
  late _RecordingClient client;
  late NekoApi api;

  setUp(() {
    client = _RecordingClient();
    api = NekoApi(clientFactory: (_, _) => client);
  });

  test('拉取自建 / 收藏歌单', () async {
    client.response = const {
      'success': true,
      'playlists': [
        {'id': 1, 'name': 'p1'},
      ],
    };
    final created = await api.userPlaylists();
    expect(client.calls.last.path, '/api/user/playlists');
    expect(client.calls.last.method, 'GET');
    expect(created.single.id, '1');

    await api.favoritePlaylists();
    expect(client.calls.last.path, '/api/user/favorite-playlists');
  });

  test('新建歌单：POST /api/user/playlist/create', () async {
    client.response = const {
      'success': true,
      'playlist': {'id': 7, 'name': 'n'},
    };
    final p = await api.createPlaylist('n', description: 'd');
    expect(client.calls.last.method, 'POST');
    expect(client.calls.last.path, '/api/user/playlist/create');
    expect(_body(client.calls.last.body), {'name': 'n', 'description': 'd'});
    expect(p?.id, '7');
  });

  test('更新 / 删除歌单', () async {
    await api.updatePlaylist('5', name: 'nn', description: 'dd');
    expect(client.calls.last.path, '/api/user/playlist/update');
    expect(_body(client.calls.last.body), {
      'id': 5,
      'name': 'nn',
      'description': 'dd',
    });

    await api.deletePlaylist('5');
    expect(client.calls.last.path, '/api/user/playlist/delete');
    expect(_body(client.calls.last.body), {'id': 5});
  });

  test('添加歌曲：单曲 musicId / 多曲 musicIds', () async {
    client.response = const {'success': true, 'addedCount': 2};
    final n = await api.addMusicToPlaylist('5', ['1']);
    expect(client.calls.last.path, '/api/user/playlist/music/add');
    expect(_body(client.calls.last.body), {'playlistId': 5, 'musicId': 1});
    expect(n, 2);

    await api.addMusicToPlaylist('5', ['1', '2']);
    expect(_body(client.calls.last.body), {
      'playlistId': 5,
      'musicIds': [1, 2],
    });
  });

  test('移除歌曲 / 收藏 / 取消收藏', () async {
    await api.removeMusicFromPlaylist('5', ['9']);
    expect(client.calls.last.path, '/api/user/playlist/music/remove');
    expect(_body(client.calls.last.body), {'playlistId': 5, 'musicId': 9});

    await api.favoritePlaylist('5');
    expect(client.calls.last.method, 'POST');
    expect(client.calls.last.path, '/api/user/favorite-playlists');
    expect(_body(client.calls.last.body), {'playlistId': 5});

    await api.unfavoritePlaylist('5');
    expect(client.calls.last.method, 'DELETE');
    expect(client.calls.last.path, '/api/user/favorite-playlists/5');
  });

  test('success=false 抛 NekoApiException', () async {
    client.response = const {'success': false, 'message': 'boom'};
    expect(() => api.deletePlaylist('5'), throwsA(isA<NekoApiException>()));
  });
}
