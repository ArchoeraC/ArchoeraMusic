library;

import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('copyWith(source: null) 能显式置空 source（stop 后播放条收缩的前提）',
      () {
    const s = PlaybackState(source: 'http://x', sessionId: 's1');
    final cleared = s.copyWith(source: null);
    expect(cleared.source, isNull);
    // 其他字段不受影响
    expect(cleared.sessionId, 's1');
  });

  test('copyWith 不传 source 保留旧值', () {
    const s = PlaybackState(source: 'http://x');
    expect(s.copyWith().source, 'http://x');
    expect(s.copyWith(playing: true).source, 'http://x');
    expect(s.copyWith(source: 'http://y').source, 'http://y');
  });

  test('copyWith(sessionId: null) 能显式置空 sessionId', () {
    const s = PlaybackState(sessionId: 's1');
    expect(s.copyWith(sessionId: null).sessionId, isNull);
    expect(s.copyWith().sessionId, 's1');
  });
}
