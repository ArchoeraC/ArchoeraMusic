// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic（实验性音源 `neko`）数据模型与 JSON 解析。
///
/// Neko 响应信封不统一（`data` / `playlists` / `results` / `favorites` /
/// `musicList` 等），解析集中在此，业务层只消费强类型。
library;

/// Neko 登录用户（`/api/user/login` 与 `/api/user/info` 的 `data.user`）。
///
/// 服务端自 `d6a0117` 起把用户昵称字段统一为 **`nickname`**（旧版为 `username`），
/// 这里优先读 `nickname`、兼容回退 `username`（老客户端 / 老会话）。
class NekoUser {
  const NekoUser({
    required this.id,
    required this.nickname,
    this.email = '',
    this.isVip = false,
    this.vipExpiresAt,
  });

  final String id;
  final String nickname;
  final String email;
  final bool isVip;
  final String? vipExpiresAt;

  factory NekoUser.fromJson(Map<String, dynamic> json) => NekoUser(
    id: json['id']?.toString() ?? '',
    nickname:
        json['nickname']?.toString() ?? json['username']?.toString() ?? '',
    email: json['email']?.toString() ?? '',
    isVip: json['isVip'] == true,
    vipExpiresAt: json['vipExpiresAt']?.toString(),
  );

  /// 会话 Map（vault 持久化；键值均 String）。
  Map<String, String> toSessionMap() => {
    'userId': id,
    'nickname': nickname,
    'email': email,
    'isVip': '$isVip',
    'vipExpiresAt': ?vipExpiresAt,
  };

  factory NekoUser.fromSessionMap(Map<String, String> s) => NekoUser(
    id: s['userId'] ?? '',
    // 老会话用 'username' 键；新版写 'nickname'。
    nickname: s['nickname'] ?? s['username'] ?? '',
    email: s['email'] ?? '',
    isVip: s['isVip'] == 'true',
    vipExpiresAt: s['vipExpiresAt'],
  );

  String get displayName => nickname.isNotEmpty ? nickname : email;
}

/// 歌单（自建 / 收藏 / 搜索 共用；字段按响应可选）。
class NekoPlaylist {
  const NekoPlaylist({
    required this.id,
    required this.name,
    this.description = '',
    this.musicCount = 0,
    this.creator,
    this.firstMusicCover,
  });

  final String id;
  final String name;
  final String description;
  final int musicCount;

  /// 创建者昵称（收藏歌单返回 `creator.nickname`，旧版为 `creator.username`）。
  final String? creator;

  /// 首曲封面路径（`/api/music/cover/{id}`，可能为默认头像路径）。
  final String? firstMusicCover;

  factory NekoPlaylist.fromJson(Map<String, dynamic> json) {
    final creatorRaw = json['creator'];
    final creatorName = creatorRaw is Map
        ? (creatorRaw['nickname'] ?? creatorRaw['username'])?.toString()
        : null;
    return NekoPlaylist(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      musicCount: (json['musicCount'] as num?)?.toInt() ?? 0,
      creator: (creatorName ?? '').isEmpty ? null : creatorName,
      firstMusicCover: json['firstMusicCover']?.toString(),
    );
  }
}

/// 用户曲库（一次拉取填充收藏页各 tab）。
class NekoUserLibrary {
  const NekoUserLibrary({
    required this.createdPlaylists,
    required this.collectedPlaylists,
    required this.isVip,
  });

  final List<NekoPlaylist> createdPlaylists;
  final List<NekoPlaylist> collectedPlaylists;
  final bool isVip;
}

/// 二维码登录会话（`/api/user/qrlogin/create`）。
class NekoQrSession {
  const NekoQrSession({
    required this.sessionId,
    required this.qrContent,
    this.expiresIn = 180,
  });

  final String sessionId;

  /// `nekomusic://qrlogin?sid=...`（Neko 手机 App 扫码解析）。
  final String qrContent;
  final int expiresIn;
}

/// 二维码登录状态。
enum NekoQrState { pending, scanned, confirmed, canceled, expired, unknown }

/// 二维码状态事件（`event: status` 的 data）。
class NekoQrStatus {
  const NekoQrStatus({
    required this.state,
    this.token,
    this.user,
    this.message = '',
  });

  final NekoQrState state;
  final String? token;
  final NekoUser? user;
  final String message;

  factory NekoQrStatus.fromJson(Map<String, dynamic> json) {
    final raw = json['status']?.toString() ?? '';
    final userRaw = json['user'];
    return NekoQrStatus(
      state: switch (raw) {
        'pending' => NekoQrState.pending,
        'scanned' => NekoQrState.scanned,
        'confirmed' => NekoQrState.confirmed,
        'canceled' || 'cancelled' => NekoQrState.canceled,
        'expired' => NekoQrState.expired,
        _ => NekoQrState.unknown,
      },
      token: json['token']?.toString(),
      user: userRaw is Map
          ? NekoUser.fromJson(Map<String, dynamic>.from(userRaw))
          : null,
      message: json['message']?.toString() ?? '',
    );
  }
}

/// 单条歌曲评论（`GET /api/comments` 的 `data.comments[]`）。
///
/// 服务端只做两层：顶层楼层 + 楼层内回复（回复再回复归入同一楼层，用
/// `replyToUser` 标记 @ 对象），故 [replies] 最多一层。
class NekoComment {
  const NekoComment({
    required this.id,
    required this.userName,
    required this.text,
    this.userId,
    this.time,
    this.location,
    this.replyTotal = 0,
    this.replies = const [],
    this.replyToName,
    this.canDelete = false,
  });

  final String id;
  final String? userId;
  final String userName;
  final String text;

  /// 发表时间（毫秒 epoch；服务端为东八区墙钟，已换算为本地时间基准）。
  final int? time;

  /// IP 属地（如「浙江」；空 → null）。
  final String? location;

  /// 楼内回复数。
  final int replyTotal;

  /// 楼内回复（仅一层）。
  final List<NekoComment> replies;

  /// 被回复者昵称（回复项用；顶层为 null）。
  final String? replyToName;

  /// 是否可删除（服务端按当前登录用户 / 管理员判定）。
  final bool canDelete;

  factory NekoComment.fromJson(Map<String, dynamic> json) {
    final user = json['user'];
    final replyTo = json['replyToUser'];
    final replies = <NekoComment>[];
    final repliesRaw = json['replies'];
    if (repliesRaw is List) {
      for (final e in repliesRaw.whereType<Map>()) {
        replies.add(NekoComment.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    final region = json['ipRegion']?.toString() ?? '';
    return NekoComment(
      id: json['id']?.toString() ?? '',
      userId: user is Map ? user['id']?.toString() : null,
      userName: user is Map ? (user['nickname']?.toString() ?? '') : '',
      text: json['content']?.toString() ?? '',
      time: parseNekoWallClock(json['createdAt']?.toString()),
      location: region.isEmpty ? null : region,
      replyTotal: (json['replyCount'] as num?)?.toInt() ?? replies.length,
      replies: replies,
      replyToName: replyTo is Map
          ? (replyTo['nickname']?.toString() ?? '')
          : null,
      canDelete: json['canDelete'] == true,
    );
  }
}

/// 歌曲评论分页（`/api/comments` 的 `data`）。
class NekoCommentPage {
  const NekoCommentPage({
    required this.list,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.hasMore,
  });

  final List<NekoComment> list;
  final int total;
  final int page;
  final int pageSize;
  final bool hasMore;

  factory NekoCommentPage.fromData(Map<String, dynamic> data) {
    final list = <NekoComment>[];
    final raw = data['comments'];
    if (raw is List) {
      for (final e in raw.whereType<Map>()) {
        list.add(NekoComment.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    final pageSize = (data['pageSize'] as num?)?.toInt() ?? list.length;
    return NekoCommentPage(
      list: list,
      total: (data['total'] as num?)?.toInt() ?? list.length,
      page: (data['page'] as num?)?.toInt() ?? 1,
      pageSize: pageSize,
      hasMore: data['hasMore'] == true,
    );
  }
}

/// 解析服务端东八区墙钟字符串（`yyyy-MM-dd HH:mm:ss`）→ 本地时间基准的毫秒 epoch。
///
/// 服务端（`DbTimeUtil`）统一以 `Asia/Shanghai` 墙钟落库；这里按 UTC+8 解释再
/// 转 UTC 毫秒，保证非东八区用户看到的相对/绝对时间正确。
int? parseNekoWallClock(String? raw) {
  if (raw == null) return null;
  final s = raw.trim().replaceFirst('T', ' ');
  if (s.isEmpty) return null;
  final norm = s.length >= 19 ? s.substring(0, 19) : s;
  final dt = DateTime.tryParse(norm.replaceFirst(' ', 'T'));
  if (dt == null) return null;
  return DateTime.utc(
    dt.year,
    dt.month,
    dt.day,
    dt.hour,
    dt.minute,
    dt.second,
  ).subtract(const Duration(hours: 8)).millisecondsSinceEpoch;
}
