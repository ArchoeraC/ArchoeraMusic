/// 删除云盘歌曲（对齐 user_cloud_del.ts）
library;

import 'dart:convert';

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmUserCloudDel = (query, request) {
  final raw = query['id'];
  final ids = raw is List ? raw : [raw];
  final data = <String, dynamic>{'songIds': jsonEncode(ids)};
  return request('/api/cloud/del', data, nmCreateOption(query, 'weapi'));
};
