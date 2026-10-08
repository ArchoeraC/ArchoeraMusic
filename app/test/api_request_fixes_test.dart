// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 请求层回归：把「搜索异常 / 收藏获取失败」根因（请求头缺失、地址不正确、
/// 响应清洗缺失）钉成确定性单测，避免再次回归。
library;

import 'package:archoera_music/apis/netease/core/crypto.dart';
import 'package:archoera_music/apis/netease/core/device.dart';
import 'package:archoera_music/apis/qqmusic/core/credential.dart';
import 'package:archoera_music/apis/qqmusic/core/request.dart';
import 'package:archoera_music/services/kugou/kugou_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NT form-urlencode 保留空值', () {
    test('空值不被丢成裸键（反爬接口靠 k= 判定，缺 = 会 400）', () {
      final encoded = nmFormUrlEncode({
        'appVersion': '9.1.65',
        'currentKeyVersion': '',
        't1': '',
        't2': '',
        'uid': '',
        'os': 'android',
      });
      expect(encoded, contains('currentKeyVersion='));
      expect(encoded, contains('t1='));
      expect(encoded, contains('t2='));
      expect(encoded, contains('uid='));
      // 不能出现裸键（无 =）
      expect(encoded.split('&').every((p) => p.contains('=')), isTrue);
    });

    test('特殊字符被正确编码', () {
      expect(nmFormUrlEncode({'k': 'a+b/c='}), 'k=a%2Bb%2Fc%3D');
    });
  });

  test('NT deviceId 为 52 位大写 hex（对齐服务端设备标识）', () {
    final id = nmGetDeviceId();
    expect(id.length, 52);
    expect(RegExp(r'^[0-9A-F]{52}$').hasMatch(id), isTrue);
  });

  group('KG 响应清洗', () {
    test('剥离 KG_TAG 包裹注释后再 JSON 解析', () {
      const raw =
          '<!--KG_TAG_RES_START-->{"status":1,"data":{}}<!--KG_TAG_RES_END-->';
      expect(kgCleanResponse(raw), '{"status":1,"data":{}}');
      // 无包裹时原样返回（trim 后）
      expect(kgCleanResponse('  {"a":1}  '), '{"a":1}');
    });
  });

  group('QQ 登录类型与凭据映射', () {
    test('qmLoginType 优先 cookie，其次 musickey 前缀', () {
      qmMergeQQMusicCookies({
        'tmeLoginType': '1',
        'qm_keyst': 'W_Xabc',
        'qqmusic_key': 'W_Xabc',
      });
      expect(qmLoginType(), 1);

      qmMergeQQMusicCookies({
        'tmeLoginType': '',
        'qm_keyst': 'W_Xabc',
        'qqmusic_key': 'W_Xabc',
      });
      expect(qmLoginType(), 1);

      qmMergeQQMusicCookies({
        'tmeLoginType': '',
        'qm_keyst': 'plainkey',
        'qqmusic_key': 'plainkey',
      });
      expect(qmLoginType(), 2);
    });

    test('微信登录（loginType=1）映射到 wx* 字段', () {
      final session = qmCredentialToSession({
        'musickey': 'W_Xkey',
        'str_musicid': 'o12345',
        'openid': 'openid-1',
        'refresh_token': 'rt-1',
        'unionid': 'union-1',
        'loginType': 1,
      });
      expect(session['uin'], '12345');
      expect(session['wxuin'], '12345');
      expect(session['wxopenid'], 'openid-1');
      expect(session['wxrefresh_token'], 'rt-1');
      expect(session.containsKey('psrf_qqopenid'), isFalse);
      expect(session['tmeLoginType'], '1');
    });

    test('QQ 登录（loginType=2）映射到 psrf_qq* 字段', () {
      final session = qmCredentialToSession({
        'musickey': 'key',
        'str_musicid': '67890',
        'openid': 'openid-2',
        'refresh_token': 'rt-2',
        'loginType': 2,
      });
      expect(session['uin'], '67890');
      expect(session['psrf_qqopenid'], 'openid-2');
      expect(session['psrf_qqrefresh_token'], 'rt-2');
      expect(session.containsKey('wxuin'), isFalse);
      expect(session['tmeLoginType'], '2');
    });
  });
}
