// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

/// 切换加密方案时的**容器快照 / 回滚**（纯文件位移，可单测）。
///
/// 背景（2026-10 实测修复）：切换流程是「先 `destroy` 再 `init-<scheme>`」。若 `init` 失败
/// ——例如 **Linux 无系统钥匙串（Secret Service / libsecret）时 `init-crypto` 直接拒绝**
/// （"Secret Service 后端在 V1 中未实现，请使用 file 后端"）、或磁盘满 / 口令策略拒绝——
/// 旧容器已删，库就停在「未初始化」：登录态与 MCP 密钥只留内存，且新方案没成、旧方案也回不去。
/// 故切换前把容器文件**移**到同卷备份目录，`init` 失败即移回（回滚）；成功才丢弃。
///
/// 覆盖文件与 `VaultService::destroy` + Dart 侧清理一致：
/// `credentials.vault` / `.bak` / `.tmp*`、`device.key`、`sshare.bin`、`secret.key`、
/// `vault.auth`、`vault.marker`（其余文件如曲库 / 历史库**不动**）。
///
/// 用 `rename` 而非拷贝：同卷位移原子、天然保留 `0600` 权限与属主，且不产生密钥副本
/// （Dart 侧不得起子进程 `chmod`，也不该用字节拷贝把密钥写成 0644）。
///
/// **系统钥匙串里的份额无法快照**（`crypto` / LEGACY 方案）——所以切到 LEGACY 之前必须先经
/// `VaultProcess.canInitCrypto()` 预检，预检不过直接拒绝、绝不 `destroy`（见切换流程）。
///
/// 崩溃恢复：备份目录固定名，若上次切换中途崩溃会留下它。下次 [capture] 时——
/// **当前容器存在** → 说明切换其实已完成（备份是作废的旧密钥材料），直接清除；
/// **当前容器不存在** → 说明死在 destroy 与 init 之间，先把备份移回原位再继续。
class VaultSwitchSnapshot {
  VaultSwitchSnapshot._(this._dataDir, this._backupDir, this._captured);

  /// 备份目录名（数据目录内，保证与容器同卷：`rename` 才能原子且保留权限）。
  static const String dirName = '.vault-switch-backup';

  /// 参与快照的文件名（与 Rust `destroy` + Dart 清理集合对齐）。
  static const List<String> fileNames = <String>[
    'credentials.vault',
    'credentials.vault.bak',
    'device.key',
    'sshare.bin',
    'secret.key',
    'vault.auth',
    'vault.marker',
  ];

  /// 容器名（判「当前是否已有容器」用）。
  static const String vaultFileName = 'credentials.vault';

  final String _dataDir;
  final Directory _backupDir;
  final List<String> _captured;

  /// 本次快照实际移走的文件名（用于诊断 / 测试）。
  List<String> get capturedFiles => List.unmodifiable(_captured);

  static Directory backupDirFor(String dataDir) => Directory(
      '$dataDir${Platform.pathSeparator}$dirName');

  static bool _matches(String name) =>
      fileNames.contains(name) ||
      name.startsWith('$vaultFileName.tmp'); // 遗留临时文件（含 .tmp.<pid>）

  static Iterable<File> _candidates(String dataDir) {
    final dir = Directory(dataDir);
    if (!dir.existsSync()) return const <File>[];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => _matches(_name(f)));
  }

  static String _name(File f) => f.uri.pathSegments.isEmpty
      ? ''
      : Uri.decodeComponent(f.uri.pathSegments.last);

  /// 捕获当前容器（位移到备份目录）。返回的快照须在成功后 [discard]、失败后 [restore]。
  static VaultSwitchSnapshot capture(String dataDir) {
    final backup = backupDirFor(dataDir);
    _resolveStaleBackup(dataDir, backup);
    if (!backup.existsSync()) backup.createSync(recursive: true);

    final moved = <String>[];
    for (final f in _candidates(dataDir)) {
      final name = _name(f);
      if (name.isEmpty) continue;
      try {
        f.renameSync('${backup.path}${Platform.pathSeparator}$name');
        moved.add(name);
      } catch (_) {
        // 单个文件位移失败（权限 / 跨设备）：不阻断切换——最坏情况是它随 destroy 一起消失，
        // 与修复前行为一致（不新增风险）。
      }
    }
    return VaultSwitchSnapshot._(dataDir, backup, moved);
  }

  /// 上次切换中断留下的备份：按「当前是否已有容器」决定清除还是恢复（见类注释）。
  static void _resolveStaleBackup(String dataDir, Directory backup) {
    if (!backup.existsSync()) return;
    final hasContainer = File(
            '$dataDir${Platform.pathSeparator}$vaultFileName')
        .existsSync();
    if (!hasContainer) {
      // 死在 destroy 与 init 之间：把旧容器移回原位（恢复可用状态）
      for (final f in backup.listSync().whereType<File>()) {
        try {
          f.renameSync(
              '$dataDir${Platform.pathSeparator}${_name(f)}');
        } catch (_) {}
      }
    }
    _deleteDir(backup);
  }

  /// 回滚：清掉 init 失败留下的半成品，把备份移回原位（若备份为空则仅清理）。
  void restore() {
    for (final f in _candidates(_dataDir)) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    if (_backupDir.existsSync()) {
      for (final f in _backupDir.listSync().whereType<File>()) {
        try {
          f.renameSync('$_dataDir${Platform.pathSeparator}${_name(f)}');
        } catch (_) {}
      }
    }
    _deleteDir(_backupDir);
  }

  /// 切换成功：丢弃备份（旧容器作废——各方案密文结构不兼容，属设计语义）。
  void discard() => _deleteDir(_backupDir);

  static void _deleteDir(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
