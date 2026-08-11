/// 酷狗数据模型（歌词 / 评论 / 登录会话 / 用户曲库分类）。
///
/// 从 `kugou_api.dart` 拆出：与网络请求无关的纯类型定义与解析函数，
/// 供 [KugouApi] 与调用方（评论弹窗等）共享。
library;

import '../netease/netease_api.dart' show CoverItem;

/// 歌词结果（lrc 行级 + krc 逐字 + 翻译 + 罗马音）。
class KugouLyric {
  const KugouLyric({
    required this.lrc,
    this.krc = '',
    this.trans = '',
    this.roma = '',
  });

  final String lrc;
  final String krc;
  final String trans;
  final String roma;
}

/// 酷狗歌曲评论（commentsv2/getCommentWithLike 条目）。
class KugouComment {
  const KugouComment({
    required this.id,
    required this.userName,
    required this.text,
    this.avatar,
    this.location,
    this.likedCount = 0,
    this.replyTotal = 0,
    this.timeMs,
    this.reply = const [],
  });

  final String id;
  final String userName;
  final String? avatar;
  final String text;

  /// IP 属地（如「河南」）。
  final String? location;
  final int likedCount;
  final int replyTotal;

  /// 评论时间（毫秒；addtime 'YYYY-MM-DD HH:MM:SS' 解析失败为 null）。
  final int? timeMs;

  /// 被回复的引用内容（replys 首个）。
  final List<KugouComment> reply;
}

/// 酷狗歌曲评论分页。
class KugouCommentPage {
  const KugouCommentPage({
    required this.list,
    required this.total,
    required this.page,
    required this.limit,
  });

  final List<KugouComment> list;
  final int total;
  final int page;
  final int limit;

  bool get hasMore => page * limit < total && list.isNotEmpty;
}

/// 评论条目 → [KugouComment]（点赞取 `like.likenum`；`addtime` 字符串转
/// 毫秒；`replys` 首个递归解析为引用回复）。
KugouComment kgCommentFromKg(Map<String, dynamic> c) {
  final like = c['like'];
  final liked = like is Map ? (like['likenum'] as num?)?.toInt() ?? 0 : 0;
  final replys = c['replys'];
  final replies = replys is List
      ? replys
            .whereType<Map<String, dynamic>>()
            .take(1)
            .map(kgCommentFromKg)
            .toList()
      : const <KugouComment>[];
  return KugouComment(
    id: c['id']?.toString() ?? c['pid']?.toString() ?? '',
    userName: c['user_name']?.toString() ?? '匿名用户',
    avatar: c['user_pic']?.toString(),
    text: c['content']?.toString() ?? '',
    location: c['location']?.toString(),
    likedCount: liked,
    replyTotal: (c['reply_num'] as num?)?.toInt() ?? 0,
    timeMs: DateTime.tryParse(
      c['addtime']?.toString() ?? '',
    )?.millisecondsSinceEpoch,
    reply: replies,
  );
}

/// 酷狗登录会话（扫码登录成功后的 token/userid，v5/url 请求 VIP 曲目用）。
class KugouSession {
  const KugouSession({
    required this.token,
    required this.userid,
    this.nickname,
    this.avatarUrl,
  });

  final String token;
  final String userid;
  final String? nickname;

  /// 用户头像（user_detail 接口 data.pic；未获取到为 null）。
  final String? avatarUrl;

  Map<String, String> toJson() => {
    'token': token,
    'userid': userid,
    'nickname': ?nickname,
    'avatarUrl': ?avatarUrl,
  };

  factory KugouSession.fromJson(Map<String, dynamic> json) => KugouSession(
    token: json['token']?.toString() ?? '',
    userid: json['userid']?.toString() ?? '',
    nickname: json['nickname']?.toString(),
    avatarUrl: json['avatarUrl']?.toString(),
  );

  @override
  String toString() => 'KugouSession(userid=$userid, nickname=$nickname)';
}

/// 酷狗用户曲库条目类型（对齐 MoeKoeMusic Library.vue 对 `/v7/get_all_list`
/// 的分类：创建的歌单 / 收藏的歌单 / 收藏的专辑）。
enum KugouLibraryType {
  /// 我创建的歌单（含系统「我喜欢」）。
  createdPlaylist,

  /// 我收藏的歌单（非本人创建、无 `authors`）。
  collectedPlaylist,

  /// 我收藏的专辑（非本人创建、带 `authors`）。
  collectedAlbum,
}

/// 酷狗用户曲库条目。
class KugouLibraryItem {
  const KugouLibraryItem({
    required this.type,
    required this.id,
    required this.title,
    this.cover,
    this.trackCount = 0,
    this.listid,
  });

  final KugouLibraryType type;

  /// 详情弹窗用 id（`list_create_gid` 优先，`global_collection_id` 兜底；
  /// 对齐 MoeKoeMusic Library.vue 跳转 PlaylistDetail 的取参）。
  final String id;

  final String title;
  final String? cover;
  final int trackCount;

  /// 歌单列表用 id（「我喜欢」播放链路用，非公开歌单接口参数）。
  final String? listid;

  CoverItem toCoverItem() =>
      CoverItem(id: id, title: title, cover: cover, trackCount: trackCount);
}

/// 酷狗用户曲库（登录态，按 [KugouLibraryType] 分类）。
class KugouLibrary {
  const KugouLibrary({required this.items});

  final List<KugouLibraryItem> items;

  List<KugouLibraryItem> get createdPlaylists =>
      items.where((i) => i.type == KugouLibraryType.createdPlaylist).toList();

  List<KugouLibraryItem> get collectedPlaylists =>
      items.where((i) => i.type == KugouLibraryType.collectedPlaylist).toList();

  List<KugouLibraryItem> get collectedAlbums =>
      items.where((i) => i.type == KugouLibraryType.collectedAlbum).toList();
}
