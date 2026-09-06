import 'app_prefs.dart';

// ── 扫描设置键（0 = 引擎默认/自动；扩展名为额外追加项）──
const scanParallelismKey = 'scan.parallelism';
const scanBatchSizeKey = 'scan.batchSize';
const scanMaxFileSizeMbKey = 'scan.maxFileSizeMb';
const scanMaxScanFilesKey = 'scan.maxScanFiles';
const scanMaxScanErrorsKey = 'scan.maxScanErrors';
const scanExtraExtsKey = 'scan.extraExts';

/// 扫描域偏好：并行度 / 批大小 / 安全上限 / 额外音频扩展名。
///
/// 数值语义：**0 = 引擎默认（自适应或内置安全值）**，便于后续换引擎默认值
/// 时用户无需改动偏好；显式值（>0）才覆盖。
extension ScanPrefs on AppPrefs {
  /// 扫描并行度（0 = 自适应：按 CPU 与可用内存，C# AdaptiveConcurrency）。
  int get scanParallelism => data[scanParallelismKey] as int? ?? 0;

  /// 批大小（0 = 自适应，C# AdaptiveBatchSize；显式值作为用户上限）。
  int get scanBatchSize => data[scanBatchSizeKey] as int? ?? 0;

  /// 单文件大小上限 MB（0 = 引擎默认 500）。
  int get scanMaxFileSizeMb => data[scanMaxFileSizeMbKey] as int? ?? 0;

  /// 扫描文件总数上限（0 = 引擎默认 50000）。
  int get scanMaxScanFiles => data[scanMaxScanFilesKey] as int? ?? 0;

  /// 连续解析错误上限（0 = 引擎默认 50，超过后中止本轮扫描）。
  int get scanMaxScanErrors => data[scanMaxScanErrorsKey] as int? ?? 0;

  /// 额外音频扩展名（追加到引擎内置白名单；空 = 仅内置）。
  List<String> get scanExtraExts => ((data[scanExtraExtsKey] as List?) ?? const [])
      .whereType<String>()
      .map((e) => e.trim().toLowerCase().replaceFirst('.', ''))
      .where((e) => e.isNotEmpty)
      .toList();

  AppPrefs copyWithScan({
    int? parallelism,
    int? batchSize,
    int? maxFileSizeMb,
    int? maxScanFiles,
    int? maxScanErrors,
    List<String>? extraExts,
  }) => AppPrefs(
    initialData: {
      ...data,
      scanParallelismKey: ?parallelism,
      scanBatchSizeKey: ?batchSize,
      scanMaxFileSizeMbKey: ?maxFileSizeMb,
      scanMaxScanFilesKey: ?maxScanFiles,
      scanMaxScanErrorsKey: ?maxScanErrors,
      scanExtraExtsKey: ?extraExts,
    },
  );
}
