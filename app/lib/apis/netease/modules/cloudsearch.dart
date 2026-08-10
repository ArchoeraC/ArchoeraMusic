/// 云端搜索（对齐 cloudsearch.ts，返回完整 privileges 字段）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCloudsearch = (query, request) {
  final data = <String, dynamic>{
    's': query['keywords'],
    'type': query['type'] ?? 1,
    'limit': query['limit'] ?? 30,
    'offset': query['offset'] ?? 0,
    'total': true,
  };
  return request('/api/cloudsearch/pc', data, nmCreateOption(query));
};
