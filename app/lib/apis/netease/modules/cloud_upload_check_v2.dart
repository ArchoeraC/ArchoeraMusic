/// 云盘秒传查重 v2：判断已在曲库的文件能否导入（对齐 cloud_upload_check_v2.ts）
/// 返回 data[0].upload:0 可导入 / 1 已在云盘 / 2 不可导入
library;

import 'dart:convert';

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCloudUploadCheckV2 = (query, request) {
  final data = <String, dynamic>{
    'uploadType': 0,
    'songs': jsonEncode([
      {
        'md5': query['md5'],
        'songId': query['songId'] ?? -2,
        'bitrate': 999000,
        'fileSize': query['fileSize'],
      },
    ]),
  };
  return request('/api/cloud/upload/check/v2', data, nmCreateOption(query));
};
