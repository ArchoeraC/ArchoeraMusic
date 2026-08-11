/// 搜索歌曲（KG，对齐 search.ts）
///
/// 主路径 mobilecdn.kugou.com（带封面），兜底 songsearch.kugou.com（无封面）。
/// 返回结构沿用 qqmusic.search（duration 为毫秒），并带 KG 特有 hash + 多品质 sizes/hashes。
library;

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';

/// trans_param.union_cover 含 `{size}` 占位，按需替换
String? _fillCover(String? url, int size) {
  if (url == null || url.isEmpty) return null;
  return url.replaceAll('{size}', '$size');
}

/// singername 是 "A、B" / "A,B" 形式的字符串，规范成 "A / B"
String _formatMobileArtist(String? name) {
  if (name == null || name.isEmpty) return '';
  return kgDecodeName(name)
      .split(RegExp(r'、|,|;|/'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .join(' / ');
}

Map<String, dynamic> _normalizeFromMobile(Map<String, dynamic> raw) {
  final sizes = <String, int>{};
  final hashes = <String, String>{};

  final filesize = raw['filesize'];
  final hash = raw['hash'];
  if (filesize != null && hash != null) {
    sizes['128k'] = (filesize as num).toInt();
    hashes['128k'] = '$hash';
  }
  final s320size = raw['320filesize'];
  final s320hash = raw['320hash'];
  if (s320size != null && s320hash != null) {
    sizes['320k'] = (s320size as num).toInt();
    hashes['320k'] = '$s320hash';
  }
  final sqSize = raw['sqfilesize'];
  final sqHash = raw['sqhash'];
  if (sqSize != null && sqHash != null) {
    sizes['flac'] = (sqSize as num).toInt();
    hashes['flac'] = '$sqHash';
  }
  final hrSize = raw['hires_filesize'] ?? raw['resfilesize'];
  final hrHash = raw['hires_hash'] ?? raw['reshash'];
  if (hrSize != null && hrHash != null) {
    sizes['flac24bit'] = (hrSize as num).toInt();
    hashes['flac24bit'] = '$hrHash';
  }

  final interval = (raw['duration'] as num?)?.toInt() ?? 0;
  final tp = raw['trans_param'];
  final coverTpl = tp is Map ? tp['union_cover'] as String? : null;
  return {
    'id': '${raw['audio_id'] ?? ''}',
    'audioId': (raw['audio_id'] as num?)?.toInt() ?? 0,
    'hash': hash ?? '',
    'name': kgDecodeName('${raw['songname'] ?? raw['filename'] ?? ''}'),
    'artist': _formatMobileArtist(raw['singername'] as String?),
    'album': kgDecodeName('${raw['album_name'] ?? ''}'),
    'albumId': raw['album_id'] ?? '',
    'cover': _fillCover(coverTpl, 300),
    'coverOriginal': _fillCover(coverTpl, 480),
    'interval': interval,
    'duration': interval * 1000,
    'qualities': hashes.keys.toList(),
    'hashes': hashes,
    'sizes': sizes,
  };
}

Future<Map<String, dynamic>> _searchSongsMobile(String keywords, int page, int limit) async {
  final url = '$kgMobilecdnUrl?keyword=${Uri.encodeComponent(keywords)}'
      '&page=$page&pagesize=$limit&format=json&showtype=1';
  final body = await kgRequest(url);
  final data = body['data'];
  final raw = data is Map ? (data['info'] as List? ?? const []) : const [];

  final songs = <Map<String, dynamic>>[];
  final seen = <String>{};
  void push(Map<String, dynamic> item) {
    final key = '${item['audio_id'] ?? ''}_${item['hash'] ?? ''}';
    if (seen.contains(key)) return;
    seen.add(key);
    songs.add(_normalizeFromMobile(item));
  }

  for (final item in raw) {
    final m = item as Map<String, dynamic>;
    push(m);
    for (final sub in (m['group'] as List? ?? const [])) {
      push((sub as Map).cast<String, dynamic>());
    }
  }

  return {
    'code': 200,
    'total': data is Map ? (data['total'] ?? songs.length) : songs.length,
    'songs': songs,
  };
}

Map<String, dynamic> _normalizeFromLegacy(Map<String, dynamic> raw) {
  final sizes = <String, int>{};
  final hashes = <String, String>{};

  final fileSize = raw['FileSize'];
  final fileHash = raw['FileHash'];
  if (fileSize != null) {
    sizes['128k'] = (fileSize as num).toInt();
    hashes['128k'] = '$fileHash';
  }
  final hqSize = raw['HQFileSize'];
  final hqHash = raw['HQFileHash'];
  if (hqSize != null && hqHash != null) {
    sizes['320k'] = (hqSize as num).toInt();
    hashes['320k'] = '$hqHash';
  }
  final sqSize = raw['SQFileSize'];
  final sqHash = raw['SQFileHash'];
  if (sqSize != null && sqHash != null) {
    sizes['flac'] = (sqSize as num).toInt();
    hashes['flac'] = '$sqHash';
  }
  final resSize = raw['ResFileSize'];
  final resHash = raw['ResFileHash'];
  if (resSize != null && resHash != null) {
    sizes['flac24bit'] = (resSize as num).toInt();
    hashes['flac24bit'] = '$resHash';
  }

  final duration = (raw['Duration'] as num?)?.toInt() ?? 0;
  return {
    'id': '${raw['Audioid'] ?? ''}',
    'audioId': (raw['Audioid'] as num?)?.toInt() ?? 0,
    'hash': fileHash ?? '',
    'name': kgDecodeName('${raw['SongName'] ?? ''}'),
    'artist': kgFormatSingerName(raw['Singers'] as List?),
    'album': kgDecodeName('${raw['AlbumName'] ?? ''}'),
    'albumId': raw['AlbumID'] ?? '',
    'cover': null,
    'interval': duration,
    'duration': duration * 1000,
    'qualities': hashes.keys.toList(),
    'hashes': hashes,
    'sizes': sizes,
  };
}

Future<Map<String, dynamic>> _searchSongsLegacy(String keywords, int page, int limit) async {
  final url = '$kgSearchUrl?keyword=${Uri.encodeComponent(keywords)}'
      '&page=$page&pagesize=$limit'
      '&userid=0&clientver=&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1';
  final body = await kgRequest(url);
  final data = body['data'];
  final raw = data is Map ? (data['lists'] as List? ?? const []) : const [];

  final songs = <Map<String, dynamic>>[];
  final seen = <String>{};
  void push(Map<String, dynamic> item) {
    final key = '${item['Audioid']}_${item['FileHash']}';
    if (seen.contains(key)) return;
    seen.add(key);
    songs.add(_normalizeFromLegacy(item));
  }

  for (final item in raw) {
    final m = item as Map<String, dynamic>;
    push(m);
    for (final sub in (m['Grp'] as List? ?? const [])) {
      push((sub as Map).cast<String, dynamic>());
    }
  }

  return {
    'code': 200,
    'total': data is Map ? (data['total'] ?? songs.length) : songs.length,
    'songs': songs,
  };
}

KgModule kgSearch = (params) async {
  final keywords = params['keywords'] as String?;
  final page = (params['page'] as num?)?.toInt() ?? 1;
  final limit = (params['limit'] as num?)?.toInt() ?? 30;

  if (keywords == null || keywords.isEmpty) {
    return {'code': 400, 'total': 0, 'songs': <Map<String, dynamic>>[], 'message': 'keywords required'};
  }

  // mobilecdn 抛错或空结果都兜底到 songsearch
  try {
    final result = await _searchSongsMobile(keywords, page, limit);
    if ((result['songs'] as List).isNotEmpty) return result;
  } catch (err) {
    // 兜底
  }
  return _searchSongsLegacy(keywords, page, limit);
};
