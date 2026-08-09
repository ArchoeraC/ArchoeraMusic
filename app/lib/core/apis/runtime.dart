/// 宿主运行时（依赖注入点）——对齐 apis/runtime.ts。
///
/// 平台 API 库不直接依赖侧车数据库 / 配置系统：会话（cookies）、歌词缓存、
/// 设置读取等经此接口由宿主注入；未注入时使用默认内存实现（进程内缓存，
/// 重启即失），保证库可独立运行。
library;

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
}

/// 宿主运行时能力
class ApisRuntime {
  ApisRuntime({
    this.getSetting = _noSetting,
    SessionStore? sessionStore,
    LyricCacheStore? lyricCache,
    LyricMatchCacheStore? lyricMatchCache,
    LyricTtmlCacheStore? lyricTtmlCache,
  })  : sessionStore = sessionStore ?? _MemSessionStore(),
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

  @override
  Map<String, dynamic>? get(String platform, String platformId) =>
      _map['$platform:$platformId'];

  @override
  void set(String platform, String platformId, Map<String, dynamic>? result) =>
      _map['$platform:$platformId'] = result;
}

class _MemMatchCacheStore implements LyricMatchCacheStore {
  final _map = <String, MatchedRecord>{};

  @override
  MatchedRecord? get(String fingerprint, String platform) =>
      _map['$fingerprint:$platform'];

  @override
  void set(
    String fingerprint,
    String platform,
    String platformId, [
    Map<String, dynamic>? extra,
  ]) =>
      _map['$fingerprint:$platform'] =
          MatchedRecord(platformId: platformId, extra: extra);
}

class _MemTtmlCacheStore implements LyricTtmlCacheStore {
  final _map = <String, String?>{};

  @override
  Object? get(String platform, String id) {
    final key = '$platform:$id';
    if (!_map.containsKey(key)) return lyricTtmlMiss;
    return _map[key];
  }

  @override
  void set(String platform, String id, String? content) =>
      _map['$platform:$id'] = content;
}

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
