import 'dart:convert';
import 'dart:io';

/// 应用数据根目录（`~/.local/share/ArchoeraMusic`，Linux；Windows 为
/// `AppData/Local`），可用环境变量 `ARCHOERACAR_DATA` 覆盖。
///
/// 原实现内嵌于 sidecar 进程管理器，去侧车化后提取为共享 helper，
/// 供偏好（prefs.json）、流媒体服务器列表（streaming_servers.json）与
/// 扫描器默认库路径统一使用。
String resolveDataDir() {
  final override = Platform.environment['ARCHOERACAR_DATA'];
  if (override != null && override.isNotEmpty) return override;
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  final base = Platform.isLinux ? '$home/.local/share' : '$home/AppData/Local';
  return '$base/ArchoeraMusic';
}

/// 默认下载根目录：跟随媒体库——读取扫描目录配置（scan_dirs.json，
/// 与 LibraryNotifier 持久化位置一致），有扫描目录时取第一个作为默认
/// 下载目录（媒体库即用户存放音乐的位置）；无扫描目录时回退
/// `~/Music/ArchoeraMusic`。用户可在设置页修改（保存后不再走默认值）。
String defaultDownloadRoot() {
  try {
    final f = File('${resolveDataDir()}/scan_dirs.json');
    if (f.existsSync()) {
      final dirs = (jsonDecode(f.readAsStringSync()) as List<dynamic>)
          .whereType<String>()
          .where((d) => d.trim().isNotEmpty)
          .toList();
      if (dirs.isNotEmpty) return dirs.first.trim();
    }
  } catch (_) {
    // 配置损坏/不可读时回退默认，不阻断
  }
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return '$home/Music/ArchoeraMusic';
}

/// 媒体库扫描目录（`scan_dirs.json`，与 LibraryNotifier 持久化位置一致）。
/// 文件缺失/损坏/无有效目录时返回空列表，不抛异常。
List<String> scanDirs() {
  try {
    final f = File('${resolveDataDir()}/scan_dirs.json');
    if (!f.existsSync()) return const [];
    return (jsonDecode(f.readAsStringSync()) as List<dynamic>)
        .whereType<String>()
        .map((d) => d.trim())
        .where((d) => d.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}
