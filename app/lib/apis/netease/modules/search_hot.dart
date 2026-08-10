/// 热门搜索（简版，对齐 search_hot.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSearchHot = (query, request) =>
    request('/api/search/hot', {'type': 1111}, nmCreateOption(query));
