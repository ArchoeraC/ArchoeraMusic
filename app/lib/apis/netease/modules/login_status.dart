/// 登录状态（当前账号信息，对齐 login_status.ts）
library;

import '../core/option.dart';
import '../core/request.dart';
import '../core/types.dart';

NeteaseModule nmLoginStatus = (query, request) async {
  final result = await request('/api/w/nuser/account/get', {}, nmCreateOption(query, 'weapi'));
  final body = result.body;
  if (body['code'] == 200) {
    return NeteaseResponse(
      status: 200,
      body: {'data': {...body}},
      cookie: result.cookie,
    );
  }
  return result;
};
