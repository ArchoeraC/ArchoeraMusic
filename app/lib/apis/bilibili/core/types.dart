// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 协议数据模型（纯 Dart，不依赖具体 UI）。
library;

/// 视频分P。
class BilibiliPart {
  const BilibiliPart({
    required this.cid,
    required this.page,
    required this.title,
    required this.durationMs,
  });

  final int cid;
  final int page;
  final String title;
  final int durationMs;
}

/// 视频详情（含分P）。
class BilibiliVideoDetail {
  const BilibiliVideoDetail({
    required this.aid,
    required this.bvid,
    required this.title,
    required this.owner,
    required this.cover,
    required this.durationMs,
    required this.parts,
  });

  /// 稿件 avid（评论等接口以 oid=aid 定位）。
  final int aid;
  final String bvid;
  final String title;
  final String owner;
  final String? cover;
  final int durationMs;
  final List<BilibiliPart> parts;
}

/// 搜索结果条目。
class BilibiliSearchItem {
  const BilibiliSearchItem({
    required this.bvid,
    required this.title,
    required this.author,
    required this.cover,
    required this.durationMs,
    this.cid,
  });

  final String bvid;
  final String title;
  final String author;
  final String? cover;
  final int durationMs;

  /// 已知分P cid（收藏夹/历史可能直接带；搜索结果为 null）。
  final String? cid;
}

/// 收藏夹 / 历史 / 发现分页结果（泛型：协议层为 [BilibiliSearchItem]，
/// 门面层映射为 `Track`）。
class BilibiliTrackPage<T> {
  const BilibiliTrackPage({required this.items, this.nextCursor});

  final List<T> items;

  /// 下一页游标；null = 没有更多。
  final String? nextCursor;
}

/// 单条视频评论（含楼内回复预览）。
class BilibiliComment {
  const BilibiliComment({
    required this.id,
    required this.userName,
    required this.text,
    this.avatar,
    this.location,
    this.timeMs,
    this.likedCount = 0,
    this.replyTotal = 0,
    this.replies = const [],
  });

  final String id;
  final String userName;
  final String? avatar;
  final String text;

  /// IP 属地（已去掉「IP属地：」前缀）。
  final String? location;

  /// 发布时间戳（毫秒）。
  final int? timeMs;
  final int likedCount;

  /// 楼内回复总数。
  final int replyTotal;

  /// 楼内回复预览（接口只给前几条）。
  final List<BilibiliComment> replies;
}

/// 视频评论分页（游标分页；[next] 为 null 表示到底 / 评论关闭）。
class BilibiliCommentPage {
  const BilibiliCommentPage({
    required this.list,
    required this.total,
    this.next,
  });

  final List<BilibiliComment> list;
  final int total;
  final int? next;
}

/// B 站收藏夹（只读）。
class BilibiliFavFolder {
  const BilibiliFavFolder({
    required this.id,
    required this.title,
    required this.cover,
    required this.count,
  });

  final String id;
  final String title;
  final String? cover;
  final int count;
}

/// 搜索结果页。
class BilibiliSearchPage {
  const BilibiliSearchPage({
    required this.items,
    required this.total,
    required this.page,
    required this.hasMore,
  });

  final List<BilibiliSearchItem> items;
  final int total;
  final int page;
  final bool hasMore;
}

/// 可播放的 B 站音频流。
class BilibiliAudioStream {
  const BilibiliAudioStream({
    required this.url,
    required this.qualityId,
    required this.bandwidth,
    required this.backups,
    this.deadline,
    this.fileSize,
    this.codec = 'aac',
    this.isLossless = false,
  });

  final String url;
  final int qualityId;
  final int bandwidth;
  final List<String> backups;

  /// 直链过期时间（Unix 秒；仅用于诊断，不持久化 URL）。
  final int? deadline;

  /// 服务端声明大小（字节）。
  final int? fileSize;

  /// 实际音轨编码（`aac` / `flac` / `eac3`）。
  final String codec;

  /// 是否为无损音轨（FLAC）。
  final bool isLossless;
}

/// 扫码登录挑战。
class BilibiliQrChallenge {
  const BilibiliQrChallenge({required this.key, required this.url});

  /// 轮询用 `qrcode_key`。
  final String key;

  /// 供手机客户端扫描的登录 URL。
  final String url;
}

/// 扫码状态。
enum BilibiliQrState { waiting, scanned, expired, signedIn }

/// 已登录账号资料。
class BilibiliAccount {
  const BilibiliAccount({
    required this.mid,
    required this.nickname,
    required this.avatarUrl,
    required this.isVip,
  });

  final String mid;
  final String nickname;
  final String avatarUrl;
  final bool isVip;
}

/// B 站图片 URL 归一：协议相对补 https，http 升级 https，拒绝 userinfo。
String? bilibiliHttpsUrl(Object? raw) {
  var value = raw?.toString().trim() ?? '';
  if (value.isEmpty) return null;
  if (value.startsWith('//')) value = 'https:$value';
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  if (uri.scheme == 'https') return uri.toString();
  if (uri.scheme == 'http') {
    return uri.replace(scheme: 'https').toString();
  }
  return null;
}

/// 时长文本（`mm:ss` / `hh:mm:ss`）→ 毫秒；已为数字时按秒处理。
int bilibiliDurationMs(Object? raw) {
  if (raw is num) return (raw * 1000).round();
  final text = raw?.toString().trim() ?? '';
  if (text.isEmpty) return 0;
  final parts = text.split(':');
  if (parts.length == 1) {
    final seconds = int.tryParse(parts.first);
    return seconds == null ? 0 : seconds * 1000;
  }
  var seconds = 0;
  for (final part in parts) {
    final value = int.tryParse(part.trim());
    if (value == null) return 0;
    seconds = seconds * 60 + value;
  }
  return seconds * 1000;
}

/// BV 号格式校验。
final RegExp bilibiliBvPattern = RegExp(r'^BV[0-9A-Za-z]{10}$');

bool isBilibiliBvid(String value) => bilibiliBvPattern.hasMatch(value);
