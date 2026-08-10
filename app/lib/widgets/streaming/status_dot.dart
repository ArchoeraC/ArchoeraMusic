import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/streaming/streaming_provider.dart';

/// 连接状态点（绿=已连接 / 红=连接出错 / 琥珀=待连接）。
class StreamingStatusDot extends StatelessWidget {
  const StreamingStatusDot({
    super.key,
    required this.state,
    required this.scheme,
  });

  final StreamingState state;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final color = state.connected
        ? const Color(0xFF34C759)
        : (state.connectionError != null && !state.connecting)
            ? scheme.error
            : const Color(0xFFFFB340);
    return Tooltip(
      message: state.connected
          ? (state.serverVersion != null
              ? '${context.l10n.streamingServerConnected} · v${state.serverVersion}'
              : context.l10n.streamingServerConnected)
          : (state.connecting
                ? context.l10n.commonLoading
                : context.l10n.streamingServerDisconnected),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 4),
          ],
        ),
      ),
    );
  }
}
