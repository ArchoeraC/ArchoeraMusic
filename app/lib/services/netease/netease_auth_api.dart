part of 'netease_api.dart';

/// 登录 / 会话域：登录状态、匿名注册、二维码登录、登出。
mixin NeteaseAuthApi on NeteaseApiBase {
  /// 当前登录账号（login_status）；未登录返回 null。
  ///
  /// 需要登录态接口（每日推荐/我喜欢）先经 [ensureAnonymous] 匿名注册，
  /// 再按需 [loginQr*] 扫码登录。
  Future<NeteaseAccount?> loginStatus() async {
    final body = await _call('login_status', const {});
    final data = body?['data'];
    if (data is! Map<String, dynamic>) return null;
    final profile = data['profile'];
    final account = data['account'];
    if (profile is! Map<String, dynamic>) return null;
    return NeteaseAccount(
      userId: profile['userId']?.toString() ?? '',
      nickname: profile['nickname']?.toString() ?? '',
      avatarUrl: profile['avatarUrl']?.toString(),
      vip:
          (profile['vipType'] as num?)?.toInt() != 0 ||
          (account is Map<String, dynamic> &&
              (account['vipType'] as num?)?.toInt() != 0),
    );
  }

  /// 注册/获取匿名态（register_anonimous）：无登录态也可用推荐类接口。
  Future<void> ensureAnonymous() async {
    await _call('register_anonimous', const {});
  }

  /// 二维码登录第一步：获取 unikey（后续生成二维码 + 轮询 [loginQrCheck]）。
  Future<String> loginQrKey() async {
    final body = await _call('login_qr_key', const {});
    return body?['data']?['unikey']?.toString() ?? '';
  }

  /// 二维码登录内容（qrurl 即扫码内容）。
  Future<String> loginQrCreate(String key) async {
    final body = await _call('login_qr_create', {'key': key});
    return body?['data']?['qrurl']?.toString() ?? '';
  }

  /// 二维码轮询结果；[NeteaseQrStatus.code]：801 待扫码 / 802 待确认 /
  /// 800 已过期 / 803 已确认（登录成功，cookie 已写回会话）。
  Future<NeteaseQrStatus> loginQrCheck(String key) async {
    final body = await _call('login_qr_check', {'key': key});
    final code = (body?['code'] as num?)?.toInt() ?? -1;
    return NeteaseQrStatus(
      code: code,
      message: body?['message']?.toString() ?? '',
    );
  }

  /// 登出（logout，清空会话 cookie）。
  Future<void> logout() async {
    await _call('logout', const {});
    nmClearNeteaseCookies();
  }
}
