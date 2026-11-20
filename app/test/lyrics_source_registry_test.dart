// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词来源注册表守卫：
/// - 每个 [SourcePlatform.lyricSources] 声明的来源 id 必须与音源 `source` 一致，
///   且全局唯一（防止新增/重构歌词来源时漏登记或串台）；
/// - 在线源按默认顺序回退到其它平台，非在线源只用自己的来源。
///
/// 背景：来源层只负责 I/O，格式优先级统一交给
/// `apis/lyric/format.dart`；注册关系需要回归守卫，避免后续
/// 「解析器能力」与「注册表登记」再次脱节。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/engine/lyric_source.dart';
import 'package:archoera_music/services/lyrics/engine/lyrics_engine.dart';
import 'package:archoera_music/services/source/source_platform.dart';
import 'package:archoera_music/stores/prefs_lyrics.dart';

/// 音源 → 歌词来源（在 Provider 内拿真实 [Ref]，与生产 `lyricsEngineProvider` 一致）。
final _sourcesOfProvider = Provider.family<List<LyricSource>, SourcePlatform>(
  (ref, platform) => platform.lyricSources(ref),
);

/// 全量歌词来源注册表（顺序与 `allSourcePlatforms` 一致）。
final _allSourcesProvider = Provider<List<LyricSource>>(
  (ref) => [
    for (final platform in allSourcePlatforms()) ...platform.lyricSources(ref),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('歌词来源注册表：id 与音源一致、全局唯一', () {
    final container = ProviderContainer.test();
    final registered = <String, LyricSource>{};

    for (final platform in allSourcePlatforms()) {
      for (final source in container.read(_sourcesOfProvider(platform))) {
        expect(
          source.id,
          platform.source,
          reason: '${platform.source} 注册了不属于自己的歌词来源 ${source.id}',
        );
        expect(
          registered.putIfAbsent(source.id, () => source),
          same(source),
          reason: '歌词来源 id 重复：${source.id}',
        );
      }
    }

    // 有歌词能力的音源都必须登记（B 站无专属歌词源，走标准源回退）。
    expect(
      registered.keys,
      containsAll(<String>[
        'netease',
        'kugou',
        'qqmusic',
        'local',
        'streaming',
      ]),
    );
    expect(registered.keys, isNot(contains('bilibili')));
  });

  test('在线源按默认顺序回退，非在线源只用自身来源', () {
    final container = ProviderContainer.test();
    final engine = LyricsEngine(container.read(_allSourcesProvider));

    // 非在线源只用自己的来源，不做在线回退。
    expect(
      engine.orderedSources('local', defaultLyricSourceOrder).map((s) => s.id),
      ['local'],
    );
    expect(
      engine
          .orderedSources('netease', defaultLyricSourceOrder)
          .map((s) => s.id),
      ['netease', 'qqmusic', 'kugou'],
    );
  });
}
