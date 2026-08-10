/// 日志 shim（Dart 版）——对齐 apis/utils/logger.ts。
///
/// 不落盘、只输出到开发者日志（debug console）；保持 coreLog 同构导出。
library;

import 'dart:developer' as dev;

class _ScopedLogger {
  const _ScopedLogger();

  void info(Object message) => dev.log('[core] $message');

  void warn(Object message) => dev.log('[core][warn] $message', level: 900);
}

/// 模块内部日志（对齐 coreLog）
const coreLog = _ScopedLogger();
