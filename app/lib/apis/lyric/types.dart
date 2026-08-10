/// 歌词候选匹配类型——对齐 shared/types/lyrics.ts 的 LyricMatchResult
/// 与 apis/common/lyric/utils.ts 的 LyricCandidate。
library;

/// 归一化后的候选项（extra 携带平台特定主键）
class LyricCandidate<Extra> {
  const LyricCandidate({
    required this.name,
    required this.artist,
    this.album,
    this.duration,
    required this.extra,
  });

  final String name;
  final String artist;
  final String? album;

  /// 毫秒
  final int? duration;
  final Extra extra;
}

/// 歌词匹配结果：主 + 可选翻译 / 音译
class LyricMatchResult {
  const LyricMatchResult({
    required this.platform,
    required this.format,
    required this.content,
    this.translation,
    this.translationFormat,
    this.romaji,
    this.romajiFormat,
    this.extra,
  });

  factory LyricMatchResult.fromJson(Map<String, dynamic> json) {
    // 纠正旧版本格式
    var translationFormat = json['translationFormat'] as String?;
    var romajiFormat = json['romajiFormat'] as String?;
    if (translationFormat == 'yrc') translationFormat = 'lrc';
    if (romajiFormat == 'yrc') romajiFormat = 'lrc';
    final extra = json['extra'];
    return LyricMatchResult(
      platform: json['platform'] as String,
      format: json['format'] as String,
      content: json['content'] as String,
      translation: json['translation'] as String?,
      translationFormat: translationFormat,
      romaji: json['romaji'] as String?,
      romajiFormat: romajiFormat,
      extra: extra is Map ? Map<String, dynamic>.from(extra) : null,
    );
  }

  /// 来源平台（'netease' / 'qqmusic' / 'kugou'）
  final String platform;

  /// 主歌词格式（'yrc' / 'qrc' / 'krc' / 'lrc'）
  final String format;

  /// 主歌词原始文本
  final String content;

  /// 翻译原始文本
  final String? translation;
  final String? translationFormat;

  /// 罗马音原始文本
  final String? romaji;
  final String? romajiFormat;

  /// 平台额外字段（QM 的 mid 等）
  final Map<String, dynamic>? extra;

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'format': format,
        'content': content,
        if (translation != null) 'translation': translation,
        if (translationFormat != null) 'translationFormat': translationFormat,
        if (romaji != null) 'romaji': romaji,
        if (romajiFormat != null) 'romajiFormat': romajiFormat,
        if (extra != null) 'extra': extra,
      };
}
