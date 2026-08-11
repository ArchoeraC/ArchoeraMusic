import 'app_prefs.dart';
import 'data_dir.dart';

// ── 下载域键（download. 前缀）──────────────────────────────────
const downloadRootKey = 'download.rootDir';
const downloadMaxConcurrentKey = 'download.maxConcurrent';
const downloadSubdirKey = 'download.subdirStrategy';
const downloadQualityKey = 'download.quality';
const downloadSpeedLimitKey = 'download.speedLimit';
const downloadFilenameTemplateKey = 'download.filenameTemplate';
const downloadHistoryLimitKey = 'download.historyLimit';

/// 下载音质档位（高→低，Rust 内部按此顺序自动降级）。
/// 与 [qualityLabels]（netease/track.dart）键一致；集中定义避免散落字面量。
const downloadQualityLevels = <String>['hi-res', 'lossless', 'hq', 'sq', 'lq'];

/// 下载域偏好：根目录/并发数/分组策略/默认音质/限速/文件名模板/记录上限。
extension DownloadPrefs on AppPrefs {
  /// 下载根目录（默认 `~/Music/ArchoeraMusic`，设置页可改）。
  String get downloadRoot =>
      data[downloadRootKey] as String? ?? defaultDownloadRoot();

  /// 同时下载最大任务数（1~5，默认 3）。
  int get downloadMaxConcurrent =>
      ((data[downloadMaxConcurrentKey] as num?)?.toInt() ?? 3).clamp(1, 5);

  /// 下载目录分组策略（0=flat, 1=bySource, 2=byArtist，默认 bySource）。
  int get downloadSubdirStrategy =>
      ((data[downloadSubdirKey] as num?)?.toInt() ?? 1).clamp(0, 2);

  /// 默认下载音质档（hi-res/lossless/hq/sq/lq，默认 hq）。
  /// 非法值回退 hq；右键菜单「下载」弹窗默认选中此档。
  String get downloadQuality {
    final v = data[downloadQualityKey] as String?;
    return (v != null && downloadQualityLevels.contains(v)) ? v : 'hq';
  }

  /// 全局限速（bytes/sec；0 = 不限速，默认）。设置页「下载限速」可调。
  int get downloadSpeedLimit =>
      ((data[downloadSpeedLimitKey] as num?)?.toInt() ?? 0).clamp(
        0,
        20 * 1024 * 1024,
      );

  /// 文件名模板（占位符 {artist}/{title}/{album}；默认 `{artist} - {title}`）。
  /// 空串视为默认；只影响之后入队的任务。
  String get downloadFilenameTemplate {
    final v = data[downloadFilenameTemplateKey] as String?;
    final t = v?.trim() ?? '';
    return t.isEmpty ? '{artist} - {title}' : t;
  }

  /// 下载记录上限：失败/取消的 finished 条目超过该值淘汰最旧（10~500，默认 100）。
  int get downloadHistoryLimit =>
      ((data[downloadHistoryLimitKey] as num?)?.toInt() ?? 100).clamp(10, 500);

  AppPrefs copyWithDownload({
    String? rootDir,
    int? maxConcurrent,
    int? subdirStrategy,
    String? quality,
    int? speedLimit,
    String? filenameTemplate,
    int? historyLimit,
  }) {
    // 非法档位 → 视为未提供（null-aware 不写入，避免覆盖旧值）
    final q = (quality != null && downloadQualityLevels.contains(quality))
        ? quality
        : null;
    // 空串模板 → 视为未提供（保留旧值；getter 空串回退默认）
    final tpl = (filenameTemplate != null && filenameTemplate.trim().isNotEmpty)
        ? filenameTemplate.trim()
        : null;
    return AppPrefs(
      initialData: {
        ...data,
        downloadRootKey: ?rootDir,
        downloadMaxConcurrentKey: ?maxConcurrent?.clamp(1, 5),
        downloadSubdirKey: ?subdirStrategy?.clamp(0, 2),
        downloadQualityKey: ?q,
        downloadSpeedLimitKey: ?speedLimit?.clamp(0, 20 * 1024 * 1024),
        downloadFilenameTemplateKey: ?tpl,
        downloadHistoryLimitKey: ?historyLimit?.clamp(10, 500),
      },
    );
  }
}
