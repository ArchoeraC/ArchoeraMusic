/// 手机号登录（密码或验证码均可，对齐 login_cellphone.ts）
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../core/option.dart';
import '../core/request.dart';
import '../core/types.dart';

String _md5(String text) => crypto.md5.convert(utf8.encode(text)).toString();

NeteaseModule nmLoginCellphone = (query, request) async {
  final hasCaptcha = query['captcha'] != null && '${query['captcha']}' != '' && query['captcha'] != false;
  final data = <String, dynamic>{
    'type': '1',
    'https': 'true',
    'phone': query['phone'],
    'countrycode': query['countrycode'] ?? '86',
    'captcha': query['captcha'],
    'remember': 'true',
  };
  if (hasCaptcha) {
    data['captcha'] = query['captcha'];
  } else {
    data['password'] =
        (query['md5_password'] as String?) ?? _md5((query['password'] as String?) ?? '');
  }

  var result = await request('/api/w/login/cellphone', data, nmCreateOption(query, 'weapi'));
  final body = result.body;

  if (body['code'] == 200) {
    final renamed = jsonDecode(jsonEncode(body).replaceAll('avatarImgId_str', 'avatarImgIdStr'))
        as Map<String, dynamic>;
    result = NeteaseResponse(
      status: 200,
      body: {...renamed, 'cookie': result.cookie.join(';')},
      cookie: result.cookie,
    );
  }
  return result;
};
