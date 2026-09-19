// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 音频效果 ──────────────────────────────────────────────────────────

/// 音频效果分类：10 段均衡器 / 响度归一化 / 播放速度。
///
/// 引擎支持运行时命令，改动即时下发（无需重启会话）；滑块用本地草稿值
/// 保证拖动顺滑，松手才落盘并下发。
class AudioEffectsSection extends ConsumerStatefulWidget {
  const AudioEffectsSection({super.key});

  @override
  ConsumerState<AudioEffectsSection> createState() =>
      _AudioEffectsSectionState();
}

class _AudioEffectsSectionState extends ConsumerState<AudioEffectsSection> {
  /// 拖动中的 10 段增益草稿；null = 跟随偏好。
  List<double>? _draftGains;

  /// 拖动中的预增益草稿。
  double? _draftPreamp;

  /// 拖动中的播放速度草稿。
  double? _draftSpeed;

  List<double> get _gains => _draftGains ?? ref.read(appPrefsProvider).eqGains;

  double get _preamp =>
      _draftPreamp ?? ref.read(appPrefsProvider).eqPreampDb;

  double get _speed => _draftSpeed ?? ref.read(appPrefsProvider).playbackSpeed;

  /// 把当前偏好下发到引擎（实时生效）。
  void _apply() {
    // ignore: discarded_futures
    ref.read(playbackProvider.notifier).applyAudioEffects();
  }

  String _presetLabel(AppLocalizations l10n, String id) => switch (id) {
    'flat' => l10n.settingsEqPresetFlat,
    'pop' => l10n.settingsEqPresetPop,
    'rock' => l10n.settingsEqPresetRock,
    'jazz' => l10n.settingsEqPresetJazz,
    'classical' => l10n.settingsEqPresetClassical,
    'vocal' => l10n.settingsEqPresetVocal,
    'bass' => l10n.settingsEqPresetBass,
    _ => l10n.settingsEqPresetCustom,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    final eqOn = prefs.eqEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1) 均衡器
        SettingSection(
          title: l10n.settingsSectionEqualizer,
          children: [
            SettingSwitchTile(
              icon: EtaIcons.soundLine,
              title: l10n.settingsEqEnabled,
              subtitle: eqOn
                  ? l10n.settingsEqEnabledOn
                  : l10n.settingsEqEnabledOff,
              value: eqOn,
              onChanged: (v) {
                notifier.setEq(enabled: v);
                _apply();
              },
            ),
            SettingTile(
              icon: EtaIcons.magic2Outline,
              title: l10n.settingsEqPreset,
              subtitle: _presetLabel(l10n, prefs.eqPreset),
              enabled: eqOn,
              trailing: DropdownButton<String>(
                value: prefs.eqPreset,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: [
                  for (final id in eqPresetIds)
                    DropdownMenuItem(
                      value: id,
                      child: Text(_presetLabel(l10n, id)),
                    ),
                ],
                onChanged: eqOn
                    ? (v) {
                        if (v == null || v == 'custom') return;
                        final gains = eqPresets[v];
                        if (gains == null) return;
                        setState(() => _draftGains = null);
                        notifier.setEq(preset: v, gains: gains);
                        _apply();
                      }
                    : null,
              ),
            ),
            _bandTile(
              l10n,
              enabled: eqOn,
              label: l10n.settingsEqPreamp,
              sub: '${_preamp.toStringAsFixed(1)} dB',
              value: _preamp,
              onChanged: (v) => setState(() => _draftPreamp = v),
              onChangeEnd: (v) {
                setState(() => _draftPreamp = v);
                notifier.setEq(preampDb: v);
                _apply();
              },
            ),
            for (var i = 0; i < eqBandCount; i++)
              _bandTile(
                l10n,
                enabled: eqOn,
                label: eqBandLabels[i],
                sub: '${_gains[i].toStringAsFixed(1)} dB',
                value: _gains[i],
                onChanged: (v) =>
                    setState(() => _draftGains = [..._gains]..[i] = v),
                onChangeEnd: (v) {
                  final gains = [..._gains]..[i] = v;
                  setState(() => _draftGains = gains);
                  notifier.setEq(gains: gains, preset: 'custom');
                  _apply();
                },
              ),
            SettingSwitchTile(
              icon: EtaIcons.dashboard4Outline,
              title: l10n.settingsEqLimiter,
              subtitle: l10n.settingsEqLimiterDesc,
              value: prefs.limiterEnabled,
              onChanged: (v) {
                notifier.setEq(limiter: v);
                _apply();
              },
            ),
            SettingTile(
              icon: EtaIcons.refresh,
              title: l10n.settingsEqReset,
              subtitle: _presetLabel(l10n, 'flat'),
              trailing: SButton(
                label: l10n.commonReset,
                variant: SButtonVariant.secondary,
                size: SButtonSize.small,
                onPressed: () {
                  setState(() => _draftGains = null);
                  notifier.setEq(gains: eqPresets['flat'], preset: 'flat');
                  _apply();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // 2) 响度归一化
        SettingSection(
          title: l10n.settingsSectionNormalization,
          note: l10n.settingsNormalizationDesc,
          children: [
            SettingSwitchTile(
              icon: EtaIcons.transferHorizontal,
              title: l10n.settingsNormalization,
              subtitle: prefs.normalizationEnabled
                  ? l10n.settingsNormalizationOn
                  : l10n.settingsNormalizationOff,
              value: prefs.normalizationEnabled,
              onChanged: (v) {
                notifier.setNormalization(v);
                _apply();
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        // 3) 播放速度
        SettingSection(
          title: l10n.settingsSectionSpeed,
          children: [
            _bandTile(
              l10n,
              enabled: true,
              label: l10n.settingsPlaybackSpeed,
              sub: '${_speed.toStringAsFixed(2)}×',
              value: _speed,
              min: speedMin,
              max: speedMax,
              divisions: 30,
              onChanged: (v) => setState(() => _draftSpeed = v),
              onChangeEnd: (v) {
                setState(() => _draftSpeed = v);
                notifier.setPlaybackSpeed(v);
                _apply();
              },
            ),
            SettingTile(
              icon: EtaIcons.refresh,
              title: l10n.settingsPlaybackSpeedNormal,
              subtitle: l10n.settingsPlaybackSpeedDesc,
              trailing: SButton(
                label: '1.00×',
                variant: SButtonVariant.secondary,
                size: SButtonSize.small,
                onPressed: () {
                  setState(() => _draftSpeed = null);
                  notifier.setPlaybackSpeed(1.0);
                  _apply();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _bandTile(
    AppLocalizations l10n, {
    required bool enabled,
    required String label,
    required String sub,
    required double value,
    double min = eqGainMinDb,
    double max = eqGainMaxDb,
    int divisions = 24,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: IgnorePointer(
        ignoring: !enabled,
        child: SettingSliderTile(
          icon: EtaIcons.columnsOutline,
          title: label,
          subtitle: sub,
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: sub,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ),
    );
  }
}
