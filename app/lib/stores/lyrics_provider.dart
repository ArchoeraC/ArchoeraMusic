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
import '../services/netease/track.dart';
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

/// 歌词请求键（曲目 + 播放实例 id）。
///
/// 作为 family 参数使用：切歌 → 新键 → **新的 provider 实例**。Riverpod 只会在
/// 同一实例内保留 loading 期间的旧值；跨实例不保留，因此切歌后渲染端拿到的是
/// loading（value = null），不会短暂显示上一首的歌词。
class LyricsRequestKey {
  const LyricsRequestKey({required this.track, this.trackId});

  final Track track;
  final String? trackId;

  @override
  bool operator ==(Object other) =>
      other is LyricsRequestKey &&
      other.track == track &&
      other.trackId == trackId;

  @override
  int get hashCode => Object.hash(track, trackId);
}

/// 当前曲目的歌词请求键；无播放曲目时为 null。
final currentLyricsRequestProvider = Provider.autoDispose<LyricsRequestKey?>((
  ref,
) {
  final state = ref.watch(
    playbackProvider.select((s) => (track: s.track, trackId: s.trackId)),
  );
  final track = state.track;
  if (track == null) return null;
  return LyricsRequestKey(track: track, trackId: state.trackId);
});

/// 按请求键解析歌词组（内部 family；供 [currentLyricsProvider] 与本文件
/// [awaitCurrentLyrics] 使用）。
///
/// 只依赖**影响歌词内容**的偏好（逐项 select）：字号 / 配色 / 歌词显隐
/// （`showLyricsInPlayer`）等无关偏好变化时**不重算**歌词。列表以分隔符
/// join 成字符串参与结构化相等。
final lyricsForRequestProvider = FutureProvider.autoDispose
    .family<List<LyricGroup>, LyricsRequestKey>((ref, request) async {
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
          ),
        ),
      );
      final locale = ref.watch(localeProvider);

      final groups = await ref
          .watch(lyricsEngineProvider)
          .resolve(
            request.track,
            trackId: request.trackId,
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
        ),
      );
    });

/// 当前曲目歌词（UI 入口；`value` 语义与旧 FutureProvider 一致）。
///
/// 包装成同步 [Provider]：切歌时请求键变化 → 立即切到新 family 实例的
/// loading 状态（无上一首旧值）；同曲目内的偏好变化仍保留旧值，避免闪空。
final currentLyricsProvider =
    Provider.autoDispose<AsyncValue<List<LyricGroup>>>((ref) {
      final request = ref.watch(currentLyricsRequestProvider);
      if (request == null) return const AsyncData(<LyricGroup>[]);
      return ref.watch(lyricsForRequestProvider(request));
    });

/// 等待当前曲目歌词解析完成（MCP / 非 UI 调用方）。
Future<List<LyricGroup>> awaitCurrentLyrics(Ref ref) async {
  final request = ref.read(currentLyricsRequestProvider);
  if (request == null) return const <LyricGroup>[];
  return ref.read(lyricsForRequestProvider(request).future);
}
