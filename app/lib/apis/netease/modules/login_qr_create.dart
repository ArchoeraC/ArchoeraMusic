/// 生成二维码登录 URL（对齐 login_qr_create.ts）
library;

import '../core/request.dart';
import '../core/types.dart';

NeteaseModule nmLoginQrCreate = (query, request) async {
  final url = 'https://music.163.com/login?codekey=${query['key']}';
  return NeteaseResponse(
    status: 200,
    body: {
      'code': 200,
      'data': {'qrurl': url, 'qrimg': ''},
    },
    cookie: const [],
  );
};
