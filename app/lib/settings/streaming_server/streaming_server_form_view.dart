// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../streaming_server_list.dart';

extension _StreamingServerFormView on _ServerFormState {
  Widget _buildServerForm(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final testOk = _testResult?.ok ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildFormField(
          scheme,
          l10n.streamingServerType,
          child: _buildTypeDropdown(scheme),
        ),
        _buildFormField(
          scheme,
          l10n.streamingServerName,
          child: SInput(
            controller: _nameCtrl,
            hintText: l10n.streamingServerNamePlaceholder,
          ),
        ),
        _buildFormField(
          scheme,
          l10n.streamingServerHost,
          child: SInput(
            controller: _hostCtrl,
            hintText: l10n.streamingServerHostPlaceholder,
            enabled: !_isLocal,
          ),
        ),
        if (!_isLocal) ...[
          Row(
            children: [
              Expanded(
                child: _buildFormField(
                  scheme,
                  l10n.streamingServerPort,
                  child: SInput(
                    controller: _portCtrl,
                    hintText: '443',
                    keyboardType: TextInputType.number,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildFormField(
                  scheme,
                  'HTTPS',
                  child: _SwitchTile(value: _useHttps, onChanged: _setHttps),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              l10n.streamingServerPortNote,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
        _buildFormField(
          scheme,
          l10n.streamingServerLocalTitle,
          child: _SwitchTile(value: _isLocal, onChanged: _setLocal),
        ),
        if (_isLocal)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              l10n.streamingServerLocalDesc,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
        _buildFormField(
          scheme,
          l10n.streamingServerUsername,
          child: SInput(controller: _userCtrl),
        ),
        _buildFormField(
          scheme,
          l10n.streamingServerPassword,
          child: SInput(controller: _passCtrl, obscureText: true),
        ),
        if (_formError != null)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _formError!,
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
          ),
        if (_testResult != null) _buildTestResult(scheme, l10n, testOk),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SButton(
              label: l10n.commonCancel,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: _submitting || _testing
                  ? null
                  : () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 10),
            SButton(
              label: l10n.streamingServerTest,
              icon: Icons.wifi_tethering,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              loading: _testing,
              onPressed: _submitting ? null : () => _handleTest(l10n),
            ),
            const SizedBox(width: 10),
            SButton(
              label: l10n.commonSave,
              icon: Icons.check,
              variant: SButtonVariant.primary,
              size: SButtonSize.small,
              loading: _submitting,
              onPressed: _testing ? null : () => _handleSubmit(l10n),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTestResult(
    ColorScheme scheme,
    AppLocalizations l10n,
    bool testOk,
  ) {
    final result = _testResult!;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: (testOk ? _okGreen : scheme.error).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                testOk ? Icons.check_circle : Icons.error,
                size: 14,
                color: testOk ? _okGreen : scheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  testOk
                      ? (result.version != null
                            ? '${l10n.streamingServerTestOk} · v${result.version}'
                            : l10n.streamingServerTestOk)
                      : l10n.streamingServerTestFail,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: testOk ? _okGreen : scheme.error,
                  ),
                ),
              ),
            ],
          ),
          if (result.error != null) ...[
            const SizedBox(height: 4),
            Text(
              result.error!,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTypeDropdown(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: DropdownButton<StreamingServerType>(
        value: _type,
        isDense: true,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(10),
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        icon: Icon(Icons.arrow_drop_down, color: scheme.onSurfaceVariant),
        onChanged: (v) {
          if (v != null) _setType(v);
        },
        items: [
          for (final t in StreamingServerType.values)
            DropdownMenuItem(
              value: t,
              child: Text(streamingTypeLabels[t] ?? t.name),
            ),
        ],
      ),
    );
  }

  Widget _buildFormField(
    ColorScheme scheme,
    String label, {
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
