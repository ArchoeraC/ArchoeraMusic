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

/// 默认下载根目录（对齐设计文档 §11：`~/Music/ArchoeraMusic`，
/// Scanner 可识别；可在设置页修改）。
String defaultDownloadRoot() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return '$home/Music/ArchoeraMusic';
}
