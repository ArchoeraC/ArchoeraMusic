/// 酷狗响应解析（KRC 歌词 + 歌单/榜单/搜索通用条目 → [Track]）。
///
/// 从 `kugou_api.dart` 拆出：纯解析函数，与网络请求/会话解耦，便于
/// 单测与复用。
library;

import 'dart:convert';
import 'dart:io';

import '../netease/track.dart';
import 'kugou_types.dart';

/// KRC 歌词密钥（lx-music kg.js）
const _krcKey = <int>[
  0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, //
  0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

/// 毫秒 → `MM:SS.xxx`（对齐 krc.ts msToTimeTag）。
String kgMsToTimeTag(int ms) {
  final m = (ms ~/ 60000).toString().padLeft(2, '0');
  final s = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
  final x = (ms % 1000).toString().padLeft(3, '0');
  return '$m:$s.$x';
}

/// 解析解密后的 KRC 文本 → 四种歌词（对齐 krc.ts parseKrc）。
KugouLyric kgParseKrc(String raw) {
  var text = raw.replaceAll('\r', '');
  // KRC 头部元数据行（[id:$]/[ar:]/[ti:]/[al:]/[by:]/[hash:]/[sign:]/
  // [qq:]/[total:]/[offset:]）整体移除——此前仅移除 [id:$] 行，其余
  // 残留进 lrc 文本污染行级解析。注意 [id:$xxxx] 值后直接 ']'（无冒号），
  // 故冒号部分可选。
  text = text.replaceAll(
    RegExp(
      r'^\[(?:id:\$\w+|ar|ti|al|by|hash|sign|qq|total|offset)(?::[^\]]*)?\](?:\r?\n)?',
      multiLine: true,
    ),
    '',
  );

  // 翻译 & 罗马音以 [language:base64(json)] 整体嵌入
  List<String>? transLines;
  List<String>? romaLines;
  final langMatch = RegExp(r'\[language:([\w=\\/+]+)\]').firstMatch(text);
  if (langMatch != null) {
    text = text.replaceAll(RegExp(r'\[language:[\w=\\/+]+\]\n'), '');
    try {
      final json = jsonDecode(utf8.decode(base64.decode(langMatch.group(1)!)));
      final content = json is Map ? json['content'] : null;
      if (content is List) {
        for (final item in content) {
          if (item is! Map) continue;
          final type = item['type'];
          final lc = item['lyricContent'];
          if (lc is! List) continue;
          final lines = lc
              .map((arr) => arr is List ? arr.join('') : arr.toString())
              .toList();
          if (type == 0) {
            romaLines = lines;
          } else if (type == 1) {
            transLines = lines;
          }
        }
      }
    } catch (_) {
      // 译文解析失败不影响主歌词
    }
  }

  // 逐行替换行首时间标签，并同步给翻译/罗马音补时间头
  var idx = 0;
  final krcBody = text.replaceAllMapped(RegExp(r'\[((\d+),\d+)\].*'), (m) {
    final startMs = int.parse(m.group(2)!);
    final tag = kgMsToTimeTag(startMs);
    if (romaLines != null && idx < romaLines.length) {
      romaLines[idx] = '[$tag]${romaLines[idx]}';
    }
    if (transLines != null && idx < transLines.length) {
      transLines[idx] = '[$tag]${transLines[idx]}';
    }
    idx++;
    return m.group(0)!.replaceFirst(m.group(1)!, tag);
  });

  // 字级时间标签 <offset,dur,0> → <offset,dur>
  final krc = kgDecodeName(
    krcBody.replaceAllMapped(
      RegExp(r'<(\d+,\d+),\d+>'),
      (m) => '<${m.group(1)}>',
    ),
  );
  final lrc = krc.replaceAll(RegExp(r'<\d+,\d+>'), '');

  return KugouLyric(
    lrc: lrc,
    krc: krc,
    trans: kgDecodeName(transLines?.join('\n') ?? ''),
    roma: kgDecodeName(romaLines?.join('\n') ?? ''),
  );
}

/// 解密 KRC base64 内容（base64 → 去头 4 字节 → XOR → zlib inflate → utf8）。
KugouLyric decodeKrc(String base64Content) {
  if (base64Content.isEmpty) throw const FormatException('empty krc content');
  final buf = base64.decode(base64Content).sublist(4);
  for (var i = 0; i < buf.length; i++) {
    buf[i] ^= _krcKey[i % 16];
  }
  final inflated = ZLibCodec().decode(buf);
  return kgParseKrc(utf8.decode(inflated, allowMalformed: true));
}

/// 秒/毫秒双兼容时长：KG 各接口字段单位不统一（time_length/timelen/
/// timelength 有 s 也有 ms），值 < 1000 按秒处理。返回毫秒。
int kgDurationMs(Object? raw) {
  if (raw == null) return 0;
  final v = raw is num ? raw.toInt() : int.tryParse(raw.toString()) ?? 0;
  return v < 1000 ? v * 1000 : v;
}

/// 歌单条目 `name`（形如 "歌手 - 歌名.mp3"）需剥离的音频扩展名。
const _kgAudioExts = <String>{
  'mp3',
  'flac',
  'm4a',
  'aac',
  'ogg',
  'ape',
  'wav',
  'wma',
  'ac3',
  'aiff',
  'alac',
  'opus',
};

/// 歌单条目 id：hash（音频文件级唯一键）优先，audio_id 仅作兜底，
/// 保证每首歌 id 唯一（历史去重/红心匹配依赖；与 Track.fromKugouSong 一致）。
String kgTrackId(Map<String, dynamic> item, String hash) {
  if (hash.isNotEmpty) return hash;
  final audioId = item['audio_id'];
  if (audioId is num && audioId > 0) return audioId.toString();
  return '';
}

/// 从「歌单/榜单/推荐/搜索」通用条目结构构建 [Track]（source == 'kugou'）。
///
/// 兼容字段别名（对齐 MoeKoeMusic formatPlaylistTracks 等映射）：
/// - 名称：`songname` / `ori_audio_name` / `audio_name` / `name`（"歌手 - 歌名"合并名拆分）
/// - 歌手：`author_name` / `singername`
/// - 封面：`trans_param.union_cover` / `sizable_cover` / `cover`（含 {size} 占位）
/// - 品质：`hash` + `320hash`/`sqhash`/`hires_hash`，或 `hash_320`/`hash_flac`/`hash_flac_24bit`
Track kgTrackFromKgPlain(Map<String, dynamic> item) {
  final hash = item['hash']?.toString() ?? '';
  var name =
      item['songname']?.toString() ??
      item['ori_audio_name']?.toString() ??
      item['audio_name']?.toString() ??
      '';
  // 歌手：优先 singerinfo 列表（歌单/榜单条目格式，如「我喜欢」歌单）
  var author = '';
  final singerInfo = item['singerinfo'];
  if (singerInfo is List && singerInfo.isNotEmpty) {
    author = singerInfo
        .whereType<Map<String, dynamic>>()
        .map((s) => s['name']?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .join(' / ');
  }
  if (author.isEmpty) {
    author =
        item['author_name']?.toString() ?? item['singername']?.toString() ?? '';
  }
  final merged = item['name']?.toString() ?? '';
  if (name.isEmpty && merged.isNotEmpty) {
    // 合并名形如 "歌手 - 歌名.mp3"：剥离音频扩展名后按 " - " 拆分
    var m = merged;
    final dot = m.lastIndexOf('.');
    if (dot > 0 && dot > m.lastIndexOf(' ')) {
      final ext = m.substring(dot + 1).toLowerCase();
      if (_kgAudioExts.contains(ext)) m = m.substring(0, dot);
    }
    final idx = m.indexOf(' - ');
    if (idx > 0) {
      name = m.substring(idx + 3);
      if (author.isEmpty) author = m.substring(0, idx);
    } else {
      name = m;
    }
  }
  String? coverTpl;
  final tp = item['trans_param'];
  if (tp is Map) coverTpl = tp['union_cover']?.toString();
  coverTpl ??= item['sizable_cover']?.toString() ?? item['cover']?.toString();

  final hashes = <String, String>{};
  final sizes = <String, int>{};
  if (hash.isNotEmpty) hashes['128k'] = hash;
  void add(String key, Object? h, Object? s) {
    final hs = h?.toString() ?? '';
    if (hs.isEmpty) return;
    hashes[key] = hs;
    final sz = s is num
        ? s.toInt()
        : (s != null ? int.tryParse(s.toString()) : null);
    if (sz != null && sz > 0) sizes[key] = sz;
  }

  add('320k', item['320hash'] ?? item['hash_320'], item['320filesize']);
  add('flac', item['sqhash'] ?? item['hash_flac'], item['sqfilesize']);
  add(
    'flac24bit',
    item['hires_hash'] ?? item['hash_flac_24bit'] ?? item['hash_hires'],
    item['hires_filesize'],
  );

  String? albumName;
  final ai = item['albuminfo'];
  if (ai is Map) albumName = ai['name']?.toString();
  albumName ??= item['album_name']?.toString();

  // 私有歌单条目附加信息（「我喜欢」移除需要 fileid；添加需要 album_id/mixsongid；
  // sort 为收藏序号，越小越早——「我喜欢」按此升序展示，与酷狗 App 一致）
  final fileid = item['fileid'];
  final albumId = item['album_id'];
  final mixSongId = item['mixsongid'];
  final sort = item['sort'];

  return Track(
    id: kgTrackId(item, hash),
    title: kgDecodeName(name),
    artists: author.isEmpty ? const [] : kugouArtists(author),
    album: albumName == null || albumName.isEmpty
        ? null
        : TrackAlbum(
            name: kgDecodeName(albumName),
            cover: kgFillCover(coverTpl, 300),
          ),
    duration: kgDurationMs(
      item['time_length'] ??
          item['timelen'] ??
          item['timelength'] ??
          item['duration'],
    ),
    cover: kgFillCover(coverTpl, 300),
    source: 'kugou',
    // 原唱标识（MoeKoeMusic `Number(IsOriginal) === 1`）+ 版权
    // privilege == 10 → VIP（对齐 MoeKoeMusic PlaylistDetail）
    isOriginal: _kgIsOriginal(item['IsOriginal'] ?? item['isOriginal']),
    fee: _kgFee(item['privilege']),
    kugou: hashes.isEmpty
        ? null
        : KugouTrackInfo(
            hash: hash,
            hashes: hashes,
            sizes: sizes,
            fileid: fileid is num
                ? fileid.toInt()
                : (fileid != null ? int.tryParse('$fileid') : null),
            albumId: albumId is num
                ? albumId.toInt()
                : (albumId != null ? int.tryParse('$albumId') : null),
            mixSongId: mixSongId is num
                ? mixSongId.toInt()
                : (mixSongId != null ? int.tryParse('$mixSongId') : null),
            sort: sort is num
                ? sort.toInt()
                : (sort != null ? int.tryParse('$sort') : null),
          ),
  );
}

/// 酷狗 `IsOriginal`（1=原唱）→ bool；兼容数字与字符串。
bool _kgIsOriginal(Object? raw) {
  if (raw == null) return false;
  if (raw is num) return raw.toInt() == 1;
  return raw.toString() == '1' || raw.toString().toLowerCase() == 'true';
}

/// 酷狗版权 `privilege` → TrackFee（10=VIP 需会员；其余视作免费）。
int _kgFee(Object? raw) {
  if (raw == null) return 0;
  final v = raw is num ? raw.toInt() : int.tryParse(raw.toString()) ?? 0;
  return v == 10 ? 1 : 0;
}
