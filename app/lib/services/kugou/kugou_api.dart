/// 酷狗 API 封装（Dart 直连，对齐 apis/kugou + KuGouMusicApi）。
///
/// - 搜索：mobilecdn.kugou.com（带封面，http）→ 兜底 songsearch.kugou.com
/// - 取 URL：gateway.kugou.com/v5/url（android 签名 + key + 真实 dfid）
///   [dfid] 进程级缓存，status=2（需验证）时重新 register_dev 重试一次
/// - 歌词：lyrics.kugou.com 两步走（search → download），krc 用
///   XOR+zlib 解码（对齐 lx-music 的 KRC 逻辑）
///
/// 音质切换：按 SPlayer-Next 档位（lq/sq/hq/lossless/hi-res）映射 KG 品质
/// 链（128k/320k/flac/flac24bit），命中档位缺 hash 或请求失败时自动降级。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../apis/runtime.dart';
import '../netease/netease_api.dart' show CoverItem, SearchResult;
import '../netease/track.dart';
import 'kugou_crypto.dart';
import 'kugou_request.dart';

/// KRC 歌词密钥（lx-music kg.js）
const _krcKey = <int>[
  0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, //
  0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

/// 歌词结果（lrc 行级 + krc 逐字 + 翻译 + 罗马音）。
class KugouLyric {
  const KugouLyric({required this.lrc, this.krc = '', this.trans = '', this.roma = ''});

  final String lrc;
  final String krc;
  final String trans;
  final String roma;
}

/// 酷狗歌曲评论（commentsv2/getCommentWithLike 条目）。
class KugouComment {
  const KugouComment({
    required this.id,
    required this.userName,
    required this.text,
    this.avatar,
    this.location,
    this.likedCount = 0,
    this.replyTotal = 0,
    this.timeMs,
    this.reply = const [],
  });

  final String id;
  final String userName;
  final String? avatar;
  final String text;

  /// IP 属地（如「河南」）。
  final String? location;
  final int likedCount;
  final int replyTotal;

  /// 评论时间（毫秒；addtime 'YYYY-MM-DD HH:MM:SS' 解析失败为 null）。
  final int? timeMs;

  /// 被回复的引用内容（replys 首个）。
  final List<KugouComment> reply;
}

/// 酷狗歌曲评论分页。
class KugouCommentPage {
  const KugouCommentPage({
    required this.list,
    required this.total,
    required this.page,
    required this.limit,
  });

  final List<KugouComment> list;
  final int total;
  final int page;
  final int limit;

  bool get hasMore => page * limit < total && list.isNotEmpty;
}

/// 评论条目 → [KugouComment]（点赞取 `like.likenum`；`addtime` 字符串转
/// 毫秒；`replys` 首个递归解析为引用回复）。
KugouComment _commentFromKg(Map<String, dynamic> c) {
  final like = c['like'];
  final liked = like is Map ? (like['likenum'] as num?)?.toInt() ?? 0 : 0;
  final replys = c['replys'];
  final replies = replys is List
      ? replys
          .whereType<Map<String, dynamic>>()
          .take(1)
          .map(_commentFromKg)
          .toList()
      : const <KugouComment>[];
  return KugouComment(
    id: c['id']?.toString() ?? c['pid']?.toString() ?? '',
    userName: c['user_name']?.toString() ?? '匿名用户',
    avatar: c['user_pic']?.toString(),
    text: c['content']?.toString() ?? '',
    location: c['location']?.toString(),
    likedCount: liked,
    replyTotal: (c['reply_num'] as num?)?.toInt() ?? 0,
    timeMs:
        DateTime.tryParse(c['addtime']?.toString() ?? '')?.millisecondsSinceEpoch,
    reply: replies,
  );
}

/// 毫秒 → `MM:SS.xxx`（对齐 krc.ts msToTimeTag）。
String _msToTimeTag(int ms) {
  final m = (ms ~/ 60000).toString().padLeft(2, '0');
  final s = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
  final x = (ms % 1000).toString().padLeft(3, '0');
  return '$m:$s.$x';
}

/// 解析解密后的 KRC 文本 → 四种歌词（对齐 krc.ts parseKrc）。
KugouLyric _parseKrc(String raw) {
  var text = raw.replaceAll('\r', '');
  // KRC 头部元数据行（[id:$]/[ar:]/[ti:]/[al:]/[by:]/[hash:]/[sign:]/
  // [qq:]/[total:]/[offset:]）整体移除——此前仅移除 [id:$] 行，其余
  // 残留进 lrc 文本污染行级解析。注意 [id:$xxxx] 值后直接 ']'（无冒号），
  // 故冒号部分可选。
  text = text.replaceAll(
      RegExp(r'^\[(?:id:\$\w+|ar|ti|al|by|hash|sign|qq|total|offset)(?::[^\]]*)?\](?:\r?\n)?',
          multiLine: true),
      '');

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
  final krcBody = text.replaceAllMapped(
    RegExp(r'\[((\d+),\d+)\].*'),
    (m) {
      final startMs = int.parse(m.group(2)!);
      final tag = _msToTimeTag(startMs);
      if (romaLines != null && idx < romaLines.length) {
        romaLines[idx] = '[$tag]${romaLines[idx]}';
      }
      if (transLines != null && idx < transLines.length) {
        transLines[idx] = '[$tag]${transLines[idx]}';
      }
      idx++;
      return m.group(0)!.replaceFirst(m.group(1)!, tag);
    },
  );

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
  return _parseKrc(utf8.decode(inflated, allowMalformed: true));
}

/// 秒/毫秒双兼容时长：KG 各接口字段单位不统一（time_length/timelen/
/// timelength 有 s 也有 ms），值 < 1000 按秒处理。返回毫秒。
int _kgDurationMs(Object? raw) {
  if (raw == null) return 0;
  final v = raw is num ? raw.toInt() : int.tryParse(raw.toString()) ?? 0;
  return v < 1000 ? v * 1000 : v;
}

/// 歌单条目 `name`（形如 "歌手 - 歌名.mp3"）需剥离的音频扩展名。
const _kgAudioExts = <String>{
  'mp3', 'flac', 'm4a', 'aac', 'ogg', 'ape', 'wav', 'wma', 'ac3', 'aiff',
  'alac', 'opus',
};

/// 歌单条目 id：hash（音频文件级唯一键）优先，audio_id 仅作兜底，
/// 保证每首歌 id 唯一（历史去重/红心匹配依赖；与 Track.fromKugouSong 一致）。
String _kgTrackId(Map<String, dynamic> item, String hash) {
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
Track _trackFromKgPlain(Map<String, dynamic> item) {
  final hash = item['hash']?.toString() ?? '';
  var name = item['songname']?.toString() ??
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
    author = item['author_name']?.toString() ??
        item['singername']?.toString() ??
        '';
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
    final sz =
        s is num ? s.toInt() : (s != null ? int.tryParse(s.toString()) : null);
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
    id: _kgTrackId(item, hash),
    title: kgDecodeName(name),
    artists: author.isEmpty ? const [] : kugouArtists(author),
    album: albumName == null || albumName.isEmpty
        ? null
        : TrackAlbum(
            name: kgDecodeName(albumName),
            cover: kgFillCover(coverTpl, 300),
          ),
    duration: _kgDurationMs(item['time_length'] ??
        item['timelen'] ??
        item['timelength'] ??
        item['duration']),
    cover: kgFillCover(coverTpl, 300),
    source: 'kugou',
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

/// 酷狗登录会话（扫码登录成功后的 token/userid，v5/url 请求 VIP 曲目用）。
class KugouSession {
  const KugouSession({
    required this.token,
    required this.userid,
    this.nickname,
    this.avatarUrl,
  });

  final String token;
  final String userid;
  final String? nickname;

  /// 用户头像（user_detail 接口 data.pic；未获取到为 null）。
  final String? avatarUrl;

  Map<String, String> toJson() => {
        'token': token,
        'userid': userid,
        'nickname': ?nickname,
        'avatarUrl': ?avatarUrl,
      };

  factory KugouSession.fromJson(Map<String, dynamic> json) => KugouSession(
        token: json['token']?.toString() ?? '',
        userid: json['userid']?.toString() ?? '',
        nickname: json['nickname']?.toString(),
        avatarUrl: json['avatarUrl']?.toString(),
      );

  @override
  String toString() => 'KugouSession(userid=$userid, nickname=$nickname)';
}

/// 会话在宿主会话存储中的平台键。
const _kugouSessionPlatform = 'kugou';

/// 酷狗 API 封装。
class KugouApi extends ChangeNotifier {
  KugouApi() {
    session = _restoreSession();
    // 启动恢复会话时异步补齐头像/昵称（旧会话可能未存 avatarUrl）
    if (session != null) {
      unawaited(refreshUserInfo());
    }
  }

  /// 进程级设备标识（register_dev 返回；v5/url 前置条件，随机 dfid
  /// 会被服务端拒为「需要验证」）。
  String? _dfid;

  /// 进程级设备 MID（v5/url 签名用）。
  late final String _mid = kgCalcMid(kgRandomString(16));

  /// 登录会话（扫码成功 → token/userid；v5/url 注入后即可拿 VIP 曲目）。
  KugouSession? session;

  /// 是否已登录。
  bool get isLoggedIn => session != null;

  /// 从宿主会话存储恢复（跨重启保留登录态）。
  KugouSession? _restoreSession() {
    final saved = getRuntime().sessionStore.get(_kugouSessionPlatform);
    if (saved.isEmpty) return null;
    final session = KugouSession.fromJson(saved);
    if (session.token.isEmpty || session.userid.isEmpty) return null;
    return session;
  }

  /// 保存登录会话（扫码成功后调用；落盘到宿主会话存储，重启保留）。
  void saveSession(String token, String userid, {String? nickname}) {
    session = KugouSession(token: token, userid: userid, nickname: nickname);
    _likeListId = null;
    getRuntime()
        .sessionStore
        .save(_kugouSessionPlatform, session!.toJson());
    notifyListeners();
  }

  /// 拉取用户详情并更新会话（user_detail：nickname / avatarUrl）。
  /// 登录后或启动恢复会话后调用；失败静默（头像回退昵称首字）。
  Future<void> refreshUserInfo() async {
    final current = session;
    if (current == null) return;
    try {
      final info = await kgGetMyInfo(
        token: current.token,
        userid: current.userid,
        dfid: await _getDfid(),
        mid: _mid,
      );
      final pic = info['pic']?.toString();
      final nick = info['nickname']?.toString();
      if ((pic == null || pic.isEmpty) &&
          (nick == null || nick.isEmpty)) {
        return; // 无有效更新
      }
      session = KugouSession(
        token: current.token,
        userid: current.userid,
        nickname: nick == null || nick.isEmpty ? current.nickname : nick,
        avatarUrl: pic == null || pic.isEmpty ? current.avatarUrl : pic,
      );
      getRuntime()
          .sessionStore
          .save(_kugouSessionPlatform, session!.toJson());
      notifyListeners();
    } catch (_) {
      // 头像获取失败不影响播放功能，静默
    }
  }

  /// 清除登录会话。
  void clearSession() {
    session = null;
    _likeListId = null;
    getRuntime().sessionStore.clear(_kugouSessionPlatform);
    notifyListeners();
  }

  Future<String> _getDfid() async {
    final cached = _dfid;
    if (cached != null) return cached;
    _dfid = await kgRegisterDevice(mid: _mid);
    return _dfid!;
  }

  // ─── 扫码登录 ─────────────────────────────────────────────────────

  /// 生成登录二维码 key（UI 用它拼 `$kgQrLoginPage?qrcode=$key` 出图）。
  Future<String> qrKey() => kgQrKey(mid: _mid);

  /// 轮询扫码状态。返回 {status, token, userid, nickname}：
  /// 0=过期 / 1=等待 / 2=待确认 / 4=成功（成功后调用 [saveSession]）。
  Future<Map<String, dynamic>> qrCheck(String key) =>
      kgQrCheck(key, mid: _mid);

  // ─── 搜索 ─────────────────────────────────────────────────────────

  /// 搜索歌曲（mobilecdn → 兜底 songsearch）。
  ///
  /// 返回 [Track]（source == 'kugou'，含 kugou 品质信息）。
  Future<SearchResult<Track>> searchSongs(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    if (keyword.isEmpty) {
      return SearchResult(items: const [], total: 0, hasMore: false);
    }
    try {
      final result = await _searchMobile(keyword, page, limit);
      if (result.items.isNotEmpty) return result;
    } catch (_) {
      // 主路径失败，兜底旧接口
    }
    return _searchLegacy(keyword, page, limit);
  }

  /// 下载前补齐酷狗 hash 链：按 title 重新 mobilecdn 搜索，把匹配条目的
  /// 高音质 hash（320k/flac/flac24bit）合并进 [track]（原 hash 优先，缺档补上）。
  /// 历史/收藏/歌单等入口恢复的旧 Track 可能只有 128k hash，直接下载会被
  /// 静默降级；此方法保证下载能用上最高可用音质。已完整或无匹配返回 null。
  Future<Track?> enrichKugouHashes(Track track) async {
    final kugou = track.kugou;
    if (kugou == null || track.title.trim().isEmpty) return null;
    const wanted = ['flac24bit', 'flac', '320k', '128k'];
    if (wanted.every((k) => (kugou.hashes[k] ?? '').isNotEmpty)) return null;

    final result = await searchSongs(track.title.trim(), page: 1, limit: 20);
    Track? best;
    final curHash = kugou.hash.toLowerCase();
    final curId = track.id.toLowerCase();
    // 1) 音频级 hash 精确匹配（最稳，不会下错版本）
    for (final t in result.items) {
      final info = t.kugou;
      if (info == null) continue;
      final h = info.hash.toLowerCase();
      if (h.isNotEmpty && (h == curHash || h == curId)) {
        best = t;
        break;
      }
    }
    // 2) 标题 + 歌手规范化匹配（原 hash 可能来自旧数据源/不同接口）
    if (best == null) {
      String norm(String s) => s.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      final nt = norm(track.title);
      final na = norm(track.artistNames);
      for (final t in result.items) {
        if (t.kugou == null) continue;
        if (norm(t.title) == nt && norm(t.artistNames) == na) {
          best = t;
          break;
        }
      }
    }
    final src = best?.kugou;
    if (best == null || src == null) return null;

    final newHashes = <String, String>{};
    final newSizes = <String, int>{};
    for (final k in wanted) {
      final old = kugou.hashes[k];
      newHashes[k] =
          (old != null && old.isNotEmpty) ? old : (src.hashes[k] ?? '');
      final os = kugou.sizes[k];
      newSizes[k] = (os != null && os > 0) ? os : (src.sizes[k] ?? 0);
    }
    final info = KugouTrackInfo(
      hash: kugou.hash,
      hashes: newHashes,
      sizes: newSizes,
      fileid: kugou.fileid,
      albumId: kugou.albumId,
      mixSongId: kugou.mixSongId,
      sort: kugou.sort,
    );
    return track.copyWithKugou(info);
  }

  Future<SearchResult<Track>> _searchMobile(
    String keyword,
    int page,
    int limit,
  ) async {
    final uri = Uri.parse(kgMobilecdnUrl).replace(queryParameters: {
      'keyword': keyword,
      'page': '$page',
      'pagesize': '$limit',
      'format': 'json',
      'showtype': '1',
    });
    final body = await kgGet(uri);
    final data = body is Map<String, dynamic> ? body['data'] : null;
    final info = data is Map<String, dynamic> ? data['info'] : null;
    final raw = info is List ? info : const [];
    final total = (data is Map<String, dynamic> ? data['total'] : null);
    final totalNum =
        total is num ? total.toInt() : (total != null ? int.tryParse(total.toString()) ?? 0 : 0);

    final items = <Track>[];
    final seen = <String>{};
    void push(Map<String, dynamic> song) {
      final key = '${song['audio_id']}_${song['hash']}';
      if (seen.contains(key)) return;
      seen.add(key);
      items.add(Track.fromKugouSong(song));
    }

    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      push(item);
      final group = item['group'];
      if (group is List) {
        for (final sub in group) {
          if (sub is Map<String, dynamic>) push(sub);
        }
      }
    }
    return SearchResult(
      items: items,
      total: totalNum > 0 ? totalNum : items.length,
      hasMore: items.length >= limit,
    );
  }

  Future<SearchResult<Track>> _searchLegacy(
    String keyword,
    int page,
    int limit,
  ) async {
    final uri = Uri.parse(kgSearchUrl).replace(queryParameters: {
      'keyword': keyword,
      'page': '$page',
      'pagesize': '$limit',
      'userid': '0',
      'clientver': '',
      'platform': 'WebFilter',
      'filter': '2',
      'iscorrection': '1',
      'privilege_filter': '0',
      'area_code': '1',
    });
    final body = await kgGet(uri);
    final data = body is Map<String, dynamic> ? body['data'] : null;
    final lists = data is Map<String, dynamic> ? data['lists'] : null;
    final raw = lists is List ? lists : const [];
    final total = (data is Map<String, dynamic> ? data['total'] : null);
    final totalNum =
        total is num ? total.toInt() : (total != null ? int.tryParse(total.toString()) ?? 0 : 0);

    final items = <Track>[];
    final seen = <String>{};
    void push(Map<String, dynamic> song) {
      final key = '${song['Audioid']}_${song['FileHash']}';
      if (seen.contains(key)) return;
      seen.add(key);
      items.add(Track.fromKugouSong(song));
    }

    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      push(item);
      final grp = item['Grp'];
      if (grp is List) {
        for (final sub in grp) {
          if (sub is Map<String, dynamic>) push(sub);
        }
      }
    }
    return SearchResult(
      items: items,
      total: totalNum > 0 ? totalNum : items.length,
      hasMore: items.length >= limit,
    );
  }

  // ─── 取 URL（音质切换） ───────────────────────────────────────────

  /// 解析可播放 URL（gateway.kugou.com/v5/url）。
  ///
  /// [quality] 为 SPlayer-Next 档位（lq/sq/hq/lossless/hi-res），按
  /// KugouTrackInfo 品质链降级尝试；全部失败或无资源返回 null。
  Future<String?> resolvePlayUrl(
    KugouTrackInfo info, {
    String quality = 'hq',
  }) async {
    const chains = <String, List<String>>{
      'lq': ['128k'],
      'sq': ['320k', '128k'],
      'hq': ['320k', '128k'],
      'lossless': ['flac', '320k', '128k'],
      'hi-res': ['flac24bit', 'flac', '320k', '128k'],
    };
    for (final q in chains[quality] ?? const <String>[]) {
      final hash = info.hashes[q];
      final qualityParam = KugouTrackInfo.qualityParam(q);
      if (hash == null || hash.isEmpty || qualityParam == null) continue;
      try {
        final url = await _tryUrl(hash, qualityParam);
        if (url != null) return url;
      } catch (_) {
        // 网络错误继续降级
      }
    }
    return null;
  }

  /// 单档 URL 请求（dfid 用 register_dev 真实值，对齐 MoeKouMusic 后端
  /// 先 /register/dev 再 /song/url 的链路；status=2 需验证时换新 dfid
  /// 重试一次）。
  Future<String?> _tryUrl(String hash, String qualityParam,
      {bool retried = false}) async {
    final dfid = await _getDfid();
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final hashLc = hash.toLowerCase();

    final params = <String, dynamic>{
      ...kgSongUrlBase,
      'dfid': dfid,
      'mid': _mid,
      'uuid': '-',
      'appid': kgLiteAppid,
      'clienttime': ts,
      'hash': hashLc,
      'quality': qualityParam,
    };
    // 登录态注入 token/userid（对齐 request.js defaultParams：
    // `if (token) token; if (userid && userid !== 0) userid`）
    final uid = session?.userid ?? '';
    final token = session?.token ?? '';
    if (token.isNotEmpty) params['token'] = token;
    if (uid.isNotEmpty && uid != '0') params['userid'] = uid;
    params['key'] = kgSignKey(
      hashLc,
      _mid,
      int.tryParse(uid) ?? 0,
      kgLiteAppid,
      salt: kgLiteKeySalt,
    );
    params['signature'] = kgSignature(params, salt: kgLiteSignSalt);

    final uri = Uri.parse('$kgSongUrl?${kgQueryString(params)}');
    final body = await kgGet(uri, headers: {
      'User-Agent': kgAndroidUa,
      'x-router': 'trackercdn.kugou.com',
      'dfid': dfid,
      'clienttime': '$ts',
      'mid': _mid,
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
    });
    if (body is! Map<String, dynamic>) return null;

    final status = (body['status'] as num?)?.toInt() ?? 0;
    if (status == 1) {
      final urls = body['url'];
      if (urls is List && urls.isNotEmpty) {
        final first = urls.first?.toString() ?? '';
        if (first.isNotEmpty) return first;
      }
      return null;
    }
    if (status == 2 && !retried) {
      // 本次请求需要验证：重新注册拿新 dfid 再试一次
      _dfid = null;
      return _tryUrl(hashLc, qualityParam, retried: true);
    }
    return null;
  }

  // ─── 歌词 ─────────────────────────────────────────────────────────

  /// 歌词：hash + 歌名 + 时长（秒）三元组匹配（KG 特有）。
  Future<KugouLyric?> lyric({
    required String hash,
    String name = '',
    int? durationSeconds,
  }) async {
    final seconds = durationSeconds ?? 0;
    final searchUri = Uri.parse(kgLyricSearchUrl).replace(queryParameters: {
      'ver': '1',
      'man': 'yes',
      'client': 'pc',
      'lrctxt': '1',
      'keyword': name,
      'hash': hash,
      'timelength': '$seconds',
    });
    final searchResp = await kgGet(searchUri, headers: kgLyricHeaders);
    if (searchResp is! Map<String, dynamic>) return null;
    final candidates = searchResp['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final cand = candidates.first;
    if (cand is! Map<String, dynamic>) return null;

    final id = cand['id']?.toString() ?? '';
    final accesskey = cand['accesskey']?.toString() ?? '';
    if (id.isEmpty || accesskey.isEmpty) return null;
    final krctype = (cand['krctype'] as num?)?.toInt() ?? 0;
    final contenttype = (cand['contenttype'] as num?)?.toInt() ?? 0;
    final fmt = krctype == 1 && contenttype != 1 ? 'krc' : 'lrc';

    final dlUri = Uri.parse(kgLyricDownloadUrl).replace(queryParameters: {
      'ver': '1',
      'client': 'pc',
      'charset': 'utf8',
      'id': id,
      'accesskey': accesskey,
      'fmt': fmt,
    });
    final dl = await kgGet(dlUri, headers: kgLyricHeaders);
    if (dl is! Map<String, dynamic>) return null;
    final content = dl['content']?.toString() ?? '';
    if (content.isEmpty) return null;

    if (dl['fmt']?.toString() == 'krc') {
      return decodeKrc(content);
    }
    return KugouLyric(
      lrc: utf8.decode(base64.decode(content), allowMalformed: true),
    );
  }

  /// 歌曲评论（mcomment commentsv2/getCommentWithLike；无需登录）。
  ///
  /// [hash] 为歌曲 hash；返回分页评论。评论条目的 `replys` 首个作为
  /// 引用回复（_commentFromKg 递归解析）。
  Future<KugouCommentPage> songComments(
    String hash, {
    int page = 1,
    int pagesize = 20,
  }) async {
    if (hash.isEmpty) throw KgApiException('缺少歌曲 hash，无法获取评论');
    final resp = await kgComments(hash, page: page, pagesize: pagesize);
    final listRaw = resp['list'];
    final list = listRaw is List
        ? listRaw
            .whereType<Map<String, dynamic>>()
            .map(_commentFromKg)
            .toList()
        : const <KugouComment>[];
    return KugouCommentPage(
      list: list,
      total: (resp['count'] as num?)?.toInt() ?? 0,
      page: page,
      limit: pagesize,
    );
  }

  // ─── 网关模块（对齐 KuGouMusicApi module/*.js，概念版 lite） ───────

  /// 网关请求快捷入口（注入设备与登录态，缺省 dfid='-'）。
  Future<dynamic> _gateway(
    String path, {
    required String method,
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    String baseUrl = 'https://gateway.kugou.com',
    bool encryptKey = false,
  }) =>
      kgGateway(
        path,
        method: method,
        query: query,
        body: body,
        headers: headers,
        baseUrl: baseUrl,
        encryptKey: encryptKey,
        mid: _mid,
        token: session?.token,
        userid: session?.userid,
      );

  /// 每日推荐（需登录；未登录抛异常提示）。
  Future<List<Track>> everydayRecommend() async {
    if (session == null) {
      throw KgApiException('每日推荐需要登录酷狗账号');
    }
    final resp = await _gateway(
      '/everyday_song_recommend',
      method: 'POST',
      query: {'platform': 'ios'},
      headers: {'x-router': 'everydayrec.service.kugou.com'},
    );
    final list = resp is Map ? resp['song_list'] : null;
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(_trackFromKgPlain)
        .where((t) => t.kugou != null)
        .toList();
  }

  /// 推荐歌单（categoryId 0=推荐，其余分类 id 走 /v2/special_recommend）。
  Future<List<CoverItem>> topPlaylists({
    int categoryId = 0,
    int page = 1,
    int pagesize = 30,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final resp = await _gateway(
      '/v2/special_recommend',
      method: 'POST',
      body: {
        // 对齐 top_playlist.js：body 内用标准版 appid/clientver（与 lite 注入的 query 并存）
        'appid': 1005,
        'mid': _mid,
        'clientver': 20489,
        'platform': 'android',
        'clienttime': ts,
        'userid': int.tryParse(session?.userid ?? '') ?? 0,
        'module_id': 1,
        'page': page,
        'pagesize': pagesize,
        'key': kgSignParamsKey('$ts'),
        'special_recommend': {
          'withtag': 1,
          'withsong': 1,
          'sort': 1,
          'ugc': 1,
          'is_selected': 0,
          'withrecommend': 1,
          'area_code': 1,
          'categoryid': categoryId,
        },
        'req_multi': 1,
        'retrun_min': 5,
        'return_special_falg': 1,
      },
      headers: {'x-router': 'specialrec.service.kugou.com'},
    );
    final list = resp is Map ? resp['special_list'] : null;
    if (list is! List) return const [];
    return list.whereType<Map<String, dynamic>>().map((p) {
      final id = p['global_collection_id']?.toString() ?? '';
      return CoverItem(
        id: id,
        title: p['specialname']?.toString() ?? '',
        cover: kgFillCover(p['flexible_cover']?.toString(), 300),
        subtitle: p['intro']?.toString() ?? '',
      );
    }).toList();
  }

  /// 歌单详情（v3/get_list_info）。
  Future<Map<String, dynamic>?> playlistDetail(String id) async {
    final resp = await _gateway(
      '/v3/get_list_info',
      method: 'POST',
      body: {
        'data': [
          {'global_collection_id': id},
        ],
        'userid': int.tryParse(session?.userid ?? '') ?? 0,
        'token': session?.token ?? '',
      },
      headers: {'x-router': 'pubsongs.kugou.com'},
    );
    final data = resp is Map ? resp['data'] : null;
    if (data is List && data.isNotEmpty && data.first is Map) {
      return Map<String, dynamic>.from(data.first as Map);
    }
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  /// 公开歌单全量歌曲（playlist_track_all；60/页循环拉满，最多 [max] 首）。
  Future<List<Track>> playlistTracksAll(String id, {int max = 300}) async {
    const pagesize = 60;
    final all = <Track>[];
    var page = 1;
    while (all.length < max) {
      final resp = await _gateway(
        '/pubsongs/v2/get_other_list_file_nofilt',
        method: 'GET',
        query: {
          'area_code': 1,
          'begin_idx': (page - 1) * pagesize,
          'plat': 1,
          'type': 1,
          'mode': 1,
          'personal_switch': 1,
          'extend_fields': 'abtags,hot_cmt,popularization',
          'pagesize': pagesize,
          'global_collection_id': id,
        },
      );
      final songs = resp is Map ? resp['songs'] : null;
      if (songs is! List || songs.isEmpty) break;
      all.addAll(
        songs
            .whereType<Map<String, dynamic>>()
            .map(_trackFromKgPlain)
            .where((t) => t.kugou != null),
      );
      final listInfo = resp is Map ? resp['list_info'] : null;
      final total = listInfo is Map ? listInfo['count'] : null;
      final totalNum =
          total is num ? total.toInt() : int.tryParse('$total') ?? 0;
      if (songs.length < pagesize) break;
      if (totalNum > 0 && all.length >= totalNum) break;
      page++;
    }
    return all;
  }

  /// 私有歌单（用户歌单/"我喜欢"）全量歌曲（playlist_track_all_new）。
  ///
  /// 60/页循环翻页至接口返回的 count（总数），无硬上限——「我喜欢」
  /// 可上千首，此前默认截断 300 首导致列表不完整。
  Future<List<Track>> playlistTracksAllNew(String listid) async {
    if (session == null) return const [];
    const pagesize = 60;
    final all = <Track>[];
    var page = 1;
    // 安全上限：60 首/页 × 200 页 = 12000 首，防接口异常时死循环
    while (page <= 200) {
      final resp = await _gateway(
        '/v4/get_list_all_file',
        method: 'POST',
        body: {
          'listid': listid,
          'userid': session!.userid,
          'area_code': 1,
          'show_relate_goods': 0,
          'pagesize': pagesize,
          'allplatform': 1,
          'show_cover': 1,
          'type': 0,
          'token': session!.token,
          'page': page,
        },
        headers: {'x-router': 'cloudlist.service.kugou.com'},
      );
      final data = resp is Map ? resp['data'] : null;
      // v4/get_list_all_file 歌曲在 data.info（非 data.songs），
      // 总数在 data.count（非 data.total）
      final songs = data is Map ? data['info'] : null;
      if (songs is! List || songs.isEmpty) break;
      all.addAll(
        songs
            .whereType<Map<String, dynamic>>()
            .map(_trackFromKgPlain)
            .where((t) => t.kugou != null),
      );
      final total = data is Map ? data['count'] : null;
      final totalNum =
          total is num ? total.toInt() : int.tryParse('$total') ?? 0;
      if (songs.length < pagesize) break;
      if (totalNum > 0 && all.length >= totalNum) break;
      page++;
    }
    return all;
  }

  /// 用户歌单列表（v7/get_all_list，需登录）。
  Future<List<CoverItem>> userPlaylists({int pagesize = 500}) async {
    if (session == null) return const [];
    final resp = await _gateway(
      '/v7/get_all_list',
      method: 'POST',
      query: {
        'plat': 1,
        'userid': int.tryParse(session!.userid) ?? 0,
        'token': session!.token,
      },
      body: {
        'userid': session!.userid,
        'token': session!.token,
        'total_ver': 979,
        'type': 2,
        'page': 1,
        'pagesize': pagesize,
      },
      headers: {'x-router': 'cloudlist.service.kugou.com'},
    );
    final data = resp is Map ? resp['data'] : null;
    final info = data is Map ? data['info'] : null;
    if (info is! List) return const [];
    return info.whereType<Map<String, dynamic>>().map((p) {
      final id = p['listid']?.toString() ?? '';
      return CoverItem(
        id: id,
        title: p['name']?.toString() ?? '',
        cover: kgFillCover(p['cover']?.toString(), 300),
        subtitle: p['list_create_userid']?.toString() ?? '',
      );
    }).toList();
  }

  /// 「我喜欢」歌单 listid（进程内缓存；未找到返回 null）。
  String? _likeListId;

  /// 查找「我喜欢」歌单 listid（对齐 MoeKoeMusic Library.vue 约定：
  /// 用户歌单里 `name == '我喜欢'`）。
  Future<String?> likeListId() async {
    final cached = _likeListId;
    if (cached != null) return cached;
    final playlists = await userPlaylists();
    final like = playlists.where((p) => p.title == '我喜欢').toList();
    _likeListId = like.isEmpty ? null : like.first.id;
    return _likeListId;
  }

  /// 清除「我喜欢」listid 缓存（登录态/歌单变更后调用）。
  void invalidateLikeListId() => _likeListId = null;

  /// 「我喜欢」歌曲列表：user_playlist 匹配 `name == '我喜欢'` 的 listid →
  /// playlist_track_all_new 拉全量（对齐 MoeKoeMusic Library.vue 约定）。
  Future<List<Track>> likedTracks() async {
    final listid = await likeListId();
    if (listid == null) return const [];
    final tracks = await playlistTracksAllNew(listid);
    // 按收藏序号 sort 升序（先收藏的在前，与酷狗 App 展示顺序一致）；
    // 分页接口返回顺序不稳定，不能依赖 reversed；sort 缺失时
    // 退化为原接口顺序（旧数据兜底）。
    final sorted = List<Track>.of(tracks)
      ..sort((a, b) => (a.kugou?.sort ?? 0).compareTo(b.kugou?.sort ?? 0));
    return sorted;
  }

  /// 添加歌曲到「我喜欢」（对齐 KuGouMusicApi playlist_tracks_add.js）。
  ///
  /// 参数：`userid, token, listid, list_ver:0, type:0, slow_upload:1,
  /// scene:'false;null', data:[{number, name, hash, size, sort, timelen,
  /// bitrate, album_id, mixsongid}]`，query 带 `last_time/last_area`。
  Future<void> addToLike(Track track) async {
    final s = session;
    if (s == null) throw KgApiException('需要登录酷狗账号');
    final listid = await likeListId();
    if (listid == null) throw KgApiException('未找到「我喜欢」歌单');
    final hash = track.kugou?.hash ?? '';
    if (hash.isEmpty) throw KgApiException('缺少歌曲 hash，无法添加');
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _gateway(
      '/cloudlist.service/v6/add_song',
      method: 'POST',
      query: {
        'last_time': clienttime,
        'last_area': 'gztx',
        'userid': s.userid,
        'token': s.token,
      },
      body: {
        'userid': s.userid,
        'token': s.token,
        'listid': listid,
        'list_ver': 0,
        'type': 0,
        'slow_upload': 1,
        'scene': 'false;null',
        'data': [
          {
            'number': 1,
            'name': track.title,
            'hash': hash,
            'size': 0,
            'sort': 0,
            'timelen': 0,
            'bitrate': 0,
            'album_id': track.kugou?.albumId ?? 0,
            'mixsongid': track.kugou?.mixSongId ?? 0,
          },
        ],
      },
    );
  }

  /// 从「我喜欢」移除歌曲（对齐 KuGouMusicApi playlist_tracks_del.js）。
  ///
  /// 参数：`listid, userid, data:[{fileid}], type:0, token, list_ver:0`，
  /// header `x-router: cloudlist.service.kugou.com`。[fileid] 取自歌单条目
  /// （playlistTracksAllNew 返回的 Track.kugou.fileid）。搜索结果等来源的
  /// 曲目无 fileid 字段，此时按 hash 从「我喜欢」歌单反查补全。
  Future<void> removeFromLike(Track track) async {
    final s = session;
    if (s == null) throw KgApiException('需要登录酷狗账号');
    final listid = await likeListId();
    if (listid == null) throw KgApiException('未找到「我喜欢」歌单');
    var fileid = track.kugou?.fileid;
    if (fileid == null) {
      // 搜索结果无 fileid：反查「我喜欢」歌单，用 hash 匹配补全
      final hash = track.kugou?.hash ?? '';
      if (hash.isEmpty) throw KgApiException('缺少歌曲 hash，无法移除');
      final liked = await playlistTracksAllNew(listid);
      for (final t in liked) {
        if (t.kugou?.hash == hash && t.kugou?.fileid != null) {
          fileid = t.kugou!.fileid;
          break;
        }
      }
      if (fileid == null) throw KgApiException('缺少歌曲 fileid，无法移除');
    }
    await _gateway(
      '/v4/delete_songs',
      method: 'POST',
      body: {
        'listid': listid,
        'userid': s.userid,
        'data': [
          {'fileid': fileid},
        ],
        'type': 0,
        'token': s.token,
        'list_ver': 0,
      },
      headers: {'x-router': 'cloudlist.service.kugou.com'},
    );
  }

  /// 排行榜列表（ocean/v6/rank/list，带部分歌曲）。
  Future<List<CoverItem>> rankList() async {
    final resp = await _gateway(
      '/ocean/v6/rank/list',
      method: 'GET',
      query: {'plat': 2, 'withsong': 1, 'parentid': 0},
    );
    final data = resp is Map ? resp['data'] : null;
    final info = data is Map ? data['info'] : null;
    if (info is! List) return const [];
    return info.whereType<Map<String, dynamic>>().map((r) {
      final id = r['rankid']?.toString() ?? '';
      return CoverItem(
        id: id,
        title: r['rankname']?.toString() ?? '',
        cover: r['imgurl']?.toString() ?? r['banner']?.toString(),
        subtitle: r['intro']?.toString() ?? '',
      );
    }).toList();
  }

  /// 榜单歌曲（openapi/kmr/v2/rank/audio）。
  Future<List<Track>> rankTracks(
    String rankId, {
    int page = 1,
    int pagesize = 60,
  }) async {
    final resp = await _gateway(
      '/openapi/kmr/v2/rank/audio',
      method: 'POST',
      body: {
        'show_portrait_mv': 1,
        'show_type_total': 1,
        'filter_original_remarks': 1,
        'area_code': 1,
        'pagesize': pagesize,
        'rank_cid': 0,
        'type': 1,
        'page': page,
        'rank_id': rankId,
      },
      headers: {'kg-tid': '369'},
    );
    final data = resp is Map ? resp['data'] : null;
    final list = data is Map ? data['songlist'] : null;
    if (list is! List) return const [];
    return list.whereType<Map<String, dynamic>>().map((s) {
      // hash 嵌套在 deprecated 内（对齐 MoeKoeMusic formatArtistTracks 结构）
      final deprecated = s['deprecated'];
      final item = <String, dynamic>{
        if (deprecated is Map) ...Map<String, dynamic>.from(deprecated),
        ...s,
      };
      return _trackFromKgPlain(item);
    }).where((t) => t.kugou != null).toList();
  }

  /// 新碟上架（musicadservice/v1/mobile_newalbum_sp；chn/eur/jpn/kor 合并）。
  Future<List<CoverItem>> newAlbums({int page = 1, int pagesize = 30}) async {
    final resp = await _gateway(
      '/musicadservice/v1/mobile_newalbum_sp',
      method: 'POST',
      body: {
        'apiver': 20,
        'token': session?.token ?? '',
        'page': page,
        'pagesize': pagesize,
        'withpriv': 1,
      },
    );
    final data = resp is Map ? resp['data'] : null;
    if (data is! Map) return const [];
    final items = <CoverItem>[];
    for (final key in const ['chn', 'eur', 'jpn', 'kor']) {
      final list = data[key];
      if (list is! List) continue;
      for (final a in list.whereType<Map<String, dynamic>>()) {
        final id = a['albumid']?.toString() ?? '';
        if (id.isEmpty) continue;
        items.add(CoverItem(
          id: id,
          title: a['albumname']?.toString() ?? '',
          cover: kgFillCover(a['imgurl']?.toString(), 300),
          subtitle: a['singername']?.toString() ?? '',
          trackCount: a['songcount'] is num ? a['songcount']!.toInt() : 0,
        ));
      }
    }
    return items;
  }

  /// 专辑详情（kmr/v2/albums，返回 data[0]）。
  Future<Map<String, dynamic>?> albumDetail(String albumId) async {
    final resp = await _gateway(
      '/kmr/v2/albums',
      method: 'POST',
      body: {
        'data': [
          {'album_id': albumId},
        ],
        'is_buy': 0,
        'fields':
            'album_id,album_name,publish_date,sizable_cover,intro,language,is_publish,heat,type,quality,authors,exclusive,author_name,trans_param',
      },
      headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '255'},
    );
    final data = resp is Map ? resp['data'] : null;
    if (data is List && data.isNotEmpty && data.first is Map) {
      return Map<String, dynamic>.from(data.first as Map);
    }
    return null;
  }

  /// 专辑歌曲（openapi.kugou.com/v1/album_audio/lite）。
  Future<List<Track>> albumTracks(
    String albumId, {
    int page = 1,
    int pagesize = 60,
  }) async {
    final resp = await _gateway(
      '/v1/album_audio/lite',
      method: 'POST',
      body: {
        'album_id': albumId,
        'is_buy': '',
        'page': page,
        'pagesize': pagesize,
      },
      headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '255'},
    );
    final data = resp is Map ? resp['data'] : null;
    final songs = data is Map ? data['songs'] : null;
    if (songs is! List) return const [];
    return songs.whereType<Map<String, dynamic>>().map((s) {
      final audioInfo = s['audio_info'];
      final base = s['base'];
      final albumInfo = s['album_info'];
      final hash =
          audioInfo is Map ? audioInfo['hash']?.toString() ?? '' : '';
      final item = <String, dynamic>{
        'hash': hash,
        'audio_name':
            base is Map ? base['audio_name']?.toString() ?? '' : '',
        'author_name':
            base is Map ? base['author_name']?.toString() ?? '' : '',
        'album_name': albumInfo is Map
            ? albumInfo['album_name']?.toString() ?? ''
            : '',
        'duration': audioInfo is Map ? audioInfo['duration'] : null,
        'hash_320': audioInfo is Map ? audioInfo['hash_320'] : null,
        'hash_flac': audioInfo is Map ? audioInfo['hash_flac'] : null,
        if (s['trans_param'] is Map)
          'trans_param': s['trans_param'],
      };
      return _trackFromKgPlain(item);
    }).where((t) => t.kugou != null).toList();
  }

  /// 歌手详情（kmr/v3/author）。
  Future<Map<String, dynamic>?> artistDetail(String authorId) async {
    final resp = await _gateway(
      '/kmr/v3/author',
      method: 'POST',
      body: {'author_id': authorId},
      headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '36'},
    );
    final data = resp is Map ? resp['data'] : null;
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  /// 歌手单曲（openapi.kugou.com/kmr/v1/audio_group/author）。
  Future<List<Track>> artistAudios(
    String authorId, {
    String sort = 'hot', // 'hot' 最热 / 'new' 最新
    int page = 1,
    int pagesize = 60,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final resp = await _gateway(
      '/kmr/v1/audio_group/author',
      method: 'POST',
      body: {
        'appid': 1005,
        'clientver': 20489,
        'mid': _mid,
        'clienttime': ts,
        'key': kgSignParamsKey('$ts'),
        'author_id': authorId,
        'pagesize': pagesize,
        'page': page,
        'sort': sort == 'hot' ? 1 : 2,
        'area_code': 'all',
      },
      headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '220'},
      baseUrl: 'https://openapi.kugou.com',
    );
    final data = resp is Map ? resp['data'] : null;
    final list = data is Map ? data['songlist'] : data is List ? data : null;
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(_trackFromKgPlain)
        .where((t) => t.kugou != null)
        .toList();
  }

  /// 歌手专辑（openapi.kugou.com/kmr/v1/author/albums）。
  Future<List<CoverItem>> artistAlbums(
    String authorId, {
    String sort = 'new', // 'hot' 最热 / 'new' 最新
    int page = 1,
    int pagesize = 30,
  }) async {
    final resp = await _gateway(
      '/kmr/v1/author/albums',
      method: 'POST',
      body: {
        'author_id': authorId,
        'pagesize': pagesize,
        'page': page,
        'sort': sort == 'hot' ? 3 : 1,
        'category': 1,
        'area_code': 'all',
      },
      headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '36'},
    );
    final data = resp is Map ? resp['data'] : null;
    final list = data is Map ? data['album_list'] : data is List ? data : null;
    if (list is! List) return const [];
    return list.whereType<Map<String, dynamic>>().map((a) {
      final id = a['album_id']?.toString() ?? '';
      return CoverItem(
        id: id,
        title: a['album_name']?.toString() ?? '',
        cover: kgFillCover(a['sizable_cover']?.toString(), 300),
        subtitle: a['publish_date']?.toString() ?? '',
        trackCount: a['song_count'] is num ? a['song_count']!.toInt() : 0,
      );
    }).toList();
  }

  /// 分类搜索（对齐 KuGouMusicApi search.js：song/album/author/special）。
  ///
  /// 返回泛型：type == 'song' 时 items 为 [Track]，其余为 [CoverItem]。
  Future<SearchResult<Object>> searchByType(
    String keyword, {
    String type = 'song',
    int page = 1,
    int pagesize = 30,
  }) async {
    final resp = await _gateway(
      '/${type == 'song' ? 'v3' : 'v1'}/search/$type',
      method: 'GET',
      query: {
        'albumhide': 0,
        'iscorrection': 1,
        'keyword': keyword,
        'nocollect': 0,
        'page': page,
        'pagesize': pagesize,
        'platform': 'AndroidFilter',
      },
      headers: {'x-router': 'complexsearch.kugou.com'},
      baseUrl: 'https://complexsearch.kugou.com',
    );
    final data = resp is Map ? resp['data'] : null;
    final lists = data is Map ? data['lists'] : null;
    final total = data is Map ? data['total'] : null;
    final totalNum =
        total is num ? total.toInt() : int.tryParse('$total') ?? 0;
    if (lists is! List) {
      return SearchResult(items: const [], total: totalNum, hasMore: false);
    }
    final items = <Object>[];
    if (type == 'song') {
      for (final s in lists.whereType<Map<String, dynamic>>()) {
        // gateway /v3/search/song 返回 PascalCase + Duration(ms) + Image 封面
        final hash = s['FileHash']?.toString() ?? s['hash']?.toString() ?? '';
        if (hash.isEmpty) continue;
        final name = kgDecodeName((s['SongName'] ?? s['OriSongName'] ?? '')
            .toString());
        final author = s['SingerName']?.toString() ?? '';
        final hashes = <String, String>{'128k': hash};
        void add(String key, Object? h) {
          final hs = h?.toString() ?? '';
          if (hs.isNotEmpty) hashes[key] = hs;
        }

        add('320k', s['HQFileHash']);
        add('flac', s['SQFileHash']);
        add('flac24bit', s['ResFileHash']);
        final cover = s['Image']?.toString();
        items.add(Track(
          id: s['AudioId']?.toString() ?? hash,
          title: name,
          artists: author.isEmpty ? const [] : kugouArtists(author),
          album: null,
          duration: _kgDurationMs(s['Duration']),
          cover: kgFillCover(cover, 300),
          source: 'kugou',
          kugou: KugouTrackInfo(hash: hash, hashes: hashes, sizes: const {}),
        ));
      }
    } else {
      for (final c in lists.whereType<Map<String, dynamic>>()) {
        final id = (c['SpecialID'] ??
                c['AlbumID'] ??
                c['AuthorID'] ??
                c['albumid'] ??
                c['authorid'])
            ?.toString() ??
            '';
        if (id.isEmpty) continue;
        final title = (c['specialname'] ??
                c['albumname'] ??
                c['authorname'] ??
                c['AuthorName'] ??
                c['AlbumName'])
            ?.toString() ??
            '';
        final coverTpl = (c['img'] ?? c['imgurl'] ?? c['Avatar'] ?? c['ImgUrl'])
            ?.toString();
        items.add(CoverItem(
          id: id,
          title: title,
          cover: kgFillCover(coverTpl, 300),
          subtitle: type == 'special'
              ? (c['nickname']?.toString() ?? '')
              : type == 'album'
                  ? (c['singername']?.toString() ??
                      c['SingerName']?.toString() ??
                      '')
                  : '',
        ));
      }
    }
    return SearchResult(
      items: items,
      total: totalNum > 0 ? totalNum : items.length,
      hasMore: items.length >= pagesize,
    );
  }
}
