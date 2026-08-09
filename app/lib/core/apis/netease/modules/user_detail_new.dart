/// 用户详情（新版，eapi，对齐 user_detail_new.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmUserDetailNew = (query, request) {
  final data = <String, dynamic>{'all': 'true', 'userId': query['uid']};
  return request('/api/w/v1/user/detail/${query['uid']}', data, nmCreateOption(query, 'eapi'));
};
