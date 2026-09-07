// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../streaming_server_list.dart';

extension _StreamingServerListView on _StreamingServerListState {
  Widget _buildStreamingServerList(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(streamingProvider);
    final notifier = ref.read(streamingProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: cardDecoration(scheme),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.streamingHint,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.streamingHintDetail,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SButton(
                label: l10n.streamingServerAdd,
                icon: EtaIcons.add,
                variant: SButtonVariant.secondary,
                size: SButtonSize.small,
                onPressed: () => _showServerForm(context, l10n),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (state.servers.isEmpty)
          _buildStreamingServerEmpty(scheme, l10n)
        else
          ...state.servers.map(
            (cfg) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildStreamingServerCard(
                context,
                scheme,
                l10n,
                cfg,
                state,
                notifier,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStreamingServerEmpty(ColorScheme scheme, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: cardDecoration(scheme),
      child: Column(
        children: [
          Icon(
            EtaIcons.serverOutline,
            size: 30,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.streamingEmptyNoServer,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.streamingEmptyAddHint,
            style: TextStyle(
              fontSize: 11.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStreamingServerCard(
    BuildContext context,
    ColorScheme scheme,
    AppLocalizations l10n,
    StreamingServerConfig cfg,
    StreamingState state,
    StreamingNotifier notifier,
  ) {
    final isActive = state.activeServerId == cfg.id;
    final isConnected = isActive && state.connected;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: cardDecoration(scheme),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStreamingStatusDot(scheme, state, isActive, isConnected),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        cfg.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _TypeTag(
                      label: streamingTypeLabels[cfg.type] ?? cfg.type.name,
                    ),
                    if (isActive)
                      _buildStreamingStatusTag(l10n, state, isConnected),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${cfg.username}@${cfg.host}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
                if (cfg.lastConnected != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${l10n.streamingServerLastConnected}: '
                    '${_StreamingServerListState._formatDateTime(cfg.lastConnected!)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _buildStreamingActions(context, l10n, cfg, state, notifier),
        ],
      ),
    );
  }

  Widget _buildStreamingStatusDot(
    ColorScheme scheme,
    StreamingState state,
    bool isActive,
    bool isConnected,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isConnected
              ? _okGreen
              : (state.connectionError != null && isActive)
              ? scheme.error
              : _warnOrange,
        ),
      ),
    );
  }

  Widget _buildStreamingStatusTag(
    AppLocalizations l10n,
    StreamingState state,
    bool isConnected,
  ) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: _TypeTag(
        label: isConnected
            ? l10n.streamingServerConnected
            : (state.connecting
                  ? l10n.commonLoading
                  : l10n.streamingServerDisconnected),
        color: isConnected ? _okGreen : _warnOrange,
      ),
    );
  }

  Widget _buildStreamingActions(
    BuildContext context,
    AppLocalizations l10n,
    StreamingServerConfig cfg,
    StreamingState state,
    StreamingNotifier notifier,
  ) {
    final isActive = state.activeServerId == cfg.id;
    final isConnected = isActive && state.connected;
    final connecting = isActive && state.connecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (isActive && isConnected)
          SButton(
            label: l10n.streamingServerDisconnect,
            icon: EtaIcons.unlink,
            variant: SButtonVariant.secondary,
            size: SButtonSize.small,
            onPressed: () => _disconnect(notifier, l10n),
          )
        else
          SButton(
            label: l10n.streamingServerConnect,
            icon: EtaIcons.link,
            variant: SButtonVariant.secondary,
            size: SButtonSize.small,
            loading: _switchingId == cfg.id || connecting,
            onPressed: () => _connect(notifier, l10n, cfg),
          ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SButton(
              label: l10n.streamingServerEdit,
              icon: EtaIcons.editOutline,
              variant: SButtonVariant.ghost,
              size: SButtonSize.small,
              onPressed: () => _showServerForm(context, l10n, existing: cfg),
            ),
            const SizedBox(width: 6),
            SButton(
              label: l10n.commonDelete,
              icon: EtaIcons.deleteOutline,
              variant: SButtonVariant.ghost,
              size: SButtonSize.small,
              onPressed: () => _confirmRemove(context, l10n, cfg, notifier),
            ),
          ],
        ),
      ],
    );
  }
}
