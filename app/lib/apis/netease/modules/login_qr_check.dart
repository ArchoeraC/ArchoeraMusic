/// 轮询二维码扫码状态（对齐 login_qr_check.ts）
/// - 801 待扫码、802 待确认、800 已过期、803 已确认（此时 cookie 里有 MUSIC_U）
library;

import '../core/option.dart';
import '../core/request.dart';
import '../core/types.dart';

NeteaseModule nmLoginQrCheck = (query, request) async {
  final data = <String, dynamic>{'key': query['key'], 'type': 3};
  try {
    final result = await request('/api/login/qrcode/client/login', data, nmCreateOption(query));
    return NeteaseResponse(
      status: 200,
      body: {...result.body, 'cookie': result.cookie.join(';')},
      cookie: result.cookie,
    );
  } catch (err) {
    final cookie = err is NeteaseRequestError ? err.response.cookie : const <String>[];
    return NeteaseResponse(status: 200, body: {}, cookie: cookie);
  }
};
