/// Fuck DJ Mode：DJ 版 / 口水歌识别（对齐原项目 `utils/preset/djMode.ts`）。
///
/// 标题或歌手名包含任一关键词（不区分大小写）即判定为应跳过的曲目。
/// 关键词直接沿用原项目：DJ / 抖音 / 0.9 / 0.8 / 网红 / 车载 / 热歌 / 慢摇。
library;

import '../netease/track.dart';

/// DJ 模式关键词（大写匹配）。
const djSkipKeywords = ['DJ', '抖音', '0.9', '0.8', '网红', '车载', '热歌', '慢摇'];

/// 判断曲目是否为 DJ 混音 / 口水歌（fuckDjMode 开启时跳过）。
bool shouldSkipDjTrack(Track track) {
  final full = '${track.title} ${track.artistNames}'.toUpperCase();
  return djSkipKeywords.any((k) => full.contains(k.toUpperCase()));
}
