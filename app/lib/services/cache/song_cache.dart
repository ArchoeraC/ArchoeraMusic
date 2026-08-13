import 'dart:io';

import '../../stores/data_dir.dart';

/// 歌曲磁盘缓存（流媒体歌曲文件级缓存，对齐 SPlayer-Next songCache 异步模型）。
///
/// - 播放时照常走在线 URL（不增加播放延迟），同时后台把整曲下载入缓存；
/// - 下次播放同曲目（source + id + quality 相同）命中缓存 → 直接 load 本地文件；
/// - 超上限按 LRU 淘汰（文件 mtime = 最近访问，命中时 touch 保活）。
///
/// 纯文件层，不依赖 Riverpod：开关 / 上限由调用方从 [AppPrefs] 读取传入。
class SongCache {
  SongCache._();

  static final SongCache shared = SongCache._();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  /// 缓存根目录：统一收敛在 `<数据目录>/cache/` 下，与数据库（*.db /
  /// prefs.json / streaming_servers.json 等散文件）隔开，防止缓存文件
  /// 与用户数据混淆造成不可逆损坏。
  String rootDir() => '${resolveDataDir()}/cache/song-cache';

  /// 旧布局（`<数据目录>/song-cache`）迁移标记：仅首次命中时搬移一次。
  bool _migrated = false;

  /// 一次性迁移旧缓存目录（v0.8.7 前的 `<数据目录>/song-cache` → cache/ 下）。
  /// 目标已有同名文件时跳过（优先保留新缓存），迁移失败静默不阻断。
  void _migrateOnce() {
    if (_migrated) return;
    _migrated = true;
    try {
      final old = Directory('${resolveDataDir()}/song-cache');
      if (!old.existsSync()) return;
      final dir = Directory(rootDir());
      dir.createSync(recursive: true);
      for (final e in old.listSync()) {
        if (e is! File) continue;
        final dst = File('${dir.path}/${e.uri.pathSegments.last}');
        if (!dst.existsSync()) e.renameSync(dst.path);
      }
      old.deleteSync(recursive: true);
    } catch (_) {
      // 迁移失败静默：下次启动重试
    }
  }

  /// 缓存键（文件名安全）：`<source>_<id>_<quality>.audio`。
  String cacheKeyFor(String source, String id, String quality) =>
      '${source}_${id}_$quality.audio';

  /// 命中查询：文件存在则刷新 mtime（LRU 保活）并返回绝对路径，否则 null。
  String? lookup(String key) {
    _migrateOnce();
    final f = File('${rootDir()}/$key');
    if (!f.existsSync()) return null;
    try {
      f.setLastModifiedSync(DateTime.now());
    } catch (_) {
      // touch 失败不阻断命中
    }
    return f.path;
  }

  /// 进行中的下载（按 key 去重，避免同一曲目并发重复下载）。
  final Set<String> _inFlight = {};

  /// 后台缓存一首曲目：HTTP 下载 [url] 到临时文件 → 原子改名入缓存 → trim。
  ///
  /// 失败静默（缓存仅是加速，不影响在线播放）；中断时清理临时文件。
  Future<void> storeAsync(
    String key,
    String url, {
    String referer = '',
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_inFlight.add(key)) return;
    _migrateOnce();
    final dir = Directory(rootDir());
    final part = File('${dir.path}/.tmp_$key.part');
    try {
      dir.createSync(recursive: true);
      final client = HttpClient()..connectionTimeout = timeout;
      final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      if (referer.isNotEmpty) {
        req.headers.set(HttpHeaders.refererHeader, referer);
      }
      final res = await req.close().timeout(timeout);
      client.close();
      if (res.statusCode != HttpStatus.ok) return;
      final sink = part.openSync(mode: FileMode.writeOnly);
      try {
        await for (final chunk in res) {
          sink.writeFromSync(chunk);
        }
      } finally {
        sink.closeSync();
      }
      // 原子入缓存：先删旧目标，避免覆盖正在播放的文件
      final dst = File('${dir.path}/$key');
      if (dst.existsSync()) dst.deleteSync();
      part.renameSync(dst.path);
    } catch (_) {
      // 网络/磁盘失败静默
    } finally {
      _inFlight.remove(key);
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
    }
  }

  /// 按 LRU 淘汰至上限以内：超限时按 mtime 最旧删除。
  void trim(int limitMiB) {
    _migrateOnce();
    try {
      final dir = Directory(rootDir());
      if (!dir.existsSync()) return;
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => !f.path.endsWith('.part'))
              .toList()
            ..sort(
              (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
            );
      var total = files.fold<int>(0, (s, f) => s + f.lengthSync());
      final limit = limitMiB * 1024 * 1024;
      for (final f in files) {
        if (total <= limit) break;
        final len = f.lengthSync();
        try {
          f.deleteSync();
          total -= len;
        } catch (_) {
          // 占用中/只读，跳过
        }
      }
    } catch (_) {
      // 目录不可读/统计异常静默
    }
  }

  /// 缓存统计：(总字节, 文件数)。异常时返回 (0, 0)。
  (int bytes, int files) stats() {
    _migrateOnce();
    try {
      final dir = Directory(rootDir());
      if (!dir.existsSync()) return (0, 0);
      var bytes = 0, count = 0;
      for (final e in dir.listSync()) {
        if (e is File && !e.path.endsWith('.part')) {
          count++;
          bytes += e.lengthSync();
        }
      }
      return (bytes, count);
    } catch (_) {
      return (0, 0);
    }
  }

  /// 清空全部缓存文件。
  void clear() {
    _migrateOnce();
    try {
      final dir = Directory(rootDir());
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // 静默
    }
  }
}
