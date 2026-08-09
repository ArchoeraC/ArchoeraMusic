/// 获取二维码登录 unikey（对齐 login_qr_key.ts）
library;

import '../core/option.dart';
import '../core/request.dart';
import '../core/types.dart';

NeteaseModule nmLoginQrKey = (query, request) async {
  final result = await request('/api/login/qrcode/unikey', {'type': 3}, nmCreateOption(query));
  return NeteaseResponse(
    status: 200,
    body: {'data': result.body, 'code': 200},
    cookie: result.cookie,
  );
};
