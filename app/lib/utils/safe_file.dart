// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 应用配置类文件的**安全读写**（收口 App 层所有「裸」`readAsStringSync` /
/// `writeAsStringSync` / `openSync` 调用）。
///
/// **为什么需要**：配置目录对同用户可写，攻击者（或误操作）可在其中植入
///   - **FIFO**：`readAsStringSync` / `openSync` 会**阻塞在打开阶段**（dart:io 无超时）→
///     界面/启动流程冻结；`set -e` 型脚本里更会永久挂住；
///   - **符号链接**：读会**重定向**到任意文件（隐私/解析错乱）；写会**穿透**覆盖链接目标
///     （擦除器的覆盖写更会把任意文件抹掉）；
///   - **超大文件**：一次性读进内存 → OOM。
///
/// **读策略**：[readBytes]/[readString] 先按元数据判定「必须是普通文件」
/// （`allowSymlink` 时解析链接后再判定，照顾把配置文件软链到 dotfiles 的用户），
/// 并施加长度上限；不满足一律返回 `null`，由调用方按「无配置/默认值」处理。
///
/// **写策略**：[writeAtomic] 先写同目录**随机唯一名**临时文件（避免被预置同名符号链接/FIFO），
/// 校验其确为普通文件后再 `rename` 覆盖目标 —— `rename` 不跟随符号链接，只会**替换链接本身**，
/// 从而杜绝「写入穿透」。
///
/// **已知残余（如实）**：`dart:io` 无 `O_NONBLOCK`/`O_NOFOLLOW`，判定与真正的读写之间存在
/// 极窄的 TOCTOU 窗口（攻击者需精确抢时）；彻底关闭需经 `app/native/platform` 走原生
/// `open(2)`，当前未做。此防线足以消除**确定性**攻击（预置文件即可触发的那类）。
class SafeFile {
  SafeFile._();

  /// 默认读取上限（配置类文件；超出视为异常 → 拒绝，避免 OOM）。
  static const int defaultMaxBytes = 8 << 20; // 8 MiB

  static final Random _rng = Random.secure();

  /// 目标是否为「普通文件」。[allowSymlink] 为 true 时解析符号链接后再判定。
  static bool isRegularFile(String path, {bool allowSymlink = true}) {
    try {
      final t = FileSystemEntity.typeSync(path, followLinks: allowSymlink);
      return t == FileSystemEntityType.file;
    } catch (_) {
      return false;
    }
  }

  /// 读取字节：缺失 / 非普通文件 / 超限 / 读失败 → `null`。
  static Uint8List? readBytes(
    String path, {
    int maxBytes = defaultMaxBytes,
    bool allowSymlink = true,
  }) {
    try {
      if (!isRegularFile(path, allowSymlink: allowSymlink)) return null;
      final f = File(path);
      // 先判长度再读（避免把巨型内容读进内存）。
      if (f.lengthSync() > maxBytes) return null;
      final bytes = f.readAsBytesSync();
      if (bytes.length > maxBytes) return null; // 判定后被增长：再挡一次
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 读取 UTF-8 文本：语义同 [readBytes]（解码失败亦返回 `null`）。
  static String? readString(
    String path, {
    int maxBytes = defaultMaxBytes,
    bool allowSymlink = true,
  }) {
    final bytes = readBytes(path, maxBytes: maxBytes, allowSymlink: allowSymlink);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  /// 原子写：同目录唯一临时名 + `rename`；返回是否成功。
  ///
  /// 目标为符号链接时**只替换链接本身**（不穿透写目标）；临时名随机，无法被预置。
  static bool writeAtomic(String path, List<int> bytes) {
    File? tmp;
    try {
      final target = File(path);
      final dir = target.parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final name = target.uri.pathSegments.isEmpty
          ? 'safe'
          : target.uri.pathSegments.last; // 跨平台取文件名（不依赖路径分隔符样式）
      tmp = File('${dir.path}${Platform.pathSeparator}'
          '$name.tmp.${_rng.nextInt(1 << 32).toRadixString(16)}');
      final raf = tmp.openSync(mode: FileMode.writeOnly);
      try {
        raf.writeFromSync(bytes);
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
      // 打开后再验类型（防预置符号链接/FIFO 被顺写）：非普通文件即放弃。
      if (tmp.statSync().type != FileSystemEntityType.file) {
        try {
          tmp.deleteSync();
        } catch (_) {}
        return false;
      }
      tmp.renameSync(path);
      return true;
    } catch (_) {
      if (tmp != null && tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
      return false;
    }
  }

  /// 原子写 UTF-8 文本（便于替换 `writeAsStringSync`）。
  static bool writeAtomicString(String path, String text) =>
      writeAtomic(path, utf8.encode(text));
}
