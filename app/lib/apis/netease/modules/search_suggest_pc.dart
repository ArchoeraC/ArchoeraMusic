/// 搜索建议（PC 版，对齐 search_suggest_pc.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSearchSuggestPc = (query, request) {
  final data = <String, dynamic>{'keyword': query['keyword'] ?? ''};
  return request('/api/search/pc/suggest/keyword/get', data, nmCreateOption(query));
};
