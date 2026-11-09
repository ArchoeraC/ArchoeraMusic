// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// KG 风控回归：设备身份必须跨实例稳定，注册/登录协议使用新版 lite 参数。
library;

import 'package:archoera_music/apis/runtime.dart';
import 'package:archoera_music/services/kugou/kugou_api.dart';
import 'package:archoera_music/services/kugou/kugou_crypto.dart';
import 'package:archoera_music/services/kugou/kugou_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ApisRuntime previous;

  setUp(() {
    previous = getRuntime();
    setRuntime(runtime: ApisRuntime());
  });

  tearDown(() => setRuntime(runtime: previous));

  test('设备身份首次生成并持久化，跨实例稳定（不随机换设备）', () {
    final first = KugouApi();
    final saved = getRuntime().sessionStore.get('kugou_device');

    expect(saved['guid'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(saved['guid']!.split('-').length, 5);
    expect(BigInt.tryParse(saved['mid'] ?? ''), isNotNull);
    expect(saved['dev'], matches(RegExp(r'^[0-9A-Z]{10}$')));
    expect(saved['mac'], '02:00:00:00:00:00');
    expect(saved['webgl'], isNotEmpty);

    final second = KugouApi();
    expect(second.device.guid, first.device.guid);
    expect(second.device.mid, first.device.mid);
    expect(second.device.dev, first.device.dev);
    expect(second.device.webgl, first.device.webgl);
  });

  test('register_dev 使用 v3（v2 会频繁拿不到 dfid）', () {
    expect(kgRegisterUrl, endsWith('/risk/v3/r_register_dev'));
  });

  test('lite 验证码登录 t1：与 crypto-js/openssl 输出一致', () {
    expect(
      kgAesEncryptHexRawKeyIv(
        '|1700000000000',
        '5e4ef500e9597fe004bd09a46d8add98',
        '04bd09a46d8add98',
      ),
      '7586bc68c78aa9b94609abd54a220dbe',
    );
  });

  test('lite 验证码登录 t2：设备信封与 crypto-js/openssl 输出一致', () {
    expect(
      kgAesEncryptHexRawKeyIv(
        '550e8400-e29b-41d4-a716-446655440000'
            '|0f607264fc6318a92b9e13c65db7cd3c'
            '|02:00:00:00:00:00|ABCDEFGHIJ|1700000000000',
        'fd14b35e3f81af3817a20ae7adae7020',
        '17a20ae7adae7020',
      ),
      '174fcf18c889a2e44b10cdef39bd9d08'
      'c914976c945fae4b300b3683a5e62837'
      '2a6c734169f275254e1a782f3cf0e9ec'
      'ad87871c31794969eafdb480d99584ac'
      'd58c768b9bfef87fba5f518557737676'
      '84c48e46d2a159e6d0b640d5f586d01f'
      '18feea3d5169ea30c71998fbd4bc77a2'
      'a4f05176c18ac4397335757bf8b8a65f',
    );
  });
}
