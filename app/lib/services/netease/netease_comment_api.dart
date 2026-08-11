part of 'netease_api.dart';

/// 歌曲评论域：热门/最新评论、发表评论、跨源找评论 id。
mixin NeteaseCommentApi on NeteaseApiBase, NeteaseSearchApi {
  /// 热门评论（comment_hot，无需登录）。
  Future<NeteaseCommentPage> songHotComments(
    String id, {
    int page = 1,
    int limit = 20,
  }) => _comments(hot: true, id: id, page: page, limit: limit);

  /// 最新评论（comment_music，分页）。
  Future<NeteaseCommentPage> songComments(
    String id, {
    int page = 1,
    int limit = 20,
  }) => _comments(hot: false, id: id, page: page, limit: limit);

  /// 发表评论（comment_add，需登录）。
  /// 成功返回；失败（未登录 / 重复评论 code 505 等）抛 [NeteaseApiError]。
  Future<void> sendComment(String id, String content) async {
    final body = await _call('comment_add', {'id': id, 'content': content});
    final code = body?['code'];
    if (code is num && code != 200) {
      throw NeteaseApiError('发送评论失败 code=$code', body);
    }
  }

  /// 统一评论拉取与归一化（对齐 getNeteaseComments + normalizeNeteaseCommentPage）。
  Future<NeteaseCommentPage> _comments({
    required bool hot,
    required String id,
    required int page,
    required int limit,
  }) async {
    final body = await _call(hot ? 'comment_hot' : 'comment_music', {
      'id': id,
      'limit': limit,
      'offset': (page - 1) * limit,
    });
    final map = body ?? const <String, dynamic>{};
    final rawList =
        (map[hot ? 'hotComments' : 'comments'] ?? map['data']?['comments']);
    final list = <NeteaseComment>[];
    if (rawList is List) {
      for (final raw in rawList) {
        if (raw is! Map<String, dynamic>) continue;
        final item = _normalizeComment(raw);
        if (item != null) list.add(item);
      }
    }
    final total =
        (map['total'] ?? map['data']?['totalCount'] ?? list.length) as num? ??
        list.length;
    return NeteaseCommentPage(
      list: list,
      total: total.toInt(),
      page: page,
      limit: limit,
    );
  }

  /// 归一化单条评论（对齐 normalizeNeteaseComment）。
  static NeteaseComment? _normalizeComment(Map<String, dynamic> raw) {
    final id =
        raw['commentId']?.toString() ?? raw['beRepliedCommentId']?.toString();
    final text = raw['content']?.toString().trim() ?? '';
    if (id == null || id.isEmpty || text.isEmpty) return null;
    final user = raw['user'];
    final location = raw['ipLocation'];
    final replyRaw = raw['beReplied'];
    final reply = replyRaw is List
        ? replyRaw
              .whereType<Map<String, dynamic>>()
              .map(_normalizeComment)
              .whereType<NeteaseComment>()
              .toList()
        : const <NeteaseComment>[];
    return NeteaseComment(
      id: id,
      userId: user is Map<String, dynamic> ? user['userId']?.toString() : null,
      userName: user is Map<String, dynamic>
          ? user['nickname']?.toString() ?? ''
          : '',
      avatar: user is Map<String, dynamic>
          ? user['avatarUrl']?.toString()
          : null,
      text: text,
      time: (raw['time'] as num?)?.toInt(),
      location: location is Map<String, dynamic>
          ? location['location']?.toString()
          : null,
      likedCount: (raw['likedCount'] as num?)?.toInt() ?? 0,
      replyTotal: (raw['replyCount'] as num?)?.toInt() ?? 0,
      reply: reply,
    );
  }

  /// 匹配当前 [track] 的网易云歌曲 id（对齐 findNeteaseId）：
  /// 网易云源直接用 id；异源用「标题 + 歌手」关键词 cloudsearch +
  /// [pickBestCandidate] 挑最匹配项；找不到返回 null。
  Future<String?> findNeteaseCommentId(Track track) async {
    if (track.source == 'netease' && track.id.isNotEmpty) return track.id;
    final keyword = [
      track.title,
      track.artists.map((a) => a.name).join(' '),
    ].map((s) => s.trim()).where((s) => s.isNotEmpty).join(' ');
    if (keyword.isEmpty) return null;
    final res = await searchSongs(keyword, limit: 20);
    final candidates = res.items
        .map(
          (t) => LyricCandidate<String>(
            name: t.title,
            artist: t.artistNames,
            album: t.album?.name,
            duration: t.duration,
            extra: t.id,
          ),
        )
        .toList();
    return pickBestCandidate(candidates, track)?.extra;
  }
}
