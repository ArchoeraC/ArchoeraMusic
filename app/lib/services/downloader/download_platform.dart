// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 下载能力注册表。
///
/// 下载器先前按 `track.source` 写死分支（回退来源集合、请求 headers、
/// 扩展名推断、kugou extra、neko 探测）。现统一收敛到本文件的
/// [DownloadPlatform] 接口：**新增音源 = 实现一个适配器并放进 [_all]**，
/// 控制器与请求构造不再出现具体平台分支。
///
/// 每个适配器负责该源的全部差异：
/// - 能力位：Rust 是否原生解析、是否允许播放管线回退、是否支持下载 /
///   嵌入元数据 / 封面 / 歌词（后四者供未来下载 UI 展示用）；
/// - enqueue 请求：`extra`（如 kugou hashes/sizes）；
/// - 回退预解析：CDN headers、落盘扩展名推断 / 探测、品质 key。
library;

import '../netease/track.dart';
import '../../apis/runtime.dart';
import '../../stores/providers.dart';

/// 单个音源的下载能力适配器。
abstract class DownloadPlatform {
  /// 平台标识（与 `Track.source` 对齐）。
  String get source;

  /// Rust 侧是否有自研解析器（true = 引擎自行解析 URL；
  /// false = 需 Dart 播放管线预解析后经 retry_with_url 注入）。
  bool get nativeResolver => false;

  /// Rust 解析失败后是否允许播放管线回退解析。
  bool get playbackFallback => true;

  /// 是否支持下载（能力位，供下载 UI 使用）。
  bool get supportsDownload => true;

  /// 是否嵌入元数据（标签）。
  bool get embedsMetadata => true;

  /// 是否嵌入封面。
  bool get embedsCover => true;

  /// 是否嵌入歌词。
  bool get embedsLyrics => true;

  // ── enqueue 请求 ────────────────────────────────────────────────

  /// enqueue 请求的 `extra` 字段（平台私有解析参数；默认无）。
  Map<String, Object?> requestExtra(Track track) => const {};

  // ── 回退预解析（retry_with_url） ─────────────────────────────────

  /// CDN 请求头（Referer / UA / Cookie 等；默认无）。
  List<List<String>> requestHeaders(Track track, String quality) => const [];

  /// 同步扩展名覆盖（已知格式时直接给定；默认 null 走通用推断）。
  String? fileExtensionOverride(Track track, String quality) => null;

  /// 异步探测扩展名（直链无扩展名的源，如 Neko 按文件头魔数嗅探）；
  /// 默认 null（调用方回退通用推断）。
  Future<String?> probeExtension(dynamic ref, Track track) async => null;

  /// 实际品质 key（供 done 事件 actualQuality 展示；近似，以扩展名为准）。
  String qualityKey(String quality, String ext) => ext == 'flac'
      ? (quality == 'hi-res' ? 'flac24bit' : 'flac')
      : (quality == 'lq' ? '128k' : '320k');

  /// 综合扩展名推断：适配器覆盖 > 异步探测 > URL > codec > 档位默认。
  ///
  /// - [url] 播放管线预解析出的直链；
  /// - [probed] 由 [probeExtension] 得到的探测结果；
  /// - [quality] 音质档（lq/sq/hq/lossless/hi-res）。
  String resolveExtension(
    Track track, {
    required String url,
    required String quality,
    String? probed,
  }) =>
      fileExtensionOverride(track, quality) ??
      probed ??
      _extFromUrl(url) ??
      _extFromCodec(track.quality?.codec) ??
      ((quality == 'lossless' || quality == 'hi-res') ? 'flac' : 'mp3');

  /// 从 URL 路径推断扩展名（决定落盘扩展与标签写入格式）。
  static String? _extFromUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in const ['flac', 'mp3', 'm4a', 'aac', 'wav', 'ogg']) {
      if (path.endsWith('.$ext')) return ext;
    }
    return null;
  }

  /// 由平台元数据 codec/suffix 推断扩展名（流媒体 `format=raw` 为原文件，
  /// URL 不带扩展名；Subsonic `suffix` / Jellyfin codec 即原始格式）。
  static String? _extFromCodec(String? codec) {
    final c = (codec ?? '').trim().toLowerCase();
    if (c.isEmpty) return null;
    switch (c) {
      case 'alac':
      case 'mp4':
        return 'm4a';
      case 'mpeg':
      case 'mpga':
        return 'mp3';
    }
    const known = {
      'flac',
      'mp3',
      'm4a',
      'aac',
      'wav',
      'ogg',
      'opus',
      'ape',
      'wv',
    };
    return known.contains(c) ? c : null;
  }
}

/// 按 `Track.source` 取适配器；未注册源回退默认适配器（与现状一致：
/// 不参与回退解析、无 headers/extra/探测）。
DownloadPlatform downloadPlatform(String source) =>
    _registry[source] ?? _default;

/// 已注册平台适配器（顺序即注册顺序；不含默认回退）。
List<DownloadPlatform> downloadPlatforms() =>
    List<DownloadPlatform>.unmodifiable(_all);

final List<DownloadPlatform> _all = [
  _NeteaseDownloadPlatform(),
  _KugouDownloadPlatform(),
  _QqMusicDownloadPlatform(),
  _NekoDownloadPlatform(),
  _StreamingDownloadPlatform(),
];

final Map<String, DownloadPlatform> _registry = {
  for (final p in _all) p.source: p,
};

/// 未注册源的兜底适配器：行为等同改动前的「不在回退集合内」。
final DownloadPlatform _default = _DefaultDownloadPlatform();

// ── NT ─────────────────────────────────────────────────────────────────

class _NeteaseDownloadPlatform extends DownloadPlatform {
  @override
  String get source => 'netease';

  @override
  bool get nativeResolver => true;

  @override
  List<List<String>> requestHeaders(Track track, String quality) {
    // 网易 CDN 通常需 Referer/UA；带登录态时补 Cookie（对齐 Rust resolver）。
    final headers = <List<String>>[
      const ['Referer', 'https://music.163.com/'],
      const [
        'User-Agent',
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0',
      ],
    ];
    final cookies = getRuntime().sessionStore.get('netease');
    if (cookies.isNotEmpty) {
      headers.add([
        'Cookie',
        cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      ]);
    }
    return headers;
  }
}

// ── KG ─────────────────────────────────────────────────────────────────

class _KugouDownloadPlatform extends DownloadPlatform {
  @override
  String get source => 'kugou';

  @override
  bool get nativeResolver => true;

  @override
  Map<String, Object?> requestExtra(Track track) {
    final kugou = track.kugou;
    if (kugou == null) return const {};
    return {'hashes': kugou.hashes, 'sizes': kugou.sizes};
  }

  // KG 回退请求不带额外 headers（沿用改动前行为；CDN 鉴权由 Rust/直链承担）。
}

// ── QQ ─────────────────────────────────────────────────────────────────

class _QqMusicDownloadPlatform extends DownloadPlatform {
  @override
  String get source => 'qqmusic';

  @override
  bool get nativeResolver => false;

  @override
  List<List<String>> requestHeaders(Track track, String quality) {
    // QQ CDN 需 UA/Referer；带登录态时补 Cookie（GetVkey 直链鉴权）。
    final headers = <List<String>>[
      const ['User-Agent', 'QQMusic 14090008(android 15)'],
      const ['Referer', 'https://y.qq.com'],
    ];
    final cookies = getRuntime().sessionStore.get('qqmusic');
    if (cookies.isNotEmpty) {
      headers.add([
        'Cookie',
        cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      ]);
    }
    return headers;
  }
}

// ── Neko（实验性音源） ───────────────────────────────────────────────────

class _NekoDownloadPlatform extends DownloadPlatform {
  @override
  String get source => 'neko';

  @override
  bool get nativeResolver => false;

  @override
  Future<String?> probeExtension(dynamic ref, Track track) async {
    // Neko 直传原文件、直链无扩展名：按文件头魔数嗅探真实容器（对齐官方
    // PC 客户端），失败再回退 `fileFormat`，避免落盘扩展名错配。
    try {
      return await ref.read(nekoApiProvider).probeAudioExtension(track.id);
    } catch (_) {
      // 探测失败回退通用扩展名推断
      return null;
    }
  }
}

// ── Streaming（Subsonic / Jellyfin） ────────────────────────────────────

class _StreamingDownloadPlatform extends DownloadPlatform {
  @override
  String get source => 'streaming';

  @override
  bool get nativeResolver => false;

  // 流媒体下载一律取原文件（`format=raw`），扩展名由 codec/suffix 推断。
}

// ── 默认（未注册源） ─────────────────────────────────────────────────────

class _DefaultDownloadPlatform extends DownloadPlatform {
  @override
  String get source => '';

  @override
  bool get nativeResolver => false;

  @override
  bool get playbackFallback => false;
}
