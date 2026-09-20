// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic（实验性音源 `neko`）数据模型与 JSON 解析。
///
/// Neko 响应信封不统一（`data` / `playlists` / `results` / `favorites` /
/// `musicList` 等），解析集中在此，业务层只消费强类型。
library;

/// Neko 登录用户（`/api/user/login` 的 `data.user`）。
class NekoUser {
  const NekoUser({
    required this.id,
    required this.username,
    this.email = '',
    this.isVip = false,
    this.vipExpiresAt,
  });

  final String id;
  final String username;
  final String email;
  final bool isVip;
  final String? vipExpiresAt;

  factory NekoUser.fromJson(Map<String, dynamic> json) => NekoUser(
    id: json['id']?.toString() ?? '',
    username: json['username']?.toString() ?? '',
    email: json['email']?.toString() ?? '',
    isVip: json['isVip'] == true,
    vipExpiresAt: json['vipExpiresAt']?.toString(),
  );

  /// 会话 Map（vault 持久化；键值均 String）。
  Map<String, String> toSessionMap() => {
    'userId': id,
    'username': username,
    'email': email,
    'isVip': '$isVip',
    'vipExpiresAt': ?vipExpiresAt,
  };

  factory NekoUser.fromSessionMap(Map<String, String> s) => NekoUser(
    id: s['userId'] ?? '',
    username: s['username'] ?? '',
    email: s['email'] ?? '',
    isVip: s['isVip'] == 'true',
    vipExpiresAt: s['vipExpiresAt'],
  );

  String get displayName => username.isNotEmpty ? username : email;
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

  /// 创建者昵称（收藏歌单返回 `creator.username`）。
  final String? creator;

  /// 首曲封面路径（`/api/music/cover/{id}`，可能为默认头像路径）。
  final String? firstMusicCover;

  factory NekoPlaylist.fromJson(Map<String, dynamic> json) {
    final creatorRaw = json['creator'];
    final creatorName = creatorRaw is Map
        ? creatorRaw['username']?.toString()
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
