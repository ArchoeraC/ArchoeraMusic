/// 邮箱登录（对齐 login.ts）
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../core/option.dart';
import '../core/request.dart';
import '../core/types.dart';

String _md5(String text) => crypto.md5.convert(utf8.encode(text)).toString();

NeteaseModule nmLogin = (query, request) async {
  final password = (query['md5_password'] as String?) ?? _md5((query['password'] as String?) ?? '');
  final data = <String, dynamic>{
    'type': '0',
    'https': 'true',
    'username': query['email'],
    'password': password,
    'rememberLogin': 'true',
  };
  var result = await request('/api/w/login', data, nmCreateOption(query));
  final body = result.body;

  if (body['code'] == 502) {
    return NeteaseResponse(
      status: 200,
      body: {'msg': '账号或密码错误', 'code': 502, 'message': '账号或密码错误'},
      cookie: result.cookie,
    );
  }
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
