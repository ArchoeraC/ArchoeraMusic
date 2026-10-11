// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 网易云歌单写操作单测：校验各 mutation 的模块名与请求参数（对齐原项目
/// apis/playlist/netease.ts），以及非 200 响应抛 [NeteaseApiError]。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/netease/netease_api.dart';

/// 记录调用的 NT 传输层桩：返回可配置响应体。
class _RecordingCaller implements NeteaseCaller {
  final List<String> names = [];
  final List<Map<String, dynamic>> params = [];
  Map<String, dynamic> response = const {'code': 200};

  Map<String, dynamic> get last => params.last;

  @override
  Future<Map<String, dynamic>?> call(
    String name,
    Map<String, dynamic> p,
  ) async {
    names.add(name);
    params.add(Map<String, dynamic>.from(p));
    return response;
  }
}

void main() {
  late _RecordingCaller caller;
  late NeteaseApi api;

  setUp(() {
    caller = _RecordingCaller();
    api = NeteaseApi(caller);
  });

  test('收藏 / 取消收藏：playlist_subscribe 的 t = 1 / 2', () async {
    await api.subscribePlaylist('p1', subscribe: true);
    expect(caller.names.last, 'playlist_subscribe');
    expect(caller.last, {'id': 'p1', 't': 1});

    await api.subscribePlaylist('p1', subscribe: false);
    expect(caller.names.last, 'playlist_subscribe');
    expect(caller.last, {'id': 'p1', 't': 2});
  });

  test('新建歌单：playlist_create + 解析新 id', () async {
    caller.response = const {
      'code': 200,
      'id': 987,
      'playlist': {'id': 987},
    };
    final id = await api.createPlaylist('我的新歌单', privacy: 10);
    expect(id, '987');
    expect(caller.names.last, 'playlist_create');
    expect(caller.last, {'name': '我的新歌单', 'privacy': 10});
  });

  test('删除歌单：playlist_delete', () async {
    await api.deletePlaylist('p2');
    expect(caller.names.last, 'playlist_delete');
    expect(caller.last, {'id': 'p2'});
  });

  test('重命名 / 简介：playlist_name_update + playlist_desc_update', () async {
    await api.updatePlaylistName('p3', '新名字');
    expect(caller.names.last, 'playlist_name_update');
    expect(caller.last, {'id': 'p3', 'name': '新名字'});

    await api.updatePlaylistDesc('p3', '简介');
    expect(caller.names.last, 'playlist_desc_update');
    expect(caller.last, {'id': 'p3', 'desc': '简介'});
  });

  test('增 / 删歌曲：playlist_tracks 的 op=add / del，返回服务端 count', () async {
    caller.response = const {'code': 200, 'count': 2};
    final added = await api.playlistAddTracks('p4', ['a', 'b']);
    expect(added, 2);
    expect(caller.names.last, 'playlist_tracks');
    expect(caller.last, {'op': 'add', 'pid': 'p4', 'tracks': 'a,b'});

    caller.response = const {'code': 200};
    await api.playlistRemoveTracks('p4', ['a', 'b']);
    expect(caller.names.last, 'playlist_tracks');
    expect(caller.last, {'op': 'del', 'pid': 'p4', 'tracks': 'a,b'});
  });

  test('空 id 列表不请求（add / del 早退）', () async {
    expect(await api.playlistAddTracks('p5', const []), 0);
    await api.playlistRemoveTracks('p5', const []);
    expect(caller.names, isEmpty);
  });

  test('非 200 code 抛 NeteaseApiError', () async {
    caller.response = const {'code': 400};
    expect(
      () => api.subscribePlaylist('p6', subscribe: true),
      throwsA(isA<NeteaseApiError>()),
    );
  });
}
