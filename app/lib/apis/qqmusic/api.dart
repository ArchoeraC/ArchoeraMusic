// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM 主进程服务（Dart 移植）——对齐 apis/qqmusic/index.ts。
///
/// 与 netease 不同：匿名 session（uid/sid）内存缓存 1h；登录 cookie 经
/// 宿主 [getRuntime().sessionStore]（平台键 'qqmusic'）持久化，请求自动注入。
/// 无加密 body（靠 UA + comm 伪装）。
///
/// 统一入口：[qmCall]。
library;

import '../lru_cache.dart';
import 'core/types.dart';
import 'modules/index.dart';

final LruCache<Object> _apiCache = LruCache<Object>();

/// 不缓存的实时接口
const Set<String> _qmNonCacheable = {
  'user_detail',
  'song_url',
  'comment',
  'login_qr_key',
  'login_qr_check',
  // 收藏写/读与红心状态强相关，禁用 LRU（否则红心切换后读列表命中旧缓存）
  'favorite_list',
  'favorite_add',
  'favorite_remove',
};

/// 清空 QM 接口缓存
void qmClearCache() => _apiCache.clear();

/// 调用任意 QM API
/// [name] 见 [qmModules] 的 key；[cache] 为 false（或接口本身非缓存）时不缓存。
/// 不想命中缓存也可传 `timestamp: DateTime.now()`。
Future<Object?> qmCall(String name, [QmParams params = const {}]) async {
  final fn = qmModules[name];
  if (fn == null) throw StateError('unknown qm api: $name');

  final key = LruCache.key(name, params);
  final hit = _apiCache.get(key);
  if (hit != null) return hit;

  final value = await fn(params);
  if (value != null && !_qmNonCacheable.contains(name)) _apiCache.set(key, value);
  return value;
}
