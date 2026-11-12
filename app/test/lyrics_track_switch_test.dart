// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 切歌歌词隔离回归：新曲目歌词解析期间不得把上一首的结果当作当前曲目。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/stores/lyrics_provider.dart';

class _Prefs extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

class _FakePlayback extends PlaybackNotifier {
  _FakePlayback(this.initial);

  final PlaybackState initial;

  @override
  PlaybackState build() => initial;

  void set(PlaybackState next) => state = next;
}

const _trackA = Track(id: 'a', title: 'A');
const _trackB = Track(id: 'b', title: 'B');

void main() {
  test('切歌后 loading 期间不返回上一首歌词', () async {
    final pending = <String, Completer<List<LyricGroup>>>{};
    final container = ProviderContainer(
      overrides: [
        appPrefsProvider.overrideWith(_Prefs.new),
        playbackProvider.overrideWith(
          () =>
              _FakePlayback(const PlaybackState(track: _trackA, trackId: 'ta')),
        ),
        lyricsForRequestProvider.overrideWith((ref, key) {
          final completer = Completer<List<LyricGroup>>();
          pending[key.track.id] = completer;
          return completer.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(currentLyricsProvider, (_, _) {});
    addTearDown(sub.close);

    // 第一首歌词就绪。
    final keyA = container.read(currentLyricsRequestProvider)!;
    pending['a']!.complete(const [
      LyricGroup(original: LyricLine(timeMs: 0, text: 'A 行')),
    ]);
    await container.read(lyricsForRequestProvider(keyA).future);
    expect(
      container.read(currentLyricsProvider).value?.single.original.text,
      'A 行',
    );

    // 切到第二首（歌词尚未返回）：不得把 A 的歌词当作当前曲目。
    (container.read(playbackProvider.notifier) as _FakePlayback).set(
      const PlaybackState(track: _trackB, trackId: 'tb'),
    );
    final loading = container.read(currentLyricsProvider);
    expect(loading.isLoading, isTrue);
    expect(loading.value, isNull, reason: '新曲目解析中不应保留上一首歌词');
    expect(loading.value ?? const <LyricGroup>[], isEmpty);

    // 第二首就绪后正常显示。
    final keyB = container.read(currentLyricsRequestProvider)!;
    expect(keyB, isNot(equals(keyA)));
    pending['b']!.complete(const [
      LyricGroup(original: LyricLine(timeMs: 0, text: 'B 行')),
    ]);
    await container.read(lyricsForRequestProvider(keyB).future);
    expect(
      container.read(currentLyricsProvider).value?.single.original.text,
      'B 行',
    );
  });
}
