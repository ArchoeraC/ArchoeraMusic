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
/// **已知残余（如实，纯 Dart 路径）**：`dart:io` 无 `O_NONBLOCK`/`O_NOFOLLOW`，判定与真正的
/// 读写之间存在极窄的 TOCTOU 窗口（攻击者需精确抢时）。此防线足以消除**确定性**攻击
/// （预置文件即可触发的那类）。
///
/// **原生后端（可选，消除上述残余）**：平台桥接可用时由 `PlatformCapabilities` 注入
/// [SafeFileBackend]（`app/native/platform` 的 `apl_file_*`：原生 `open(2)` + `O_NONBLOCK`/
/// `O_NOFOLLOW` + 打开后按句柄 `fstat` 判普通文件），以「打开即校验」彻底关闭 TOCTOU。
/// 未注入（桥接缺失 / 非桌面 / 单测）时退回下方纯 Dart 实现，语义不变。
abstract class SafeFileBackend {
  /// 读取普通文件字节（原生 open(2)）；非普通文件 / 超限 / 不存在 / 失败返回 null。
  Uint8List? readBytes(String path, {required int maxBytes, required bool allowSymlink});

  /// 原子写（同目录临时名 + rename）；返回是否成功。目录须已存在。
  bool writeAtomic(String path, List<int> bytes);
}

class SafeFile {
  SafeFile._();

  /// 原生安全文件后端（能力可用时由平台层注入；null = 纯 Dart 实现）。
  static SafeFileBackend? backend;

  /// 默认读取上限（配置类文件；超出视为异常 → 拒绝，避免 OOM）。
  static const int defaultMaxBytes = 8 << 20; // 8 MiB

  static final Random _rng = Random.secure();

  /// 路径是否为绝对本地路径（与 `apl_file_*` 的输入契约一致：Linux/macOS 以 `/` 开头，
  /// Windows `X:\`/`X:/` 或 `\\server`）。相对路径不经原生后端（保持 Dart 语义）。
  static bool _isAbsolutePath(String path) {
    if (path.isEmpty) return false;
    if (path.startsWith('/')) return true;
    if (path.startsWith('\\\\')) return true; // Windows UNC
    if (path.length >= 3 && path[1] == ':' && (path[2] == '\\' || path[2] == '/')) {
      final c = path.codeUnitAt(0);
      return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
    }
    return false;
  }

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
    final b = backend;
    if (b != null && _isAbsolutePath(path)) {
      // 原生后端权威：失败即 null（不回退 Dart，以免重新引入 TOCTOU）。
      try {
        return b.readBytes(path, maxBytes: maxBytes, allowSymlink: allowSymlink);
      } catch (_) {
        return null;
      }
    }
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
    final b = backend;
    if (b != null && _isAbsolutePath(path)) {
      try {
        final dir = File(path).parent;
        if (!dir.existsSync()) dir.createSync(recursive: true);
        return b.writeAtomic(path, bytes);
      } catch (_) {
        return false;
      }
    }
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
