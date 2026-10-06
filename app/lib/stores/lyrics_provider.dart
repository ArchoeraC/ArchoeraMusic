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

import '../l10n/l10n.dart';
import '../services/lyrics/engine/lyric_pipeline.dart';
import '../services/lyrics/engine/lyrics_engine.dart';
import '../services/lyrics/lyric_line.dart';
import '../services/playback/playback_notifier.dart';
import '../services/source/source_platform.dart';
import 'app_prefs.dart';

/// 歌词引擎（应用级单例；来源可插拔）。
///
/// 来源集合由**音源注册表**提供（`SourcePlatform.lyricSources`）：新增音源时
/// 只需在其 [SourcePlatform] 适配器里声明歌词来源，此处无需改动。
final lyricsEngineProvider = Provider<LyricsEngine>(
  (ref) => LyricsEngine([
    for (final p in allSourcePlatforms()) ...p.lyricSources(ref),
  ]),
);

/// 按当前播放曲目解析出的歌词组；曲目变化时自动重新拉取。
///
/// autoDispose：由播放页与迷你播放条按需 `ref.watch` 持有——播放中（迷你条
/// 常驻）一直存活，停止播放 / 页面子树卸载后释放内存，重新播放时对当前曲目
/// 重新解析。
final currentLyricsProvider = FutureProvider.autoDispose<List<LyricGroup>>((
  ref,
) async {
  // 只依赖**影响歌词内容**的偏好（逐项 select）：字号 / 配色 / 歌词显隐
  // （`showLyricsInPlayer`）等无关偏好变化时**不重算**歌词。否则切换歌词显隐
  // 会先写偏好 → 本 provider 进入 loading → 渲染端（全屏歌词 / 播放条）闪
  // 「暂无歌词」，且可能重复联网。列表以分隔符 join 成字符串参与结构化相等。
  final cfg = ref.watch(
    appPrefsProvider.select(
      (p) => (
        p.lyricSourceOrder.join(','),
        p.preferWordByWord,
        p.lyricEnableOnlineTtml,
        p.lyricExcludeEnabled,
        p.lyricExcludeKeywords.join('\u0000'),
        p.lyricExcludeRegexes.join('\u0000'),
        p.uncensorProfanity,
        p.amllSyntheticSweep,
      ),
    ),
  );
  final locale = ref.watch(localeProvider);
  final track = ref.watch(playbackProvider.select((s) => s.track));
  final trackId = ref.watch(playbackProvider.select((s) => s.trackId));
  if (track == null) return const [];

  final groups = await ref
      .watch(lyricsEngineProvider)
      .resolve(
        track,
        trackId: trackId,
        sourceOrder: cfg.$1.isEmpty ? const [] : cfg.$1.split(','),
        preferRich: cfg.$2,
        enableTtmlOverlay: cfg.$3,
        preferredLang: locale.toLanguageTag(),
      );

  return LyricPipeline.standard.process(
    groups,
    LyricProcessContext(
      excludeEnabled: cfg.$4,
      excludeKeywords: cfg.$5.isEmpty ? const [] : cfg.$5.split('\u0000'),
      excludeRegexes: cfg.$6.isEmpty ? const [] : cfg.$6.split('\u0000'),
      uncensor: cfg.$7,
      syntheticSweep: cfg.$8,
    ),
  );
});
