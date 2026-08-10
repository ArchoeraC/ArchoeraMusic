/// 云盘上传 - 文件查重（秒传判定，对齐 cloud_upload_check.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCloudUploadCheck = (query, request) {
  final data = <String, dynamic>{
    'bitrate': '999000',
    'ext': '',
    'length': query['length'],
    'md5': query['md5'],
    'songId': '0',
    'version': 1,
  };
  return request('/api/cloud/upload/check', data, nmCreateOption(query));
};
