// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM 会员归一（对齐 apis/qqmusic/core/vip.ts）。
///
/// 将 vip_login_base 响应归一为播放权限状态（是否具会员 / 会员等级）。
library;

/// 归一 QQ 会员播放权限状态。
({bool isVip, int vipLevel}) qmNormalizeQQMusicVip(Map<String, dynamic>? data) {
  final identity = data?['identity'];
  final identityMap = identity is Map ? identity : const <String, dynamic>{};
  final svip = data?['svip'];
  final userinfo = data?['userinfo'];
  final userinfoMap = userinfo is Map ? userinfo : const <String, dynamic>{};

  bool flagPositive(dynamic v) => (v is num ? v.toInt() : int.tryParse('$v') ?? 0) > 0;

  final isVip = <dynamic>[
    svip,
    identityMap['vip'],
    identityMap['HugeVip'],
    identityMap['huge_vip'],
    identityMap['ExpVip'],
    identityMap['exp_vip'],
    identityMap['GroupVipFlag'],
    identityMap['group_vip_flag'],
    identityMap['CPLoverFlag'],
    identityMap['cp_lover_flag'],
  ].any(flagPositive);

  final level = identityMap['level'] ?? userinfoMap['music_level'];
  final levelNum = level is num ? level.toInt() : int.tryParse('$level') ?? 0;
  return (isVip: isVip, vipLevel: levelNum);
}
