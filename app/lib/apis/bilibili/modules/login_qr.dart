// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 扫码登录 / 账号身份（passport + nav）。
///
/// 只接受官方二维码挑战 URL；登录成功必须再请求 `/x/web-interface/nav`
/// 核实身份后才交给 UI。二维码 key 只保存在内存，不落盘。
library;

import '../core/request.dart';
import '../core/types.dart';

Future<BilibiliQrChallenge> bilibiliQrGenerate(BilibiliRequest request) async {
  final root = await request.getJson(
    '/x/passport-login/web/qrcode/generate',
    passport: true,
  );
  final data = bilibiliData(root);
  final key = data['qrcode_key']?.toString() ?? '';
  final urlText = data['url']?.toString() ?? '';
  final uri = Uri.tryParse(urlText);
  final expected =
      uri != null &&
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      ((uri.host == 'passport.bilibili.com' &&
              uri.path == '/h5-app/passport/login/scan') ||
          (uri.host == 'account.bilibili.com' &&
              uri.path == '/h5/account-h5/auth/scan-web')) &&
      uri.queryParameters['qrcode_key'] == key;
  if (key.isEmpty || key.length > 256 || !expected) {
    throw const BilibiliApiException(
      'Bilibili did not return a valid sign-in code.',
      kind: BilibiliErrorKind.invalidResponse,
    );
  }
  return BilibiliQrChallenge(key: key, url: urlText);
}

Future<BilibiliQrState> bilibiliQrPoll(
  BilibiliRequest request,
  String key,
) async {
  if (key.isEmpty) {
    return BilibiliQrState.expired;
  }
  final root = await request.getJson(
    '/x/passport-login/web/qrcode/poll',
    passport: true,
    params: {'qrcode_key': key},
  );
  final data = bilibiliData(root);
  final code = _asInt(data['code']);
  switch (code) {
    case 86101:
      return BilibiliQrState.waiting;
    case 86090:
      return BilibiliQrState.scanned;
    case 86038:
      return BilibiliQrState.expired;
    case 0:
      // poll 成功的 Set-Cookie 已由请求层捕获；显式落盘一次。
      request.saveSession();
      return BilibiliQrState.signedIn;
    default:
      final message = data['message']?.toString().trim() ?? '';
      throw BilibiliApiException(
        message.isEmpty ? 'Bilibili did not confirm sign-in.' : message,
        kind: BilibiliErrorKind.unavailable,
        code: code,
      );
  }
}

Future<BilibiliAccount> bilibiliNav(BilibiliRequest request) async {
  final root = await request.getJson('/x/web-interface/nav');
  final data = bilibiliData(root);
  if (data['isLogin'] != true) {
    throw const BilibiliApiException(
      'Bilibili session expired. Sign in again.',
      kind: BilibiliErrorKind.authRequired,
      code: -101,
    );
  }
  final mid = data['mid']?.toString() ?? '';
  final nickname = data['uname']?.toString().trim() ?? '';
  if (mid.isEmpty || nickname.isEmpty) {
    throw const BilibiliApiException(
      'Bilibili account identity is missing.',
      kind: BilibiliErrorKind.invalidResponse,
    );
  }
  final avatar = bilibiliHttpsUrl(data['face']) ?? '';
  final vipStatus = _asInt(data['vipStatus']) ?? 0;
  final vipType = _asInt(data['vip_type']) ?? 0;
  return BilibiliAccount(
    mid: mid,
    nickname: nickname,
    avatarUrl: avatar,
    isVip: vipStatus == 1 || vipType > 0,
  );
}

int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
