// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水 Passport 登录（扫码 + 2046 短信 MFA）——纯 Dart HTTP 复刻。
///
/// 移植自 `music-lib/soda/login.go`：`get_qrcode` → `check_qrconnect` →
/// （`account_flow=verify` / `error_code=2046`）`send_code` / `validate_code` /
/// `upsms/verify` → 回填 `verify_params` 再轮询 → 会话 cookie。
/// **不引 WebView / JS 运行时，无需 `a_bogus`**（实测两步即通）。
///
/// 模块本身无状态：cookie / encrypt_uid / verify_params 由 service 传入与保存。
library;

import '../core/passport.dart';
import '../core/request.dart';
import '../core/types.dart';

Map<String, dynamic> _asMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};

Map<String, String> _stringMap(Object? v) {
  if (v is! Map) return const {};
  return v.map((k, value) => MapEntry('$k', '$value'));
}

Map<String, String> _passportHeaders({required bool lite}) => {
  'User-Agent': sodaPassportUa,
  'Content-Type': 'application/x-www-form-urlencoded',
  'Accept': lite
      ? 'application/json, text/plain, */*'
      : 'application/json, text/javascript',
  'sec-ch-ua': '"Not.A/Brand";v="99", "Chromium";v="136"',
  'sec-ch-ua-mobile': '?0',
  'sec-ch-ua-platform': '"Windows"',
  'bd-ticket-guard-version': '2',
  'bd-ticket-guard-iteration-version': '2',
  'bd-ticket-guard-ree-public-key':
      'BAnIxKL96Jby5x+Um9i7HZ2c8O6lfZJRxm6yk73Mqcr06l2qIw2iqu2Mtm3U/6OI98usukA9dqxUlsctVWK9rKA=',
  'bd-ticket-guard-server-cert-sn': '0',
};

/// `get_qrcode`：取二维码（返回 token / 二维码图 / 展示 URL + csrf cookie）。
SodaModule sodaLoginQrKey = (params) async {
  final query = sodaEncodeOrderedForm({
    ...sodaPassportNormalValues(),
    'next': 'https://api.qishui.com',
    'need_logo': 'false',
    'need_short_url': 'false',
    'is_frontier': 'true',
  }, [...sodaPassportNormalQueryOrder, 'next', 'need_logo', 'need_short_url', 'is_frontier']);

  final res = await sodaRawRequest(
    'GET',
    Uri.parse('$sodaQrCreateUrl?$query'),
    headers: const {
      'User-Agent': sodaPassportUa,
      'Accept': 'application/json, text/javascript',
    },
  );
  final data = _asMap(res.json['data']);
  final token = '${data['token'] ?? ''}';
  if (token.isEmpty) {
    return {
      'code': 500,
      'message': '${res.json['message'] ?? 'get_qrcode failed'}',
      'cookies': res.cookies,
    };
  }
  final indexUrl = '${data['qrcode_index_url'] ?? ''}';
  final webUrl = '${data['web_url'] ?? ''}';
  final scanUrl = sodaScanLoginUrl(token);
  return {
    'code': 200,
    'token': token,
    'url': indexUrl.isNotEmpty ? indexUrl : (webUrl.isNotEmpty ? webUrl : scanUrl),
    'imageUrl': sodaQrCodeImageUrl('${data['qrcode'] ?? ''}'),
    'scanLoginUrl': scanUrl,
    'cookies': res.cookies,
  };
};

/// `check_qrconnect`：轮询扫码 / MFA 状态。
SodaModule sodaLoginQrCheck = (params) async {
  final token = '${params['token'] ?? ''}';
  if (token.isEmpty) return {'code': 400, 'message': 'token required'};
  final includeVerify = params['includeVerify'] == true;
  final verify = _stringMap(params['verifyParams']);

  final form = <String, String>{
    'need_logo': 'false',
    'need_short_url': 'false',
    'is_frontier': 'true',
    'token': token,
    'is_new_login': '1',
    'next': 'https://api.qishui.com',
    if (includeVerify) ...verify,
    if (includeVerify && !verify.containsKey('std_verify_way'))
      'std_verify_way': '',
  };
  final query = sodaEncodeOrderedForm(
    sodaPassportNormalValues(),
    sodaPassportNormalQueryOrder,
  );
  final res = await sodaRawRequest(
    'POST',
    Uri.parse('$sodaQrCheckUrl?$query'),
    body: sodaEncodeOrderedForm(form, sodaCheckFormOrder),
    headers: _passportHeaders(lite: false),
    cookieHeader: params['cookieHeader'] as String?,
  );
  final data = _asMap(res.json['data']);
  return {
    'code': 200,
    'token': token,
    'status': '${data['status'] ?? ''}',
    'errorCode': (data['error_code'] as num?)?.toInt() ?? 0,
    'accountFlow': '${data['account_flow'] ?? ''}',
    'description': '${data['description'] ?? ''}',
    'message': '${res.json['message'] ?? ''}',
    'mobile': sodaFindString(res.json, 'mobile'),
    'encryptUid': sodaFindString(res.json, 'encrypt_uid'),
    'upSmsMobile': sodaFindString(res.json, 'channel_mobile'),
    'upSmsContent': sodaFindString(res.json, 'sms_content'),
    'verifyParams': sodaCollectVerifyParams(res.json),
    'cookies': res.cookies,
  };
};

/// `send_code`：下发短信验证码（MFA `mobile_sms_verify`）。
SodaModule sodaLoginSendCode = (params) async {
  final encryptUid = '${params['encryptUid'] ?? ''}';
  if (encryptUid.isEmpty) {
    return {'code': 400, 'message': '缺少短信验证参数，请刷新二维码重试'};
  }
  final verify = _stringMap(params['verifyParams']);
  final form = <String, String>{
    'mix_mode': '1',
    'type': '3737',
    'encrypt_uid': encryptUid,
    'verify_ticket': '',
    'copywriting_key': 'qr_connect',
    'ies_safety_diversion_tag': 'mfa',
    'new_verify_flow': '',
    'std_verify_way': 'mobile_sms_verify',
    'is6Digits': '1',
    'aid': sodaPassportAid,
    'new_authn_sdk_version': '1.0.0.404-web',
    ...verify,
  };
  final query = sodaEncodeOrderedForm(
    sodaPassportLiteValues(),
    sodaPassportLiteQueryOrder,
  );
  final res = await sodaRawRequest(
    'POST',
    Uri.parse('$sodaSendCodeUrl?$query'),
    body: sodaEncodeOrderedForm(form, sodaSendCodeFormOrder),
    headers: _passportHeaders(lite: true),
    cookieHeader: params['cookieHeader'] as String?,
  );
  final message = '${res.json['message'] ?? ''}';
  if (!sodaMessageOk(message)) {
    return {'code': 500, 'message': '验证码发送失败: $message', 'cookies': res.cookies};
  }
  final data = _asMap(res.json['data']);
  return {
    'code': 200,
    'mobile': '${data['mobile'] ?? ''}',
    'retryTime': (data['retry_time'] as num?)?.toInt() ?? 0,
    'cookies': res.cookies,
  };
};

/// `validate_code`：校验短信验证码（`code` 以数字 ASCII 的 hex 发送）。
SodaModule sodaLoginValidateCode = (params) async {
  final encryptUid = '${params['encryptUid'] ?? ''}';
  final code = '${params['code'] ?? ''}';
  if (encryptUid.isEmpty || code.isEmpty) {
    return {'code': 400, 'message': '缺少短信验证参数或验证码'};
  }
  final verify = _stringMap(params['verifyParams']);
  final form = <String, String>{
    'mix_mode': '1',
    'type': '3737',
    'encrypt_uid': encryptUid,
    'verify_ticket': '',
    'copywriting_key': 'qr_connect',
    'ies_safety_diversion_tag': 'mfa',
    'new_verify_flow': '',
    'std_verify_way': 'mobile_sms_verify',
    'code': sodaEncodeSmsCode(code),
    'aid': sodaPassportAid,
    'new_authn_sdk_version': '1.0.0.404-web',
    ...verify,
  };
  final query = sodaEncodeOrderedForm(
    sodaPassportLiteValues(),
    sodaPassportLiteQueryOrder,
  );
  final res = await sodaRawRequest(
    'POST',
    Uri.parse('$sodaValidateUrl?$query'),
    body: sodaEncodeOrderedForm(form, sodaValidateFormOrder),
    headers: _passportHeaders(lite: true),
    cookieHeader: params['cookieHeader'] as String?,
  );
  final data = _asMap(res.json['data']);
  final ticket = '${data['ticket'] ?? ''}';
  final message = '${res.json['message'] ?? ''}';
  if (ticket.isEmpty && !sodaMessageOk(message)) {
    return {'code': 500, 'message': '验证码错误: $message', 'cookies': res.cookies};
  }
  return {'code': 200, 'ticket': ticket, 'cookies': res.cookies};
};

/// `upsms/verify`：上行短信确认（`mobile_up_sms_verify`）。
SodaModule sodaLoginUpSms = (params) async {
  final encryptUid = '${params['encryptUid'] ?? ''}';
  if (encryptUid.isEmpty) {
    return {'code': 400, 'message': '缺少短信验证参数，请刷新二维码重试'};
  }
  final verify = _stringMap(params['verifyParams']);
  final form = <String, String>{
    'encrypt_uid': encryptUid,
    'verify_ticket': '',
    'copywriting_key': 'qr_connect',
    'ies_safety_diversion_tag': 'mfa',
    'new_verify_flow': '',
    'aid': sodaPassportAid,
    'new_authn_sdk_version': '1.0.0.404-web',
    ...verify,
    'std_verify_way': 'mobile_up_sms_verify',
  };
  final query = sodaEncodeOrderedForm(
    sodaPassportLiteValues(),
    sodaPassportLiteQueryOrder,
  );
  final res = await sodaRawRequest(
    'POST',
    Uri.parse('$sodaUpSmsVerifyUrl?$query'),
    body: sodaEncodeOrderedForm(form, sodaUpSmsFormOrder),
    headers: _passportHeaders(lite: true),
    cookieHeader: params['cookieHeader'] as String?,
  );
  final data = _asMap(res.json['data']);
  final registered = data['registered'] == true;
  final ticket = '${data['ticket'] ?? ''}';
  final message = '${res.json['message'] ?? ''}';
  if ((!registered && ticket.isEmpty) || !sodaMessageOk(message)) {
    return {'code': 500, 'message': '上行短信确认失败: $message', 'cookies': res.cookies};
  }
  return {
    'code': 200,
    'registered': registered,
    'ticket': ticket,
    'cookies': res.cookies,
  };
};
