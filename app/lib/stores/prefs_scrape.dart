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

/// 刮削域偏好：刮削目录 + 数据源开关。
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

  /// 刮削配置：目录（空列表 = 使用媒体库扫描目录）+ 数据源开关。
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
    },
  );
}
