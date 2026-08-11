/// 发送短信验证码（对齐 captcha_sent.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCaptchaSent = (query, request) {
  final data = <String, dynamic>{
    'ctcode': query['ctcode'] ?? '86',
    'secrete': 'music_middleuser_pclogin',
    'cellphone': query['phone'],
  };
  return request('/api/sms/captcha/sent', data, nmCreateOption(query, 'weapi'));
};
