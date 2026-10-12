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
                    icon: EtaIcons.refresh,
                    variant: SButtonVariant.ghost,
                    size: SButtonSize.small,
                    onPressed: _refresh,
                  ),
                  const Spacer(),
                  SButton(
                    label: l10n.settingsSecurityDestroyAll,
                    icon: EtaIcons.deleteOutline,
                    variant: SButtonVariant.error,
                    size: SButtonSize.small,
                    onPressed: hasAny ? _destroyAll : null,
                  ),
                ],
              ),
            ),
            _buildDestroyRow(
              context,
              icon: EtaIcons.serverOutline,
              title: l10n.settingsSecurityStreaming,
              info:
                  '${streamingServersPath()}\n${_formatBytes(_streamingBytes)} · ${l10n.settingsSecurityStreamingCount(count: _streamingCount)} · ${l10n.settingsSecurityStreamingDesc}',
              enabled: _hasStreaming,
              onDestroy: _destroyStreaming,
            ),
            _buildDestroyRow(
              context,
              icon: EtaIcons.userOutline,
              title: l10n.settingsSecuritySession,
              info:
                  '${vaultFilePath()}\n${_formatBytes(_sessionBytes)} · ${l10n.settingsSecuritySessionDesc}'
                  '${_neteaseOnline || _kugouOnline ? ' · ${l10n.settingsSecurityLoggedIn}' : ''}',
              enabled: _hasSession,
              onDestroy: _destroySession,
            ),
            _buildDestroyRow(
              context,
              icon: EtaIcons.storageOutline,
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
          EtaIcons.wastebasketOutline,
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
            icon: EtaIcons.lockOutline,
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
            icon: EtaIcons.pic2Outline,
            text: l10n.settingsVaultShareBrokenBanner,
            scheme: scheme,
            button: SButton(
              label: l10n.settingsVaultShareBrokenRebuild,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: _deviceBusy ? null : _destroyBrokenVault,
            ),
          ),
        if (_m2aRecoveryReminder)
          _SecurityBanner(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            icon: EtaIcons.warningOutline,
            text: l10n.settingsSchemeRecoveryReminder,
            scheme: scheme,
            tone: scheme.tertiary,
            button: SButton(
              label: l10n.settingsSchemeRecoveryReminderAck,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: _deviceBusy ? null : _ackRecoveryCode,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: _buildSchemeGrid(l10n, scheme),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                EtaIcons.informationOutline,
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
        _buildKdfSelector(l10n, scheme),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                EtaIcons.wastebasketOutline,
                size: 14,
                color: scheme.error.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.settingsSchemeResetHint,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: scheme.error.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Argon2id 强度选择器：仅 m1/m2a 可用（口令承载槽）；crypto/file/m2b
  /// 无口令 KDF → 置灰并给出说明。切换需验证当前口令（见 [_onKdfPresetChanged]）。
  Widget _buildKdfSelector(AppLocalizations l10n, ColorScheme scheme) {
    // 优先回显 vault 实际生效强度（status.kdf）；读取失败/未匹配回退偏好。
    final current = _presetIdForKdf(_vaultKdf) ??
        ref.watch(appPrefsProvider).vaultKdfPreset;
    final supports = _scheme == 'm1' || _scheme == 'm2a';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                EtaIcons.keyOutline,
                size: 16,
                color: supports
                    ? scheme.primary
                    : scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.settingsKdfTitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: supports
                        ? scheme.onSurface
                        : scheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
              Opacity(
                opacity: supports ? 1 : 0.4,
                child: IgnorePointer(
                  ignoring: !supports || _deviceBusy,
                  child: SSegmented<String>(
                    options: [
                      SSegmentedOption('low', l10n.settingsKdfLow),
                      SSegmentedOption('medium', l10n.settingsKdfMedium),
                      SSegmentedOption('high', l10n.settingsKdfHigh),
                    ],
                    selected: current,
                    onChanged: _onKdfPresetChanged,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            supports ? l10n.settingsKdfSubtitle : l10n.settingsKdfUnsupported,
            style: TextStyle(
              fontSize: 11,
              height: 1.35,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  /// 方案卡片响应式网格（每行两张；窄窗自动堆叠）。
  Widget _buildSchemeGrid(AppLocalizations l10n, ColorScheme scheme) {
    final cards = <({String value, String title, String badge, Color color,
        String desc})>[
      (
        value: 'crypto',
        title: l10n.settingsSchemeCryptoTitle,
        badge: l10n.settingsSchemeCryptoBadge,
        color: scheme.primary,
        desc: l10n.settingsSchemeCryptoDesc,
      ),
      (
        value: 'file',
        title: l10n.settingsSchemeFileTitle,
        badge: l10n.settingsSchemeFileBadge,
        color: scheme.tertiary,
        desc: l10n.settingsSchemeFileDesc,
      ),
      (
        value: 'm1',
        title: l10n.settingsSchemeM1Title,
        badge: l10n.settingsSchemeM1Badge,
        color: scheme.secondary,
        desc: l10n.settingsSchemeM1Desc,
      ),
      (
        value: 'm2a',
        title: l10n.settingsSchemeM2aTitle,
        badge: l10n.settingsSchemeM2aBadge,
        color: scheme.primary,
        desc: l10n.settingsSchemeM2aDesc,
      ),
      (
        value: 'm2b',
        title: l10n.settingsSchemeM2bTitle,
        badge: l10n.settingsSchemeM2bBadge,
        color: scheme.secondary,
        desc: l10n.settingsSchemeM2bDesc,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoCol = constraints.maxWidth >= 420;
        final width = twoCol
            ? (constraints.maxWidth - 10) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in cards)
              SizedBox(
                width: width,
                child: _SchemeCard(
                  value: c.value,
                  selected: _scheme,
                  busy: _deviceBusy,
                  title: c.title,
                  badge: c.badge,
                  badgeColor: c.color,
                  desc: c.desc,
                  icon: EtaIcons.keyOutline,
                  onTap: _onSchemeSelected,
                ),
              ),
          ],
        );
      },
    );
  }

  String _schemeDesc(AppLocalizations l10n) {
    switch (_scheme) {
      case 'file':
        return l10n.settingsSchemeFileModeDesc;
      case 'm1':
        return l10n.settingsSchemeM1ModeDesc;
      case 'm2a':
        return l10n.settingsSchemeM2aModeDesc;
      case 'm2b':
        return l10n.settingsSchemeM2bModeDesc;
      case 'crypto':
      default:
        return l10n.settingsSchemeCryptoModeDesc;
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
    this.tone,
  });

  final EdgeInsets padding;
  final IconData icon;
  final String text;
  final ColorScheme scheme;
  final Widget button;

  /// 强调色（默认危险红；恢复码提醒等警示场景可传 scheme.tertiary）。
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final color = tone ?? scheme.error;
    return Padding(
      padding: padding,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  color: color,
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
