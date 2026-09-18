// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ArchoeraOS 安装向导回归：
//  - 草稿校验（加密口令长度/一致性、名称规则、btrfs 上交换文件收敛到 none）；
//  - 步骤流转：语言 → 时区 → 键盘 → 磁盘 → 加密 → 用户 → 摘要 → 进度 → 完成；
//  - 提交的计划内容与用户选择一致（含 LUKS 口令、locale/时区/键盘）；
//  - 进度到达 done 后出现「立即重启」，重启经会话桥接下发。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/installer/installer_wizard.dart';
import 'package:archoera_music/installer/installer_draft.dart';
import 'package:archoera_music/installer/installer_options.dart';
import 'package:archoera_music/services/platform/live_install.dart';
import 'package:archoera_music/services/platform/os_session.dart';
import 'package:archoera_music/services/platform/platform_capabilities.dart';
import 'package:archoera_music/services/platform/system_os.dart';

/// 记录计划并模拟进度的假安装服务。
class _FakeLive implements LiveInstallService {
  _FakeLive({required this.diskList});

  final List<LiveDisk> diskList;
  LivePlan? started;
  LiveInstallStatus next = const LiveInstallStatus(
    running: true,
    percent: 40,
    message: '正在格式化…',
  );
  bool requestCalled = false;

  @override
  bool get available => true;

  @override
  List<LiveDisk> disks() => diskList;

  @override
  bool start(LivePlan plan) {
    started = plan;
    return true;
  }

  @override
  LiveInstallStatus status() => next;

  @override
  bool requestInstaller() {
    requestCalled = true;
    return true;
  }
}

class _FakeOs implements SystemOsSession {
  int reboots = 0;
  int powerOffs = 0;

  @override
  bool get available => true;
  @override
  int setEvents(bool on) => 0;
  @override
  int setBrightness(int percent) => 0;
  @override
  int setVolume(int percent) => 0;
  @override
  int setScreenEnabled(bool on) => 0;
  @override
  int powerOff() {
    powerOffs++;
    return 0;
  }

  @override
  int reboot() {
    reboots++;
    return 0;
  }

  @override
  int suspend() => 0;
  @override
  int hibernate() => 0;
  @override
  int setOutputScale(int scaleMilli) => 0;
  @override
  int setOutputMode(int width, int height) => 0;
  @override
  int setOutputTransform(int transform) => 0;
  @override
  int key(int keycode, int state) => 0;
  @override
  List<OsDisplayOutput> displayOutputs() => const <OsDisplayOutput>[];
  @override
  int setDisplayOutputMode(int outputId, int index) => 0;
  @override
  int setDisplayOutputScale(int outputId, int scaleMilli) => 0;
  @override
  int setDisplayOutputTransform(int outputId, int transform) => 0;
  @override
  Stream<int> get capabilities => const Stream.empty();
  @override
  Stream<int> get brightness => const Stream.empty();
  @override
  Stream<int> get volume => const Stream.empty();
  @override
  Stream<OsBatteryState> get battery => const Stream.empty();
  @override
  Stream<OsSessionState> get session => const Stream.empty();
  @override
  Stream<bool> get screenEnabled => const Stream.empty();
  @override
  Stream<OsPowerKey> get powerKey => const Stream.empty();
  @override
  Stream<OsOutputState> get output => const Stream.empty();
}

const _disks = <LiveDisk>[
  LiveDisk(name: 'sda', sizeBytes: 32 * 1024 * 1024 * 1024, transport: 'usb'),
  LiveDisk(
    name: 'nvme0n1',
    sizeBytes: 512 * 1024 * 1024 * 1024,
    model: 'Samsung SSD',
    transport: 'nvme',
  ),
  LiveDisk(
    name: 'sdb',
    sizeBytes: 8 * 1024 * 1024 * 1024,
    transport: 'usb',
    isLive: true,
  ),
];

Widget _host(_FakeLive live, _FakeOs os) => ProviderScope(
  overrides: [
    liveInstallProvider.overrideWithValue(live),
    osSessionControllerProvider.overrideWithValue(os),
    osCapabilitiesProvider.overrideWithValue(0),
  ],
  child: const InstallerApp(),
);

void main() {
  group('草稿校验', () {
    test('加密口令：过短 / 不一致都拦下，通过后进入计划', () {
      final draft = InstallerDraft()
        ..encrypt = true
        ..luksPassphrase = 'short'
        ..luksConfirm = 'short';
      expect(
        draft.passphraseError(tooShort: 'tooShort', mismatch: 'mismatch'),
        'tooShort',
      );
      draft.luksPassphrase = 'longenough';
      draft.luksConfirm = 'different';
      expect(
        draft.passphraseError(tooShort: 'tooShort', mismatch: 'mismatch'),
        'mismatch',
      );
      draft.luksConfirm = 'longenough';
      expect(
        draft.passphraseError(tooShort: 'tooShort', mismatch: 'mismatch'),
        isNull,
      );
      draft.disk = '/dev/nvme0n1';
      expect(draft.toPlan().luksPassphrase, 'longenough');
    });

    test('文件系统候选含 ext4/btrfs/xfs/f2fs（btrfs 为子卷布局）', () {
      expect(
        installerFilesystems,
        containsAll(<String>['ext4', 'btrfs', 'xfs', 'f2fs']),
      );
      final draft = InstallerDraft()
        ..fs = 'xfs'
        ..swap = 'file';
      draft.normalize();
      expect(draft.swap, 'file', reason: 'xfs 允许交换文件');
      draft.fs = 'btrfs';
      draft.normalize();
      expect(draft.swap, 'none', reason: 'btrfs 子卷布局不支持交换文件');
    });

    test('名称规则与 btrfs 交换文件收敛', () {
      final draft = InstallerDraft()
        ..fs = 'btrfs'
        ..swap = 'file';
      draft.normalize();
      expect(draft.swap, 'none');
      expect(isValidName('archoera'), isTrue);
      expect(isValidName('Archoera'), isFalse);
      expect(isValidName('1archoera'), isFalse);
      expect(isValidName('archo era'), isFalse);
    });
  });

  testWidgets('向导走完全程并提交一致的计划', (tester) async {
    final live = _FakeLive(diskList: _disks);
    final os = _FakeOs();
    await tester.pumpWidget(_host(live, os));
    await tester.pumpAndSettle();

    // 1) 语言：选英文（同时切换向导界面语言）。
    await tester.tap(find.text('English (US)'));
    await tester.pumpAndSettle();
    expect(find.text('Language'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 2) 时区：搜索并选择上海。
    await tester.enterText(find.byType(TextField).first, 'Shanghai');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Asia/Shanghai'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 3) 键盘：选德语。
    await tester.tap(find.text('German').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 4) 磁盘：Live 介质不可选；选 nvme。
    expect(find.textContaining('current live medium'), findsOneWidget);
    await tester.tap(find.textContaining('Samsung SSD'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 5) 加密：开启并输入口令。
    await tester.tap(find.text('Encrypt the disk (LUKS2)'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'correct horse');
    await tester.enterText(fields.at(1), 'correct horse');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 6) 用户：改用户名/主机名。
    final userFields = find.byType(TextFormField);
    await tester.enterText(userFields.at(0), 'archoera');
    await tester.enterText(userFields.at(1), 'archoera-pc');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 7) 摘要：确认显示关键选择，提交后进入进度。
    expect(find.text('Asia/Shanghai'), findsOneWidget);
    expect(find.text('Enabled (LUKS2)'), findsOneWidget);
    await tester.tap(find.text('Start install'));
    await tester.pumpAndSettle();

    final plan = live.started;
    expect(plan, isNotNull);
    expect(plan!.disk, '/dev/nvme0n1');
    expect(plan.locale, 'en_US.UTF-8');
    expect(plan.timezone, 'Asia/Shanghai');
    expect(plan.keymap, 'de');
    expect(plan.encrypt, isTrue);
    expect(plan.luksPassphrase, 'correct horse');
    expect(plan.username, 'archoera');
    expect(plan.hostname, 'archoera-pc');

    // 进度轮询：模拟完成 → 出现重启入口，重启走会话桥接。
    live.next = const LiveInstallStatus(done: true, percent: 100);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reboot now'));
    await tester.pumpAndSettle();
    expect(os.reboots, 1);
    expect(tester.takeException(), isNull);
  });
}
