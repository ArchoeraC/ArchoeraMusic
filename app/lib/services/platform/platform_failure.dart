// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 平台能力失败模型（facade 文档 §5 降级两档）。
///
/// 能力缺失 = Noop 静默降级（工厂负责，不经此类型）；
/// 执行失败（系统服务拒绝 / 后端断连）= 经 [SystemPower.failures] 等流上抛，
/// UI 侧监听并 toast 显式告警——绝不静默吞掉，也不中断业务。
library;

/// 一次能力执行失败 / 后端异常。
class PlatformCapabilityFailure {
  const PlatformCapabilityFailure({
    required this.capability,
    required this.code,
    required this.message,
    this.lost = false,
  });

  /// 能力标识：'power' / 'media' / 'window'。
  final String capability;

  /// 原生错误码（APL_ERR_*，负数）。
  final int code;

  /// 面向日志/告警的英文描述（UI 文案由 l10n 层生成）。
  final String message;

  /// true = 后端断连（APL_EVENT_BACKEND_STATE），后续调用将持续失败直至恢复。
  final bool lost;

  @override
  String toString() =>
      'PlatformCapabilityFailure($capability, code=$code, lost=$lost): $message';
}

/// APL 错误码 → 描述。
String aplErrorMessage(int code) => switch (code) {
      0 => 'ok',
      -1 => 'unsupported on this platform',
      -2 => 'backend failure',
      -3 => 'invalid state / not initialized',
      _ => 'unknown error',
    };
