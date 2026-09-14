// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 回归测试：下载任务行的进度条与速度显示。
//
// 背景：UI 迁移到官方 material_ui 拆分包、下载控制器拆分为多文件模块后，
// 需确认进度条（LinearProgressIndicator 的 value）与状态文本里的速度/百分比
// 仍按 DownloadTask 的 received/total/speed 正确渲染。
//
// 覆盖三种形态：
//  ① total 已知 → 确定进度条（value=received/total）+ 百分比 + 大小 + 速度；
//  ② total 未知但已收到字节 → 不定进度条 + “下载中…速度”；
//  ③ 无速度（0）→ 不显示速度后缀。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/downloader/download_controller.dart';
import 'package:archoera_music/widgets/download/download_task_tile.dart';

DownloadTask _runningTask({int received = 0, int? total, int speed = 0}) {
  return DownloadTask(
    taskId: 't1',
    trackId: 'track-1',
    source: 'kugou',
    platformId: 'track-1',
    title: '晴天',
    artist: '周杰伦',
    quality: 'hq',
    status: 'running',
    received: received,
    total: total,
    speed: speed,
  );
}

Future<void> _pumpTile(WidgetTester tester, DownloadTask task) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: DownloadTaskTile(
            task: task,
            scheme: ColorScheme.fromSeed(seedColor: Colors.blue),
            selectMode: false,
            selected: false,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('total 已知：确定进度条 value 正确 + 百分比/大小/速度文本', (tester) async {
    await _pumpTile(
      tester,
      _runningTask(received: 512, total: 1024, speed: 2048),
    );

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, isNotNull, reason: 'total 已知应为确定进度条');
    expect(bar.value, closeTo(0.5, 0.0001));

    expect(find.textContaining('50%'), findsOneWidget);
    expect(find.textContaining('512 B'), findsOneWidget);
    expect(find.textContaining('2.0 KB/s'), findsOneWidget);
  });

  testWidgets('total 未知但有字节：不定进度条 + 速度（无百分比）', (tester) async {
    await _pumpTile(
      tester,
      _runningTask(received: 4096, total: null, speed: 1536),
    );

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, isNull, reason: 'total 未知应为不定进度条');

    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('1.5 KB/s'), findsOneWidget);
  });

  testWidgets('速度为 0：不显示速度后缀', (tester) async {
    await _pumpTile(tester, _runningTask(received: 256, total: 1024, speed: 0));

    expect(find.textContaining('%'), findsOneWidget);
    expect(find.textContaining('B/s'), findsNothing);
  });

  test('copyWith(resetProgress) 清空上一轮进度残留，保留其余字段', () {
    final t = _runningTask(received: 512, total: 1024, speed: 2048);
    final reset = t.copyWith(status: 'resolving', resetProgress: true);
    expect(reset.received, 0);
    expect(reset.total, isNull);
    expect(reset.speed, 0);
    expect(reset.status, 'resolving');
    expect(reset.title, '晴天');
    expect(reset.taskId, 't1');
  });

  test('copyWith 默认（暂停→恢复）保留已收字节', () {
    final t = _runningTask(received: 512, total: 1024, speed: 2048);
    final resumed = t.copyWith(status: 'resolving');
    expect(resumed.received, 512);
    expect(resumed.total, 1024);
  });

  testWidgets('解析阶段已清零：不显示进度条', (tester) async {
    final t = _runningTask(
      received: 512,
      total: 1024,
      speed: 2048,
    ).copyWith(status: 'resolving', resetProgress: true);
    await _pumpTile(tester, t);

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
