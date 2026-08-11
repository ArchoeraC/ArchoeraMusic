/// 用户详情（旧版，对齐 user_detail.ts）
library;

import 'dart:convert';

import '../core/option.dart';
import '../core/request.dart';
import '../core/types.dart';

NeteaseModule nmUserDetail = (query, request) async {
  final res = await request('/api/v1/user/detail/${query['uid']}', {}, nmCreateOption(query, 'weapi'));
  final renamed = jsonEncode({'status': res.status, 'body': res.body, 'cookie': res.cookie})
      .replaceAll('avatarImgId_str', 'avatarImgIdStr');
  final obj = jsonDecode(renamed) as Map<String, dynamic>;
  return NeteaseResponse(
    status: (obj['status'] as num).toInt(),
    body: (obj['body'] as Map).cast<String, dynamic>(),
    cookie: (obj['cookie'] as List).cast<String>(),
  );
};
