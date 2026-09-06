// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM 歌曲评论（对齐 comment.ts）。
library;

import '../core/request.dart';
import '../core/types.dart';

QmModule qmComment = (params) async {
  final id = '${params['id'] ?? ''}';
  if (id.isEmpty) return {'code': 400, 'message': 'id required'};
  final type = params['type'] == 'new' ? 'new' : 'hot';
  final page = (((params['page'] as num?)?.toInt() ?? 1)).clamp(1, 1 << 30);
  final limit = (((params['limit'] as num?)?.toInt() ?? 20)).clamp(1, 1 << 30);
  final cursor = '${params['cursor'] ?? ''}';

  final requestParams = <String, dynamic>{
    'BizType': 1,
    'BizId': id,
    'LastCommentSeqNo': cursor,
    'PageSize': limit,
    'PageNum': page - 1,
    'PicEnable': 1,
    if (type == 'hot')
      ...<String, dynamic>{'HotType': 1, 'WithAirborne': 0}
    else
      ...<String, dynamic>{
        'HashTagID': '',
        'SelfSeeEnable': 1,
        'AudioEnable': 1,
      },
  };

  final data = await qmRequest<Map<String, dynamic>>(
    'music.globalComment.CommentRead',
    type == 'hot' ? 'GetHotCommentList' : 'GetNewCommentList',
    requestParams,
    session: false,
  );
  final commentList = data['CommentList'];
  final listMap = commentList is Map ? commentList : const <String, dynamic>{};
  final comments = (listMap['Comments'] as List?) ?? const [];
  final list = comments.whereType<Map>().toList();
  final total = listMap['Total'];
  final hasMore = (listMap['HasMore'] as num?)?.toInt() == 1;
  return {
    'code': 200,
    'comments': list,
    'total': total is num ? total.toInt() : list.length,
    'hasMore': hasMore,
    'nextCursor': hasMore && list.isNotEmpty
        ? (list.last['SeqNo'] ?? '')
        : '',
  };
};

