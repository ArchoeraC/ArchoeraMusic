// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水 Passport（ByteDance 账号）公共参数与编码工具。
///
/// 移植自 `music-lib/soda/login.go`（纯 Go `net/http`，无 `a_bogus`/浏览器）。
/// 出站仅 `api.qishui.com`（官方）；二维码内容域名 `bff-pc.qishui.com` 仅展示。
///
/// 关键：ByteDance Passport 对 **query/form 字段顺序**敏感（见
/// `sodaEncodeOrderedForm`），故按 Go 的固定顺序手工拼串，不用 `Uri` 自动编码。
library;

import 'dart:convert';

import 'config.dart';

/// Passport 客户端 UA（SodaMusic Electron）。
const sodaPassportUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) SodaMusic/3.1.0 Chrome/136.0.7103.59 '
    'Electron/36.4.0-rs.22.release.main.1 TTElectron/36.4.0-rs.22.release.main.1 '
    'Safari/537.36';

/// Passport 固定参数（对齐 login.go 常量）。
const sodaPassportJsVer = '2.4.13';
const sodaPassportAid = '386088';
const sodaPassportVersionCode = '3.3.0';
const sodaPassportPzt = '3.3.5';
const sodaPassportPver = '1.0.29';
const sodaPassportPbd = '1.0.0.41';

/// Passport 端点（官方 `api.qishui.com`）。
const sodaQrCreateUrl = '$sodaApiBase/passport/web/get_qrcode/';
const sodaQrCheckUrl = '$sodaApiBase/passport/web/check_qrconnect/';
const sodaSendCodeUrl = '$sodaApiBase/passport/web/send_code/';
const sodaValidateUrl = '$sodaApiBase/passport/web/validate_code/';
const sodaUpSmsVerifyUrl = '$sodaApiBase/passport/upsms/verify/';
const sodaScanLoginBase = 'https://bff-pc.qishui.com/light/invoke/scan_login';

String? _deviceId;
String? _installId;
String? _bizTraceId;

/// 稳定的设备/安装 id（进程内一次；对齐 `sodaStableDeviceID`）。
String sodaStableDeviceId() {
  if (_deviceId == null) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _deviceId = '$now';
    _installId = '${now + 1}';
  }
  return _deviceId!;
}

String sodaStableInstallId() {
  sodaStableDeviceId();
  return _installId!;
}

/// `biz_trace_id`：8 位十六进制（进程内一次；对齐 `sodaPassportBizTraceID`）。
String sodaPassportBizTraceId() {
  if (_bizTraceId == null) {
    final v = DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF;
    _bizTraceId = v.toRadixString(16).padLeft(8, '0');
  }
  return _bizTraceId!;
}

Map<String, String> _baseValues(String jsVer, String jsType) => {
  'passport_jssdk_version': jsVer,
  'passport_jssdk_type': jsType,
  'is_from_ttaccountsdk': '1',
  'aid': sodaPassportAid,
  'language': 'zh',
  'is_new_login': '1',
  'is_from_iesaccountsaas': '1',
  'device_id': sodaStableDeviceId(),
  'install_id': sodaStableInstallId(),
  'did': sodaStableDeviceId(),
  'iid': sodaStableInstallId(),
  'device_platform': 'PC',
  'version_code': sodaPassportVersionCode,
  'biz_trace_id': sodaPassportBizTraceId(),
};

/// `normal` 公共参数（get_qrcode / check_qrconnect 的 query）。
Map<String, String> sodaPassportNormalValues() => {
  ..._baseValues(sodaPassportJsVer, 'normal'),
  'account_sdk_source': 'web',
  'p_js_v': sodaPassportJsVer,
  'p_js_t': 'pro',
  'p_zt': sodaPassportPzt,
  'p_ver': sodaPassportPver,
  'request_host': 'app%3A%2F%2Fresources',
  'p_bd': sodaPassportPbd,
};

/// `lite` 公共参数（send_code / validate_code / upsms 的 query）。
Map<String, String> sodaPassportLiteValues() => {
  ..._baseValues('5.1.2', 'lite'),
  'new_authn_sdk_version': '1.0.0.404-web',
  'account_app_language': 'en-US',
};

/// normal query 字段顺序（对齐 `sodaPassportNormalQueryOrder`）。
const List<String> sodaPassportNormalQueryOrder = [
  'passport_jssdk_version', 'passport_jssdk_type', 'is_from_ttaccountsdk',
  'aid', 'language', 'account_sdk_source', 'account_sdk_source_info',
  'p_js_v', 'p_js_t', 'p_zt', 'p_ver', 'request_host', 'p_bd', 'biz_trace_id',
  'is_new_login', 'is_from_iesaccountsaas', 'device_id', 'install_id', 'did',
  'iid', 'device_platform', 'version_code', 'msToken', 'a_bogus',
];

/// lite query 字段顺序（对齐 `sodaPassportLiteQueryOrder`）。
const List<String> sodaPassportLiteQueryOrder = [
  'passport_jssdk_version', 'passport_jssdk_type', 'is_from_ttaccountsdk',
  'aid', 'language', 'account_app_language', 'new_authn_sdk_version',
  'is_new_login', 'is_from_iesaccountsaas', 'device_id', 'install_id', 'did',
  'iid', 'device_platform', 'version_code', 'biz_trace_id', 'msToken', 'a_bogus',
];

/// check_qrconnect 表单顺序（对齐 login.go `sodaEncodePassportForm`）。
const List<String> sodaCheckFormOrder = [
  'need_logo', 'need_short_url', 'is_frontier', 'token', 'is_new_login', 'next',
  'passport_mfa_retry_tag', 'std_verify_flow_id', 'std_verify_scene',
  'std_verify_template', 'std_verify_token', 'std_verify_type', 'std_verify_way',
];

const List<String> sodaSendCodeFormOrder = [
  'mix_mode', 'type', 'encrypt_uid', 'verify_ticket', 'copywriting_key',
  'ies_safety_diversion_tag', 'new_verify_flow', 'std_verify_flow_id',
  'std_verify_scene', 'std_verify_template', 'std_verify_token',
  'std_verify_type', 'std_verify_way', 'is6Digits', 'aid',
  'new_authn_sdk_version',
];

const List<String> sodaValidateFormOrder = [
  'mix_mode', 'type', 'encrypt_uid', 'verify_ticket', 'copywriting_key',
  'ies_safety_diversion_tag', 'mfa', 'new_verify_flow', 'std_verify_flow_id',
  'std_verify_scene', 'std_verify_template', 'std_verify_token',
  'std_verify_type', 'std_verify_way', 'code', 'aid', 'new_authn_sdk_version',
];

const List<String> sodaUpSmsFormOrder = [
  'encrypt_uid', 'verify_ticket', 'copywriting_key',
  'ies_safety_diversion_tag', 'new_verify_flow', 'std_verify_flow_id',
  'std_verify_scene', 'std_verify_template', 'std_verify_token',
  'std_verify_type', 'std_verify_way', 'aid', 'new_authn_sdk_version',
];

/// 按 [order] 优先、其余按字典序，拼出 `k=v&k=v`（值用 `Uri.encodeQueryComponent`）。
String sodaEncodeOrderedForm(Map<String, String> form, List<String> order) {
  final seen = <String>{};
  final parts = <String>[];
  void add(String key) {
    final value = form[key];
    if (value != null) parts.add('${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}');
  }

  for (final key in order) {
    if (form.containsKey(key)) {
      seen.add(key);
      add(key);
    }
  }
  final rest = form.keys.where((k) => !seen.contains(k)).toList()..sort();
  for (final key in rest) {
    add(key);
  }
  return parts.join('&');
}

/// 二维码内容（PC 扫码登录），仅展示用途。
String sodaScanLoginUrl(String token) {
  final q = <String>[
    'token=${Uri.encodeQueryComponent(token)}',
    'os=Windows',
    'computer_name=${Uri.encodeQueryComponent('ArchoeraMusic')}',
  ].join('&');
  return '$sodaScanLoginBase?$q';
}

/// `qrcode` 字段 → 可直接渲染的图片 URL（base64 时补 data URI 前缀）。
String sodaQrCodeImageUrl(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return '';
  if (v.startsWith('data:') || v.startsWith('http://') || v.startsWith('https://')) {
    return v;
  }
  return 'data:image/png;base64,$v';
}

/// 短信验证码 → 数字 ASCII 的 hex（对齐 `sodaEncodeSMSCode`，如 `661701`）。
String sodaEncodeSmsCode(String code) =>
    utf8.encode(code.trim()).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

bool sodaMessageOk(String? message) {
  final v = (message ?? '').trim().toLowerCase();
  return v.isEmpty || v == 'success';
}

String _normalizeKey(String key) =>
    key.trim().toLowerCase().replaceAll('_', '').replaceAll('-', '');

/// 递归查找 JSON 中的字符串字段（键名忽略 `_`/`-`/大小写）。
String sodaFindString(Object? value, String field) {
  final want = _normalizeKey(field);
  if (value is Map) {
    for (final entry in value.entries) {
      if (_normalizeKey('${entry.key}') == want) {
        final child = entry.value;
        if (child is String && child.trim().isNotEmpty) return child.trim();
        if (child is num) return child.toInt().toString();
      }
      final found = sodaFindString(entry.value, field);
      if (found.isNotEmpty) return found;
    }
  } else if (value is List) {
    for (final child in value) {
      final found = sodaFindString(child, field);
      if (found.isNotEmpty) return found;
    }
  } else if (value is String) {
    final text = value.trim();
    if (text.startsWith('{')) {
      try {
        return sodaFindString(jsonDecode(text), field);
      } catch (_) {}
    }
  }
  return '';
}

/// 递归收集 MFA `std_verify_*` / `passport_mfa_retry_tag` 回填参数。
Map<String, String> sodaCollectVerifyParams(Object? value) {
  const allow = {
    'passport_mfa_retry_tag',
    'std_verify_flow_id',
    'std_verify_scene',
    'std_verify_template',
    'std_verify_token',
    'std_verify_type',
    'std_verify_way',
  };
  final out = <String, String>{};
  void walk(Object? v) {
    if (v is Map) {
      for (final entry in v.entries) {
        final key = '${entry.key}';
        if (allow.contains(key)) {
          final child = entry.value;
          if (child is String && child.trim().isNotEmpty) out[key] = child.trim();
          if (child is num) out[key] = child.toInt().toString();
        }
        walk(entry.value);
      }
    } else if (v is List) {
      for (final child in v) {
        walk(child);
      }
    } else if (v is String) {
      final text = v.trim();
      if (text.contains('std_verify_') || text.contains('passport_mfa_retry_tag')) {
        final q = text.indexOf('?');
        final query = q >= 0 ? text.substring(q + 1) : text;
        try {
          Uri.splitQueryString(query).forEach((k, val) {
            if (allow.contains(k) && val.trim().isNotEmpty) out[k] = val.trim();
          });
        } catch (_) {}
      }
      if (text.startsWith('{')) {
        try {
          walk(jsonDecode(text));
        } catch (_) {}
      }
    }
  }

  walk(value);
  return out;
}
