/// 默认搜索关键词（搜索框 placeholder，对齐 search_default.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSearchDefault = (query, request) =>
    request('/api/search/defaultkeyword/get', {}, nmCreateOption(query));
