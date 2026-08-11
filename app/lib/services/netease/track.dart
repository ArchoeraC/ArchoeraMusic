/// 歌曲 / 歌单的轻量元数据模型（对齐 @shared/types/player 的 Track 子集）。
///
/// 仅承载 UI 层展示与播放所需字段；数据来自 apis 包（纯 Dart 直连）
/// 返回的网易云/酷狗原始对象（字段映射对齐原项目 `src/utils/format/netease.ts`）。
library;

/// 封面 URL 拼尺寸（对齐 withPicSize：缺省 300 边长）。
String withPicSize(String? url, [int size = 300]) {
  if (url == null || url.isEmpty) return '';
  if (url.contains('?param=')) return url;
  return '$url?param=${size}y$size';
}

/// HTML 实体反转义（KG 搜索结果含 `&amp;`、`&#039;` 等）。
String kgDecodeName(String? str) {
  if (str == null || str.isEmpty) return '';
  const map = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'",
    '&#039;': "'",
  };
  final buf = StringBuffer();
  var rest = str;
  while (true) {
    final amp = rest.indexOf('&');
    if (amp < 0) {
      buf.write(rest);
      break;
    }
    buf.write(rest.substring(0, amp));
    final semi = rest.indexOf(';', amp);
    if (semi < 0) {
      buf.write(rest.substring(amp));
      break;
    }
    final entity = rest.substring(amp, semi + 1);
    buf.write(map[entity] ?? entity);
    rest = rest.substring(semi + 1);
  }
  return buf.toString();
}

/// trans_param.union_cover 含 `{size}` 占位，按需替换。
String? kgFillCover(String? url, int size) {
  if (url == null || url.isEmpty) return null;
  return url.replaceAll('{size}', '$size');
}

/// 酷狗歌曲品质信息（来自搜索结果：各档 hash + 文件大小）。
class KugouTrackInfo {
  const KugouTrackInfo({
    required this.hash,
    this.hashes = const {},
    this.sizes = const {},
    this.fileid,
    this.albumId,
    this.mixSongId,
    this.sort,
  });

  /// 主 hash（128k 档）。
  final String hash;

  /// 品质 key（'128k'/'320k'/'flac'/'flac24bit'）→ hash。
  final Map<String, String> hashes;

  /// 品质 key → 文件大小（字节）。
  final Map<String, int> sizes;

  /// 用户歌单中的 fileid（「我喜欢」等私有歌单条目；移除歌曲用）。
  final int? fileid;

  /// 专辑 id（添加至「我喜欢」时传参；缺省 0）。
  final int? albumId;

  /// mixsongid（添加至「我喜欢」时传参；缺省 0）。
  final int? mixSongId;

  /// 用户歌单中的收藏序号（「我喜欢」条目；服务端按添加时间递增，
  /// 越小越早——「我喜欢」列表按此升序 = 先收藏的在前，与酷狗 App
  /// 展示顺序一致）。
  final int? sort;

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'hashes': hashes,
    'sizes': sizes,
    'fileid': fileid,
    'albumId': albumId,
    'mixSongId': mixSongId,
    'sort': sort,
  };

  factory KugouTrackInfo.fromJson(Map<String, dynamic> json) => KugouTrackInfo(
    hash: json['hash']?.toString() ?? '',
    hashes:
        (json['hashes'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ) ??
        const {},
    sizes:
        (json['sizes'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), (v as num).toInt()),
        ) ??
        const {},
    fileid: (json['fileid'] as num?)?.toInt(),
    albumId: (json['albumId'] as num?)?.toInt(),
    mixSongId: (json['mixSongId'] as num?)?.toInt(),
    sort: (json['sort'] as num?)?.toInt(),
  );

  /// 可用品质 key 列表。
  List<String> get available => hashes.keys.toList();

  static const _levelChain = <String, List<String>>{
    'lq': ['128k'],
    'sq': ['320k', '128k'],
    'hq': ['320k', '128k'],
    'lossless': ['flac', '320k', '128k'],
    'hi-res': ['flac24bit', 'flac', '320k', '128k'],
  };

  /// 该音质档实际命中的品质 key（缺档时按高→低回退；无可用返回 null）。
  String? keyFor(String level) {
    for (final q in _levelChain[level] ?? const <String>[]) {
      final h = hashes[q];
      if (h != null && h.isNotEmpty) return q;
    }
    return null;
  }

  /// 该音质档的 hash；档位缺档时按高→低回退。
  String? hashFor(String level) {
    final q = keyFor(level);
    return q != null ? hashes[q] : null;
  }

  /// 由档位 key 生成 [quality] 参数值（对齐 MoeKoeMusic /v5/url quality 枚举）。
  static String? qualityParam(String qualityKey) =>
      _kugouQualityParam[qualityKey];
}

/// 品质 key → /v5/url 的 quality 参数。
const _kugouQualityParam = <String, String>{
  '128k': '128',
  '320k': '320',
  'flac': 'flac',
  'flac24bit': 'high',
};

/// 音质档位 → 转码 bitrate（对齐规划文档 §5.6 QualityLevel→bitrate 表）。
const qualityBitrate = <String, int>{
  'hi-res': 256000,
  'lossless': 192000,
  'hq': 128000,
  'sq': 96000,
  'lq': 64000,
};

/// 音质档位短码文案（对齐 SPlayer-Next QUALITY_LABELS）。
const qualityLabels = <String, String>{
  'hi-res': 'Hi-Res',
  'lossless': '无损',
  'hq': 'HQ',
  'sq': 'SQ',
  'lq': 'LQ',
};

/// 酷狗 `singername`（"A、B"）→ 歌手列表。
List<TrackArtist> kugouArtists(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  final names = kgDecodeName(
    raw,
  ).split(RegExp(r'、|,|;|/')).map((s) => s.trim()).where((s) => s.isNotEmpty);
  return names.map((n) => TrackArtist(name: n)).toList();
}

/// 歌手。
class TrackArtist {
  const TrackArtist({this.id, required this.name});

  final String? id;
  final String name;

  factory TrackArtist.fromNetease(Map<String, dynamic> json) => TrackArtist(
    id: json['id']?.toString(),
    name: json['name']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory TrackArtist.fromJson(Map<String, dynamic> json) => TrackArtist(
    id: json['id']?.toString(),
    name: json['name']?.toString() ?? '',
  );
}

/// 专辑。
class TrackAlbum {
  const TrackAlbum({this.id, required this.name, this.cover});

  final String? id;
  final String name;
  final String? cover;

  factory TrackAlbum.fromNetease(Map<String, dynamic> json) {
    final name = json['name']?.toString() ?? '';
    return TrackAlbum(
      id: json['id']?.toString(),
      name: name,
      cover: name.isEmpty ? null : withPicSize(json['picUrl']?.toString()),
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'cover': cover};

  factory TrackAlbum.fromJson(Map<String, dynamic> json) => TrackAlbum(
    id: json['id']?.toString(),
    name: json['name']?.toString() ?? '',
    cover: json['cover']?.toString(),
  );
}

/// 音频品质信息（流媒体服务器返回，对齐 @shared/types/player Track.quality）。
class TrackQuality {
  const TrackQuality({
    this.sampleRate = 0,
    this.channels = 2,
    this.bitsPerSample = 0,
    this.bitRate = 0,
    this.codec = '',
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int bitRate;
  final String codec;

  Map<String, dynamic> toJson() => {
    'sampleRate': sampleRate,
    'channels': channels,
    'bitsPerSample': bitsPerSample,
    'bitRate': bitRate,
    'codec': codec,
  };

  factory TrackQuality.fromJson(Map<String, dynamic> json) => TrackQuality(
    sampleRate: (json['sampleRate'] as num?)?.toInt() ?? 0,
    channels: (json['channels'] as num?)?.toInt() ?? 2,
    bitsPerSample: (json['bitsPerSample'] as num?)?.toInt() ?? 0,
    bitRate: (json['bitRate'] as num?)?.toInt() ?? 0,
    codec: json['codec']?.toString() ?? '',
  );
}

/// 歌曲（netease / kugou song → Track）。
class Track {
  const Track({
    required this.id,
    required this.title,
    this.comment,
    this.artists = const [],
    this.album,
    this.duration = 0,
    this.cover,
    this.fee = 0,
    this.source = 'netease',
    this.kugou,
    this.localPath,
    this.lyrics,
    this.serverId,
    this.originalId,
    this.coverOriginal,
    this.fileSize,
    this.quality,
    this.isOriginal = false,
  });

  final String id;
  final String title;

  /// 副标题（网易 alias 首条）。
  final String? comment;
  final List<TrackArtist> artists;
  final TrackAlbum? album;

  /// 时长（毫秒）。
  final int duration;

  /// 封面 URL（300px）。
  final String? cover;

  /// 付费等级（0 免费 / 1 VIP / 2 购买，对齐 TrackFee）。
  final int fee;

  /// 来源平台（'netease' / 'kugou' / 'local'，决定播放源解析与音质切换路径）。
  final String source;

  /// 酷狗品质信息（source == 'kugou' 时存在）。
  final KugouTrackInfo? kugou;

  /// 本地曲目文件路径（source == 'local' 时存在，直接作播放源）。
  final String? localPath;

  /// 本地曲目内嵌歌词（source == 'local' 时存在；LRC 文本或纯文本）。
  final String? lyrics;

  /// 来源流媒体服务器 id（source == 'streaming' 时存在，对应 StreamingServerConfig.id）。
  final String? serverId;

  /// 服务器侧原始 id（source == 'streaming' 时存在）。
  final String? originalId;

  /// 封面 URL（1500px，全屏播放器/背景用；仅流媒体服务器明确返回时存在）。
  final String? coverOriginal;

  /// 文件大小（字节；仅服务器明确返回时存在）。
  final int? fileSize;

  /// 音频品质信息（网易云 hr/sq/h/m/l、酷狗最高档、流媒体服务器返回时存在）。
  final TrackQuality? quality;

  /// 是否为原唱（酷狗 `IsOriginal == 1` 时置位；翻唱/伴奏不置位）。
  final bool isOriginal;

  String get artistNames => artists.map((a) => a.name).join(' / ');

  /// 替换酷狗品质信息，其余字段原样保留（下载前补齐 hash 链时使用）。
  Track copyWithKugou(KugouTrackInfo? kugou) => Track(
    id: id,
    title: title,
    comment: comment,
    artists: artists,
    album: album,
    duration: duration,
    cover: cover,
    fee: fee,
    source: source,
    kugou: kugou,
    localPath: localPath,
    lyrics: lyrics,
    serverId: serverId,
    originalId: originalId,
    coverOriginal: coverOriginal,
    fileSize: fileSize,
    quality: quality,
    isOriginal: isOriginal,
  );

  /// 列表副标题：歌手 + 副标题。
  String get subtitle => [
    if (artistNames.isNotEmpty) artistNames,
    if (comment != null && comment!.isNotEmpty) '（$comment）',
  ].join(' ');

  /// 网易云 song 对象 → Track（对齐 songToTrack）。
  factory Track.fromNeteaseSong(Map<String, dynamic> song) {
    final albumRaw = song['al'] ?? song['album'];
    final artistsRaw = (song['ar'] ?? song['artists'] ?? []) as List;
    final aliases = (song['alia'] ?? song['alias'] ?? []) as List;
    String? comment;
    for (final a in aliases) {
      final s = a?.toString().trim() ?? '';
      if (s.isNotEmpty) {
        comment = s;
        break;
      }
    }
    final album = albumRaw is Map<String, dynamic>
        ? TrackAlbum.fromNetease(albumRaw)
        : null;
    return Track(
      id: song['id'].toString(),
      title: song['name']?.toString() ?? '',
      comment: comment,
      artists: artistsRaw
          .whereType<Map<String, dynamic>>()
          .map(TrackArtist.fromNetease)
          .toList(),
      album: album,
      duration: song['dt'] ?? song['duration'] ?? 0,
      cover: album?.cover,
      fee: _toTrackFee(song['fee']),
      quality: _pickNeteaseQuality(song),
    );
  }

  /// 由 song 的 `hr`/`sq`/`h`/`m`/`l` 字段选择最佳音质（对齐
  /// SPlayer-Next `utils/format/netease.ts` 的 pickQuality）：
  /// 优先 Hi-Res（flac 24bit，采样率按 96kHz 起步）→ 无损（flac 16bit）
  /// → 最高 MP3 档（h=320k / m=192k / l=128k）。搜索/歌单接口不返回
  /// hr/sq 时安全回退为 null（列表不显示音质标签）。
  static TrackQuality? _pickNeteaseQuality(Map<String, dynamic> song) {
    TrackQuality mp3(Map<String, dynamic> q, int bits) => TrackQuality(
      codec: 'mp3',
      sampleRate: (q['sr'] as num?)?.toInt() ?? 0,
      bitsPerSample: bits,
      bitRate: (q['br'] as num?)?.toInt() ?? 0,
      channels: 2,
    );
    final hr = song['hr'];
    if (hr is Map<String, dynamic>) {
      return TrackQuality(
        codec: 'flac',
        sampleRate: ((hr['sr'] as num?)?.toInt() ?? 0) >= 96000
            ? (hr['sr'] as num).toInt()
            : 96000,
        bitsPerSample: 24,
        bitRate: (hr['br'] as num?)?.toInt() ?? 0,
        channels: 2,
      );
    }
    final sq = song['sq'];
    if (sq is Map<String, dynamic>) {
      return TrackQuality(
        codec: 'flac',
        sampleRate: (sq['sr'] as num?)?.toInt() ?? 0,
        bitsPerSample: 16,
        bitRate: (sq['br'] as num?)?.toInt() ?? 0,
        channels: 2,
      );
    }
    final mp3Raw = song['h'] ?? song['m'] ?? song['l'];
    if (mp3Raw is Map<String, dynamic>) return mp3(mp3Raw, 16);
    return null;
  }

  /// 酷狗 song 对象 → Track（兼容 mobilecdn 小写字段与 songsearch PascalCase 字段）。
  factory Track.fromKugouSong(Map<String, dynamic> song) {
    final hash = (song['hash'] ?? song['FileHash'] ?? '').toString();
    final audioId = song['audio_id'] ?? song['Audioid'];
    final name = kgDecodeName(
      (song['songname'] ?? song['SongName'] ?? song['filename'] ?? '')
          .toString(),
    );
    final albumName = kgDecodeName(
      (song['album_name'] ?? song['AlbumName'] ?? '').toString(),
    );
    final coverTpl = song['trans_param'] is Map
        ? (song['trans_param'] as Map)['union_cover']?.toString()
        : null;

    // 歌手：mobilecdn 是 "A、B" 字符串；songsearch 是 Singers 数组
    List<TrackArtist> artists;
    final singerRaw = song['singername']?.toString();
    if (singerRaw != null && singerRaw.isNotEmpty) {
      artists = kugouArtists(singerRaw);
    } else {
      final singers = song['Singers'];
      artists = singers is List
          ? singers
                .whereType<Map<String, dynamic>>()
                .map((s) => s['name']?.toString() ?? '')
                .where((n) => n.isNotEmpty)
                .map((n) => TrackArtist(name: kgDecodeName(n)))
                .toList()
          : const [];
    }

    // 各品质档 hash + 文件大小。hash 与 size 解耦：size 缺失/为 0 时
    // 仍保留 hash（下载链只依赖 hash），否则某些响应缺 size 字段会
    // 把 320k/flac 档整个丢掉，导致下载被静默降到 128k。
    final hashes = <String, String>{};
    final sizes = <String, int>{};
    void add(String key, Object? h, Object? s) {
      final hs = h?.toString() ?? '';
      if (hs.isEmpty) return;
      hashes[key] = hs;
      final sz = s is num
          ? s.toInt()
          : (s != null ? int.tryParse(s.toString()) : null);
      if (sz != null && sz > 0) sizes[key] = sz;
    }

    add('128k', hash, song['filesize'] ?? song['FileSize']);
    add(
      '320k',
      song['320hash'] ?? song['HQFileHash'],
      song['320filesize'] ?? song['HQFileSize'],
    );
    add(
      'flac',
      song['sqhash'] ?? song['SQFileHash'],
      song['sqfilesize'] ?? song['SQFileSize'],
    );
    add(
      'flac24bit',
      song['hires_hash'] ?? song['reshash'] ?? song['ResFileHash'],
      song['hires_filesize'] ?? song['resfilesize'] ?? song['ResFileSize'],
    );

    final durationSec = song['duration'] ?? song['Duration'] ?? 0;
    final sec = durationSec is num
        ? durationSec.toInt()
        : int.tryParse(durationSec.toString()) ?? 0;

    // id 以 hash（音频文件级唯一键）优先，audio_id 仅作兜底。
    // 酷狗把同一作品的不同版本（不同专辑/音源）归并到同一个 audio_id，
    // 若用 audio_id 当 id，列表会同时高亮多个版本、队列会误判为同一首
    // （对齐原版 songToTrack 的 `song.hash || song.id`）。
    return Track(
      id: hash.isNotEmpty ? hash : (audioId?.toString() ?? ''),
      title: name,
      artists: artists,
      album: albumName.isEmpty
          ? null
          : TrackAlbum(name: albumName, cover: kgFillCover(coverTpl, 300)),
      duration: sec * 1000,
      cover: kgFillCover(coverTpl, 300),
      source: 'kugou',
      kugou: hashes.isEmpty
          ? null
          : KugouTrackInfo(hash: hash, hashes: hashes, sizes: sizes),
      // 原唱标识（MoeKoeMusic `Number(IsOriginal) === 1`）+ 酷狗版权
      // privilege == 10 → VIP（对齐 MoeKoeMusic PlaylistDetail）
      isOriginal: _kgIsOriginal(song['IsOriginal'] ?? song['isOriginal']),
      fee: _kgFee(song['privilege']),
    );
  }

  /// 酷狗 `IsOriginal`（1=原唱）→ bool；兼容数字与字符串。
  static bool _kgIsOriginal(Object? raw) {
    if (raw == null) return false;
    if (raw is num) return raw.toInt() == 1;
    return raw.toString() == '1' || raw.toString().toLowerCase() == 'true';
  }

  /// 酷狗版权 `privilege` → TrackFee（10=VIP 需会员；其余视作免费）。
  static int _kgFee(Object? raw) {
    if (raw == null) return 0;
    final v = raw is num ? raw.toInt() : int.tryParse(raw.toString()) ?? 0;
    return v == 10 ? 1 : 0;
  }

  /// fee → TrackFee（0/8=免费，1=VIP，4=购买）。
  static int _toTrackFee(Object? fee) {
    final f = fee is num ? fee.toInt() : -1;
    if (f == 0 || f == 8) return 0;
    if (f == 1) return 1;
    if (f == 4) return 2;
    return 0;
  }

  /// 序列化（历史/收藏本地持久化快照）。
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'comment': comment,
    'artists': artists.map((a) => a.toJson()).toList(),
    'album': album?.toJson(),
    'duration': duration,
    'cover': cover,
    'fee': fee,
    'source': source,
    'kugou': kugou?.toJson(),
    'localPath': localPath,
    'lyrics': lyrics,
    'serverId': serverId,
    'originalId': originalId,
    'coverOriginal': coverOriginal,
    'fileSize': fileSize,
    'quality': quality?.toJson(),
    'isOriginal': isOriginal,
  };

  /// 反序列化（[toJson] 逆操作；缺失字段给安全默认值）。
  factory Track.fromJson(Map<String, dynamic> json) {
    final kugou = json['kugou'];
    final quality = json['quality'];
    return Track(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      comment: json['comment']?.toString(),
      artists:
          (json['artists'] as List?)
              ?.whereType<Map>()
              .map((e) => TrackArtist.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const [],
      album: json['album'] is Map
          ? TrackAlbum.fromJson(Map<String, dynamic>.from(json['album'] as Map))
          : null,
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      cover: json['cover']?.toString(),
      fee: (json['fee'] as num?)?.toInt() ?? 0,
      source: json['source']?.toString() ?? 'netease',
      kugou: kugou is Map
          ? KugouTrackInfo.fromJson(Map<String, dynamic>.from(kugou))
          : null,
      localPath: json['localPath']?.toString(),
      lyrics: json['lyrics']?.toString(),
      serverId: json['serverId']?.toString(),
      originalId: json['originalId']?.toString(),
      coverOriginal: json['coverOriginal']?.toString(),
      fileSize: (json['fileSize'] as num?)?.toInt(),
      quality: quality is Map
          ? TrackQuality.fromJson(Map<String, dynamic>.from(quality))
          : null,
      isOriginal: json['isOriginal'] == true,
    );
  }
}

/// 歌单（netease playlist → PlaylistItem）。
class PlaylistItem {
  const PlaylistItem({
    required this.id,
    required this.name,
    this.cover,
    this.trackCount = 0,
    this.owner,
    this.subscribed = false,
  });

  final String id;
  final String name;
  final String? cover;
  final int trackCount;
  final String? owner;

  /// 是否已收藏（user_playlist 的 subscribed 字段）。
  final bool subscribed;

  factory PlaylistItem.fromNetease(Map<String, dynamic> json) => PlaylistItem(
    id: json['id'].toString(),
    name: json['name']?.toString() ?? '',
    cover: withPicSize(json['coverImgUrl']?.toString()),
    trackCount: json['trackCount'] ?? 0,
    owner: json['creator']?['nickname']?.toString(),
    subscribed: json['subscribed'] == true,
  );
}
