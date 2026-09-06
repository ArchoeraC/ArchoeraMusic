// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM 二维码登录模块（对齐 login_qr.ts + core/credential.ts）。
///
/// 仅支持 QQ 扫码登录：
/// - ptlogin2 ptqrshow 出码 → ptqrlogin 轮询 → check_sig 取 p_skey →
///   graph.qq.com authorize 换 code → QQConnectLogin 换 musickey
///
/// 成功后将凭据写入 host sessionStore（平台键 'qqmusic'，vault 加密）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/config.dart';
import '../core/credential.dart';
import '../core/request.dart';
import '../core/types.dart';

class _HttpResult {
  _HttpResult({
    required this.status,
    required this.body,
    this.location,
    this.setCookies = const [],
  });

  final int status;
  final Uint8List body;
  final String? location;
  final List<String> setCookies;

  String get text =>
      utf8.decode(body, allowMalformed: true).replaceAll('\uFFFD', '?');
}

Map<String, String> _cookieJar = <String, String>{};

Future<_HttpResult> _httpGet(
  String url, {
  Map<String, String>? headers,
  bool manual = false,
  Duration timeout = const Duration(seconds: 8),
}) =>
    _http('GET', url, headers: headers, manual: manual, timeout: timeout);

Future<_HttpResult> _httpPostForm(
  String url,
  Map<String, String> form, {
  Map<String, String>? headers,
  bool manual = false,
}) {
  final body = form.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
  return _http(
    'POST',
    url,
    bodyBytes: utf8.encode(body),
    headers: <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      ...?headers,
    },
    manual: manual,
  );
}

Future<_HttpResult> _http(
  String method,
  String url, {
  List<int>? bodyBytes,
  Map<String, String>? headers,
  bool manual = false,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final uri = Uri.parse(url);
    final req = method == 'GET'
        ? await client.getUrl(uri)
        : await client.postUrl(uri);
    req.followRedirects = !manual;
    req.headers.set('User-Agent', qmWebUa);
    if (headers != null) headers.forEach((k, v) => req.headers.set(k, v));
    final cookieStr = _stringifyCookies(_cookieJar);
    if (cookieStr.isNotEmpty) req.headers.set('Cookie', cookieStr);
    if (bodyBytes != null) req.add(bodyBytes);
    final res = await req.close().timeout(timeout);
    final bytes = await res.fold<BytesBuilder>(
      BytesBuilder(),
      (b, chunk) => b..add(chunk),
    );
    final setCookies = res.headers[HttpHeaders.setCookieHeader] ?? const [];
    _mergeCookies(setCookies);
    return _HttpResult(
      status: res.statusCode,
      body: bytes.takeBytes(),
      location: res.headers.value(HttpHeaders.locationHeader),
      setCookies: setCookies,
    );
  } finally {
    client.close();
  }
}

/// 从 Set-Cookie 原始串解析并合入 Cookie jar。
void _mergeCookies(List<String> rawList) {
  for (final raw in rawList) {
    final first = raw.split(';').first;
    final eq = first.indexOf('=');
    if (eq <= 0) continue;
    final name = first.substring(0, eq).trim();
    final value = first.substring(eq + 1).trim();
    if (name.isNotEmpty && value.isNotEmpty) _cookieJar[name] = value;
  }
}

String _stringifyCookies(Map<String, String> cookies) => cookies.entries
    .where((e) => e.value.isNotEmpty)
    .map((e) => '${e.key}=${e.value}')
    .join('; ');

/// 解析 `ptuiCB('...', '...', ...)` 中的字符串参数。
List<String> _parsePtuiArgs(String text) {
  final match = RegExp(r'ptuiCB\((.*?)\)').firstMatch(text);
  if (match == null) return const [];
  final body = match.group(1) ?? '';
  final args = <String>[];
  for (final m in RegExp(r"'((?:\\.|[^'])*)'").allMatches(body)) {
    args.add(m.group(1)!.replaceAll(r"\'", "'"));
  }
  return args;
}

String _joinForm(Map<String, String> form) =>
    form.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');

/// 登录前清空残留 cookie（避免上个账号污染）
void _resetJar() => _cookieJar = <String, String>{};

// ── 出码 ─────────────────────────────────────────────────────────────

/// 获取 QQ 登录二维码 Key 及图片内容（仅 QQ 扫码）。
Future<Map<String, dynamic>> _qrKey(String type) async {
  _resetJar();

  // QQ 扫码
  final url =
      'https://ssl.ptlogin2.qq.com/ptqrshow?appid=716027609&e=2&l=M&s=3&d=72&v=4&t=${DateTime.now().microsecondsSinceEpoch}&daid=383&pt_3rd_aid=100497308';
  final res = await _httpGet(
    url,
    headers: {'Referer': 'https://xui.ptlogin2.qq.com/'},
  );
  if (res.status != 200) {
    throw HttpException('获取 QQ 登录二维码失败: HTTP ${res.status}');
  }
  final qrsig = _cookieJar['qrsig'];
  if (qrsig == null || qrsig.isEmpty) {
    throw HttpException('未能获取到 QQ 登录 qrsig');
  }
  return <String, dynamic>{
    'code': 200,
    'key': qrsig,
    'content': 'data:image/png;base64,${base64Encode(res.body)}',
    'type': 'qq',
  };
}

// ── 轮询 ─────────────────────────────────────────────────────────────

/// 轮询 QQ 扫码状态：0=过期/取消 1=等待 2=已扫码待确认 4=成功（已写 cookie）。
Future<Map<String, dynamic>> _qrCheck(String key, String type) async {
  // QQ 扫码检查
  final ptqrtoken = qmHash33(key, 0);
  final now = DateTime.now().millisecondsSinceEpoch;
  final query = {
    'u1': 'https://graph.qq.com/oauth2.0/login_jump',
    'ptqrtoken': '$ptqrtoken',
    'ptredirect': '0',
    'h': '1',
    't': '1',
    'g': '1',
    'from_ui': '1',
    'ptlang': '2052',
    'action': '0-0-$now',
    'js_ver': '20102616',
    'js_type': '1',
    'pt_uistyle': '40',
    'aid': '716027609',
    'daid': '383',
    'pt_3rd_aid': '100497308',
    'has_onekey': '1',
  };
  _resetJar();
  _cookieJar['qrsig'] = key;
  final res = await _httpGet(
    'https://ssl.ptlogin2.qq.com/ptqrlogin?${_joinForm(query)}',
    headers: {'Referer': 'https://xui.ptlogin2.qq.com/'},
  );
  final args = _parsePtuiArgs(res.text);
  if (args.isEmpty) return {'code': 200, 'status': 1};

  final statusCode = args[0];
  final nickname = args.length > 5 ? args[5] : '';

  if (statusCode == '65') return {'code': 200, 'status': 0};
  if (statusCode == '67') return {'code': 200, 'status': 2, 'nickname': nickname};
  if (statusCode == '0') {
    final jumpUrl = args.length > 2 ? args[2] : '';
    if (jumpUrl.isEmpty || !jumpUrl.startsWith('http')) {
      throw HttpException('无效的跳转链接: $jumpUrl');
    }

    // check_sig 校验跳转并建立会话 Cookie（携带 ptqrlogin 返回的 cookies；
    // _http 会自动把响应 Set-Cookie 并入 [_cookieJar]）
    await _httpGet(
      jumpUrl,
      headers: {'Referer': 'https://xui.ptlogin2.qq.com/'},
      manual: true,
    );
    final pSkey = _cookieJar['p_skey'] ??
        _cookieJar['p_sKey'] ??
        _cookieJar['skey'] ??
        _cookieJar['pskey'];
    if (pSkey == null || pSkey.isEmpty) {
      throw HttpException('获取 p_skey 失败');
    }

    // authorize 换取授权 code。redirect_uri 为 QQ OAuth（client_id
    // 100497308）在 y.qq.com 注册的回跳页，页面名含 "wx" 属上游命名，
    // 属于 QQ 登录流程（非微信登录），不可改动。
    final authBody = <String, String>{
      'response_type': 'code',
      'client_id': '100497308',
      'redirect_uri':
          'https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/',
      'scope': 'get_user_info,get_app_friends',
      'state': 'state',
      'switch': '',
      'from_ptlogin': '1',
      'src': '1',
      'update_auth': '1',
      'openapi': '1010_1030',
      'g_tk': '${qmHash33(pSkey, 5381)}',
      'auth_time': '$now',
      'ui': _randHex(),
    };
    final authRes = await _httpPostForm(
      'https://graph.qq.com/oauth2.0/authorize',
      authBody,
      headers: {'Referer': 'https://xui.ptlogin2.qq.com/'},
      manual: true,
    );
    final location = authRes.location ?? '';
    final codeMatch = RegExp(r'(?:code=)(.+?)(?:&|$)').firstMatch(location);
    if (codeMatch == null) {
      throw HttpException('获取 QQ 授权 code 失败');
    }
    final code = codeMatch.group(1)!;

    // QQLogin 换取音乐凭据
    final qqLoginData = await qmRequest<Map<String, dynamic>>(
      'QQConnectLogin.LoginServer',
      'QQLogin',
      {'code': code},
      session: false,
      comm: {'tmeLoginType': 2},
    );
    final uinMatch = RegExp(r'(?:\?|&)uin=(.+?)&').firstMatch(jumpUrl);
    final uin = uinMatch?.group(1) ?? '';
    return _finalizeLogin(qqLoginData, fallbackUin: uin);
  }

  return {'code': 200, 'status': 1};
}

String _randHex() {
  final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  return '$now${now.hashCode.toRadixString(16).replaceAll('-', '')}';
}

/// 登录成功收尾：校验凭据 → 写 cookie → 返回 UI 结果。
Future<Map<String, dynamic>> _finalizeLogin(
  Map<String, dynamic> loginData, {
  String fallbackUin = '',
}) async {
  final uinStr = qmCredentialMusicId(loginData, fallbackUin);
  final musickey = loginData['musickey'];
  if (uinStr.isEmpty || musickey == null || '$musickey'.isEmpty) {
    throw HttpException('QQ登录响应缺少有效凭据');
  }
  final saved = qmCredentialToSession(
    loginData,
    fallbackMusicId: fallbackUin,
  );
  qmMergeQQMusicCookies(saved);
  final nick = loginData['nick'] ?? loginData['nickname'];
  final logo = loginData['logo'] ?? loginData['avatarUrl'];
  final fallbackAvatar =
      'https://q.qlogo.cn/headimg_dl?dst_uin=$uinStr&spec=100';
  return <String, dynamic>{
    'code': 200,
    'status': 4,
    'nickname': nick == null ? '' : '$nick',
    'avatarUrl': (logo == null || '$logo'.isEmpty)
        ? fallbackAvatar
        : '$logo',
  };
}

QmModule qmLoginQrKey = (params) async {
  final type = '${params['type'] ?? 'qq'}'.toLowerCase();
  return _qrKey(type);
};

QmModule qmLoginQrCheck = (params) async {
  final key = '${params['key'] ?? ''}';
  final type = '${params['type'] ?? 'qq'}'.toLowerCase();
  if (key.isEmpty) throw StateError('缺少二维码 key');
  return _qrCheck(key, type);
};

