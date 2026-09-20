// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 实验性音源 NekoMusic 歌词来源：向曲目所属服务器直取歌词。
///
/// 非在线源（[online] = false）：只服务 `source == 'neko'` 的曲目，
/// 不参与其它平台的歌词回退（Neko id 与 NT/KG/QM id 不同命名空间）。
///
/// **格式兼容**：Neko 返回的是**非标准 LRC**（正文行带时间戳、下一行为无
/// 时间戳的 `{译文}`，或整行 `[mm:ss.xx]{译文}`），标准解析器会丢弃译文。
/// 这里经 [parseNekoLyrics] 归一化为「标准主歌词 LRC + 独立译文 LRC」，
/// 复用引擎既有的翻译对齐能力（见 [LyricMatchResult.translation]）。
///
/// **不可信内容兜底**：Neko 歌词常为站点广告（「资源来自Neko云音乐…」）或
/// 占位词。命中这类内容时返回 null：[online] = true 使其参与引擎回退，
/// 改由标准源（NT/KG/QM，按用户来源顺序）提供歌词。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../apis/lyric/types.dart';
import '../../neko/neko_lyrics.dart';
import '../../../stores/providers.dart';
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
    final raw = await _ref.read(nekoApiProvider).lyricText(id);
    if (raw == null || raw.trim().isEmpty) return null;
    // 广告/占位内容不可信 → 放弃，交由引擎回退到标准源。
    if (isAdMetadataText(raw)) return null;
    final parsed = parseNekoLyrics(raw);
    // 无任何带时间戳的正文行 → 视为无可用歌词（不展示裸 `{}` 文本）。
    if (parsed.content.trim().isEmpty) return null;
    return LyricMatchResult(
      platform: 'neko',
      format: 'lrc',
      content: parsed.content,
      translation: parsed.translation,
      translationFormat: parsed.translation == null ? null : 'lrc',
    );
  }
}
