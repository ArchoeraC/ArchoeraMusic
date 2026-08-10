import 'dart:convert';
import 'dart:io';

import '../apis/runtime.dart';
import 'data_dir.dart';

/// 文件型会话存储（cookies 落盘到数据目录 `netease_session.json`，
/// 替代 [SessionStore] 默认内存实现，登录态跨重启保留）。
class FileSessionStore implements SessionStore {
  static String get _path => '${resolveDataDir()}/netease_session.json';

  Map<String, dynamic> _loadAll() {
    try {
      final f = File(_path);
      if (!f.existsSync()) return {};
      final json = jsonDecode(f.readAsStringSync());
      if (json is Map<String, dynamic>) return json;
    } catch (_) {
      // 损坏文件回退空
    }
    return {};
  }

  void _saveAll(Map<String, dynamic> all) {
    try {
      final f = File(_path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(all));
    } catch (_) {
      // 持久化失败不阻塞（登录态重启丢失可接受）
    }
  }

  @override
  Map<String, String> get(String platform) {
    final all = _loadAll();
    final raw = all[platform];
    if (raw is! Map) return {};
    return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  @override
  void save(String platform, Map<String, String> cookies) {
    final all = _loadAll();
    all[platform] = {for (final e in cookies.entries) e.key: e.value};
    _saveAll(all);
  }

  @override
  void clear(String platform) {
    final all = _loadAll();
    all.remove(platform);
    _saveAll(all);
  }
}
