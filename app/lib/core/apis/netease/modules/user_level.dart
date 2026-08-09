/// 用户等级（听歌时长、登录天数等，对齐 user_level.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmUserLevel = (query, request) =>
    request('/api/user/level', {}, nmCreateOption(query, 'weapi'));
