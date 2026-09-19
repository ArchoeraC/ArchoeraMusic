// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 当前播放曲目的歌词（§10.2 歌词流水线 UI 端入口）。
///
/// 数据流：`playback state.track` → [LyricsEngine]（来源顺序回退 + 统一解码）
/// → [LyricPipeline]（排除规则 / 脏话还原）→ 渲染端。空列表 = 暂无歌词。
///
/// 引擎与来源的职责见 `services/lyrics/engine/` 与 `services/lyrics/sources/`；
/// 本文件只做 Riverpod 接线与偏好读取。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/lyrics/engine/lyric_pipeline.dart';
import '../services/lyrics/engine/lyrics_engine.dart';
import '../services/lyrics/lyric_line.dart';
import '../services/lyrics/sources/kugou_lyric_source.dart';
import '../services/lyrics/sources/local_lyric_source.dart';
import '../services/lyrics/sources/netease_lyric_source.dart';
import '../services/lyrics/sources/qqmusic_lyric_source.dart';
import '../services/lyrics/sources/streaming_lyric_source.dart';
import '../services/playback/playback_notifier.dart';
import 'app_prefs.dart';

/// 歌词引擎（应用级单例；来源可插拔）。
final lyricsEngineProvider = Provider<LyricsEngine>(
  (ref) => LyricsEngine([
    const NeteaseLyricSource(),
    const QqmusicLyricSource(),
    const KugouLyricSource(),
    const LocalLyricSource(),
    StreamingLyricSource(ref),
  ]),
);

/// 按当前播放曲目解析出的歌词组；曲目变化时自动重新拉取。
final currentLyricsProvider = FutureProvider<List<LyricGroup>>((ref) async {
  // watch 建立依赖：偏好 / 曲目变化时自动重算歌词。
  final prefs = ref.watch(appPrefsProvider);
  final track = ref.watch(playbackProvider.select((s) => s.track));
  final trackId = ref.watch(playbackProvider.select((s) => s.trackId));
  if (track == null) return const [];

  final groups = await ref
      .watch(lyricsEngineProvider)
      .resolve(
        track,
        trackId: trackId,
        sourceOrder: prefs.lyricSourceOrder,
        preferRich: prefs.preferWordByWord,
      );

  return LyricPipeline.standard.process(
    groups,
    LyricProcessContext(
      excludeEnabled: prefs.lyricExcludeEnabled,
      excludeKeywords: prefs.lyricExcludeKeywords,
      excludeRegexes: prefs.lyricExcludeRegexes,
      uncensor: prefs.uncensorProfanity,
    ),
  );
});
