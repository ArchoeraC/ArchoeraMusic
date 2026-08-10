/// 接口响应内存缓存——对齐 apis/netease/core/cache.ts。
///
/// 默认 2 分钟 TTL；只缓存 status === 200 的响应；
/// key = `${name}|${md5(params)}`。
library;

import '../../lru_cache.dart';

class NeteaseCacheValue {
  NeteaseCacheValue(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;
}

final LruCache<NeteaseCacheValue> _apiCache = LruCache<NeteaseCacheValue>(
  shouldCache: (v) => v.status == 200,
);

/// 构造缓存 key
String nmBuildCacheKey(String name, Map<String, dynamic>? params) =>
    LruCache.key(name, params);

NeteaseCacheValue? nmCacheGet(String key) => _apiCache.get(key);

void nmCacheSet(String key, NeteaseCacheValue value, [int? ttl]) =>
    _apiCache.set(key, value, ttl);

void nmCacheClear() => _apiCache.clear();
