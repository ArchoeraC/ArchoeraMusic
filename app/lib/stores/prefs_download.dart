import 'dart:io' show Platform;
import 'dart:math';

import '../services/kugou/kugou_crypto.dart';
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
const downloaderIdentityKey = 'download.downloaderIdentity';
const downloadDynamicFingerprintKey = 'download.dynamicFingerprint';

/// 生成下载器设备指纹（对齐 downloader-identity-plan §3.1，格式与 Rust
/// `DownloaderIdentity` / resolvers.rs 消费侧一致）：
/// - kgGuid：16 位大写字母数字（酷狗 guid，kgRandomString 字符池）
/// - kgMid：`kg_calc_mid(kgGuid)`（md5 → 十进制大整数）
/// - nmDeviceId：26 位大写 hex（对齐 resolvers.rs `{:X}` 随机 deviceId）
/// - nmNuid：32 位小写 hex（对齐 resolvers.rs `rand_hex_bytes(16)`）
/// - osver：网易系统版本伪装（[generateOsver]，Windows 读真实版本）
///
/// 首次启动生成后持久化，此后跨会话不变（同一用户指纹稳定、异用户隔离）。
Map<String, String> generateDownloaderIdentity() {
  final rng = Random.secure();
  const hexDigits = '0123456789abcdef';
  String randHex(int n) =>
      List.generate(n, (_) => hexDigits[rng.nextInt(16)]).join();
  final kgGuid = kgRandomString(16);
  return {
    'kgGuid': kgGuid,
    'kgMid': kgCalcMid(kgGuid),
    'nmDeviceId': randHex(26).toUpperCase(),
    'nmNuid': randHex(32),
    'osver': generateOsver(),
  };
}

/// 网易 osver 系统版本字符串（对齐 resolvers.rs 回落格式
/// `Microsoft-Windows-10-Professional-build-19045-64bit`）。
///
/// Windows：读真实系统版本（`Platform.operatingSystemVersion` 如
/// "Windows 10 10.0.22631"），build ≥ 22000 记 Windows 11，否则 Windows 10。
/// Linux/macOS：回落官方值——网易 osver 仅接受 Windows 风格字符串（下载器
/// 始终伪装 Windows 客户端），改用本机真实系统名会被服务端拒绝
/// （downloader-identity-plan §3.2 权衡，见该文档）。
String generateOsver() {
  const fallback = 'Microsoft-Windows-10-Professional-build-19045-64bit';
  if (!Platform.isWindows) return fallback;
  final m = RegExp(r'10\.0\.(\d+)').firstMatch(Platform.operatingSystemVersion);
  final build = int.tryParse(m?.group(1) ?? '');
  if (build == null) return fallback;
  final name = build >= 22000 ? '11' : '10';
  return 'Microsoft-Windows-$name-Professional-build-$build-64bit';
}


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

  /// 设备指纹 JSON（[generateDownloaderIdentity] 生成后持久化的原串；
  /// null = 尚未生成，下载引擎 init 时生成并写回）。
  String? get downloaderIdentity => data[downloaderIdentityKey] as String?;

  /// 动态设备指纹开关（默认关闭）：开启后回退旧版「每次启动随机」动态值
  /// 行为（Rust 下载器 mid/deviceId/_ntes_nuid 每次启动随机，可能触发平台
  /// 风控；downloader-identity-plan §2 风险定性）。关闭 = 持久化指纹（默认）。
  bool get downloadDynamicFingerprint =>
      (data[downloadDynamicFingerprintKey] as bool?) ?? false;

  AppPrefs copyWithDownloaderIdentity(String identityJson) {
    return AppPrefs(initialData: {
      ...data,
      downloaderIdentityKey: identityJson,
    });
  }

  AppPrefs copyWithDownloadDynamicFingerprint(bool value) {
    return AppPrefs(initialData: {
      ...data,
      downloadDynamicFingerprintKey: value,
    });
  }

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
