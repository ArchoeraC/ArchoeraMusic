library;

import 'dart:io';

import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/playback/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PlaybackSnapshot 序列化往返 + 存储覆盖', () {
    // 数据目录由命令行 ARCHOERA_DATA_DIR 指向临时目录（见下方执行方式）
    const store = PlaybackSessionStore();
    final track = Track(
      id: '123',
      title: '测试',
      artists: const [TrackArtist(name: '歌手')],
      source: 'netease',
      duration: 200000,
    );
    final snap = PlaybackSnapshot.fromState(
      queue: [
        track,
        Track(id: '456', title: 'B', source: 'local', localPath: '/x.mp3'),
      ],
      queueIndex: 0,
      position: const Duration(seconds: 65),
      repeatMode: 'one',
      shuffle: true,
      quality: 'hq',
      playing: true,
      title: '测试',
      trackId: '123',
      track: track,
      source: 'http://x',
    );
    store.save(snap);
    final loaded = store.load();
    expect(loaded, isNotNull);
    expect(loaded!.queue.length, 2);
    expect(loaded.queueIndex, 0);
    expect(loaded.positionMs, 65000);
    expect(loaded.repeatMode, 'one');
    expect(loaded.shuffle, isTrue);
    expect(loaded.playing, isTrue);
    expect(loaded.currentTrack!.id, '123');
    expect(loaded.currentTrack!.title, '测试');
    expect(loaded.queue[1].source, 'local');
    expect(loaded.queue[1].localPath, '/x.mp3');
    expect(File(PlaybackSessionStore.filePath).existsSync(), isTrue);

    // 空现场（清空队列后）读取应为 null
    store.save(const PlaybackSnapshot(
      queue: [],
      queueIndex: -1,
      positionMs: 0,
      repeatMode: 'list',
      shuffle: false,
      quality: 'hq',
    ));
    expect(store.load(), isNull);
  });
}
