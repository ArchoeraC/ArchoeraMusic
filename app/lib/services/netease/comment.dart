/// 网易云歌曲评论模型（对齐原项目 `@shared/types/comment` 的
/// MusicCommentItem / MusicCommentPage 子集）。
library;

/// 单条歌曲评论。
class NeteaseComment {
  const NeteaseComment({
    required this.id,
    required this.userName,
    required this.text,
    this.userId,
    this.avatar,
    this.time,
    this.location,
    this.likedCount = 0,
    this.replyTotal = 0,
    this.reply = const [],
  });

  final String id;
  final String? userId;
  final String userName;
  final String? avatar;

  /// 评论正文。
  final String text;

  /// 评论时间戳（毫秒）。
  final int? time;

  /// IP 属地（如「浙江」）。
  final String? location;
  final int likedCount;

  /// 回复数（仅楼中楼计数）。
  final int replyTotal;

  /// 被回复的引用内容（beReplied，仅展示引用）。
  final List<NeteaseComment> reply;
}

/// 歌曲评论分页。
class NeteaseCommentPage {
  const NeteaseCommentPage({
    required this.list,
    required this.total,
    required this.page,
    required this.limit,
  });

  final List<NeteaseComment> list;
  final int total;
  final int page;
  final int limit;

  bool get hasMore => page * limit < total && list.isNotEmpty;
}
