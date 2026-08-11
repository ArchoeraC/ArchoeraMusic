/// KG 主进程服务（Dart 移植）——对齐 apis/kugou/index.ts。
///
/// 与 netease 不同：无账号体系、无 cookie、无加密 body，纯 HTTP GET。
/// 搜索主走 mobilecdn（含封面），失败兜底 songsearch（无封面）；
/// 歌词是 hash + 歌名 + 时长 三元组匹配。
///
/// 统一入口：[kgCall]。
library;

import '../lru_cache.dart';
import 'core/types.dart';
import 'modules/index.dart';

bool _isEmptyResult(Object? value) {
  if (value is! Map) return false;
  final songs = value['songs'];
  if (songs is List && songs.isEmpty) return true;
  return false;
}

final LruCache<Object> _apiCache = LruCache<Object>(shouldCache: (v) => !_isEmptyResult(v));

/// 清空 KG 接口缓存
void kgClearCache() => _apiCache.clear();

/// 调用任意 KG API
/// [name] 见 [kgModules] 的 key；不想命中缓存可传 `timestamp: DateTime.now()`
Future<Object?> kgCall(String name, [KgParams params = const {}]) async {
  final fn = kgModules[name];
  if (fn == null) throw StateError('unknown kg api: $name');

  final key = LruCache.key(name, params);
  final hit = _apiCache.get(key);
  if (hit != null) return hit;

  final value = await fn(params);
  if (value != null) _apiCache.set(key, value);
  return value;
}
