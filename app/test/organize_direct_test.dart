// ArchoeraMusic UI
// SPDX-License-Identifier: AGPL-3.0-or-later

// 仅目录整理（organize）集成回归：源目录内文件按模板移入目标目录树。
// 真实 lib + 一份真实音频样本，无网络。

import 'dart:io';

import 'package:archoera_music/services/scraper/scraper_bindings.dart';
import 'package:archoera_music/services/scraper/scrape_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _waitDone(
  ProviderContainer c, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (c.read(scrapeControllerProvider).scraping &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

/// 在 [base] 下（递归）找第一个 >20KB 的 mp3；目录不存在或不可读（权限等）
/// 时返回 null，而不是让用例失败。
Future<String?> _findMp3Sample(String base) async {
  final d = Directory(base);
  if (!d.existsSync()) return null;
  try {
    await for (final e in d.list(recursive: true, followLinks: false)) {
      if (e is File &&
          e.path.toLowerCase().endsWith('.mp3') &&
          e.lengthSync() > 20000) {
        return e.path;
      }
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

void main() {
  test('仅整理：源文件移入 目标目录/{artist}/{album}/', () async {
    final so = ScraperBindings.resolveSoPath();
    if (so == null) {
      markTestSkipped('libarchoera_scraper 未构建，跳过');
      return;
    }
    // 找一份真实音频样本，确定性优先：
    //   1) 仓库内置 MP3 样本（app/core/audio-engine/kernel/fmt/mp3/samples/，
    //      随仓库分发；flutter test 的 CWD = app/，故用包根相对路径）；
    //   2) 再回退用户音乐目录 `$HOME/音乐`（不可读时静默跳过）。
    // 不再递归扫 /tmp：CI/发行版上 /tmp 含 systemd 私有目录（不可列举 →
    // PathAccessException 直接炸用例），且只能撞运气命中别的用例的临时残留，
    // 属非确定性来源（见 AGENTS「偶发失败不得当抖动重试掩盖」）。
    final seeds = <String>[];
    for (final rel in const [
      'core/audio-engine/kernel/fmt/mp3/samples/lame_mono.mp3',
      'core/audio-engine/kernel/fmt/mp3/samples/cbr_mono.mp3',
    ]) {
      final f = File(rel);
      if (f.existsSync() && f.lengthSync() > 20000) {
        seeds.add(f.absolute.path);
        break;
      }
    }
    if (seeds.isEmpty) {
      final home = Platform.environment['HOME'];
      final found = home == null ? null : await _findMp3Sample('$home/音乐');
      if (found != null) seeds.add(found);
    }
    if (seeds.isEmpty) {
      markTestSkipped('无可用音频样本');
      return;
    }

    final tmp = Directory.systemTemp.createTempSync('organize_test');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final src = '${tmp.path}/src';
    Directory(src).createSync();
    final sampleSrc = seeds.first;
    final sampleName = sampleSrc.split(Platform.pathSeparator).last;
    final sample = File(sampleSrc).copySync('$src/sample_$sampleName');
    final out = '${tmp.path}/out';
    Directory(out).createSync();

    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(scrapeControllerProvider.notifier).startOrganize(
          dirs: [src],
          dbPath: '${tmp.path}/state.db',
          targetDir: out,
          pattern: '{artist}/{album}/{track}. {title}.{ext}',
        );
    await _waitDone(c);
    // 留出自动收尾窗口（_finish 复查），避免 teardown dispose 撞上回调
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final st = c.read(scrapeControllerProvider);
    expect(st.scraping, isFalse);
    expect(st.error, isNull, reason: 'organize 不应报错: ${st.error}');

    // 源文件应被移动（不再位于 src 根）
    expect(sample.existsSync(), isFalse, reason: '源文件应被移走');
    // 目标目录树应有非空子目录文件
    final moved = <File>[];
    if (Directory(out).existsSync()) {
      await for (final e in Directory(out).list(recursive: true)) {
        if (e is File) moved.add(e);
      }
    }
    expect(moved, isNotEmpty, reason: '整理后目标目录应有文件');

    // dismissResult：完成后可关闭结果视图回到空闲态（表单可再编辑）
    c.read(scrapeControllerProvider.notifier).dismissResult();
    final after = c.read(scrapeControllerProvider);
    expect(after.scraping, isFalse);
    expect(after.organize, isFalse, reason: 'dismiss 后 organize 标志复位');
    expect(after.hasActivity, isFalse, reason: 'dismiss 后结果快照清空');
    expect(after.error, isNull);
  });
}
