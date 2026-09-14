// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水登录编排（扫码 + 2046 短信 MFA）——纯 Dart HTTP，无 WebView / JS 运行时。
///
/// 流程（对齐 `music-lib/soda/login.go`）：
/// 1. [qrKey]：`get_qrcode` → token / 二维码图 / csrf cookie；
/// 2. [qrCheck]：`check_qrconnect` 轮询；`account_flow=verify` 或
///    `error_code=2046` → [SodaLoginStatus.mfaRequired]；
/// 3. MFA：[sendSmsCode] 下发 → [validateSmsCode] 校验（或 [upSms] 上行短信）
///    → 回填 `verify_params` 再 `check_qrconnect` → 会话 cookie 落 vault（键 `soda`）。
///
/// 出站域名硬校验在 `apis/soda/core/request.dart`（仅官方 `api.qishui.com`）。
library;

import 'package:flutter/foundation.dart';

import '../../apis/soda/api.dart';
import '../../apis/soda/core/request.dart';
import 'soda_api.dart' show SodaApiException;

/// 汽水登录状态。
enum SodaLoginStatus {
  waiting,
  scanned,
  mfaRequired,
  smsSent,
  success,
  expired,
  failed,
}

/// 扫码会话（token + 展示用二维码）。
class SodaQrSession {
  const SodaQrSession({
    required this.token,
    required this.url,
    required this.imageUrl,
    this.scanLoginUrl = '',
  });

  final String token;
  final String url;
  final String imageUrl;
  final String scanLoginUrl;
}

/// 一次登录轮询 / MFA 操作的结果。
class SodaLoginResult {
  const SodaLoginResult({
    required this.status,
    this.message = '',
    this.mobile = '',
    this.encryptUid = '',
    this.verifyParams = const {},
    this.upSmsMobile = '',
    this.upSmsContent = '',
    this.canUpSms = false,
  });

  final SodaLoginStatus status;
  final String message;
  final String mobile;
  final String encryptUid;
  final Map<String, String> verifyParams;
  final String upSmsMobile;
  final String upSmsContent;

  /// 是否可走「上行短信」分支。
  final bool canUpSms;
}

class SodaAuth extends ChangeNotifier {
  SodaQrSession? _session;
  final Map<String, String> _flowCookies = {};
  String _encryptUid = '';
  Map<String, String> _verifyParams = {};

  SodaQrSession? get session => _session;

  /// 是否已登录（存在会话 cookie）。
  bool get isLoggedIn => sodaHasSession();

  String? _cookieHeader() {
    final merged = <String, String>{...sodaGetCookies(), ..._flowCookies};
    final keys =
        merged.keys.where((k) => (merged[k] ?? '').isNotEmpty).toList()..sort();
    if (keys.isEmpty) return null;
    return keys.map((k) => '$k=${merged[k]}').join('; ');
  }

  bool _hasSessionCookie() {
    final merged = <String, String>{...sodaGetCookies(), ..._flowCookies};
    for (final key in const [
      'sessionid',
      'sessionid_ss',
      'sid_tt',
      'sid_guard',
    ]) {
      if ((merged[key] ?? '').isNotEmpty) return true;
    }
    return false;
  }

  Future<Map<String, dynamic>> _call(
    String name, [
    Map<String, dynamic> params = const {},
  ]) async {
    try {
      final body = await sodaCall(name, params);
      if (body is Map<String, dynamic>) return body;
      if (body is Map) return Map<String, dynamic>.from(body);
      throw SodaApiException('汽水：响应结构异常');
    } on SodaApiException {
      rethrow;
    } on SodaRequestException catch (e) {
      throw SodaApiException(e.message);
    } catch (err) {
      throw SodaApiException('汽水：$err');
    }
  }

  void _absorbCookies(Map<String, dynamic> body) {
    final cookies = body['cookies'];
    if (cookies is Map) {
      for (final entry in cookies.entries) {
        _flowCookies['${entry.key}'] = '${entry.value}';
      }
    }
  }

  void _resetFlow() {
    _session = null;
    _flowCookies.clear();
    _encryptUid = '';
    _verifyParams = {};
  }

  /// 取二维码，开启一次登录会话。
  Future<SodaQrSession> qrKey() async {
    _resetFlow();
    final body = await _call('login_qr_key');
    _absorbCookies(body);
    final token = '${body['token'] ?? ''}';
    if (body['code'] != 200 || token.isEmpty) {
      throw SodaApiException('汽水：获取二维码失败（${body['message'] ?? ''}）');
    }
    final session = SodaQrSession(
      token: token,
      url: '${body['url'] ?? ''}',
      imageUrl: '${body['imageUrl'] ?? ''}',
      scanLoginUrl: '${body['scanLoginUrl'] ?? ''}',
    );
    _session = session;
    return session;
  }

  /// 轮询扫码状态（并在需要时进入 / 完成 MFA）。
  Future<SodaLoginResult> qrCheck() async {
    final token = _session?.token ?? '';
    if (token.isEmpty) {
      throw SodaApiException('汽水：登录会话已失效，请刷新二维码');
    }
    final includeVerify = _encryptUid.isNotEmpty || _verifyParams.isNotEmpty;
    final body = await _call('login_qr_check', {
      'token': token,
      'includeVerify': includeVerify,
      'verifyParams': _verifyParams,
      'cookieHeader': _cookieHeader(),
    });
    _absorbCookies(body);

    // 成功：会话 cookie 已下发 → 落盘并结束。
    if (_hasSessionCookie()) {
      sodaMergeCookies(_flowCookies);
      _resetFlow();
      notifyListeners();
      return const SodaLoginResult(
        status: SodaLoginStatus.success,
        message: '登录成功',
      );
    }

    final status = '${body['status'] ?? ''}'.toLowerCase();
    final errorCode = (body['errorCode'] as num?)?.toInt() ?? 0;
    final flow = '${body['accountFlow'] ?? ''}'.toLowerCase();
    final message = '${body['message'] ?? ''}';

    // MFA：account_flow=verify 或 error_code=2046。
    if (flow == 'verify' || errorCode == 2046) {
      _encryptUid = '${body['encryptUid'] ?? ''}';
      final vp = body['verifyParams'];
      if (vp is Map) {
        _verifyParams = vp.map((k, v) => MapEntry('$k', '$v'));
      }
      if (_encryptUid.isEmpty && _verifyParams.isEmpty) {
        return SodaLoginResult(
          status: SodaLoginStatus.failed,
          message: message.isNotEmpty ? message : '需要短信验证，但未取到验证参数',
        );
      }
      final upMobile = '${body['upSmsMobile'] ?? ''}';
      final upContent = '${body['upSmsContent'] ?? ''}';
      return SodaLoginResult(
        status: SodaLoginStatus.mfaRequired,
        message: '需要短信验证',
        mobile: '${body['mobile'] ?? ''}',
        encryptUid: _encryptUid,
        verifyParams: _verifyParams,
        upSmsMobile: upMobile,
        upSmsContent: upContent,
        canUpSms: upMobile.isNotEmpty || upContent.isNotEmpty,
      );
    }

    switch (status) {
      case 'confirmed':
        return const SodaLoginResult(
          status: SodaLoginStatus.scanned,
          message: '已扫码确认，等待登录结果',
        );
      case 'scanned':
        return const SodaLoginResult(
          status: SodaLoginStatus.scanned,
          message: '已扫码，请在手机上确认',
        );
      case 'expired':
        return const SodaLoginResult(
          status: SodaLoginStatus.expired,
          message: '二维码已过期',
        );
      case 'error':
      case 'failed':
        return SodaLoginResult(
          status: SodaLoginStatus.failed,
          message: message.isNotEmpty ? message : '登录失败',
        );
      case 'new':
      case '':
        if (errorCode != 0) {
          return SodaLoginResult(
            status: SodaLoginStatus.failed,
            message: message.isNotEmpty ? message : '登录失败（code=$errorCode）',
          );
        }
        return const SodaLoginResult(status: SodaLoginStatus.waiting);
      default:
        if (errorCode != 0) {
          return SodaLoginResult(
            status: SodaLoginStatus.failed,
            message: message.isNotEmpty ? message : '登录失败（code=$errorCode）',
          );
        }
        return const SodaLoginResult(status: SodaLoginStatus.waiting);
    }
  }

  /// 下发短信验证码（MFA `mobile_sms_verify`）。
  Future<SodaLoginResult> sendSmsCode() async {
    if (_session?.token.isEmpty ?? true) {
      throw SodaApiException('汽水：登录会话已失效，请刷新二维码');
    }
    final body = await _call('login_send_code', {
      'encryptUid': _encryptUid,
      'verifyParams': _verifyParams,
      'cookieHeader': _cookieHeader(),
    });
    _absorbCookies(body);
    if (body['code'] != 200) {
      return SodaLoginResult(
        status: SodaLoginStatus.failed,
        message: '${body['message'] ?? '验证码发送失败'}',
      );
    }
    final mobile = '${body['mobile'] ?? ''}';
    return SodaLoginResult(
      status: SodaLoginStatus.smsSent,
      message: mobile.isEmpty ? '验证码已发送' : '验证码已发送至 $mobile',
      mobile: mobile,
      encryptUid: _encryptUid,
      verifyParams: _verifyParams,
    );
  }

  /// 校验短信验证码，成功后回填并轮询直至下发会话。
  Future<SodaLoginResult> validateSmsCode(String code) async {
    if (code.trim().isEmpty) {
      return const SodaLoginResult(
        status: SodaLoginStatus.failed,
        message: '请输入短信验证码',
      );
    }
    final body = await _call('login_validate_code', {
      'encryptUid': _encryptUid,
      'verifyParams': _verifyParams,
      'code': code.trim(),
      'cookieHeader': _cookieHeader(),
    });
    _absorbCookies(body);
    if (body['code'] != 200) {
      return SodaLoginResult(
        status: SodaLoginStatus.failed,
        message: '${body['message'] ?? '验证码错误'}',
      );
    }
    return qrCheck();
  }

  /// 上行短信确认，成功后回填并轮询。
  Future<SodaLoginResult> upSms() async {
    final body = await _call('login_upsms', {
      'encryptUid': _encryptUid,
      'verifyParams': _verifyParams,
      'cookieHeader': _cookieHeader(),
    });
    _absorbCookies(body);
    if (body['code'] != 200) {
      return SodaLoginResult(
        status: SodaLoginStatus.failed,
        message: '${body['message'] ?? '上行短信确认失败'}',
      );
    }
    return qrCheck();
  }

  /// 退出登录（清空会话 cookie）。
  void logout() {
    sodaClearCookies();
    _resetFlow();
    notifyListeners();
  }
}
