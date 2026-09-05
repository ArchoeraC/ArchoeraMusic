/// 刮削器事件泵（wait_event push）回归测试。
///
/// 可控事件源：真实 lib + 空目录 → worker 立即产出 `empty`+`done` 终态事件，
/// 全程无网络请求。验证：
///   - start 后事件经接收 isolate 事件泵自动消费（去 120ms 轮询）；
///   - done/empty 终态后 scraping 复位、state 保留、自动收尾不挂死；
///   - 连续两次刮削（create/run/destroy/再 create）稳定，事件泵可重建。
///
/// 若本机未构建 libarchoera_scraper（或加载失败）则跳过（非 CI 硬依赖）。
library;

import 'dart:io';

import 'package:archoera_music/services/scraper/scraper_bindings.dart';
import 'package:archoera_music/services/scraper/scrape_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 等 state 收敛（scraping=false 或超时）；返回最终 state。
Future<ScrapeState> _waitSettled(
  ProviderContainer container, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  var st = container.read(scrapeControllerProvider);
  while (st.scraping && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    st = container.read(scrapeControllerProvider);
  }
  return st;
}

void main() {
  test('事件泵：空目录刮削自动收敛 + 连续会话稳定（去 120ms 轮询）', () async {
    final so = ScraperBindings.resolveSoPath();
    if (so == null) {
      markTestSkipped('libarchoera_scraper 未构建，跳过（需 cmake --build app/core/scraper）');
      return;
    }

    final tmp = Directory.systemTemp.createTempSync('scraper_pump_test');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final emptyDir = '${tmp.path}/nofiles';
    Directory(emptyDir).createSync();
    final dbPath = '${tmp.path}/scraper-state.db';

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(scrapeControllerProvider.notifier);

    // 连续两轮：事件泵 create/run→事件→自动收尾 destroy→再 create 全链路
    for (var round = 0; round < 2; round++) {
      notifier.start(dirs: [emptyDir], dbPath: dbPath);
      // start 同步触发；run 后事件尚未回流（主 isolate 未让出事件循环）
      expect(
        container.read(scrapeControllerProvider).scraping,
        isTrue,
        reason: '第 $round 轮 start 后应立即进入 scraping',
      );

      final st = await _waitSettled(container);
      expect(st.scraping, isFalse, reason: '第 $round 轮终态后 scraping=false');
      expect(st.error, isNull, reason: '第 $round 轮不应有 error');

      // 终态事件（empty/done）后留出自动收尾窗口（_finish 一次性复查），
      // 再进入下一轮以暴露残留泵/未销毁句柄导致的挂死或崩溃。
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  });
}
