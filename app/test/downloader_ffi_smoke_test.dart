import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/downloader/downloader_ffi.dart';

/// downloader cdylib 的 FFI 冒烟测试：验证 .so 可加载、全部导出符号签名匹配、
/// init → enqueue → cancel → destroy 全生命周期可用。
///
/// 定位共享库：dev 兜底 cwd=app/ → app/core/downloader/target/debug/ 下。
void main() {
  final soPath = DownloaderLibrary.resolveSoPath();

  test('downloader .so 可加载（全部导出符号解析）', () {
    final lib = DownloaderLibrary.load(soPath: soPath);
    expect(lib, isNotNull);
  });

  test('init → enqueue → cancel → destroy 生命周期', () async {
    final tmp = await Directory.systemTemp.createTemp('downloader_smoke');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final lib = DownloaderLibrary.load(soPath: soPath);

    // init 要求 event_cb 非空：注册一个忽略事件的 listener 回调。
    final eventCallable =
        NativeCallable<Void Function(Pointer<Utf8>)>.listener((Pointer<Utf8> _) {});
    addTearDown(eventCallable.close);

    final code = lib.init(
      rootDir: '${tmp.path}/music',
      subdirStrategy: 1,
      maxConcurrent: 2,
      eventCb: eventCallable.nativeFunction.cast<Void>(),
      freeFn: null,
    );
    expect(code, 0, reason: 'init 应返回 0');

    // enqueue：只传 Track 基本信息，URL 解析全在 Rust 内部完成。
    final (enqCode, taskId) = lib.enqueue({
      'trackId': 'smoke-001',
      'source': 'kugou',
      'platformId': '8744B6EACB2AE3BF1A987886609AAE5B7557C3D0',
      'quality': 'lq',
      'title': 'Smoke',
      'artist': 'Tester',
    });
    expect(enqCode, 0, reason: 'enqueue 应返回 0');
    expect(taskId, isNotEmpty);
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(taskId),
      isTrue,
      reason: 'taskId 应为 UUID v4，实际: $taskId',
    );

    final cancelCode = lib.cancel(taskId);
    expect(cancelCode, 0, reason: 'cancel 应返回 0');

    lib.destroy();
  });
}
