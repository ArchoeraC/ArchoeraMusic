/// 用户收藏计数（歌单/专辑/MV 等，对齐 user_subcount.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmUserSubcount = (query, request) =>
    request('/api/subcount', {}, nmCreateOption(query, 'weapi'));
