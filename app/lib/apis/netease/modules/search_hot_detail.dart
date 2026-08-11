/// 热搜详情（带热度/图标，对齐 search_hot_detail.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSearchHotDetail = (query, request) =>
    request('/api/hotsearchlist/get', {}, nmCreateOption(query, 'weapi'));
