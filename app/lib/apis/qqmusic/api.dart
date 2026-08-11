/// QM 主进程服务（Dart 移植）——对齐 apis/qqmusic/index.ts。
///
/// 与 netease 不同：无持久化 session（uid/sid 匿名态内存缓存 1h）、
/// 无 cookie 登录态、无加密 body（靠 UA + comm 伪装）。
///
/// 统一入口：[qmCall]。
library;

import '../lru_cache.dart';
import 'core/types.dart';
import 'modules/index.dart';

final LruCache<Object> _apiCache = LruCache<Object>();

/// 清空 QM 接口缓存
void qmClearCache() => _apiCache.clear();

/// 调用任意 QM API
/// [name] 见 [qmModules] 的 key；不想命中缓存可传 `timestamp: DateTime.now()`
Future<Object?> qmCall(String name, [QmParams params = const {}]) async {
  final fn = qmModules[name];
  if (fn == null) throw StateError('unknown qm api: $name');

  final key = LruCache.key(name, params);
  final hit = _apiCache.get(key);
  if (hit != null) return hit;

  final value = await fn(params);
  if (value != null) _apiCache.set(key, value);
  return value;
}
