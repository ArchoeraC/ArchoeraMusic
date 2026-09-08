// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// M3 观测：极低内存下“启动播放流”的动作（命中拒绝→回退 URL 分支）。
// 用本机回环 HttpServer 模拟在线音源；内存门禁注入 env 压低，不依赖引擎 .so
// （拒绝分支在 store 创建前返回，无需原生库）。
import 'dart:io';

import 'package:archoera_music/services/playback/store_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('极低内存（CEIL 8MiB<floor 32MiB）→ 在线播放流拒绝纯内存并回退 URL', () async {
    final payload = List<int>.generate(1 << 20, (i) => i & 0xFF); // 1 MiB
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fut = server.first.then((req) async {
      req.response.headers.contentLength = payload.length;
      req.response.add(payload);
      await req.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/x.flac';
    final r = await prepareWholeTrackStore(
      url,
      gateEnv: const {'ARCHOERA_MEMORY_CEIL_MB': '8'},
    ).done;
    await fut;
    await server.close(force: true);

    expect(r.ok, isFalse, reason: '整首驻留缓存区=0 → 不建 store、不启动纯内存');
    expect(r.store, 0);
    expect(r.error, contains('回退 URL 路径'));
    // ignore: avoid_print
    print('[M3-观察] 极低内存动作: ${r.error} → 播放器回退引擎 URL 直连');
  });

  test('限高：CEIL 48/FLOOR 32 → 20MiB 曲判定回退（16MiB 内才纯内存）', () async {
    final payload = List<int>.generate(20 << 20, (i) => i & 0xFF); // 20 MiB
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fut = server.first.then((req) async {
      req.response.headers.contentLength = payload.length;
      req.response.add(payload);
      await req.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/x.flac';
    final r = await prepareWholeTrackStore(
      url,
      gateEnv: const {
        'ARCHOERA_MEMORY_CEIL_MB': '48',
        'ARCHOERA_MEMORY_FLOOR_MB': '32',
      },
    ).done;
    await fut;
    await server.close(force: true);
    expect(r.ok, isFalse);
    expect(r.error, contains('> 纯内存整首驻留上限 16777216'));
    // ignore: avoid_print
    print('[M3-观察] 限高动作: ${r.error}');
  });

  test('M2.3b：会话被取代 → cancel 中止在途下载（结果为 cancelled，无 store/回退）',
      () async {
    // 慢速分块服务器（让下载进行中再取消）；客户端取消后写侧吞错退出。
    final payload = List<int>.generate(8 << 20, (i) => i & 0xFF); // 8 MiB
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.first.then((req) async {
      try {
        req.response.headers.contentLength = payload.length;
        const step = 64 * 1024;
        for (var i = 0; i < payload.length; i += step) {
          final end = i + step > payload.length ? payload.length : i + step;
          req.response.add(payload.sublist(i, end));
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await req.response.close();
      } catch (_) {
        // 客户端已取消：写侧异常直接结束（测试不关心）
      }
    });
    final url = 'http://127.0.0.1:${server.port}/slow.flac';
    final fetch = prepareWholeTrackStore(url);
    await Future<void>.delayed(const Duration(milliseconds: 80)); // 让拉流进行
    fetch.cancel();
    final r = await fetch.done.timeout(const Duration(seconds: 8));
    await server.close(force: true);

    expect(r.cancelled, isTrue, reason: '取消后应为 cancelled（不做 fallback/弹窗）');
    expect(r.store, 0);
    expect(r.error, isNull);
    // ignore: avoid_print
    print('[M2.3b] 取消动作: 在途下载已中止，无 SegStore 泄漏/回退');
  });
}
