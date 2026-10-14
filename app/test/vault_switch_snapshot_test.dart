// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/security/vault_switch_snapshot.dart';

/// 切换方案的容器快照 / 回滚（纯文件位移）单测。
///
/// 回归背景：切换流程「先 destroy 再 init」，init 失败（如 Linux 无系统钥匙串时切回 LEGACY）
/// 会让旧容器已删、库停在「未初始化」。快照使其 **失败即回滚**。
void main() {
  late Directory dataDir;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('vault_switch_snapshot');
  });
  tearDown(() {
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  File f(String name) => File('${dataDir.path}/$name');
  void write(String name, String content) =>
      f(name).writeAsStringSync(content, flush: true);

  test('capture 移走容器文件（含 .tmp*），不动无关文件', () {
    write('credentials.vault', 'V1');
    write('credentials.vault.bak', 'V0');
    write('device.key', 'DEV');
    write('vault.auth', 'AUTH');
    write('credentials.vault.tmp.123', 'TMP');
    write('library.db', 'NOT-VAULT'); // 曲库：不得被碰

    final snap = VaultSwitchSnapshot.capture(dataDir.path);

    for (final name in [
      'credentials.vault',
      'credentials.vault.bak',
      'device.key',
      'vault.auth',
      'credentials.vault.tmp.123',
    ]) {
      expect(f(name).existsSync(), isFalse, reason: '$name 应已移入备份');
    }
    expect(f('library.db').readAsStringSync(), 'NOT-VAULT', reason: '无关文件不动');
    expect(snap.capturedFiles, contains('credentials.vault'));
  });

  test('restore 回滚：删除 init 半成品并把原容器移回', () {
    write('credentials.vault', 'OLD');
    write('device.key', 'OLD-DEV');
    final snap = VaultSwitchSnapshot.capture(dataDir.path);

    // 模拟 init 失败留下的半成品
    write('credentials.vault', 'HALF-NEW');
    write('device.key', 'HALF-NEW-DEV');
    write('sshare.bin', 'HALF-SHARE');

    snap.restore();

    expect(f('credentials.vault').readAsStringSync(), 'OLD');
    expect(f('device.key').readAsStringSync(), 'OLD-DEV');
    expect(f('sshare.bin').existsSync(), isFalse, reason: '半成品应被清掉');
    expect(VaultSwitchSnapshot.backupDirFor(dataDir.path).existsSync(), isFalse,
        reason: '回滚后不留备份目录');
  });

  test('discard：切换成功即丢弃备份（旧容器作废）', () {
    write('credentials.vault', 'OLD');
    final snap = VaultSwitchSnapshot.capture(dataDir.path);
    write('credentials.vault', 'NEW'); // 新方案已建成
    snap.discard();

    expect(f('credentials.vault').readAsStringSync(), 'NEW');
    expect(VaultSwitchSnapshot.backupDirFor(dataDir.path).existsSync(), isFalse);
    expect(f('device.key').existsSync(), isFalse);
  });

  test('崩溃恢复：无容器时自动移回上次中断的备份', () {
    // 上次切换中断：备份里躺着旧容器，数据目录里没有容器
    final backup = VaultSwitchSnapshot.backupDirFor(dataDir.path)
      ..createSync(recursive: true);
    File('${backup.path}/credentials.vault').writeAsStringSync('INTERRUPTED', flush: true);

    final snap = VaultSwitchSnapshot.capture(dataDir.path);

    // capture 先恢复再重新捕获 → 内容仍在（未丢），且确实被重新移入备份
    expect(backup.existsSync(), isTrue);
    expect(File('${backup.path}/credentials.vault').readAsStringSync(), 'INTERRUPTED');
    expect(snap.capturedFiles, contains('credentials.vault'));
    // 回滚后能回到原状
    snap.restore();
    expect(f('credentials.vault').readAsStringSync(), 'INTERRUPTED');
  });

  test('崩溃恢复：已有容器时清除陈旧备份（那是作废的旧密钥材料）', () {
    final backup = VaultSwitchSnapshot.backupDirFor(dataDir.path)
      ..createSync(recursive: true);
    File('${backup.path}/credentials.vault').writeAsStringSync('STALE-OLD', flush: true);
    write('credentials.vault', 'CURRENT-NEW'); // 说明切换其实已完成

    final snap = VaultSwitchSnapshot.capture(dataDir.path);

    // 关键：陈旧的旧容器**不得**盖回当前容器；当前容器被正常捕获进备份
    final captured = File('${backup.path}/credentials.vault');
    expect(captured.readAsStringSync(), 'CURRENT-NEW');
    expect(snap.capturedFiles, contains('credentials.vault'));
    // 回滚后仍是当前容器（陈旧材料已清）
    snap.restore();
    expect(f('credentials.vault').readAsStringSync(), 'CURRENT-NEW');
  });
}
