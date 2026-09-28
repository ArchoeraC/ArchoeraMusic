// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 日志 shim（Dart 版）——对齐 apis/utils/logger.ts。
///
/// 统一走 [Log]（落盘 + 控制台）；保持 coreLog 同构导出。
library;

import '../services/log/log.dart';

class _ScopedLogger {
  const _ScopedLogger();

  void info(Object message) => Log.i('core', message);

  void warn(Object message) => Log.w('core', message);
}

/// 模块内部日志（对齐 coreLog）
const coreLog = _ScopedLogger();
