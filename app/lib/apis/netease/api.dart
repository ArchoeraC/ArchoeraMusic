// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Netease API 主入口（Dart 移植）——对齐 apis/netease/index.ts。
///
/// 统一入口 [nmCallNetease]：会话注入（内存缓存）→ 响应缓存 → 模块路由 →
/// 仅登录相关接口将响应 cookie 写回会话存储。
library;

import 'dart:math';

import '../runtime.dart';
import 'core/cache.dart';
import 'core/cookie.dart';
import 'core/device.dart';
import 'core/request.dart';
import 'core/xeapi.dart';
import 'modules/index.dart';

/// 会变更登录态的接口：响应里若带 set-cookie 才写回会话存储
const _sessionMutating = <String>{
  'login',
  'login_cellphone',
  'login_qr_check',
  'login_refresh',
  'logout',
  'register_anonimous',
};

/// 不采用缓存的实时接口
const _nonCacheable = <String>{
  'song_url',
  'song_download_url',
  'scrobble',
  'scrobble_v1',
  'like',
  'comment_add',
  'playlist_create',
  'playlist_delete',
  'playlist_tracks',
  'playlist_subscribe',
  'playlist_name_update',
  'playlist_desc_update',
  'playlist_order_update',
  'playlist_detail',
  'user_playlist',
  'user_subcount',
  'user_cloud',
  'user_cloud_del',
  'cloud_upload_check',
  'cloud_nos_token',
  'cloud_upload_info',
  'cloud_pub',
  'cloud_upload_check_v2',
  'cloud_song_import',
  'album_sub',
  'playmode_intelligence',
  'personal_fm',
  'fm_trash',
  'recommend_songs',
  // 登录流：二维码与轮询必须实时（缓存会导致轮询停在首个状态 / 二维码失效）
  'login_qr_key',
  'login_qr_create',
  'login_qr_check',
  // 登录 / 会话：必须实时，缓存会产生陈旧登录态
  'login',
  'login_cellphone',
  'login_refresh',
  'login_status',
  'logout',
  'captcha_sent',
  'captcha_verify',
  'register_anonimous',
  // 喜欢列表：用户红心变更后需立即反映
  'likelist',
};

/// 国内 IP 前缀池
const _cnIpPrefixes = [
  '116.25',
  '121.8',
  '120.36',
  '39.144',
  '117.136',
  '223.104',
  '171.8',
  '182.140',
];

/// 本会话的国内 IP（进程内缓存）
String _cachedRealIp = '';
String _sessionRealIp() {
  if (_cachedRealIp.isEmpty) {
    final rng = Random.secure();
    final prefix = _cnIpPrefixes[rng.nextInt(_cnIpPrefixes.length)];
    final third = rng.nextInt(256);
    final fourth = 1 + rng.nextInt(254);
    _cachedRealIp = '$prefix.$third.$fourth';
  }
  return _cachedRealIp;
}

/// 内存缓存
Map<String, String>? _sessionCache;
Future<void>? _anonymousSessionPromise;

/// 把会话中的 deviceId / MUSIC_A 同步到进程级设备态（对齐 index.ts syncDeviceState）
void _syncDeviceState(Map<String, String> session) {
  final deviceId = session['deviceId'] ?? '';
  if (deviceId.isNotEmpty) nmSetDeviceId(deviceId);
  nmSetAnonymousToken(session['MUSIC_A'] ?? '');
}

Map<String, String> _loadSession() {
  if (_sessionCache == null) {
    _sessionCache = getRuntime().sessionStore.get('netease');
    _syncDeviceState(_sessionCache!);
  }
  return _sessionCache!;
}

void _persistSession(Map<String, String> cookies) {
  _sessionCache = cookies;
  _syncDeviceState(cookies);
  getRuntime().sessionStore.save('netease', cookies);
}

/// 确保未登录时已有稳定的 MUSIC_A（匿名 token）与 deviceId（对齐
/// `ensureNeteaseAnonymousSession`）。并发安全：同一时刻只注册一次。
Future<void> ensureNeteaseAnonymousSession() async {
  final session = _loadSession();
  if ((session['MUSIC_U'] ?? '').isNotEmpty ||
      (session['MUSIC_A'] ?? '').isNotEmpty ||
      nmGetAnonymousToken().isNotEmpty) {
    return;
  }
  final pending = _anonymousSessionPromise;
  if (pending != null) return pending;
  final future = _registerAnonymous();
  _anonymousSessionPromise = future;
  try {
    await future;
  } finally {
    if (identical(_anonymousSessionPromise, future)) {
      _anonymousSessionPromise = null;
    }
  }
}

Future<void> _registerAnonymous() async {
  final fn = modules['register_anonimous'];
  if (fn == null) throw StateError('unknown netease api: register_anonimous');
  final session = _loadSession();
  final result = await fn({'cookie': {...session}}, createRequest);
  final body = result.body;
  final patch = _parseSetCookie(result.cookie);
  final token = body['token'] is String
      ? body['token'] as String
      : (patch['MUSIC_A'] ?? '');
  if (token.isEmpty) {
    throw StateError('netease anonymous registration missing MUSIC_A');
  }
  _persistSession({
    ..._loadSession(),
    ...patch,
    'MUSIC_A': token,
    'deviceId': nmGetDeviceId(),
  });
  nmCacheClear();
}

/// "k1=v1; k2=v2; ..." 形式序列化
String _serialize(Map<String, String> cookies) =>
    cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

Map<String, String> nmGetNeteaseCookies() => {..._loadSession()};

void nmSetNeteaseCookies(Map<String, String> cookies) {
  _persistSession(cookies);
  nmCacheClear();
}

void nmMergeNeteaseCookies(Map<String, String> patch) {
  _persistSession({..._loadSession(), ...patch});
  nmCacheClear();
}

void nmClearNeteaseCookies() {
  _sessionCache = {};
  nmSetAnonymousToken('');
  nmResetXeapiKey();
  getRuntime().sessionStore.clear('netease');
  nmCacheClear();
}

/// set-cookie 数组 → 扁平对象（只取 key=value，忽略 Path/Domain/Max-Age 等属性）
Map<String, String> _parseSetCookie(List<String> arr) {
  final out = <String, String>{};
  for (final raw in arr) {
    final first = raw.split(';').first;
    final eq = first.indexOf('=');
    if (eq <= 0) continue;
    final key = first.substring(0, eq).trim();
    final val = first.substring(eq + 1).trim();
    if (key.isNotEmpty) out[key] = val;
  }
  return out;
}

/// 调用任意 Netease API（[name] 见 modules/index.dart 中的 key）
Future<({int status, Map<String, dynamic> body})> nmCallNetease(
  String name, [
  Map<String, dynamic> params = const {},
]) async {
  final fn = modules[name];
  if (fn == null) throw StateError('unknown netease api: $name');

  // 非登录/会话接口：确保未登录时已有匿名态（MUSIC_A）——否则搜索/曲库类
  // 接口可能返回空（对齐 index.ts ensureNeteaseAnonymousSession）。
  final isSessionEndpoint = name.startsWith('login') ||
      name.startsWith('captcha') ||
      name == 'logout' ||
      name == 'register_anonimous';
  if (!isSessionEndpoint && params['cookie'] == null) {
    try {
      await ensureNeteaseAnonymousSession();
    } catch (_) {
      // 匿名注册可能被风控/限流拒绝（code 400）：不阻断请求本身，
      // 大量接口匿名态下仍可用；注册成功后会落盘供后续复用。
    }
  }

  final session = _loadSession();

  // 读缓存
  final cacheable = !_nonCacheable.contains(name);
  final cacheKey = cacheable ? nmBuildCacheKey(name, params) : '';
  if (cacheable) {
    final hit = nmCacheGet(cacheKey);
    if (hit != null) return (status: hit.status, body: hit.body);
  }

  final query = <String, dynamic>{
    ...params,
    'cookie': params['cookie'] is String
        ? nmCookieToJson(params['cookie'] as String)
        : (params['cookie'] as Map<String, dynamic>?) ?? {...session},
  };

  // 注入国内 IP
  if (getRuntime().getSetting('system.neteaseRealIp') == true && query['realIP'] == null) {
    query['realIP'] = _sessionRealIp();
  }

  final res = await fn(query, createRequest);

  // 仅登录态变更接口才把响应 cookie 写回
  if (_sessionMutating.contains(name)) {
    final patch = _parseSetCookie(res.cookie);
    if (name == 'register_anonimous') {
      final token = res.body['token'];
      if (token is String && token.isNotEmpty) patch['MUSIC_A'] = token;
      patch['deviceId'] = nmGetDeviceId();
    }
    if (patch.isNotEmpty) {
      _persistSession({..._loadSession(), ...patch});
      nmCacheClear();
    }
  }

  if (cacheable && res.status == 200) {
    nmCacheSet(cacheKey, NeteaseCacheValue(res.status, res.body));
  }
  return (status: res.status, body: res.body);
}

/// 调试用：当前 cookie 序列化字符串
String nmCurrentCookieString() => _serialize(_loadSession());
