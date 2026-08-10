/// 专辑详情（元数据 + 曲目，对齐 album.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmAlbum = (query, request) =>
    request('/api/v1/album/${query['id']}', <String, dynamic>{}, nmCreateOption(query, 'weapi'));
