// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM 凭据工具——对齐 apis/qqmusic/core/credential.ts。
///
/// 负责 cookie → Cookie 请求头、登录凭据 → 持久化会话字段等纯转换。
/// Cookie 的读写（落盘）在 core/request.dart 统一管理。
library;

/// 生成发送给 QM 的 Cookie 请求头；没有可发送字段时返回 null。
String? qmSessionToCookieHeader(Map<String, String> session) {
  final entries = session.entries.where((e) => e.value.isNotEmpty).toList();
  if (entries.isEmpty) return null;
  return entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// QQ 系哈希算法（ptqrtoken / g_tk 共用）。
///
/// JS 侧等价实现：每轮 `(h<<5)+h+code` 后 `& 0xffffffff` 保留低 32 位，
/// 最终 `& 2147483647` 清符号位。Dart 用 64 位 int 运算并显式掩码等价。
int qmHash33(String str, [int seed = 0]) {
  var h = seed & 0xFFFFFFFF;
  for (final code in str.codeUnits) {
    h = (((h << 5) + h + code) & 0xFFFFFFFF);
  }
  return h & 0x7FFFFFFF;
}

/// 从登录凭据中解析真实音乐账号 ID（去掉 'o' 前缀）。
String qmCredentialMusicId(Map<String, dynamic> credential,
    [String fallback = '']) {
  final raw = credential['str_musicid'] ?? credential['musicid'] ?? fallback;
  final s = '$raw'.trim();
  return s.startsWith('o') ? s.substring(1) : s;
}

/// 将登录凭据转换为可持久化的会话字段（QQ 扫码登录，tmeLoginType=2）。
Map<String, String> qmCredentialToSession(
  Map<String, dynamic> credential, {
  String fallbackMusicId = '',
}) {
  final musicId = qmCredentialMusicId(credential, fallbackMusicId);
  final session = <String, String>{
    'uin': musicId,
    'qm_str_musicid': musicId,
    'qm_keyst': '${credential['musickey'] ?? ''}',
    'qqmusic_key': '${credential['musickey'] ?? ''}',
    'tmeLoginType': '${credential['loginType'] ?? 2}',
  };

  void put(String key, String dest) {
    final v = credential[key];
    if (v != null && '$v'.isNotEmpty) session[dest] = '$v';
  }

  put('encryptUin', 'euin');
  put('openid', 'psrf_qqopenid');
  put('unionid', 'psrf_qqunionid');
  put('refresh_token', 'psrf_qqrefresh_token');
  put('access_token', 'psrf_qqaccess_token');
  put('refresh_key', 'qm_refresh_key');
  put('expired_at', 'psrf_access_token_expiresAt');
  put('musickeyCreateTime', 'psrf_musickey_createtime');
  return session;
}
