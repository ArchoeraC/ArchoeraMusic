// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

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

/// B 站等视频源的标题清洗：去掉【…】/[…] 包装、常见「官方MV / 完整版」修饰，
/// 优先取《…》里的歌名，便于拿歌名去其它平台模糊匹配歌词。
///
/// 例：
/// - `【原创曲】为女则刚！原创歌曲《女也》完整版` → `女也`
/// - `【4K修复】《晴天》官方MV` → `晴天`
/// - `【MV】七里香（完整版）` → `七里香`
String bilibiliLyricTitle(String raw) {
  var title = raw.trim();
  if (title.isEmpty) return title;

  // 中文书名号通常就是歌名；多条时取最后一条（「《影视/企划》主题曲《歌名》」
  // 的常见写法里歌名在后）。
  final names = RegExp(r'《([^《》]{1,80})》')
      .allMatches(title)
      .map((m) => m.group(1)!.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (names.isNotEmpty) return names.last;

  // 去掉成对标签：`【…】`、`[…]`、带修饰词的 `(…)`。
  title = title.replaceAll(RegExp(r'【[^】]{0,60}】'), ' ');
  title = title.replaceAll(RegExp(r'\[[^\]]{0,60}\]'), ' ');
  title = title.replaceAll(
    RegExp(
      r'[（(][^（）()]{0,40}(?:官方|完整版|高清|无损|hi-?res|4k|8k|1080p|720p|mv|live|现场|动态歌词|歌词版|纯享|加长|翻唱|cover)[^（）()]{0,20}[）)]',
      caseSensitive: false,
    ),
    ' ',
  );
  // 尾部裸露的修饰词（含前导分隔符）。
  title = title.replaceAll(
    RegExp(
      r'(?:\s*[-—|·]\s*)?(?:官方\s*)?(?:mv|完整版|高清|无损|hi-?res|4k|8k|1080p|720p|动态歌词|歌词版|纯享版?|加长版?|现场版?|翻唱|cover)\s*$',
      caseSensitive: false,
    ),
    '',
  );
  title = title.replaceAll(RegExp(r'^[\s\-—|/·、,，]+|[\s\-—|/·、,，]+$'), '');
  return title.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 歌词模糊匹配用的标题：视频源先做包装信息清洗，其余源用原曲名。
String lyricSearchTitle(Track track) =>
    track.source == 'bilibili' ? bilibiliLyricTitle(track.title) : track.title;

/// 搜索关键词：视频源只取清洗后的歌名（UP 主名常不是演唱者，带上反而降低命中），
/// 其余源用「曲名 + 全部歌手」。
String buildLyricSearchKeyword(Track track) {
  final title = lyricSearchTitle(track);
  final artist =
      track.source == 'bilibili' ? '' : track.artists.map((a) => a.name).join(' ');
  return [title, artist]
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .join(' ');
}

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
/// 兜底：所有候选 name 均不相关时（平台改曲名，如KG《あのね》实为
/// 《Connect the World》），在「歌手精确 + 时长接近」候选中选**时长最接近
/// track 且无并列**的那一个——时长是最强证据（同一作品各版本时长几乎
/// 一致）；并列时无法区分，保持 null（宁缺毋滥）。
LyricCandidate<E>? pickBestCandidate<E>(
  List<LyricCandidate<E>> candidates,
  Track track,
) {
  // 视频源（B 站）的歌名常带包装信息，且 UP 主不一定是演唱者：
  // 用清洗后的歌名比较，并放宽歌手硬性条件（仍作为加分项）。
  final isVideoSource = track.source == 'bilibili';
  final trackName = normalize(lyricSearchTitle(track));
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
    if (!isVideoSource &&
        trackArtists.isNotEmpty &&
        !artist.exact &&
        !artist.contains) {
      continue;
    }
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
