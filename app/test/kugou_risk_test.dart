// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// KG SSA 协议回归：行为指纹结构、edt 可解密、sid 为 2048bit OAEP 密文。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archoera_music/services/kugou/kugou_crypto.dart';
import 'package:archoera_music/services/kugou/kugou_request.dart';
import 'package:archoera_music/services/kugou/kugou_risk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('行为指纹包含窗口/滚动/鼠标事件且非空', () {
    final data = kgGenerateBehaviorData(random: Random(7));
    expect(data, isNotEmpty);
    expect(data, startsWith('5,0,0:5,')); // 初始 type-5 + 哨兵
    expect(data, contains(':6,')); // 窗口事件
    expect(data, contains(':3,')); // 鼠标事件
    expect(data.split(':').every((e) => e.split(',').length >= 3), isTrue);
  });

  test('edt 可用 sid 内的 AES key 解密回行为明文', () {
    final sidEdt = kgGenerateSidEdt(
      mid: '1234567890',
      userid: '42',
      dfid: 'dfid-test',
      webgl: '987654321',
      random: Random(11),
    );

    expect(sidEdt.aesKey.length, 16);
    expect(sidEdt.edt, isNotEmpty);
    // RSA-2048 → 256 字节密文 → base64 344 字符。
    expect(base64.decode(sidEdt.sid).length, 256);

    final plain = kgAesDecryptBase64RawKeyIv(
      sidEdt.edt,
      sidEdt.aesKey,
      'kugousecurity123',
    );
    expect(plain, contains('mid=1234567890;'));
    expect(plain, contains('userid=42;'));
    expect(plain, contains('dfid=dfid-test;'));
    expect(plain, contains('webgl=987654321;'));
    expect(plain, contains('webdriver=0;'));
    expect(plain, contains('data=5,0,0:'));
  });

  test('SSA 异常携带 eventid', () {
    final e = KgRiskVerifyException('evt-1');
    expect(e.eventId, 'evt-1');
    expect(e, isA<KgApiException>());
  });

  test('kgGet 读到 ssa-code 响应头时抛验证异常', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response.headers.set('ssa-code', 'evt-get');
      req.response.write('{"status":0}');
      await req.response.close();
    });

    await expectLater(
      kgGet(Uri.parse('http://127.0.0.1:${server.port}/x')),
      throwsA(
        isA<KgRiskVerifyException>().having(
          (e) => e.eventId,
          'eventId',
          'evt-get',
        ),
      ),
    );
  });

  test('ssa-code + 成功响应不误判为验证失败', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response.headers.set('ssa-code', 'evt-success');
      req.response.write('{"status":1,"data":{"ok":true}}');
      await req.response.close();
    });

    final body = await kgGet(Uri.parse('http://127.0.0.1:${server.port}/x'));
    expect(body, isA<Map>());
    expect(body['status'], 1);
  });

  test('kgPost 读到 ssa-code 响应头时抛验证异常', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response.headers.set('ssa-code', 'evt-post');
      req.response.write('{"status":0}');
      await req.response.close();
    });

    await expectLater(
      kgPost(
        Uri.parse('http://127.0.0.1:${server.port}/x'),
        body: '{}',
        headers: const {'Content-Type': 'application/json'},
      ),
      throwsA(
        isA<KgRiskVerifyException>().having(
          (e) => e.eventId,
          'eventId',
          'evt-post',
        ),
      ),
    );
  });
}
