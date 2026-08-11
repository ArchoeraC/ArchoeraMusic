/// 歌词候选匹配 - 跨平台共享工具（对齐 apis/common/lyric/utils.ts）。
///
/// 三端（Netease / QQ / Kugou）搜索返回的候选结构不同，归一化成本结构后
/// 用 [pickBestCandidate] 挑出最匹配当前 track 的那一个，避免对多个候选串行请求歌词。
library;

import '../../services/netease/track.dart';
import 'types.dart';

/// 字符串归一化
final RegExp _normalizeReg =
    RegExp("[、&;，,/|()·・\\s\\-_'\"`~!?？！.。]+");

String normalize(String? text) {
  if (text == null || text.isEmpty) return '';
  return text.toLowerCase().replaceAll(_normalizeReg, '');
}

/// 双向 includes 命中
bool _bothContains(String left, String right) =>
    left.isNotEmpty && right.isNotEmpty && (left.contains(right) || right.contains(left));

/// 拆分候选歌手文本
final RegExp _artistSplitReg = RegExp(r'[、&;，,/|·・]+');

List<String> _splitArtists(String? text) =>
    (text ?? '').split(_artistSplitReg).map(normalize).where((s) => s.isNotEmpty).toList();

/// Track 全部歌手归一化
List<String> normalizeTrackArtists(Track track) =>
    track.artists.map((artist) => normalize(artist.name)).where((s) => s.isNotEmpty).toList();

/// 搜索关键词用全部歌手，减少平台返回同名异歌手候选
String buildLyricSearchKeyword(Track track) => [
      track.title,
      track.artists.map((artist) => artist.name).join(' '),
    ]
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join(' ');

/// 歌手是否有可用交集
({bool exact, bool contains}) _artistMatches(
  String? candidateArtist,
  List<String> trackArtists,
) {
  if (trackArtists.isEmpty) return (exact: false, contains: false);
  final candFull = normalize(candidateArtist);
  final candParts = _splitArtists(candidateArtist);
  if (candFull.isEmpty) return (exact: false, contains: false);
  final exact = trackArtists
      .any((artist) => candFull == artist || candParts.contains(artist));
  if (exact) return (exact: true, contains: false);
  final contains = trackArtists.any(
    (artist) =>
        artist.length >= 2 &&
        (_bothContains(candFull, artist) ||
            candParts.any((part) => _bothContains(part, artist))),
  );
  return (exact: false, contains: contains);
}

/// 时长是否在容差内（ms）
bool _durationClose(int? leftMs, int? rightMs, [int tolMs = 5000]) {
  if (leftMs == null || rightMs == null || leftMs == 0 || rightMs == 0) return false;
  return (leftMs - rightMs).abs() <= tolMs;
}

/// 时长差是否大到能确认"不是同一首"（ms）
bool _durationFar(int? leftMs, int? rightMs, [int tolMs = 20000]) {
  if (leftMs == null || rightMs == null || leftMs == 0 || rightMs == 0) return false;
  return (leftMs - rightMs).abs() > tolMs;
}

/// 子串命中时短串占长串的最低长度比，过低视为巧合
const double _nameContainMinRatio = 0.34;

/// 从候选列表里挑出最匹配 track 的那一个
///
/// 硬性条件（不满足直接跳过）
/// - name 全等，或双向 includes 且短串占长串比例 ≥ [_nameContainMinRatio]
/// - 双方都给了 duration 时，差距不能超过 20s
/// - track 有 artist 时，候选必须命中至少一个 artist，避免同名异歌手误匹配
///
/// 打分规则（分数越高越优先）
/// - name 全等：+10；name 子串命中：+4
/// - artist 全等：+5；artist 双向 includes：+2
/// - album 全等（且 track 有 album）：+2
/// - duration 接近（±5s）：+3
///
/// 兜底：所有候选 name 均不相关时（平台改曲名，如酷狗《あのね》实为
/// 《Connect the World》），在「歌手精确 + 时长接近」候选中选**时长最接近
/// track 且无并列**的那一个——时长是最强证据（同一作品各版本时长几乎
/// 一致）；并列时无法区分，保持 null（宁缺毋滥）。
LyricCandidate<E>? pickBestCandidate<E>(
  List<LyricCandidate<E>> candidates,
  Track track,
) {
  final trackName = normalize(track.title);
  final trackArtists = normalizeTrackArtists(track);
  final trackAlbum = normalize(track.album?.name);
  final trackDuration = track.duration;

  LyricCandidate<E>? best;
  var bestScore = 0;
  final fallbacks = <LyricCandidate<E>>[];

  for (final candidate in candidates) {
    final candName = normalize(candidate.name);
    final candAlbum = normalize(candidate.album);

    final nameExact = candName.isNotEmpty && candName == trackName;
    if (!nameExact) {
      if (!_bothContains(candName, trackName)) {
        // name 完全无关：仅「歌手精确 + 时长接近」双证据记兜底
        if (trackArtists.isNotEmpty &&
            _artistMatches(candidate.artist, trackArtists).exact &&
            _durationClose(candidate.duration, trackDuration)) {
          fallbacks.add(candidate);
        }
        continue;
      }
      final longer = candName.length > trackName.length ? candName.length : trackName.length;
      final shorter = candName.length < trackName.length ? candName.length : trackName.length;
      if (shorter / longer < _nameContainMinRatio) continue;
    }

    if (_durationFar(candidate.duration, trackDuration)) continue;

    final artist = _artistMatches(candidate.artist, trackArtists);
    if (trackArtists.isNotEmpty && !artist.exact && !artist.contains) continue;
    // 置信度地板：name 仅子串命中时必须有 artist 或时长佐证，否则视为巧合 substring 丢弃
    if (!nameExact &&
        !artist.exact &&
        !artist.contains &&
        !_durationClose(candidate.duration, trackDuration)) {
      continue;
    }

    var score = nameExact ? 10 : 4;
    if (artist.exact) {
      score += 5;
    } else if (artist.contains) {
      score += 2;
    }
    if (trackAlbum.isNotEmpty && candAlbum == trackAlbum) score += 2;
    if (_durationClose(candidate.duration, trackDuration)) score += 3;

    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }

  // name 全不命中时：双证据兜底（歌手精确 + 时长接近），取时长最接近且无并列者
  if (best == null && fallbacks.isNotEmpty) {
    LyricCandidate<E>? fb;
    var fbDiff = 1 << 62;
    var fbTie = false;
    for (final c in fallbacks) {
      final d = c.duration;
      if (d == null) continue;
      final diff = (d - trackDuration).abs();
      if (diff < fbDiff) {
        fbDiff = diff;
        fb = c;
        fbTie = false;
      } else if (diff == fbDiff) {
        fbTie = true;
      }
    }
    if (!fbTie && fb != null) best = fb;
  }
  return best;
}
