/// 云盘上传 - 发布到云盘（对齐 cloud_pub.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCloudPub = (query, request) {
  final data = <String, dynamic>{'songid': query['songid']};
  return request('/api/cloud/pub/v2', data, nmCreateOption(query));
};
