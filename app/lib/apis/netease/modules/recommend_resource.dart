/// 每日推荐歌单 / 专属歌单（需登录，对齐 recommend_resource.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmRecommendResource = (query, request) =>
    request('/api/v1/discovery/recommend/resource', <String, dynamic>{}, nmCreateOption(query, 'weapi'));
