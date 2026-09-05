/// QM 用户基础资料（对齐 user_detail.ts）。
///
/// 通过 music.UserInfo.userInfoServer / GetLoginUserInfo 获取用户昵称/头像，
/// VipLogin.VipLoginInter / vip_login_base 获取会员权限。未登录返回 code 301。
library;

import '../core/request.dart';
import '../core/types.dart';
import '../core/vip.dart';

Future<Map<String, dynamic>?> _fetchProfile() async {
  try {
    final data = await qmRequest<Map<String, dynamic>>(
      'music.UserInfo.userInfoServer',
      'GetLoginUserInfo',
      const {},
    );
    final info = data['info'];
    if (info is Map) {
      final nick = (info['nick'] ?? info['nickname'] ?? info['name']) as dynamic;
      final logo = info['logo'];
      if ((nick != null && '$nick'.isNotEmpty) ||
          (logo != null && '$logo'.isNotEmpty)) {
        return <String, dynamic>{'nick': '$nick', 'headpic': '$logo'};
      }
    }
  } catch (_) {
    // 失败回退 null（调用方自行降级）
  }
  return null;
}

Future<Map<String, dynamic>?> _fetchVipStatus() async {
  try {
    return await qmRequest<Map<String, dynamic>>(
      'VipLogin.VipLoginInter',
      'vip_login_base',
      const {},
    );
  } catch (_) {
    return null;
  }
}

QmModule qmUserDetail = (_) async {
  final uin = qmGetQQMusicUin();
  final cookies = qmGetQQMusicCookies();

  final hasKey = (cookies['qm_keyst']?.isNotEmpty == true ||
      cookies['qqmusic_key']?.isNotEmpty == true ||
      cookies['pskey']?.isNotEmpty == true ||
      cookies['p_skey']?.isNotEmpty == true ||
      cookies['skey']?.isNotEmpty == true);

  if (uin.isEmpty || uin == '0' || !hasKey) {
    return <String, dynamic>{
      'code': 301,
      'loggedIn': false,
      'message': '未登录 QM 账号',
    };
  }

  final profileFuture = _fetchProfile();
  final vipFuture = _fetchVipStatus();
  final results = await Future.wait([profileFuture, vipFuture]);
  final creator = results[0] is Map ? Map<String, dynamic>.from(results[0] as Map) : null;
  final vipData = results[1] is Map ? Map<String, dynamic>.from(results[1] as Map) : null;

  final avatar = creator?['headpic']?.toString() ?? '';
  final vip = qmNormalizeQQMusicVip(vipData);
  return <String, dynamic>{
    'code': 200,
    'loggedIn': true,
    'profile': <String, dynamic>{
      'userId': uin,
      'nickname': creator?['nick'] ?? '',
      'avatarUrl': avatar.replaceFirst(RegExp('^http://'), 'https://'),
      'isVip': vip.isVip,
      'vipLevel': vip.vipLevel,
    },
  };
};

