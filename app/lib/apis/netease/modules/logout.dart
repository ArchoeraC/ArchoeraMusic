/// 退出登录（对齐 logout.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmLogout = (query, request) =>
    request('/api/logout', {}, nmCreateOption(query));
