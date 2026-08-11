/// 验证真实在线曲目的封面在快照往返后是否存活（问题排查用，临时测试）。
library;

import 'dart:convert';

import 'package:archoera_music/services/netease/apis_netease_caller.dart';
import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/playback/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('真实网易云曲目 → PlaybackSnapshot 往返 → cover 存活', () async {
    // 1) 真实搜索拿曲目
    final api = NeteaseApi(ApisNeteaseCaller());
    final result = await api.searchSongs('周杰伦', limit: 3);
    expect(result.items, isNotEmpty);
    final live = result.items.first;
    // ignore: avoid_print
    print('[t] 在线 cover: ${live.cover}');
    // ignore: avoid_print
    print('[t] 在线 album: ${live.album?.name} cover=${live.album?.cover}');

    // 2) 模拟快照写入（对齐 PlaybackSnapshot.fromState）
    final json = {
      'queue': live.toJson(),
    };
    final track2 = Track.fromJson(json['queue'] as Map<String, dynamic>);
    // ignore: avoid_print
    print('[t] 往返 cover: ${track2.cover}');
    // ignore: avoid_print
    print('[t] 往返 album: ${track2.album?.name} cover=${track2.album?.cover}');
    expect(track2.cover, isNotNull, reason: '快照往返后封面应保留');
    expect(track2.cover, live.cover);
    expect(track2.album?.cover, live.album?.cover);

    // 3) 完整快照往返（模拟 last_session.json 落盘→读取）
    final snapJson = jsonEncode({
      'queue': [live.toJson()],
      'queueIndex': 0,
      'positionMs': 65000,
      'repeatMode': 'list',
      'shuffle': false,
      'quality': 'hq',
      'playing': false,
      'title': live.title,
      'subtitle': live.subtitle,
      'trackId': live.id,
      'track': live.toJson(),
      'source': 'http://x',
    });
    final snap = PlaybackSnapshot.fromJson(
        jsonDecode(snapJson) as Map<String, dynamic>);
    expect(snap.currentTrack?.cover, live.cover);
    expect(snap.track?.cover, live.cover);
    // ignore: avoid_print
    print('[t] 快照 currentTrack.cover: ${snap.currentTrack?.cover}');
  });
}
