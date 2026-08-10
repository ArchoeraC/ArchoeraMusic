/// 校验短信验证码（对齐 captcha_verify.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCaptchaVerify = (query, request) {
  final data = <String, dynamic>{
    'ctcode': query['ctcode'] ?? '86',
    'cellphone': query['phone'],
    'captcha': query['captcha'],
  };
  return request('/api/sms/captcha/verify', data, nmCreateOption(query, 'weapi'));
};
