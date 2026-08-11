/// 云盘上传 - 申请 NOS 上传 token（对齐 cloud_nos_token.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCloudNosToken = (query, request) {
  final data = <String, dynamic>{
    'bucket': 'jd-musicrep-privatecloud-audio-public',
    'ext': query['ext'],
    'filename': query['filename'],
    'local': false,
    'nos_product': 3,
    'type': 'audio',
    'md5': query['md5'],
  };
  return request('/api/nos/token/alloc', data, nmCreateOption(query, 'weapi'));
};
