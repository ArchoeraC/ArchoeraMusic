import 'app_prefs.dart';

// ── 刮削设置键（对齐 SPlayer-Next 刮削器多源方案）──
// 目录留空 = 使用媒体库扫描目录；数据源开关默认全开。
const scrapeDirsKey = 'scrape.dirs';
const scrapeUseMusicBrainzKey = 'scrape.useMusicBrainz';
const scrapeUseDeezerKey = 'scrape.useDeezer';
const scrapeUseItunesKey = 'scrape.useItunes';
const scrapeUseNeteaseKey = 'scrape.useNetease';
const scrapeUseQQMusicKey = 'scrape.useQQMusic';
const scrapeUseKugouKey = 'scrape.useKugou';
const scrapeUseKuwoKey = 'scrape.useKuwo';
const scrapeUseMiguKey = 'scrape.useMigu';
const scrapeUseAcoustIDKey = 'scrape.useAcoustID';
const scrapeEmbedMetadataKey = 'scrape.embedMetadata';
const scrapeEmbedCoverKey = 'scrape.embedCover';
const scrapeEmbedLyricsKey = 'scrape.embedLyrics';
const scrapeSkipScrapedKey = 'scrape.skipScraped';
const scrapeWorkersKey = 'scrape.workers';
const scrapeBatchSizeKey = 'scrape.batchSize';
const scrapeMaxRetriesKey = 'scrape.maxRetries';
const scrapeOrganizeTargetDirKey = 'scrape.organizeTargetDir';
const scrapeOrganizePatternKey = 'scrape.organizePattern';

/// 仅目录整理默认模板（与 C 侧 kOrganizeDefaultPattern 一致；只决定目录层级）。
const kScrapeOrganizePatternDefault =
    '{artist}/{album}/{track}. {title}.{ext}';

/// 刮削域偏好：刮削目录 + 数据源开关 + 写入选项 + 高级参数。
extension ScrapePrefs on AppPrefs {
  /// 刮削目录（非空覆盖媒体库扫描目录；默认空 = 使用扫描目录）。
  List<String> get scrapeDirs => ((data[scrapeDirsKey] as List?) ?? const [])
      .whereType<String>()
      .map((d) => d.trim())
      .where((d) => d.isNotEmpty)
      .toList();

  /// 数据源开关（默认全开，对齐 SPlayer-Next 刮削器默认）。
  bool get scrapeUseMusicBrainz =>
      data[scrapeUseMusicBrainzKey] as bool? ?? true;
  bool get scrapeUseDeezer => data[scrapeUseDeezerKey] as bool? ?? true;
  bool get scrapeUseItunes => data[scrapeUseItunesKey] as bool? ?? true;
  bool get scrapeUseNetease => data[scrapeUseNeteaseKey] as bool? ?? true;
  bool get scrapeUseQQMusic => data[scrapeUseQQMusicKey] as bool? ?? true;
  bool get scrapeUseKugou => data[scrapeUseKugouKey] as bool? ?? true;
  bool get scrapeUseKuwo => data[scrapeUseKuwoKey] as bool? ?? true;
  bool get scrapeUseMigu => data[scrapeUseMiguKey] as bool? ?? true;
  bool get scrapeUseAcoustID => data[scrapeUseAcoustIDKey] as bool? ?? true;

  /// 写入选项（默认全开）：是否把元数据/封面/歌词嵌入音频文件。
  bool get scrapeEmbedMetadata => data[scrapeEmbedMetadataKey] as bool? ?? true;
  bool get scrapeEmbedCover => data[scrapeEmbedCoverKey] as bool? ?? true;
  bool get scrapeEmbedLyrics => data[scrapeEmbedLyricsKey] as bool? ?? true;

  /// 跳过已刮削（已有 MBID/ISRC 的文件不再重复联网刮削）。
  bool get scrapeSkipScraped => data[scrapeSkipScrapedKey] as bool? ?? true;

  /// 并发查询线程数（0 = 引擎按硬件自动，对齐 C 侧 detectParallelism）。
  int get scrapeWorkers => data[scrapeWorkersKey] as int? ?? 0;

  /// 批大小（C 侧默认 10）。
  int get scrapeBatchSize => data[scrapeBatchSizeKey] as int? ?? 10;

  /// 失败重试上限（C 侧默认 5；超过后隔离不再重试）。
  int get scrapeMaxRetries => data[scrapeMaxRetriesKey] as int? ?? 5;

  /// 仅目录整理目标目录（空 = 默认使用第一个扫描目录）。
  String get scrapeOrganizeTargetDir =>
      data[scrapeOrganizeTargetDirKey] as String? ?? '';

  /// 仅目录整理模板（默认见 [kScrapeOrganizePatternDefault]）。
  String get scrapeOrganizePattern =>
      data[scrapeOrganizePatternKey] as String? ?? kScrapeOrganizePatternDefault;

  /// 刮削配置：目录 + 数据源开关 + 写入选项 + 高级参数。
  AppPrefs copyWithScrape({
    List<String>? dirs,
    bool? useMusicBrainz,
    bool? useDeezer,
    bool? useItunes,
    bool? useNetease,
    bool? useQQMusic,
    bool? useKugou,
    bool? useKuwo,
    bool? useMigu,
    bool? useAcoustID,
    bool? embedMetadata,
    bool? embedCover,
    bool? embedLyrics,
    bool? skipScraped,
    int? workers,
    int? batchSize,
    int? maxRetries,
    String? organizeTargetDir,
    String? organizePattern,
  }) => AppPrefs(
    initialData: {
      ...data,
      scrapeDirsKey: ?dirs,
      scrapeUseMusicBrainzKey: ?useMusicBrainz,
      scrapeUseDeezerKey: ?useDeezer,
      scrapeUseItunesKey: ?useItunes,
      scrapeUseNeteaseKey: ?useNetease,
      scrapeUseQQMusicKey: ?useQQMusic,
      scrapeUseKugouKey: ?useKugou,
      scrapeUseKuwoKey: ?useKuwo,
      scrapeUseMiguKey: ?useMigu,
      scrapeUseAcoustIDKey: ?useAcoustID,
      scrapeEmbedMetadataKey: ?embedMetadata,
      scrapeEmbedCoverKey: ?embedCover,
      scrapeEmbedLyricsKey: ?embedLyrics,
      scrapeSkipScrapedKey: ?skipScraped,
      scrapeWorkersKey: ?workers,
      scrapeBatchSizeKey: ?batchSize,
      scrapeMaxRetriesKey: ?maxRetries,
      scrapeOrganizeTargetDirKey: ?organizeTargetDir,
      scrapeOrganizePatternKey: ?organizePattern,
    },
  );
}
