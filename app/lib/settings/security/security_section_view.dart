// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../security_section.dart';

extension _SecuritySectionView on _SecuritySectionState {
  Widget _buildSecuritySection(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final hasAny = _hasStreaming || _hasSession || _hasUserDb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSecuritySection,
          note: l10n.settingsSecurityNote,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Row(
                children: [
                  SButton(
                    label: l10n.settingsCacheRefresh,
                    icon: Icons.refresh,
                    variant: SButtonVariant.ghost,
                    size: SButtonSize.small,
                    onPressed: _refresh,
                  ),
                  const Spacer(),
                  SButton(
                    label: l10n.settingsSecurityDestroyAll,
                    icon: Icons.delete_sweep_outlined,
                    variant: SButtonVariant.error,
                    size: SButtonSize.small,
                    onPressed: hasAny ? _destroyAll : null,
                  ),
                ],
              ),
            ),
            _buildDestroyRow(
              context,
              icon: Icons.dns_outlined,
              title: l10n.settingsSecurityStreaming,
              info:
                  '${streamingServersPath()}\n${_formatBytes(_streamingBytes)} · ${l10n.settingsSecurityStreamingCount(_streamingCount)} · ${l10n.settingsSecurityStreamingDesc}',
              enabled: _hasStreaming,
              onDestroy: _destroyStreaming,
            ),
            _buildDestroyRow(
              context,
              icon: Icons.account_circle_outlined,
              title: l10n.settingsSecuritySession,
              info:
                  '${vaultFilePath()}\n${_formatBytes(_sessionBytes)} · ${l10n.settingsSecuritySessionDesc}'
                  '${_neteaseOnline || _kugouOnline ? ' · ${l10n.settingsSecurityLoggedIn}' : ''}',
              enabled: _hasSession,
              onDestroy: _destroySession,
            ),
            _buildDestroyRow(
              context,
              icon: Icons.storage_outlined,
              title: l10n.settingsSecurityUserDb,
              info:
                  '${userDbPath()}\n${_formatBytes(_userDbBytes)} · ${l10n.settingsSecurityUserDbDesc}',
              enabled: _hasUserDb,
              onDestroy: _destroyUserDb,
            ),
          ],
        ),
        _buildDeviceBindSection(l10n, scheme),
      ],
    );
  }

  Widget _buildDestroyRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String info,
    required bool enabled,
    required VoidCallback onDestroy,
  }) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return SettingTile(
      icon: icon,
      title: title,
      subtitle: info,
      trailing: IconButton(
        tooltip: l10n.settingsSecurityDestroy,
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        onPressed: enabled ? onDestroy : null,
        icon: Icon(
          Icons.delete_forever_outlined,
          color: enabled
              ? scheme.error
              : scheme.onSurface.withValues(alpha: 0.25),
        ),
      ),
    );
  }

  Widget _buildDeviceBindSection(AppLocalizations l10n, ColorScheme scheme) {
    return SettingSection(
      title: l10n.settingsSchemeSection,
      note: l10n.settingsSchemeNote,
      children: [
        if (_needsRecovery)
          _SecurityBanner(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            icon: Icons.lock_outline,
            text: l10n.settingsDeviceBindRecoveryBanner,
            scheme: scheme,
            button: SButton(
              label: l10n.settingsDeviceBindRecover,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: _deviceBusy ? null : _recoverVault,
            ),
          ),
        if (_shareBroken)
          _SecurityBanner(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            icon: Icons.broken_image_outlined,
            text: l10n.settingsVaultShareBrokenBanner,
            scheme: scheme,
            button: SButton(
              label: l10n.settingsVaultShareBrokenRebuild,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: _deviceBusy ? null : _destroyBrokenVault,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _SchemeCard(
                        value: 'crypto',
                        selected: _scheme,
                        busy: _deviceBusy,
                        title: l10n.settingsSchemeCryptoTitle,
                        badge: l10n.settingsSchemeCryptoBadge,
                        badgeColor: scheme.primary,
                        desc: l10n.settingsSchemeCryptoDesc,
                        icon: Icons.vpn_key_outlined,
                        onTap: _onSchemeSelected,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _SchemeCard(
                        value: 'file',
                        selected: _scheme,
                        busy: _deviceBusy,
                        title: l10n.settingsSchemeFileTitle,
                        badge: l10n.settingsSchemeFileBadge,
                        badgeColor: scheme.tertiary,
                        desc: l10n.settingsSchemeFileDesc,
                        icon: Icons.key_outlined,
                        onTap: _onSchemeSelected,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _SchemeCard(
                value: 'vault',
                selected: _scheme,
                busy: _deviceBusy,
                title: l10n.settingsSchemeVaultTitle,
                badge: l10n.settingsSchemeVaultBadge,
                badgeColor: scheme.error,
                desc: l10n.settingsSchemeVaultDesc,
                icon: Icons.shield_outlined,
                onTap: _onSchemeSelected,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _schemeDesc(l10n),
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_scheme == 'vault') ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: _ModeCards(
              values: const ['os', 'password', 'multiseal'],
              labels: [
                l10n.settingsVaultModeV1,
                l10n.settingsVaultModeV2,
                l10n.settingsVaultModeV3,
              ],
              descriptions: [
                l10n.settingsVaultModeDescOs,
                l10n.settingsVaultModeDescPassword,
                l10n.settingsVaultModeDescMultiseal,
              ],
              icons: const [
                Icons.security_outlined,
                Icons.password_outlined,
                Icons.devices_outlined,
              ],
              selected: _vaultMode,
              disabledValues: _disabledModes,
              onChanged: _onModeSelected,
            ),
          ),
          if (_isDeviceBound) ...[
            _buildChevronTile(
              context,
              icon: Icons.password_outlined,
              title: l10n.settingsDeviceBindChangeRecovery,
              subtitle: l10n.settingsDeviceBindChangeRecoveryDesc,
              onPressed: _deviceBusy ? null : _changeRecoveryPassword,
            ),
            _buildChevronTile(
              context,
              icon: Icons.sync_lock_outlined,
              title: l10n.settingsDeviceBindRebind,
              subtitle: l10n.settingsDeviceBindRebindDesc,
              onPressed: _deviceBusy ? null : _rebindDevice,
            ),
            _buildChevronTile(
              context,
              icon: Icons.link_off_outlined,
              title: l10n.settingsDeviceBindClose,
              subtitle: l10n.settingsDeviceBindCloseDesc,
              onPressed: _deviceBusy ? null : _disableDeviceBind,
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildChevronTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onPressed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: IconButton(
        tooltip: title,
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        icon: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
      ),
    );
  }

  String _schemeDesc(AppLocalizations l10n) {
    switch (_scheme) {
      case 'crypto':
        return l10n.settingsSchemeCryptoModeDesc;
      case 'file':
        return l10n.settingsSchemeFileModeDesc;
      case 'vault':
        return l10n.settingsSchemeVaultModeDesc;
      default:
        return l10n.settingsVaultModeDescUnknown;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }
}

class _SecurityBanner extends StatelessWidget {
  const _SecurityBanner({
    required this.padding,
    required this.icon,
    required this.text,
    required this.scheme,
    required this.button,
  });

  final EdgeInsets padding;
  final IconData icon;
  final String text;
  final ColorScheme scheme;
  final Widget button;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.error.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.error),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.error,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(width: 8),
            button,
          ],
        ),
      ),
    );
  }
}
