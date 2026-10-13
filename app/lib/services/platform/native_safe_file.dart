// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 用 `libarchoera_platform` 的 `apl_file_*`（原生 `open(2)`）实现的
/// [SafeFileBackend]。由 [PlatformCapabilities] 在能力位
/// [aplCapSecureFile] 可用时注入 [SafeFile.backend]，关闭纯 dart:io 路径的
/// TOCTOU 残余（FIFO 阻塞 / 符号链接穿透 / 超限 OOM）。
library;

import 'dart:typed_data';

import '../../utils/safe_file.dart';
import 'platform_bindings.dart';

class NativeSafeFileBackend implements SafeFileBackend {
  NativeSafeFileBackend(this._b);

  final PlatformBindings _b;

  @override
  Uint8List? readBytes(String path, {required int maxBytes, required bool allowSymlink}) =>
      _b.fileReadBytes(path, maxBytes: maxBytes, allowSymlink: allowSymlink);

  @override
  bool writeAtomic(String path, List<int> bytes) => _b.fileWriteAtomic(path, bytes);
}
