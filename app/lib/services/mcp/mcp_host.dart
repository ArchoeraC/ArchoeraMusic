// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// MCP 控制服务宿主：随偏好变化启动/停止本地监听。
///
/// 与 [MediaSessionHost] 同构——挂在应用根（ProviderScope 内），持有服务实例，
/// 偏好中的开关/端口/密钥/能力组变化时把派生配置下发给服务（幂等）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stores/app_prefs.dart';
import 'mcp_models.dart';
import 'mcp_service.dart';

/// 订阅偏好并驱动 [McpService] 生命周期。
class McpHost extends ConsumerStatefulWidget {
  const McpHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<McpHost> createState() => _McpHostState();
}

class _McpHostState extends ConsumerState<McpHost> {
  McpService get _service => ref.read(mcpServiceProvider);

  @override
  void initState() {
    super.initState();
    final config = mcpConfigOf(ref.read(appPrefsProvider));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_service.apply(config));
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<McpConfig>(
      appPrefsProvider.select(mcpConfigOf),
      (_, next) => unawaited(_service.apply(next)),
    );
    return widget.child;
  }
}
