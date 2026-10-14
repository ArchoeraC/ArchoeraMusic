// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../vault_unlock_gate.dart';

extension _VaultUnlockGateView on _VaultUnlockGateState {
  Widget _buildVaultUnlockGate(BuildContext context) {
    if (!_needsUnlock) return widget.child;
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final title = _useRecovery
        ? l10n.vaultUnlockRecoveryTitle
        : l10n.vaultUnlockTitle;
    final desc = _useRecovery
        ? l10n.vaultUnlockRecoveryDesc
        : l10n.vaultUnlockDesc;
    final hint = _useRecovery
        ? l10n.vaultUnlockRecoveryHint
        : l10n.vaultUnlockHint;
    // 本门挂在 MaterialApp.builder 里、**位于 Navigator 之上**：Flutter 的 Overlay 在
    // Navigator 内部，故门内 TextField（口令/恢复码）聚焦/选择/粘贴时
    // `Overlay.of(context)` 会拿到 null → release 下 `result!` 抛空指针
    // （2026-10-14 实录：粘贴无效 + "Failed to update editing state"）。
    // 用 OverlayHost 在门内补一个 Overlay 祖先（只作用于解锁屏，不影响主界面）。
    return OverlayHost(
      child: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    _useRecovery
                        ? EtaIcons.shieldOutline
                        : EtaIcons.lockOutline,
                    size: 56,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    desc,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _ctrl,
                    autofocus: true,
                    obscureText: !_useRecovery && _obscure,
                    enabled: !_busy,
                    onSubmitted: (_) => _unlock(),
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: hint,
                      prefixIcon: const Icon(EtaIcons.keyOutline),
                      isDense: true,
                      errorText: _error,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      suffixIcon: _useRecovery
                          ? null
                          : IconButton(
                              tooltip: l10n.settingsDeviceBindShowPassword,
                              iconSize: 18,
                              onPressed: _toggleObscure,
                              icon: Icon(
                                _obscure
                                    ? EtaIcons.eyeCloseOutline
                                    : EtaIcons.eyeOutline,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _unlock,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(EtaIcons.unlockOutline, size: 18),
                    label: Text(l10n.vaultUnlockConfirm),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                  // m2a：口令 / 恢复码双通道切换（恢复码经 store 透传恢复槽）。
                  if (_isM2a)
                    TextButton(
                      onPressed: _busy ? null : _toggleRecovery,
                      child: Text(
                        _useRecovery
                            ? l10n.vaultUnlockPasswordAction
                            : l10n.vaultUnlockRecoveryAction,
                      ),
                    ),
                  TextButton(
                    onPressed: _busy ? null : _skipUnlock,
                    child: Text(l10n.vaultUnlockSkip),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
