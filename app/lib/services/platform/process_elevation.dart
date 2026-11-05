// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 启动期提权（root / 管理员）探测结果。
///
/// 原生桥接（`apl_process_elevation`，能力位 `aplCapElevation`）只负责**只读探测**；
/// 是否允许继续由启动门（`app/lib/app/elevation_gate.dart`）在 Dart 侧决定。
library;

import 'platform_bindings.dart';

/// 提权形态：POSIX root / Windows 管理员令牌。
enum ProcessElevationKind { root, administrator }

final class ProcessElevation {
  const ProcessElevation({required this.elevated, this.kind});

  /// 当前进程是否真的持有 root / 管理员权限。
  final bool elevated;

  /// 提权形态；未提权（或探测失败）时为 null。
  final ProcessElevationKind? kind;

  /// 解析原生返回值；`<0`（探测失败）返回 null，调用方应按「未提权」降级，
  /// 避免桥接异常直接阻断启动。
  static ProcessElevation? fromNative(int raw) => switch (raw) {
    aplElevationNone => const ProcessElevation(elevated: false),
    aplElevationRoot => const ProcessElevation(
      elevated: true,
      kind: ProcessElevationKind.root,
    ),
    aplElevationAdmin => const ProcessElevation(
      elevated: true,
      kind: ProcessElevationKind.administrator,
    ),
    _ => null,
  };
}
