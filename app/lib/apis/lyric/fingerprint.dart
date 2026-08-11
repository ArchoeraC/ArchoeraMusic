/// track → 平台匹配指纹（对齐 apis/common/lyric/fingerprint.ts）。
///
/// 用 title + 第一艺术家 + 时长桶 算指纹；时长按 5s 桶归一，
/// 避免不同来源元数据微差导致 miss。
library;

import '../../services/netease/track.dart';
import 'utils.dart';

const int _durationBucketMs = 5000;

String buildFingerprint(Track track) {
  final title = normalize(track.title);
  final artist = normalize(track.artists.isEmpty ? null : track.artists.first.name);
  final bucket = track.duration > 0 ? (track.duration / _durationBucketMs).round() : 0;
  return '$title|$artist|$bucket';
}
