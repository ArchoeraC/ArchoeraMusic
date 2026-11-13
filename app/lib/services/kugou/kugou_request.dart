// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// KG 请求层（Dart 移植）
///
/// 对齐 apis/kugou/core/request.ts + KuGouMusicApi util/request.js：
/// - 搜索/歌词接口无鉴权（mobilecdn 需 http，证书是共享 CDN 的）
/// - 取 URL 需先 /register/dev 拿真实 dfid，再带 android 签名访问
///   gateway.kugou.com/v5/url
///
/// 成功码约定不统一：songsearch/mobilecdn 用 error_code=0，lyrics 用
/// error_code=200；v5/url 用 status=1。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'kugou_crypto.dart';

/// 主搜索（带封面）：mobilecdn 的 /api/v3/search/song，公网无鉴权
const kgMobilecdnUrl = 'http://mobilecdn.kugou.com/api/v3/search/song';

/// 热搜：mobilecdn 的 /api/v3/search/hot，公网无鉴权
const kgSearchHotUrl = 'http://mobilecdn.kugou.com/api/v3/search/hot';

/// 兜底搜索：songsearch.kugou.com（无封面）
const kgSearchUrl = 'https://songsearch.kugou.com/song_search_v2';

/// 设备注册：拿真实 dfid（v5/url 前置条件）。
///
/// 2026-10 上游 `1c73c64` 将 v2 升级为 v3（`/register/dev` 获取失败修复），
/// v2 会频繁返回空 dfid，进而让客户端不断换设备重试，触发风控。
const kgRegisterUrl = 'https://userservice.kugou.com/risk/v3/r_register_dev';

/// 取歌曲 URL（签名 + key）
const kgSongUrl = 'https://gateway.kugou.com/v5/url';

/// 扫码登录：二维码 key 生成（web 签名）
const kgQrKeyUrl = 'https://login-user.kugou.com/v2/qrcode';

/// 扫码登录：轮询扫码状态（web 签名；status=4 时返回 token/userid）
const kgQrCheckUrl = 'https://login-user.kugou.com/v2/get_userinfo_qrcode';

/// 扫码登录页（拼上 qrcode=key 后用 qr 库生成二维码图）
const kgQrLoginPage = 'https://h5.kugou.com/apps/loginQRCode/html/index.html';

/// 歌词搜索/下载接口
const kgLyricSearchUrl = 'http://lyrics.kugou.com/search';
const kgLyricDownloadUrl = 'http://lyrics.kugou.com/download';

/// 歌词接口需要的伪装 headers（来自 KuGou2012 PC 客户端）
const kgLyricHeaders = <String, String>{
  'KG-RC': '1',
  'KG-THash': 'expand_search_manager.cpp:852736169:451',
  'User-Agent': 'KuGou2012-9020-ExpandSearchManager',
};

/// android 客户端 UA（对齐 KuGouMusicApi request.js）
const kgAndroidUa = 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';

/// 概念版 lite 的 gitversion（验证码登录 t1/t2 设备信封的一部分）。
const kgLiteGitVersion = '5f0b7c4';

/// 概念版验证码登录 t1 的固定 key/iv（AES-256-CBC）。
const _kgLiteT1Key = '5e4ef500e9597fe004bd09a46d8add98';
const _kgLiteT1Iv = '04bd09a46d8add98';

/// 概念版验证码登录 t2 的固定 key/iv（AES-256-CBC）。
const _kgLiteT2Key = 'fd14b35e3f81af3817a20ae7adae7020';
const _kgLiteT2Iv = '17a20ae7adae7020';

/// v5/url 基础请求参数（对齐 KuGouMusicApi module/song_url.js）。
///
/// 注意：取流接口的 `clientver` 上游固定为 11430（比 lite 默认 11440 旧），
/// 与 `version` 一致；沿用 11440 会与官方 lite 客户端参数对不上。
const kgSongUrlBase = <String, dynamic>{
  'album_id': 0,
  'area_code': 1,
  'ssa_flag': 'is_fromtrack',
  'version': 11430,
  'page_id': 967177915,
  'album_audio_id': 0,
  'behavior': 'play',
  'pid': 411,
  'cmd': 26,
  'pidversion': 3001,
  'IsFreePart': 0,
  'ppage_id': '356753938,823673182,967485191',
  'cdnBackup': 1,
  'module': '',
  'clientver': 11430,
};

/// register_dev 的设备信息（对齐 module/register_dev.js 默认值）
const _kgDevice = <String, dynamic>{
  'availableRamSize': 4983533568,
  'availableRomSize': 48114719,
  'availableSDSize': 48114717,
  'basebandVer': '',
  'batteryLevel': 100,
  'batteryStatus': 3,
  'brand': 'Redmi',
  'buildSerial': 'unknown',
  'device': 'marble',
  'imei': 'unknown',
  'imsi': '',
  'manufacturer': 'Xiaomi',
  'uuid': 'unknown',
  'accelerometer': false,
  'accelerometerValue': '',
  'gravity': false,
  'gravityValue': '',
  'gyroscope': false,
  'gyroscopeValue': '',
  'light': false,
  'lightValue': '',
  'magnetic': false,
  'magneticValue': '',
  'orientation': false,
  'orientationValue': '',
  'pressure': false,
  'pressureValue': '',
  'step_counter': false,
  'step_counterValue': '',
  'temperature': false,
  'temperatureValue': '',
};

/// 清洗 KG 响应文本：剥离 `<!--KG_TAG_RES_START-->` / `<!--KG_TAG_RES_END-->`
/// 包裹注释（网关/部分 CDN 会加，直接 jsonDecode 会 FormatException）。
/// 对齐 KuGouMusicApi `cleanKgResponse`。
String kgCleanResponse(String text) => text
    .trim()
    .replaceFirst(RegExp(r'^<!--KG_TAG_RES_START-->'), '')
    .replaceFirst(RegExp(r'<!--KG_TAG_RES_END-->$'), '');

/// 一次 KG GET 请求 → 解析 JSON body；失败抛 [KgApiException] 由上层兜底
Future<dynamic> kgGet(
  Uri uri, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    headers?.forEach(req.headers.set);
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) {
      throw KgApiException('KG HTTP ${res.statusCode}');
    }
    final ssaCode = _kgSsaCode(res);
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    final text = kgCleanResponse(utf8.decode(bytes, allowMalformed: true));
    dynamic body;
    try {
      body = jsonDecode(text);
    } on FormatException {
      // 非 JSON 且带 ssa：无法判断业务结果，按需要验证处理。
      if (ssaCode != null) throw KgRiskVerifyException(ssaCode);
      rethrow;
    }
    // ssa-code 在成功响应上也可能出现（上游会附着 edt/sid）；只有业务
    // 确实失败时才中断，避免把已经成功的登录/操作误判为风控失败。
    if (ssaCode != null && _kgBodyIsFailure(body)) {
      throw KgRiskVerifyException(ssaCode);
    }
    return body;
  } finally {
    client.close(force: true);
  }
}

/// 一次 KG POST 请求（register_dev 用），返回原始字节
Future<Uint8List> kgPost(
  Uri uri, {
  required String body,
  required Map<String, String> headers,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(uri).timeout(timeout);
    headers.forEach(req.headers.set);
    req.write(body);
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) {
      throw KgApiException('KG POST HTTP ${res.statusCode}');
    }
    final ssaCode = _kgSsaCode(res);
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    if (ssaCode != null) {
      // JSON 响应能判断成功/失败；加密/二进制响应无法判断，按需要验证处理
      // （register_dev 失败会走 _safeDfid 的降级路径，不会误伤登录成功）。
      try {
        final text = kgCleanResponse(utf8.decode(bytes, allowMalformed: true));
        final body = jsonDecode(text);
        if (_kgBodyIsFailure(body)) throw KgRiskVerifyException(ssaCode);
      } on FormatException {
        throw KgRiskVerifyException(ssaCode);
      }
    }
    return Uint8List.fromList(bytes);
  } finally {
    client.close(force: true);
  }
}

/// 读取 SSA 事件 id（响应头大小写不敏感，兼容 `ssa`）。
String? _kgSsaCode(HttpClientResponse res) {
  for (final name in const ['ssa-code', 'ssa']) {
    final value = res.headers.value(name)?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// 兼容两种失败码约定：status=0 或 error_code 非 0/200。
bool _kgBodyIsFailure(dynamic body) {
  if (body is! Map) return false;
  final status = body['status'];
  if (status is num && status == 0) return true;
  final raw = body['error_code'] ?? body['errcode'] ?? body['err_code'];
  final code = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
  return code != 0 && code != 200;
}

/// KG 业务异常
class KgApiException implements Exception {
  KgApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 服务端返回 `ssa-code`：需要完成二次安全验证后才能重试原请求。
///
/// [eventId] 是风控事件 id，交给 UI 走 `/get/verify/info` → `/sidedt`。
class KgRiskVerifyException extends KgApiException {
  KgRiskVerifyException(this.eventId) : super('KG 要求安全验证（eventid=$eventId）');

  final String eventId;
}

/// 验证未完成/验证后仍被拦截：这是给用户看的最终提示。
class KgRiskVerifyRequiredException extends KgApiException {
  KgRiskVerifyRequiredException(super.message);
}

/// 按「签名原文」拼接 query：`key=value`（空值保留 `=`，逗号等不做
/// URL 编码）。服务器按收到的参数原文校验 signature，Uri 的
/// queryParameters 会把空值变成裸键（丢 `=`）、编码逗号，导致验签失败。
String kgQueryString(Map<String, dynamic> params) =>
    params.entries.map((e) => '${e.key}=${e.value}').join('&');

/// 值做标准 URL 编码的 query（扫码登录用：qrcode_txt 含 `://?&` 等，
/// 必须编码，否则会被当作参数分隔符截断；服务器解码后按原文验签）。
String kgQueryStringEncoded(Map<String, dynamic> params) => params.entries
    .map((e) => '${e.key}=${Uri.encodeQueryComponent('${e.value}')}')
    .join('&');

/// 生成扫码登录二维码 key。
/// 对齐 KuGouMusicApi module/login_qr_key.js：GET login-user.kugou.com
/// /v2/qrcode，`appid=1001`（web 登录专用，覆盖平台 appid）+ srcappid，
/// web 签名。返回 key，二维码内容 = `$kgQrLoginPage?qrcode=$key`。
Future<String> kgQrKey({String? mid}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final params = <String, dynamic>{
    'appid': 1001,
    'type': 1,
    'plat': 4,
    // 对齐 login_qr_key.js：qrcode_txt 里的 appid 用当前平台 appid
    // （lite=3116），不是 srcappid；旧实现填 2919 会与 appid=1001 不一致。
    'qrcode_txt': '$kgQrLoginPage?appid=$kgLiteAppid&',
    'srcappid': kgSrcAppid,
    'dfid': '-',
    'mid': mid,
    'uuid': '-',
    'clientver': kgLiteClientver,
    'clienttime': ts,
  };
  params['signature'] = kgSignatureWeb(params);
  final uri = Uri.parse('$kgQrKeyUrl?${kgQueryStringEncoded(params)}');
  final body = await kgGet(uri, headers: _kgBaseHeaders(mid, ts));
  final data = body is Map ? body['data'] : null;
  final key = data is Map ? data['qrcode']?.toString() : null;
  if (key == null || key.isEmpty) {
    throw KgApiException('login_qr_key 未返回 key: $body');
  }
  return key;
}

/// 轮询扫码状态。
/// 对齐 KuGouMusicApi module/login_qr_check.js：GET /v2/get_userinfo_qrcode，
/// web 签名。返回 {status, token, userid, nickname}：
/// status 0=已过期 / 1=等待扫码 / 2=已扫待确认 / 4=登录成功（带 token）。
Future<Map<String, dynamic>> kgQrCheck(
  String key, {
  String? mid,
  String? dev,
}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final params = <String, dynamic>{
    'plat': 4,
    'appid': kgLiteAppid,
    'srcappid': kgSrcAppid,
    'qrcode': key,
    // 对齐 login_qr_check.js：轮询也要带稳定设备名，缺失会被当作
    // 另一台设备在确认登录，提高二次验证概率。
    if (dev != null && dev.isNotEmpty) 'dev': dev,
    'dfid': '-',
    'mid': mid,
    'uuid': '-',
    'clientver': kgLiteClientver,
    'clienttime': ts,
  };
  params['signature'] = kgSignatureWeb(params);
  final uri = Uri.parse('$kgQrCheckUrl?${kgQueryStringEncoded(params)}');
  final body = await kgGet(uri, headers: _kgBaseHeaders(mid, ts));
  final data = body is Map && body['data'] is Map
      ? (body['data'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  return {
    'status': data['status'],
    'token': data['token']?.toString(),
    'userid': data['userid']?.toString(),
    'nickname': data['nickname']?.toString(),
  };
}

/// 登录用户详情（user_detail.js：POST usercenter.kugou.com/v3/get_my_info）。
///
/// body：`{visit_time, usertype, p, userid}`，其中 p = raw RSA 加密
/// `{token, clienttime}`（cryptoRSAEncrypt，零填充模幂）大写 hex；
/// android 签名 + `x-router: usercenter.kugou.com` 头。
/// 返回 data：`{nickname, pic(头像), gender, vip_type, ...}`。
Future<Map<String, dynamic>> kgGetMyInfo({
  required String token,
  required String userid,
  String dfid = '-',
  String? mid,
}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final p = kgRsaRawEncryptHex(jsonEncode({'token': token, 'clienttime': ts}));
  final body = await kgGateway(
    '/v3/get_my_info',
    method: 'POST',
    query: {'plat': 1},
    body: {
      'visit_time': ts,
      'usertype': 1,
      'p': p,
      'userid': int.tryParse(userid) ?? 0,
    },
    headers: {'x-router': 'usercenter.kugou.com'},
    baseUrl: 'https://usercenter.kugou.com',
    dfid: dfid,
    mid: mid,
    token: token,
    userid: userid,
  );
  final data = body is Map && body['data'] is Map
      ? (body['data'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  return data;
}

// ─── SSA 安全验证（对齐 module/get_verify_info.js / verify_user_info.js）──

/// 获取风控验证信息（`/verifyservice/v3/get_verify_info`）。
///
/// 返回 data（通常含 `v_type`、`txappid`）；23=腾讯 TCaptcha，32=短信。
Future<Map<String, dynamic>> kgGetVerifyInfo(
  String eventId, {
  String dfid = '-',
  String? mid,
  String? token,
  String? userid,
}) async {
  final resp = await kgGateway(
    '/verifyservice/v3/get_verify_info',
    method: 'POST',
    body: {
      'eventid': eventId,
      'userid': int.tryParse(userid ?? '') ?? 0,
      'platid': 2,
      'rtype': 1,
      'wasm': 1,
      'i': '',
      'sid': '',
      'edt': '',
    },
    dfid: dfid,
    mid: mid,
    token: token,
    userid: userid,
  );
  final data = resp is Map ? resp['data'] : null;
  if (data is Map) return Map<String, dynamic>.from(data);
  if (resp is Map) return Map<String, dynamic>.from(resp);
  return const {};
}

/// 提交 SSA 验证（`/v4/verify_user_info`）。
///
/// 对齐 verify_user_info.js：
/// - v_type=23（腾讯）：`verifycode` + AES({}) 的 `params/pk`；
/// - v_type=32（短信）：`code` + AES({code}) 的 `params/pk`。
/// `sid/edt` 由 [kgGenerateSidEdt] 生成。
Future<Map<String, dynamic>> kgVerifyUserInfo({
  required String eventId,
  required int vType,
  required String sid,
  required String edt,
  String verifyCode = '',
  String dfid = '-',
  String? mid,
  String? token,
  String? userid,
}) async {
  final body = <String, dynamic>{
    'eventid': eventId,
    'userid': int.tryParse(userid ?? '') ?? 0,
    'platid': 2,
    'v_type': vType,
    'wasm': 1,
    'i': '',
    'sid': sid,
    'edt': edt,
  };

  if (vType == 23 || vType == 32) {
    final tempKey = kgRandomString(16).toLowerCase();
    final payload = vType == 23
        ? <String, dynamic>{}
        : <String, dynamic>{'code': verifyCode};
    body['params'] = kgAesEncryptHex256(jsonEncode(payload), tempKey);
    body['pk'] = kgRsaRawEncryptHex(jsonEncode({'key': tempKey})).toUpperCase();
    if (vType == 23) {
      body['verifycode'] = verifyCode;
    } else {
      body['code'] = verifyCode;
    }
  }

  final resp = await kgGateway(
    '/v4/verify_user_info',
    method: 'POST',
    query: {'clientver': 11510},
    body: body,
    baseUrl: 'https://verifyservice.kugou.com',
    dfid: dfid,
    mid: mid,
    token: token,
    userid: userid,
  );
  return resp is Map ? Map<String, dynamic>.from(resp) : const {};
}

// ─── 账号登录（对齐 KuGouMusicApi module/login*.js，lite 平台）───────────

Map<String, String> _kgLoginHeaders(
  String mid,
  int ts, {
  String dfid = '-',
  String? router,
}) => {
  'User-Agent': kgAndroidUa,
  'dfid': dfid,
  'clienttime': '$ts',
  'mid': mid,
  'kg-rc': '1',
  'kg-thash': '5d816a0',
  'kg-rec': '1',
  'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
  'Content-Type': 'application/json',
  'x-router': ?router,
};

/// 从登录响应中解出 `secu_params`（AES-256，用本次请求的临时 key 解密），
/// 合并回 data。返回 (token, userid, nickname, avatar) 供上层存会话。
Map<String, dynamic> _kgDecodeLoginData(
  Map<String, dynamic> resp,
  String tempKey,
) {
  final data = resp['data'];
  if (data is! Map) return resp;
  final merged = data.cast<String, dynamic>();
  final secu = data['secu_params'];
  if (secu is String && secu.isNotEmpty) {
    try {
      final dec = kgAesDecryptHex256(secu, tempKey);
      try {
        final obj = jsonDecode(dec);
        if (obj is Map) merged.addAll(obj.cast<String, dynamic>());
      } catch (_) {
        merged['token'] = dec;
      }
    } catch (_) {
      // 解密失败：保留原 data，由上层按缺 token 处理
    }
  }
  resp['data'] = merged;
  return resp;
}

/// 手机验证码发送（对齐 module/captcha_sent.js）。
Future<void> kgCaptchaSent({
  required String mobile,
  String? mid,
  String dfid = '-',
}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final body = jsonEncode({'businessid': 5, 'mobile': mobile, 'plat': 3});
  final q = <String, dynamic>{
    'dfid': dfid,
    'mid': mid,
    'uuid': '-',
    'appid': kgLiteAppid,
    'clientver': kgLiteClientver,
    'clienttime': ts,
  };
  q['signature'] = kgSignature(q, data: body, salt: kgLiteSignSalt);
  final uri = Uri.parse(
    'http://login.user.kugou.com/v7/send_mobile_code?${kgQueryString(q)}',
  );
  final bytes = await kgPost(
    uri,
    body: body,
    headers: _kgLoginHeaders(mid, ts, dfid: dfid),
  );
  final resp = jsonDecode(utf8.decode(bytes, allowMalformed: true));
  if (resp is! Map || (resp['status'] as num?)?.toInt() != 1) {
    final err = resp is Map
        ? (resp['error'] ?? resp['errmsg'] ?? resp['status'])
        : resp;
    throw KgApiException('验证码发送失败：$err');
  }
}

/// 账号密码登录（对齐 module/login.js：v9/login_by_pwd）。
Future<Map<String, dynamic>> kgLoginByPwd({
  required String username,
  required String password,
  String? mid,
  String dfid = '-',
  String? dev,
}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final tsMs = DateTime.now().millisecondsSinceEpoch;
  final ts = tsMs ~/ 1000;
  final tempKey = kgRandomString(16).toLowerCase();
  final paramsEnc = kgAesEncryptHex256(
    jsonEncode({'pwd': password, 'code': '', 'clienttime_ms': tsMs}),
    tempKey,
  );
  final pk = kgRsaRawEncryptHex(
    jsonEncode({'clienttime_ms': tsMs, 'key': tempKey}),
  ).toUpperCase();
  final dataMap = <String, dynamic>{
    'plat': 1,
    'support_multi': 1,
    'clienttime_ms': tsMs,
    't1': '562a6f12a6e803453647d16a08f5f0c2ff7eee692cba2ab74cc4c8ab47fc467561a7c6b586ce7dc46a63613b246737c03a1dc8f8d162d8ce1d2c71893d19f1d4b797685a4c6d3d81341cbde65e488c4829a9b4d42ef2df470eb102979fa5adcdd9b4eecfea8b909ff7599abeb49867640f10c3c70fc444effca9d15db44a9a6c907731e2bb0f22cd9b3536380169995693e5f0e2424e3378097d3813186e3fe96bbe7023808a0981b4e2b6135a76faac',
    't2': '31c4daf4cf480169ccea1cb7d4a209295865a9d2b788510301694db229b87807469ea0d41b4d4b9173c2151da7294aeebfc9738df154bbdf11a4e117bb5dff6a3af8ce5ce333e681c1f29a44038f27567d58992eb81283e080778ac77db1400fdf49b7cf7e26be2e5af4da7830cc3be4',
    't3': 'MCwwLDAsMCwwLDAsMCwwLDA=',
    // 对齐 login.js：账号密码登录体也要带稳定设备名。
    if (dev != null && dev.isNotEmpty) 'dev': dev,
    'username': username,
    'params': paramsEnc,
    'pk': pk,
  };
  final body = jsonEncode(dataMap);
  final q = <String, dynamic>{
    'dfid': dfid,
    'mid': mid,
    'uuid': '-',
    'appid': kgLiteAppid,
    'clientver': kgLiteClientver,
    'clienttime': ts,
  };
  q['signature'] = kgSignature(q, data: body, salt: kgLiteSignSalt);
  final uri = Uri.parse(
    'https://login-user.kugou.com/v9/login_by_pwd?${kgQueryString(q)}',
  );
  final bytes = await kgPost(
    uri,
    body: body,
    headers: _kgLoginHeaders(
      mid,
      ts,
      dfid: dfid,
      router: 'login.user.kugou.com',
    ),
  );
  final resp = jsonDecode(utf8.decode(bytes, allowMalformed: true));
  if (resp is! Map<String, dynamic>) throw KgApiException('登录响应异常');
  if ((resp['status'] as num?)?.toInt() != 1) {
    throw KgApiException(
      (resp['error'] ?? resp['errmsg'] ?? '账号或密码错误').toString(),
    );
  }
  return _kgDecodeLoginData(resp, tempKey);
}

/// 手机验证码登录（对齐 module/login_cellphone.js：v7/login_by_verifycode）。
///
/// 新版 lite 协议把设备信封从静态常量升级为按 GUID / MAC / DEV / 时间
/// 现场生成：
/// - `t1 = AES-CBC("|<clienttime_ms>")`
/// - `t2 = AES-CBC("<guid>|0f6072…|<mac>|<dev>|<clienttime_ms>")`
/// 同时 body 需要 `dfid` / `dev` / `gitversion`，query 需要真实 `dfid`。
/// 仍沿用旧的 `t1=0,t2=0,t3=...` 会被服务端当作非官方客户端，验证码
/// 登录更容易触发二次验证。
Future<Map<String, dynamic>> kgLoginByVerifyCode({
  required String mobile,
  required String code,
  String? mid,
  required String guid,
  required String mac,
  required String dev,
  String dfid = '-',
}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final tsMs = DateTime.now().millisecondsSinceEpoch;
  final ts = tsMs ~/ 1000;
  final tempKey = kgRandomString(16).toLowerCase();
  final paramsEnc = kgAesEncryptHex256(
    jsonEncode({'mobile': mobile, 'code': code}),
    tempKey,
  );
  final masked = mobile.length >= 11
      ? '${mobile.substring(0, 2)}*****${mobile.substring(10, 11)}'
      : mobile;
  final pk = kgRsaRawEncryptHex(
    jsonEncode({'clienttime_ms': tsMs, 'key': tempKey}),
  ).toUpperCase();

  final t1 = kgAesEncryptHexRawKeyIv('|$tsMs', _kgLiteT1Key, _kgLiteT1Iv);
  final t2 = kgAesEncryptHexRawKeyIv(
    '$guid|0f607264fc6318a92b9e13c65db7cd3c|$mac|$dev|$tsMs',
    _kgLiteT2Key,
    _kgLiteT2Iv,
  );

  final dataMap = <String, dynamic>{
    'plat': 1,
    'support_multi': 1,
    't1': t1,
    't2': t2,
    'clienttime_ms': tsMs,
    'mobile': masked,
    'key': kgSignParamsKey('$tsMs'),
    'pk': pk,
    'params': paramsEnc,
    'dfid': dfid,
    'dev': dev,
    'gitversion': kgLiteGitVersion,
  };
  final body = jsonEncode(dataMap);
  final q = <String, dynamic>{
    'dfid': dfid,
    'mid': mid,
    'uuid': '-',
    'appid': kgLiteAppid,
    'clientver': kgLiteClientver,
    'clienttime': ts,
  };
  q['signature'] = kgSignature(q, data: body, salt: kgLiteSignSalt);
  final uri = Uri.parse(
    'https://loginserviceretry.kugou.com/v7/login_by_verifycode?${kgQueryString(q)}',
  );
  final bytes = await kgPost(
    uri,
    body: body,
    headers: {
      ..._kgLoginHeaders(mid, ts, dfid: dfid),
      'support-calm': '1',
      'User-Agent': 'Android16-1070-11440-130-0-LOGIN-wifi',
    },
  );
  final resp = jsonDecode(utf8.decode(bytes, allowMalformed: true));
  if (resp is! Map<String, dynamic>) throw KgApiException('登录响应异常');
  if ((resp['status'] as num?)?.toInt() != 1) {
    throw KgApiException(
      (resp['error'] ?? resp['errmsg'] ?? '验证码错误').toString(),
    );
  }
  return _kgDecodeLoginData(resp, tempKey);
}

/// 通用 kg-* 请求头（对齐 KuGouMusicApi request.js，无 x-router）
Map<String, String> _kgBaseHeaders(String mid, int ts) => {
  'User-Agent': kgAndroidUa,
  'dfid': '-',
  'clienttime': '$ts',
  'mid': mid,
  'kg-rc': '1',
  'kg-thash': '5d816a0',
  'kg-rec': '1',
  'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
};

/// 注册设备 → 返回 (dfid)。dfid 用于后续 /v5/url 等请求。
///
/// 对齐 KuGouMusicApi：POST userservice.kugou.com/risk/v3/r_register_dev，
/// AES-CBC 加密设备信息 + RSA-PKCS1 加密 {aes, uid, token}，android 签名。
/// 采用概念版 lite 平台（appid 3116/clientver 11440/lite 盐/lite 公钥，
/// 采用 lite 平台参数；标准版参数已被官方风控）。
///
/// [mid]/[guid] 必须来自持久化的 [KugouDevice]（同一安装长期复用），
/// 否则每次注册都是「新设备」，是账号风控的高危信号。缺省仅用于测试兜底。
Future<String> kgRegisterDevice({
  String? mid,
  String? guid,
  String dfid = '-',
}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  guid ??= kgMd5(kgRandomString(24));
  // 首次注册时调用方可能传空串（设备还没有 dfid）；服务端按 '-' 识别。
  final effectiveDfid = dfid.isEmpty ? '-' : dfid;
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // imei/uuid 用同一设备 GUID（对齐 KUGOU_API_GUID = UUID v4）
  final device = <String, dynamic>{..._kgDevice, 'imei': guid, 'uuid': guid};

  // AES 加密设备信息（密钥随请求回传，用于解密响应）
  final secretKey = kgRandomString(6).toLowerCase();
  final cipher = kgAesEncryptBase64(jsonEncode(device), secretKey);

  // RSA 加密 {aes, uid, token}（概念版 lite 公钥）
  final p = kgRsaPkcs1EncryptHex(
    jsonEncode({'aes': secretKey, 'uid': 0, 'token': ''}),
    pem: kgLitePublicKeyPem,
  );

  final params = <String, dynamic>{
    'part': 1,
    'platid': 1,
    'p': p,
    'dfid': effectiveDfid,
    'mid': mid,
    'uuid': '-',
    'appid': kgLiteAppid,
    'clientver': kgLiteClientver,
    'clienttime': ts,
  };
  params['signature'] = kgSignature(params, data: cipher, salt: kgLiteSignSalt);

  final uri = Uri.parse('$kgRegisterUrl?${kgQueryString(params)}');
  final bytes = await kgPost(
    uri,
    body: cipher,
    headers: {
      'User-Agent': kgAndroidUa,
      'dfid': effectiveDfid,
      'clienttime': '$ts',
      'mid': mid,
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
      'Content-Type': 'text/plain;charset=utf-8',
    },
  );

  final text = kgAesDecryptString(base64.encode(bytes), secretKey);
  final body = jsonDecode(text);
  if (body is! Map<String, dynamic>) throw KgApiException('register_dev 响应异常');
  final registered = body['data'] is Map
      ? body['data']['dfid']?.toString()
      : null;
  if (registered == null || registered.isEmpty) {
    throw KgApiException('register_dev 未返回 dfid: $text');
  }
  return registered;
}

/// 校验网关响应：`status:0` / `error_code` 非 0/200 视为业务失败（抛异常）。
/// 成功码约定不统一：多数网关接口用 0，部分通道（歌词系）用 200，两值均放行。
void _checkKgStatus(dynamic body) {
  if (body is! Map) return;
  // 某些网关把风控事件 id 放在 body 里（request.js 的 ssaCode 兼容字段）。
  final ssa = body['ssaCode'] ?? body['ssa_code'] ?? body['ssa-code'];
  if (ssa is String && ssa.trim().isNotEmpty) {
    throw KgRiskVerifyException(ssa.trim());
  }
  final raw = body['error_code'] ?? body['errcode'] ?? body['err_code'] ?? 0;
  final code = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
  // 20028 为账号级风控（即使没有 ssa-code 头）。
  if (code == 20028) {
    throw KgRiskVerifyRequiredException('酷狗要求完成安全验证（20028），请在酷狗官方客户端完成验证后重试。');
  }
  final status = body['status'];
  if (status is num && status == 0) {
    throw KgApiException(
      'KG status=0: ${body['error_msg'] ?? body['msg'] ?? body}',
    );
  }
  if (code != 0 && code != 200) {
    throw KgApiException('KG error_code=$code: ${body['error_msg'] ?? body}');
  }
}

/// 统一网关请求（对齐 KuGouMusicApi util/request.js createRequest）。
///
/// 流程（与 request.js 完全一致）：
/// 1. 注入默认参数 `{dfid, mid, uuid:'-', appid, clientver, clienttime}`
///    及登录态 `token` / `userid`（非空才注入）；
/// 2. [encryptKey] 时追加 `key = signKey(hash, mid, userid, appid)`；
/// 3. 序列化 [body]（POST JSON 原文参与签名）；
/// 4. android 签名（lite 盐）生成 `signature` 追加到 query；
/// 5. 组装 kg-* 头 + [headers]（x-router / kg-tid）后发送。
///
/// 响应非 2xx / status=0 / error_code!=0 抛 [KgApiException]；成功返回解析后的
/// JSON body（Map / List / 原始值）。
Future<dynamic> kgGateway(
  String path, {
  required String method,
  Map<String, dynamic>? query,
  Map<String, dynamic>? body,
  Map<String, String>? headers,
  String baseUrl = 'https://gateway.kugou.com',
  bool encryptKey = false,
  String dfid = '-',
  String? mid,
  String? token,
  String? userid,
  Duration timeout = const Duration(seconds: 10),
}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // 默认参数注入（对齐 request.js defaultParams）
  final params = <String, dynamic>{
    'dfid': dfid,
    'mid': mid,
    'uuid': '-',
    'appid': kgLiteAppid,
    'clientver': kgLiteClientver,
    'clienttime': ts,
    ...?query,
  };
  if (token != null && token.isNotEmpty) params['token'] = token;
  if (userid != null && userid.isNotEmpty && userid != '0') {
    params['userid'] = userid;
  }

  // encryptKey：key = signKey(hash, mid, userid, appid)
  if (encryptKey) {
    final hash = (params['hash'] ?? '').toString().toLowerCase();
    params['key'] = kgSignKey(
      hash,
      mid,
      int.tryParse(userid ?? '') ?? 0,
      kgLiteAppid,
      salt: kgLiteKeySalt,
    );
  }

  // POST body 序列化（空 body → ''，与 request.js `data = ''` 一致）
  final data = body == null ? '' : jsonEncode(body);

  // android 签名（lite 盐）
  params['signature'] = kgSignature(params, data: data, salt: kgLiteSignSalt);

  final uri = Uri.parse('$baseUrl$path?${kgQueryString(params)}');
  final reqHeaders = <String, String>{
    'User-Agent': kgAndroidUa,
    'dfid': dfid,
    'clienttime': '$ts',
    'mid': mid,
    'kg-rc': '1',
    'kg-thash': '5d816a0',
    'kg-rec': '1',
    'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
    ...?headers,
  };

  final dynamic resp;
  if (method == 'GET') {
    resp = await kgGet(uri, headers: reqHeaders, timeout: timeout);
  } else {
    final bytes = await kgPost(
      uri,
      body: data,
      headers: {
        ...reqHeaders,
        'Content-Type': 'application/json;charset=UTF-8',
      },
      timeout: timeout,
    );
    resp = jsonDecode(
      kgCleanResponse(utf8.decode(bytes, allowMalformed: true)),
    );
  }
  _checkKgStatus(resp);
  return resp;
}

/// ── 歌曲评论（commentsv2/getCommentWithLike，无需登录/签名） ────────

/// 评论网关
const kgCommentUrl = 'https://mcomment.kugou.com/index.php';

/// 歌曲评论固定 code（对齐安卓逆向：code=fc4be23b4e972707f36b8a828a93ba8a）
const kgCommentCode = 'fc4be23b4e972707f36b8a828a93ba8a';

/// 评论接口伪装 UA（Android COMMENT 通道）
const kgCommentUa = 'Android810-AndroidPhone-10659-14-0-COMMENT-wifi';

/// 获取歌曲评论（POST mcomment.kugou.com/index.php）。
///
/// 参数：`r=commentsv2/getCommentWithLike&code=<歌曲code>&p=<页>&pagesize=<每页>`，
/// body 为 `extdata=<歌曲hash>`。返回原始响应（list/count/current_page 等）。
Future<Map<String, dynamic>> kgComments(
  String hash, {
  int page = 1,
  int pagesize = 20,
}) async {
  final client = HttpClient();
  try {
    final query =
        'r=commentsv2/getCommentWithLike'
        '&code=$kgCommentCode'
        '&p=$page'
        '&pagesize=$pagesize'
        '&platform=android';
    final req = await client
        .postUrl(Uri.parse('$kgCommentUrl?$query'))
        .timeout(const Duration(seconds: 10));
    req.headers.set(HttpHeaders.userAgentHeader, kgCommentUa);
    req.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/x-www-form-urlencoded',
    );
    req.write('extdata=$hash');
    final res = await req.close().timeout(const Duration(seconds: 10));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (res.statusCode != 200) {
      throw KgApiException('KG comment HTTP ${res.statusCode}');
    }
    final body = jsonDecode(utf8.decode(bytes));
    if (body is! Map<String, dynamic>) {
      throw KgApiException('KG comment 响应异常: $body');
    }
    return body;
  } finally {
    client.close(force: true);
  }
}
