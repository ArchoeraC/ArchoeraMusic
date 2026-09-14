// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水（soda）API 主进程服务——对齐 QQ/netease 的 `qmCall/qmModules` 范式。
///
/// 统一入口 [sodaCall]；响应 LRU 缓存（`play_info` 等时效接口不缓存）。
/// 所有出站经 [sodaGetJson] 的官方域名硬校验（见 core/request.dart）。
library;

import '../lru_cache.dart';
import 'core/types.dart';
import 'modules/index.dart';

final LruCache<Object> _apiCache = LruCache<Object>();

/// 不缓存的实时接口（取流 URL 有时效；登录接口有一次性状态）。
const Set<String> _sodaNonCacheable = {
  'play_info',
  'comments',
  'send_comment',
  'login_qr_key',
  'login_qr_check',
  'login_send_code',
  'login_validate_code',
  'login_upsms',
};

/// 清空汽水接口缓存。
void sodaClearCache() => _apiCache.clear();

/// 调用任意汽水 API。
Future<Object?> sodaCall(String name, [SodaParams params = const {}]) async {
  final fn = sodaModules[name];
  if (fn == null) throw StateError('unknown soda api: $name');

  final key = LruCache.key(name, params);
  final hit = _apiCache.get(key);
  if (hit != null) return hit;

  final value = await fn(params);
  if (value != null && !_sodaNonCacheable.contains(name)) {
    _apiCache.set(key, value);
  }
  return value;
}
