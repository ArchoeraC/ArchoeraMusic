// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水登录（扫码 + 2046 短信 MFA）单测（**不联网**，注入 fake 传输）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/soda/api.dart';
import 'package:archoera_music/apis/soda/core/passport.dart';
import 'package:archoera_music/apis/soda/core/request.dart';
import 'package:archoera_music/services/soda/soda_auth.dart';

void main() {
  late SodaRawTransport original;
  var checkCount = 0;
  String? lastCookieHeader;

  setUp(() {
    original = sodaRawTransport;
    sodaClearCache();
    sodaClearCookies();
    checkCount = 0;
    lastCookieHeader = null;
  });

  tearDown(() {
    sodaRawTransport = original;
    sodaClearCookies();
  });

  test('sodaEncodeSmsCode：数字 ASCII hex', () {
    expect(sodaEncodeSmsCode('661701'), '363631373031');
  });

  test('raw 传输非官方域名直接拒绝', () {
    sodaRawTransport = (m, u, {body, headers, cookieHeader}) async =>
        const SodaRawResult({}, {});
    expect(
      () => sodaRawRequest('GET', Uri.parse('https://evil.example.com/x')),
      throwsA(isA<SodaRequestException>()),
    );
  });

  test('qrKey：GET get_qrcode 解析 token + csrf cookie（官方域名）', () async {
    final uris = <Uri>[];
    final methods = <String>[];
    sodaRawTransport = (method, uri, {body, headers, cookieHeader}) async {
      methods.add(method);
      uris.add(uri);
      return const SodaRawResult({
        'data': {
          'token': 'TOK',
          'qrcode_index_url': 'https://bff-pc.qishui.com/x',
          'qrcode': 'BASE64PNG',
        },
        'message': 'success',
      }, {'passport_csrf_token': 'csrf123'});
    };

    final auth = SodaAuth();
    final s = await auth.qrKey();

    expect(methods.single, 'GET');
    expect(uris.single.host, 'api.qishui.com');
    expect(uris.single.path, '/passport/web/get_qrcode/');
    expect(uris.single.query, contains('passport_jssdk_version'));
    expect(s.token, 'TOK');
    expect(s.imageUrl, 'data:image/png;base64,BASE64PNG');
  });

  test('扫码成功：check 下发 sessionid → 登录态落盘', () async {
    sodaRawTransport = (method, uri, {body, headers, cookieHeader}) async {
      if (uri.path.endsWith('/get_qrcode/')) {
        return const SodaRawResult({
          'data': {'token': 'TOK', 'qrcode_index_url': 'u'},
          'message': 'success',
        }, {'passport_csrf_token': 'csrf'});
      }
      lastCookieHeader = cookieHeader;
      return const SodaRawResult(
        {'data': {'status': 'new'}, 'message': 'success'},
        {},
      );
    };

    final auth = SodaAuth();
    await auth.qrKey();
    final waiting = await auth.qrCheck();
    expect(waiting.status, SodaLoginStatus.waiting);
    expect(lastCookieHeader, contains('passport_csrf_token=csrf'));

    sodaRawTransport = (method, uri, {body, headers, cookieHeader}) async =>
        const SodaRawResult(
          {'data': {'status': 'confirmed'}, 'message': 'success'},
          {'sessionid': 'SID', 'sid_tt': 'SIDTT'},
        );

    final done = await auth.qrCheck();
    expect(done.status, SodaLoginStatus.success);
    expect(auth.isLoggedIn, isTrue);
    expect(sodaGetCookies()['sessionid'], 'SID');
  });

  test('2046 MFA：check → send_code → validate_code → check 成功', () async {
    sodaRawTransport = (method, uri, {body, headers, cookieHeader}) async {
      final path = uri.path;
      if (path.endsWith('/get_qrcode/')) {
        return const SodaRawResult({
          'data': {'token': 'TOK'},
          'message': 'success',
        }, {'passport_csrf_token': 'csrf'});
      }
      if (path.endsWith('/check_qrconnect/')) {
        checkCount++;
        if (checkCount == 1) {
          expect(method, 'POST');
          expect(body, contains('token=TOK'));
          return const SodaRawResult({
            'data': {
              'account_flow': 'verify',
              'error_code': 2046,
              'encrypt_uid': 'ENC',
              'biz_params': {
                'passport_mfa_retry_tag': '1',
                'std_verify_flow_id': 'FLOW',
                'std_verify_scene': 'account_login',
                'std_verify_template': 'ato',
                'std_verify_token': 'VT',
                'std_verify_type': 'MFA',
              },
            },
            'message': 'error',
          }, {'passport_mfa_token': 'MFA'});
        }
        return const SodaRawResult(
          {'data': {'status': 'confirmed'}, 'message': 'success'},
          {'sessionid': 'SID'},
        );
      }
      if (path.endsWith('/send_code/')) {
        return const SodaRawResult(
          {'data': {'mobile': '138****8888', 'retry_time': 60}, 'message': 'success'},
          {'sc': '1'},
        );
      }
      if (path.endsWith('/validate_code/')) {
        expect(body, contains('code=363631373031'));
        return const SodaRawResult(
          {'data': {'ticket': 'TICK'}, 'message': 'success'},
          {'vc': '1'},
        );
      }
      return const SodaRawResult({}, {});
    };

    final auth = SodaAuth();
    await auth.qrKey();

    final mfa = await auth.qrCheck();
    expect(mfa.status, SodaLoginStatus.mfaRequired);
    expect(mfa.encryptUid, 'ENC');
    expect(mfa.verifyParams['std_verify_flow_id'], 'FLOW');
    expect(mfa.verifyParams['std_verify_scene'], 'account_login');

    final sent = await auth.sendSmsCode();
    expect(sent.status, SodaLoginStatus.smsSent);
    expect(sent.mobile, '138****8888');

    final done = await auth.validateSmsCode('661701');
    expect(done.status, SodaLoginStatus.success);
    expect(auth.isLoggedIn, isTrue);
    expect(sodaGetCookies()['sessionid'], 'SID');
  });

  test('validate_code 失败 → failed（不进入成功态）', () async {
    sodaRawTransport = (method, uri, {body, headers, cookieHeader}) async {
      if (uri.path.endsWith('/get_qrcode/')) {
        return const SodaRawResult({
          'data': {'token': 'TOK'},
          'message': 'success',
        }, {'passport_csrf_token': 'csrf'});
      }
      if (uri.path.endsWith('/check_qrconnect/')) {
        checkCount++;
        if (checkCount == 1) {
          return const SodaRawResult({
            'data': {'account_flow': 'verify', 'error_code': 2046, 'encrypt_uid': 'ENC'},
            'message': 'error',
          }, {});
        }
      }
      if (uri.path.endsWith('/validate_code/')) {
        return const SodaRawResult(
          {'data': <String, Object>{}, 'message': 'verify failed'},
          {},
        );
      }
      return const SodaRawResult({}, {});
    };

    final auth = SodaAuth();
    await auth.qrKey();
    await auth.qrCheck();
    final r = await auth.validateSmsCode('000000');
    expect(r.status, SodaLoginStatus.failed);
    expect(auth.isLoggedIn, isFalse);
  });

  test('logout：清空会话 cookie', () async {
    sodaRawTransport = (method, uri, {body, headers, cookieHeader}) async {
      if (uri.path.endsWith('/get_qrcode/')) {
        return const SodaRawResult({
          'data': {'token': 'TOK'},
          'message': 'success',
        }, {'passport_csrf_token': 'csrf'});
      }
      return const SodaRawResult(
        {'data': {'status': 'confirmed'}, 'message': 'success'},
        {'sessionid': 'SID'},
      );
    };
    final auth = SodaAuth();
    await auth.qrKey();
    final done = await auth.qrCheck();
    expect(done.status, SodaLoginStatus.success);
    expect(auth.isLoggedIn, isTrue);
    auth.logout();
    expect(auth.isLoggedIn, isFalse);
  });
}
