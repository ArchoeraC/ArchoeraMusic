/// 云盘上传 - 提交歌曲信息（对齐 cloud_upload_info.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCloudUploadInfo = (query, request) {
  final data = <String, dynamic>{
    'md5': query['md5'],
    'songid': query['songid'],
    'filename': query['filename'],
    'song': query['song'],
    'album': query['album'] ?? '未知专辑',
    'artist': query['artist'] ?? '未知艺术家',
    'bitrate': '999000',
    'resourceId': query['resourceId'],
  };
  return request('/api/upload/cloud/info/v2', data, nmCreateOption(query));
};
