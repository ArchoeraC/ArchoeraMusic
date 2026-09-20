// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/lyric/format.dart';
import 'package:archoera_music/apis/lyric/types.dart';
import 'package:archoera_music/services/lyrics/engine/lyric_pipeline.dart';
import 'package:archoera_music/services/lyrics/engine/lyric_source.dart';
import 'package:archoera_music/services/lyrics/engine/lyrics_engine.dart';
import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/services/netease/track.dart';

Track _track(String source, {String id = 't1'}) =>
    Track(id: id, title: 'Title', source: source, artists: const []);

LyricMatchResult _match(String content, {String format = 'lrc'}) =>
    LyricMatchResult(platform: 'test', format: format, content: content);

/// 可编程假来源：记录调用次数，可选抛异常。
class _FakeSource implements LyricSource {
  _FakeSource(
    this.id, {
    this.online = true,
    this.plainTextFallback = false,
    this.result,
    this.throws = false,
  });

  @override
  final String id;
  @override
  final bool online;
  @override
  final bool plainTextFallback;
  final LyricMatchResult? result;
  final bool throws;
  int calls = 0;

  @override
  Future<LyricMatchResult?> fetch(LyricRequest request) async {
    calls++;
    if (throws) throw StateError('boom');
    return result;
  }
}

void main() {
  group('pickLyricFormat', () {
    test('逐字优先时选富格式', () {
      final picked = pickLyricFormat(
        [
          const LyricFormatCandidate(content: 'rich', format: 'yrc', wordByWord: true),
          const LyricFormatCandidate(content: 'plain', format: 'lrc'),
        ],
        preferRich: true,
      );
      expect(picked?.content, 'rich');
      expect(picked?.format, 'yrc');
    });

    test('标准优先时选 LRC', () {
      final picked = pickLyricFormat(
        [
          const LyricFormatCandidate(content: 'rich', format: 'yrc', wordByWord: true),
          const LyricFormatCandidate(content: 'plain', format: 'lrc'),
        ],
        preferRich: false,
      );
      expect(picked?.content, 'plain');
      expect(picked?.format, 'lrc');
    });

    test('偏好格式缺失时回退另一类；全空返回 null', () {
      final onlyPlain = pickLyricFormat(
        [
          const LyricFormatCandidate(content: '  ', format: 'yrc', wordByWord: true),
          const LyricFormatCandidate(content: 'plain', format: 'lrc'),
        ],
        preferRich: true,
      );
      expect(onlyPlain?.format, 'lrc');
      expect(pickLyricFormat(const [], preferRich: true), isNull);
    });

    test('缓存平台键：标准优先用独立命名空间', () {
      expect(lyricCachePlatform('netease', preferRich: true), 'netease');
      expect(lyricCachePlatform('netease', preferRich: false), 'netease#lrc');
    });
  });

  group('LyricsEngine.orderedSources', () {
    test('在线平台曲目：本平台优先，其后按用户来源顺序', () {
      final engine = LyricsEngine([
        _FakeSource('netease'),
        _FakeSource('qqmusic'),
        _FakeSource('kugou'),
      ]);
      final order = engine
          .orderedSources('qqmusic', ['netease', 'kugou'])
          .map((s) => s.id)
          .toList();
      expect(order, ['qqmusic', 'netease', 'kugou']);
    });

    test('本地/流媒体曲目：只用自身源，不做在线回退', () {
      final engine = LyricsEngine([
        _FakeSource('netease'),
        _FakeSource('local', online: false),
        _FakeSource('streaming', online: false),
      ]);
      expect(engine.orderedSources('local', ['netease']).map((s) => s.id), [
        'local',
      ]);
      expect(engine.orderedSources('streaming', ['netease']).map((s) => s.id), [
        'streaming',
      ]);
    });

    test('未知来源：无候选', () {
      final engine = LyricsEngine([_FakeSource('netease')]);
      expect(engine.orderedSources('unknown', ['netease']), isEmpty);
    });
  });

  group('LyricsEngine.resolve', () {
    test('首选无结果时回退到下一个来源并解码', () async {
      final empty = _FakeSource('netease');
      final hit = _FakeSource(
        'qqmusic',
        result: _match('[00:01.000]hello\n[00:02.000]world'),
      );
      final engine = LyricsEngine([empty, hit]);
      final groups = await engine.resolve(
        _track('netease'),
        sourceOrder: const ['qqmusic'],
        preferRich: true,
      );
      expect(groups.length, 2);
      expect(groups.first.original.text, 'hello');
      expect(empty.calls, 1);
      expect(hit.calls, 1);
    });

    test('来源抛异常不阻塞回退', () async {
      final boom = _FakeSource('netease', throws: true);
      final hit = _FakeSource(
        'qqmusic',
        result: _match('[00:01.000]ok'),
      );
      final engine = LyricsEngine([boom, hit]);
      final groups = await engine.resolve(
        _track('qqmusic'),
        sourceOrder: const ['netease'],
        preferRich: true,
      );
      expect(groups.single.original.text, 'ok');
    });

    test('纯文本仅本地源降级为静态行；在线源不降级', () async {
      final local = _FakeSource(
        'local',
        online: false,
        plainTextFallback: true,
        result: _match('line one\nline two'),
      );
      final online = _FakeSource('netease', result: _match('line one\nline two'));
      final engine = LyricsEngine([local, online]);
      final localGroups = await engine.resolve(
        _track('local'),
        sourceOrder: const [],
        preferRich: true,
      );
      expect(localGroups.length, 2);
      final onlineGroups = await engine.resolve(
        _track('netease'),
        sourceOrder: const [],
        preferRich: true,
      );
      expect(onlineGroups, isEmpty);
    });
  });

  group('LyricPipeline', () {
    List<LyricGroup> groups(List<String> texts) => [
      for (final t in texts)
        LyricGroup(original: LyricLine(timeMs: 0, text: t)),
    ];

    test('排除规则按关键词丢弃匹配行', () {
      final out = LyricPipeline.standard.process(
        groups(['keep', 'drop me', 'also keep']),
        const LyricProcessContext(
          excludeEnabled: true,
          excludeKeywords: ['drop'],
        ),
      );
      expect(out.map((g) => g.original.text).toList(), ['keep', 'also keep']);
    });

    test('排除关闭时不处理', () {
      final input = groups(['a', 'b']);
      final out = LyricPipeline.standard.process(
        input,
        const LyricProcessContext(excludeEnabled: false, excludeKeywords: ['a']),
      );
      expect(out.length, 2);
    });

    test('脏话还原保持行数与结束时间', () {
      final input = [
        LyricGroup(
          original: const LyricLine(timeMs: 100, text: 'f**k'),
          endMs: 200,
        ),
      ];
      final out = LyricPipeline.standard.process(
        input,
        const LyricProcessContext(uncensor: true),
      );
      expect(out.length, 1);
      expect(out.single.endMs, 200);
    });
  });
}
