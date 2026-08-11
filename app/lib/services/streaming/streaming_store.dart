/// 流媒体服务器配置持久化（对齐 shared/types/streaming.ts StreamingApi）。
///
/// 轻量 JSON 文件（数据目录 `streaming_servers.json`），与 AppPrefs 同风格，
/// 避免为服务器列表引入 Hive/drift 依赖。
library;

import 'dart:convert';
import 'dart:io';

import '../../stores/data_dir.dart';
import 'streaming_types.dart';

/// 服务器配置存储。
class StreamingStore {
  StreamingStore._();

  /// 存储文件路径：数据目录（`~/.local/share/ArchoeraMusic`）。
  static String get filePath =>
      '${resolveDataDir()}/streaming_servers.json';

  /// 读取服务器列表 + 当前激活服务器 id。
  static ({List<StreamingServerConfig> servers, String? activeServerId}) load() {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return (servers: const [], activeServerId: null);
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map) {
        final raw = json['servers'];
        final servers = raw is List
            ? raw
                .whereType<Map>()
                .map((e) => StreamingServerConfig.fromJson(e.cast<String, dynamic>()))
                .toList()
            : <StreamingServerConfig>[];
        return (servers: servers, activeServerId: json['activeServerId']?.toString());
      }
    } catch (_) {
      // 损坏的存储文件：回退空列表
    }
    return (servers: const [], activeServerId: null);
  }

  /// 保存服务器列表 + 当前激活服务器 id。
  static void save(List<StreamingServerConfig> servers, String? activeServerId) {
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'servers': servers.map((s) => s.toJson()).toList(),
        'activeServerId': activeServerId,
      }));
    } catch (_) {
      // 持久化失败不阻塞（自用项目，配置丢失可接受）
    }
  }
}
