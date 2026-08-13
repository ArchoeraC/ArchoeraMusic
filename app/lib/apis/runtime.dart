/// 宿主运行时（依赖注入点）——对齐 apis/runtime.ts。
///
/// 平台 API 库不直接依赖侧车数据库 / 配置系统：会话（cookies）、歌词缓存、
/// 设置读取等经此接口由宿主注入；未注入时使用默认内存实现（进程内缓存，
/// 重启即失），保证库可独立运行。
library;

import 'dart:convert';

/// 第三方音源账号会话（cookies）存储
abstract class SessionStore {
  Map<String, String> get(String platform);
  void save(String platform, Map<String, String> cookies);
  void clear(String platform);
}

/// 歌词接口返回缓存
abstract class LyricCacheStore {
  Map<String, dynamic>? get(String platform, String platformId);
  void set(String platform, String platformId, Map<String, dynamic>? result);

  /// 缓存条目数（缓存管理统计用）。
  int get count;

  /// 清空全部缓存（缓存管理「清除」用）。
  void clear();
}

/// fuzzy 匹配缓存命中记录（对齐 MatchedRecord）
class MatchedRecord {
  const MatchedRecord({required this.platformId, this.extra});

  final String platformId;
  final Map<String, dynamic>? extra;
}

/// fuzzy 匹配映射缓存
abstract class LyricMatchCacheStore {
  MatchedRecord? get(String fingerprint, String platform);
  void set(
    String fingerprint,
    String platform,
    String platformId, [
    Map<String, dynamic>? extra,
  ]);

  /// 缓存条目数（缓存管理统计用）。
  int get count;

  /// 清空全部缓存（缓存管理「清除」用）。
  void clear();
}

/// TTML 未命中哨兵（区别于负缓存 null）
class _TtmlMiss {
  const _TtmlMiss();
}

const Object lyricTtmlMiss = _TtmlMiss();

/// TTML 歌词缓存：未命中返回 [lyricTtmlMiss]；命中返回内容（null 表示负缓存，72h 内不再网络请求）
abstract class LyricTtmlCacheStore {
  Object? get(String platform, String id);
  void set(String platform, String id, String? content);

  /// 缓存条目数（缓存管理统计用）。
  int get count;

  /// 清空全部缓存（缓存管理「清除」用）。
  void clear();
}

/// 宿主运行时能力
class ApisRuntime {
  ApisRuntime({
    this.getSetting = _noSetting,
    SessionStore? sessionStore,
    LyricCacheStore? lyricCache,
    LyricMatchCacheStore? lyricMatchCache,
    LyricTtmlCacheStore? lyricTtmlCache,
  }) : sessionStore = sessionStore ?? _MemSessionStore(),
       lyricCache = lyricCache ?? _MemLyricCacheStore(),
       lyricMatchCache = lyricMatchCache ?? _MemMatchCacheStore(),
       lyricTtmlCache = lyricTtmlCache ?? _MemTtmlCacheStore();

  /// 读取宿主设置（未知 key 返回 null）
  final dynamic Function(String key) getSetting;

  final SessionStore sessionStore;
  final LyricCacheStore lyricCache;
  final LyricMatchCacheStore lyricMatchCache;
  final LyricTtmlCacheStore lyricTtmlCache;
}

dynamic _noSetting(String key) => null;

// ── 默认内存实现（无宿主注入时使用） ──────────────────────────────

class _MemSessionStore implements SessionStore {
  final _map = <String, Map<String, String>>{};

  @override
  Map<String, String> get(String platform) => _map[platform] ?? {};

  @override
  void save(String platform, Map<String, String> cookies) =>
      _map[platform] = {...cookies};

  @override
  void clear(String platform) => _map[platform] = {};
}

class _MemLyricCacheStore implements LyricCacheStore {
  final _map = <String, Map<String, dynamic>?>{};
  int _bytes = 0;

  @override
  Map<String, dynamic>? get(String platform, String platformId) {
    final key = '$platform:$platformId';
    final v = _map.remove(key);
    if (v != null) _map[key] = v; // LRU 保活：重插使最近访问位于表尾
    return _map[key];
  }

  @override
  void set(String platform, String platformId, Map<String, dynamic>? result) {
    final key = '$platform:$platformId';
    final old = _map.remove(key);
    if (old != null) _bytes -= _sizeOfLyric(old);
    _map[key] = result;
    _bytes += _sizeOfLyric(result);
    _enforceLimit();
  }

  /// 超限按 LRU 淘汰（表头 = 最久未访问）。
  void _enforceLimit() {
    final limit = lyricCacheLimitBytes;
    if (limit == null) return;
    while (_bytes > limit && _map.isNotEmpty) {
      final k = _map.keys.first;
      _bytes -= _sizeOfLyric(_map.remove(k));
    }
  }

  @override
  int get count => _map.length;

  @override
  void clear() {
    _map.clear();
    _bytes = 0;
  }
}

class _MemMatchCacheStore implements LyricMatchCacheStore {
  final _map = <String, MatchedRecord>{};
  int _bytes = 0;

  @override
  MatchedRecord? get(String fingerprint, String platform) {
    final key = '$fingerprint:$platform';
    final v = _map.remove(key);
    if (v != null) _map[key] = v; // LRU 保活
    return _map[key];
  }

  @override
  void set(
    String fingerprint,
    String platform,
    String platformId, [
    Map<String, dynamic>? extra,
  ]) {
    final key = '$fingerprint:$platform';
    final old = _map.remove(key);
    if (old != null) _bytes -= 64;
    _map[key] = MatchedRecord(platformId: platformId, extra: extra);
    _bytes += 64;
    _enforceLimit();
  }

  /// 超限按 LRU 淘汰（表头 = 最久未访问）。
  void _enforceLimit() {
    final limit = lyricMatchCacheLimitBytes;
    if (limit == null) return;
    while (_bytes > limit && _map.isNotEmpty) {
      _map.remove(_map.keys.first);
      _bytes -= 64;
    }
  }

  @override
  int get count => _map.length;

  @override
  void clear() {
    _map.clear();
    _bytes = 0;
  }
}

class _MemTtmlCacheStore implements LyricTtmlCacheStore {
  final _map = <String, String?>{};
  int _bytes = 0;

  @override
  Object? get(String platform, String id) {
    final key = '$platform:$id';
    final v = _map.remove(key);
    if (v != null) _map[key] = v; // LRU 保活
    if (!_map.containsKey(key)) return lyricTtmlMiss;
    return _map[key];
  }

  @override
  void set(String platform, String id, String? content) {
    final key = '$platform:$id';
    final old = _map.remove(key);
    if (old != null) _bytes -= _sizeOfTtml(old);
    _map[key] = content;
    _bytes += _sizeOfTtml(content);
    _enforceLimit();
  }

  /// 超限按 LRU 淘汰（表头 = 最久未访问）。
  void _enforceLimit() {
    final limit = lyricTtmlCacheLimitBytes;
    if (limit == null) return;
    while (_bytes > limit && _map.isNotEmpty) {
      final k = _map.keys.first;
      _bytes -= _sizeOfTtml(_map.remove(k));
    }
  }

  @override
  int get count => _map.length;

  @override
  void clear() {
    _map.clear();
    _bytes = 0;
  }
}

/// 歌词缓存上限（字节）；null = 无上限。由主程序按偏好设置。
int? lyricCacheLimitBytes;
int? lyricMatchCacheLimitBytes;
int? lyricTtmlCacheLimitBytes;

/// 歌词内容近似字节数：JSON 字符数（UTF-8 近似，含中文按多字节偏保守）。
int _sizeOfLyric(Map<String, dynamic>? v) =>
    v == null ? 0 : jsonEncode(v).length;

/// TTML 文本近似字节数：UTF-16 码元数 × 2。
int _sizeOfTtml(String? v) => v == null ? 0 : v.length * 2;

ApisRuntime _runtime = ApisRuntime();

/// 当前宿主运行时
ApisRuntime getRuntime() => _runtime;

/// 注入宿主运行时（未提供的项回退内存实现）
void setRuntime({ApisRuntime? runtime, dynamic Function(String)? getSetting}) {
  if (runtime != null) {
    _runtime = runtime;
  } else {
    _runtime = ApisRuntime(getSetting: getSetting ?? _noSetting);
  }
}
