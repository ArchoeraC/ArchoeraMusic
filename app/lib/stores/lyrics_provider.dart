/// 当前播放曲目的歌词（§10.2 歌词流水线 UI 端入口）。
///
/// 数据流：`playback state.track` → 平台 lyric 层（缓存 + 模糊匹配）→
/// 原生富结果（YRC/KRC 逐字 + LRC 翻译）→ `parseLyricGroups` 按行对齐
/// 的歌词组（原文 + 翻译 + 逐字片段）。空列表 = 暂无歌词（播放页走空态）。
///
/// 「解锁脏话」开关（强迫症预设）开启时，原文 / 翻译 / 逐字片段统一
/// 还原被星号遮盖的脏话（对齐原项目 uncensorProfanity）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../apis/lyric/kugou.dart';
import '../apis/lyric/netease.dart';
import '../services/lyrics/lyric_line.dart';
import '../services/lyrics/profanity.dart';
import '../services/playback/playback_notifier.dart';
import 'app_prefs.dart';

/// 按当前播放曲目解析出的歌词组；曲目变化时自动重新拉取。
final currentLyricsProvider = FutureProvider<List<LyricGroup>>((ref) async {
  // watch 建立依赖（必须在 await 前）：开关变化时自动重算歌词
  final uncensor = ref.watch(appPrefsProvider).uncensorProfanity;
  final groups = await _fetchGroups(ref);
  if (!uncensor) return groups;
  return _uncensorGroups(groups);
});

/// 拉取并解析当前曲目的歌词组（按平台分流）。
Future<List<LyricGroup>> _fetchGroups(Ref ref) async {
  final track = ref.watch(playbackProvider.select((s) => s.track));
  final trackId = ref.watch(playbackProvider.select((s) => s.trackId));
  if (track == null) return const [];

  switch (track.source) {
    case 'netease':
      // 优先按平台 id 直取富结果（lyric_new：YRC 逐字 + ytlrc/tlyric 翻译），
      // 无 id 时走「歌名+歌手 → 搜索 → 最佳候选」模糊链路。
      final match = (trackId != null && trackId.isNotEmpty)
          ? await nmGetLyricByPlatformId(trackId)
          : await nmGetLyricByQuery(track);
      if (match == null) return const [];
      return parseLyricGroups(
        content: match.content,
        format: match.format,
        translation: match.translation,
      );

    case 'kugou':
      final match = await kgGetLyricByQuery(track);
      if (match == null) return const [];
      // apis 层 KRC 已解成 LX 逐字格式（<offset,dur> 字级标签），
      // parseLyricGroups 会保留逐字；翻译（trans）一并对齐。
      return parseLyricGroups(
        content: match.content,
        format: match.format,
        translation: match.translation,
      );

    default:
      // 本地曲目：scanner 直写 library.db 的内嵌歌词元数据。
      // 标准 LRC 直接解析；无时间标签的纯文本降级为整段显示
      // （LyricGroup.original.timeMs 置 0，静态歌词全文展示）。
      final raw = track.lyrics;
      if (raw == null || raw.trim().isEmpty) return const [];
      final groups = parseLyricGroups(content: raw, format: 'lrc');
      if (groups.isNotEmpty) return groups;
      return raw
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .map((l) => LyricGroup(original: LyricLine(timeMs: 0, text: l)))
          .toList();
  }
}

/// 对歌词组应用脏话还原（重建不可变对象：原文 / 翻译 / 逐字片段）。
List<LyricGroup> _uncensorGroups(List<LyricGroup> groups) {
  return [
    for (final g in groups)
      LyricGroup(
        original: LyricLine(
          timeMs: g.original.timeMs,
          text: unmaskProfanity(g.original.text),
        ),
        translation: g.translation == null
            ? null
            : unmaskProfanity(g.translation!),
        fragments: g.fragments == null
            ? null
            : [
                for (final f in g.fragments!)
                  LyricFragment(
                    text: unmaskProfanity(f.text),
                    startMs: f.startMs,
                    durationMs: f.durationMs,
                  ),
              ],
      ),
  ];
}
