// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 实验性音源 NekoMusic 歌词来源：向曲目所属服务器直取歌词。
///
/// **只服务** `source == 'neko'` 的曲目（Neko id 与 NT/KG/QM id 不同命名空间），
/// 但因 [online] = true，本来源在本平台歌词不可信时会参与引擎的标准源回退；
/// 其它平台的曲目不会把本来源加入候选（`neko` 不在用户来源顺序
/// `lyricPlatforms` 中）。
///
/// **格式兼容**（统一走 `pickLyricFormat` 格式策略，不自行决定优先级）：
/// - 新版服务端在音乐详情里返回 `neko-v1` 富歌词（`lyricsRich`），逐字时间轴
///   由引擎的 `parseNekoV1Lyrics` 解析；作为逐字候选参与格式选择；
/// - 老数据 / 无字级时间轴时是**非标准 LRC**（正文行带时间戳、下一行为无
///   时间戳的 `{译文}`，或整行 `[mm:ss.xx]{译文}`），标准解析器会丢弃译文，
///   这里经 [parseNekoLyrics] 归一化为「标准主歌词 LRC + 独立译文 LRC」，
///   复用引擎既有的翻译对齐能力（见 [LyricMatchResult.translation]）。
///
/// **不可信内容兜底**：Neko 歌词常为站点广告（「资源来自Neko云音乐…」）或
/// 占位词。整首不可用时返回 null，引擎按用户来源顺序回退到标准源。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../apis/lyric/format.dart'
    show LyricFormatCandidate, kNekoV1LyricsFormat, pickLyricFormat;
import '../../../apis/lyric/types.dart';
import '../../../stores/providers.dart';
import '../../neko/neko_lyrics.dart';
import '../ad_filter.dart';
import '../engine/lyric_source.dart';

class NekoLyricSource implements LyricSource {
  NekoLyricSource(this._ref);

  final Ref _ref;

  @override
  String get id => 'neko';

  /// 参与来源回退：Neko 曲目在自身歌词不可信时回退到标准源（NT/KG/QM）。
  /// 因 `neko` 不在用户来源顺序（`lyricPlatforms`）中，本来源不会被加到其它
  /// 平台的候选里——仅 `source == 'neko'` 的曲目会走到它。
  @override
  bool get online => true;

  @override
  bool get plainTextFallback => false;

  @override
  Future<LyricMatchResult?> fetch(LyricRequest request) async {
    final track = request.track;
    if (track.source != 'neko') return null;
    final id = (request.trackId ?? track.id).trim();
    if (id.isEmpty) return null;
    final payload = await _ref.read(nekoApiProvider).lyricPayload(id);
    if (payload == null) return null;

    // 富歌词候选：整首均为广告/占位内容时不提供该候选，避免挡住回退。
    String? richJson;
    final rich = payload.rich;
    if (rich != null && rich.isNotEmpty) {
      final encoded = jsonEncode(rich);
      if (nekoV1HasDisplayableLine(encoded)) richJson = encoded;
    }

    // 兼容 LRC 候选：归一化为「标准主歌词 + 独立译文」。
    String? lrcContent;
    String? lrcTranslation;
    final raw = payload.lrc;
    if (raw.trim().isNotEmpty && !isAdMetadataText(raw)) {
      final parsed = parseNekoLyrics(raw);
      if (parsed.content.trim().isNotEmpty) {
        lrcContent = parsed.content;
        lrcTranslation = parsed.translation;
      }
    }

    // 与 NT/KG/QQ 共用同一格式策略：逐字优先 / 标准 LRC 优先，首选缺失时
    // 回退另一类；两个候选都不可用才返回 null 交给引擎换源。
    final picked = pickLyricFormat([
      LyricFormatCandidate(
        content: richJson,
        format: kNekoV1LyricsFormat,
        wordByWord: true,
      ),
      LyricFormatCandidate(content: lrcContent, format: 'lrc'),
    ], preferRich: request.preferRich);
    if (picked == null) return null;

    final richPicked = picked.format == kNekoV1LyricsFormat;
    return LyricMatchResult(
      platform: 'neko',
      format: picked.format,
      content: picked.content,
      translation: richPicked ? null : lrcTranslation,
      translationFormat: richPicked || lrcTranslation == null ? null : 'lrc',
    );
  }
}
