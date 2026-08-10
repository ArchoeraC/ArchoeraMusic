import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/streaming/streaming_provider.dart';

/// 服务器下拉（切换激活服务器）。
class StreamingServerDropdown extends ConsumerWidget {
  const StreamingServerDropdown({super.key, required this.state});

  final StreamingState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final activeId = state.activeServerId ?? '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(100),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: state.servers.any((s) => s.id == activeId) ? activeId : null,
          isDense: true,
          borderRadius: BorderRadius.circular(10),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
          icon: Icon(Icons.arrow_drop_down, color: scheme.onSurfaceVariant),
          onChanged: state.connecting
              ? null
              : (id) {
                  if (id == null || id == activeId) return;
                  ref.read(streamingProvider.notifier).setActiveServer(id);
                },
          items: [
            for (final s in state.servers)
              DropdownMenuItem(
                value: s.id,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
