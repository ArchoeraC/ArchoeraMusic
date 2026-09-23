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

  /// 编辑中的参数化段草稿（方向① D1）；null = 跟随偏好。
  List<ParametricBand>? _draftPeqBands;

  /// 拖动中的参数化预增益草稿。
  double? _draftPeqPreamp;

  /// 拖动中的低频管理草稿（方向① D2）。
  double? _draftHpfFreq;
  int? _draftHpfOrder;
  double? _draftBassGain;
  double? _draftBassFreq;

  List<double> get _gains => _draftGains ?? ref.read(appPrefsProvider).eqGains;

  double get _preamp =>
      _draftPreamp ?? ref.read(appPrefsProvider).eqPreampDb;

  double get _speed => _draftSpeed ?? ref.read(appPrefsProvider).playbackSpeed;

  List<ParametricBand> get _peqBands =>
      _draftPeqBands ?? ref.read(appPrefsProvider).peqBands;

  double get _peqPreamp =>
      _draftPeqPreamp ?? ref.read(appPrefsProvider).peqPreampDb;

  double get _hpfFreq =>
      _draftHpfFreq ?? ref.read(appPrefsProvider).lowfreqHpfFreq;

  int get _hpfOrder =>
      _draftHpfOrder ?? ref.read(appPrefsProvider).lowfreqHpfOrder;

  double get _bassGain =>
      _draftBassGain ?? ref.read(appPrefsProvider).lowfreqBassGainDb;

  double get _bassFreq =>
      _draftBassFreq ?? ref.read(appPrefsProvider).lowfreqBassFreq;

  /// 参数化段：拖动中只更新草稿（顺滑），松手落盘并下发。
  void _draftPeqBand(int index, ParametricBand band) {
    final bands = [..._peqBands]..[index] = band;
    setState(() => _draftPeqBands = bands);
  }

  /// 参数化段：落盘并下发。
  void _commitPeqBand(int index, ParametricBand band) {
    final bands = [..._peqBands]..[index] = band;
    setState(() => _draftPeqBands = bands);
    ref.read(appPrefsProvider.notifier).setPeq(bands: bands);
    _apply();
  }

  void _addPeqBand() {
    if (_peqBands.length >= peqMaxBands) return;
    final bands = [..._peqBands, const ParametricBand()];
    setState(() => _draftPeqBands = bands);
    ref.read(appPrefsProvider.notifier).setPeq(bands: bands);
    _apply();
  }

  void _removePeqBand(int index) {
    final bands = [..._peqBands]..removeAt(index);
    setState(() => _draftPeqBands = bands);
    ref.read(appPrefsProvider.notifier).setPeq(bands: bands);
    _apply();
  }

  String _peqKindLabel(int kind) => switch (kind) {
    peqKindLowShelf => '低架',
    peqKindHighShelf => '高架',
    _ => '峰值',
  };

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
        // 1.5) 参数化均衡器（方向① D1）
        SettingSection(
          title: '参数化均衡器',
          note: '任意段峰值 / 低架 / 高架；独立于上方固定 10 段。',
          children: [
            SettingSwitchTile(
              icon: EtaIcons.chartLine,
              title: '参数化均衡器',
              subtitle: prefs.peqEnabled ? '已启用' : '已停用',
              value: prefs.peqEnabled,
              onChanged: (v) {
                notifier.setPeq(enabled: v);
                _apply();
              },
            ),
            _bandTile(
              l10n,
              enabled: prefs.peqEnabled,
              label: '预增益',
              sub: '${_peqPreamp.toStringAsFixed(1)} dB',
              value: _peqPreamp,
              min: peqPreampMinDb,
              max: peqPreampMaxDb,
              divisions: 48,
              onChanged: (v) => setState(() => _draftPeqPreamp = v),
              onChangeEnd: (v) {
                setState(() => _draftPeqPreamp = v);
                notifier.setPeq(preampDb: v);
                _apply();
              },
            ),
            for (var i = 0; i < _peqBands.length; i++)
              _peqBandTile(l10n, i, _peqBands[i], prefs.peqEnabled),
            SettingTile(
              icon: EtaIcons.add,
              title: '添加频段',
              subtitle: '${_peqBands.length} / $peqMaxBands',
              trailing: SButton(
                label: '添加',
                variant: SButtonVariant.secondary,
                size: SButtonSize.small,
                onPressed: _peqBands.length >= peqMaxBands ? null : _addPeqBand,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // 1.6) 次声 / 低频管理（方向① D2）
        SettingSection(
          title: '次声 / 低频管理',
          note: '高通去隆隆声（subsonic）+ 低架 bass boost。',
          children: [
            SettingSwitchTile(
              icon: EtaIcons.dashboard3,
              title: '低频管理',
              subtitle: prefs.lowfreqEnabled ? '已启用' : '已停用',
              value: prefs.lowfreqEnabled,
              onChanged: (v) {
                notifier.setLowFreq(enabled: v);
                _apply();
              },
            ),
            SettingTile(
              icon: EtaIcons.filter,
              title: '高通截止',
              subtitle: '${_hpfFreq.toStringAsFixed(0)} Hz / $_hpfOrder 阶',
              trailing: DropdownButton<int>(
                value: _hpfOrder,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: const [
                  DropdownMenuItem(value: 1, child: Text('1 阶')),
                  DropdownMenuItem(value: 2, child: Text('2 阶')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _draftHpfOrder = v);
                  notifier.setLowFreq(hpfOrder: v);
                  _apply();
                },
              ),
            ),
            _bandTile(
              l10n,
              enabled: prefs.lowfreqEnabled,
              label: '高通频率',
              sub: '${_hpfFreq.toStringAsFixed(0)} Hz',
              value: _hpfFreq,
              min: lowfreqHpfFreqMin,
              max: lowfreqHpfFreqMax,
              divisions: 38,
              onChanged: (v) => setState(() => _draftHpfFreq = v),
              onChangeEnd: (v) {
                setState(() => _draftHpfFreq = v);
                notifier.setLowFreq(hpfFreq: v);
                _apply();
              },
            ),
            _bandTile(
              l10n,
              enabled: prefs.lowfreqEnabled,
              label: '低架增益',
              sub: '${_bassGain.toStringAsFixed(1)} dB',
              value: _bassGain,
              min: lowfreqBassGainMinDb,
              max: lowfreqBassGainMaxDb,
              divisions: 48,
              onChanged: (v) => setState(() => _draftBassGain = v),
              onChangeEnd: (v) {
                setState(() => _draftBassGain = v);
                notifier.setLowFreq(bassGainDb: v);
                _apply();
              },
            ),
            _bandTile(
              l10n,
              enabled: prefs.lowfreqEnabled,
              label: '低架频率',
              sub: '${_bassFreq.toStringAsFixed(0)} Hz',
              value: _bassFreq,
              min: lowfreqBassFreqMin,
              max: lowfreqBassFreqMax,
              divisions: 46,
              onChanged: (v) => setState(() => _draftBassFreq = v),
              onChangeEnd: (v) {
                setState(() => _draftBassFreq = v);
                notifier.setLowFreq(bassFreq: v);
                _apply();
              },
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

  Widget _peqBandTile(
    AppLocalizations l10n,
    int index,
    ParametricBand band,
    bool enabled,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingTile(
          icon: EtaIcons.columnsOutline,
          title: '频段 ${index + 1}',
          subtitle: _peqKindLabel(band.kind),
          enabled: enabled,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<int>(
                value: band.kind,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: [
                  for (final k in peqKinds)
                    DropdownMenuItem(value: k, child: Text(_peqKindLabel(k))),
                ],
                onChanged: enabled
                    ? (v) {
                        if (v == null) return;
                        _commitPeqBand(index, band.copyWith(kind: v));
                      }
                    : null,
              ),
              const SizedBox(width: 4),
              SButton(
                label: '删除',
                variant: SButtonVariant.secondary,
                size: SButtonSize.small,
                onPressed: () => _removePeqBand(index),
              ),
            ],
          ),
        ),
        _bandTile(
          l10n,
          enabled: enabled,
          label: '频率',
          sub: '${band.freq.toStringAsFixed(0)} Hz',
          value: band.freq,
          min: peqFreqMin,
          max: peqFreqMax,
          divisions: null,
          onChanged: (v) => _draftPeqBand(index, band.copyWith(freq: v)),
          onChangeEnd: (v) => _commitPeqBand(index, band.copyWith(freq: v)),
        ),
        _bandTile(
          l10n,
          enabled: enabled,
          label: 'Q',
          sub: band.q.toStringAsFixed(2),
          value: band.q,
          min: peqQMin,
          max: peqQMax,
          divisions: null,
          onChanged: (v) => _draftPeqBand(index, band.copyWith(q: v)),
          onChangeEnd: (v) => _commitPeqBand(index, band.copyWith(q: v)),
        ),
        _bandTile(
          l10n,
          enabled: enabled,
          label: '增益',
          sub: '${band.gainDb.toStringAsFixed(1)} dB',
          value: band.gainDb,
          min: peqGainMinDb,
          max: peqGainMaxDb,
          divisions: 48,
          onChanged: (v) => _draftPeqBand(index, band.copyWith(gainDb: v)),
          onChangeEnd: (v) => _commitPeqBand(index, band.copyWith(gainDb: v)),
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
    int? divisions = 24,
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
