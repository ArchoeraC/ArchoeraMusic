// 临时冒烟测试：验证 archoera_scraper FFI 生命周期（create/run/poll/done/dispose）。
// 用空目录触发 empty+done 事件，全程无网络请求。
// 用法：dart run tool/scraper_smoke.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:archoera_music/services/scraper/scraper_bindings.dart';
import 'package:archoera_music/services/scraper/scraper_client.dart';

Future<void> main() async {
  // 1) 库定位与加载
  final so = ScraperBindings.resolveSoPath();
  if (so == null) {
    print('FAIL: 未定位到 libarchoera_scraper');
    exit(1);
  }
  print('OK: 库路径 $so');

  // 2) 创建（空目录 + 临时 db 路径）
  final tmpDir = Directory.systemTemp.createTempSync('scraper_smoke');
  final emptyDir = '${tmpDir.path}/nofiles';
  Directory(emptyDir).createSync();
  final dbPath = '${tmpDir.path}/scraper-state.db';

  final controller = ScraperController(ScraperConfig(
    dirs: [emptyDir],
    scraperDbPath: dbPath,
  ));
  print('OK: create');

  // 3) 运行
  if (!controller.run()) {
    print('FAIL: run 返回 false');
    exit(1);
  }
  print('OK: run 启动, isRunning=${controller.isRunning}');

  // 4) 轮询事件直至 done
  final events = <String>[];
  var deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!controller.isDone && DateTime.now().isBefore(deadline)) {
    final ev = controller.pollEvent();
    if (ev != null) {
      events.add(ev);
      print('EVENT: $ev');
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  // 5) 排空剩余事件
  while (true) {
    final ev = controller.pollEvent();
    if (ev == null) break;
    events.add(ev);
    print('EVENT: $ev');
  }

  if (!controller.isDone) {
    print('FAIL: 20s 内未完成');
    exit(1);
  }
  print('OK: isDone=true');

  // 6) 校验事件序列含 empty + done
  final types = events.map((e) => e.contains('"type"') ? e : e).toList();
  final hasEmpty = events.any((e) => e.contains('"empty"'));
  final hasDone = events.any((e) => e.contains('"done"'));
  if (!hasEmpty || !hasDone) {
    print('FAIL: 事件缺 empty($hasEmpty)/done($hasDone): $events');
    exit(1);
  }
  print('OK: 事件含 empty + done（$types.length 条）');

  // 7) 销毁
  controller.dispose();
  print('OK: dispose');

  tmpDir.deleteSync(recursive: true);
  print('ALL PASS');
}
