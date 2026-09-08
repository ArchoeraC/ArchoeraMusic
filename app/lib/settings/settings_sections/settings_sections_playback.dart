// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 播放 ──────────────────────────────────────────────────────────────

/// 播放分类：直通 / 会话记忆 / 关闭行为 / 电源 / 频谱 / 切歌动效 / 快捷键。
class PlaybackSection extends ConsumerStatefulWidget {
  const PlaybackSection({super.key});

  @override
  ConsumerState<PlaybackSection> createState() => _PlaybackSectionState();
}

class _PlaybackSectionState extends ConsumerState<PlaybackSection> {
  bool _engineBusy = false;
  List<_SinkDevice>? _sinks;
  bool _sinksFailed = false;
  bool _sinkBusy = false;
  StreamSubscription<String>? _sinkFailSub;

  @override
  void initState() {
    super.initState();
    _loadSinks();
    _sinkFailSub = ref.read(playbackProvider.notifier).sinkFailures.listen((
      err,
    ) {
      if (!mounted) return;
      toast(context.l10n.settingsSinkChangedFailed(err), type: ToastType.error);
    });
  }

  @override
  void dispose() {
    _sinkFailSub?.cancel();
    _sinkFailSub = null;
    super.dispose();
  }

  Future<void> _loadSinks() async {
    List<_SinkDevice>? sinks;
    var failed = false;
    try {
      final raw = EngineBindings.instance.listSinks();
      sinks = raw == null ? null : _parseSinks(raw);
      if (sinks != null && sinks.isEmpty) sinks = null;
    } catch (_) {
      failed = true;
      sinks = null;
    }
    if (!mounted) return;
    setState(() {
      _sinks = sinks;
      _sinksFailed = failed;
    });
  }

  _SinkDevice? _defaultDevice(List<_SinkDevice> sinks) {
    for (final d in sinks) {
      if (d.isDefault) return d;
    }
    return null;
  }

  _SinkDevice? _sinkById(List<_SinkDevice> sinks, String id) {
    if (id.isEmpty) return _defaultDevice(sinks);
    for (final d in sinks) {
      if (d.id == id) return d;
    }
    return null;
  }

  _SinkDevice? _firstGoodDevice(List<_SinkDevice> sinks) {
    for (final d in sinks) {
      if (d.isGood) return d;
    }
    return null;
  }

  Future<void> _selectSink(String id) async {
    if (_sinkBusy) return;
    if (id == ref.read(appPrefsProvider).sink) return;
    setState(() => _sinkBusy = true);
    try {
      ref.read(appPrefsProvider.notifier).setOutputSink(id);
      await ref.read(playbackProvider.notifier).applyOutputSink(id);
    } finally {
      if (mounted) setState(() => _sinkBusy = false);
    }
  }

  Future<void> _onChooseSink(String id) async {
    if (_sinkBusy) return;
    if (id == ref.read(appPrefsProvider).sink) return;
    final sinks = _sinks ?? const <_SinkDevice>[];
    final target = _sinkById(sinks, id);
    if (target != null && target.isCall) {
      final choice = await _confirmCallSink();
      if (!mounted) return;
      switch (choice) {
        case _CallSinkChoice.useQuality:
          final good = _firstGoodDevice(sinks);
          if (good != null) await _selectSink(good.id);
        case _CallSinkChoice.useCall:
          await _selectSink(id);
        case null:
          break;
      }
      return;
    }
    await _selectSink(id);
  }

  Future<void> _switchToGoodSink() async {
    final sinks = _sinks;
    if (sinks == null) return;
    final good = _firstGoodDevice(sinks);
    if (good != null) await _selectSink(good.id);
  }

  Future<_CallSinkChoice?> _confirmCallSink() {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final hasGood = (_firstGoodDevice(_sinks ?? const <_SinkDevice>[])) != null;
    return SDialog.show<_CallSinkChoice>(
      context,
      title: l10n.settingsOutputDeviceCallConfirmTitle,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(EtaIcons.warning, size: 18, color: scheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.settingsOutputDeviceCallConfirmDesc,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.55,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.ghost,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
        if (hasGood)
          SButton(
            label: l10n.settingsOutputDeviceUseQuality,
            icon: EtaIcons.highQualityOutline,
            variant: SButtonVariant.primary,
            size: SButtonSize.small,
            onPressed: () =>
                Navigator.of(context).pop(_CallSinkChoice.useQuality),
          ),
        SButton(
          label: l10n.settingsOutputDeviceUseCall,
          icon: EtaIcons.phoneCallOutline,
          variant: SButtonVariant.error,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(_CallSinkChoice.useCall),
        ),
      ],
    );
  }

  ({String text, Color color}) _callBadge(
    ColorScheme scheme,
    AppLocalizations l10n,
  ) => (text: l10n.settingsOutputDeviceCallBadge, color: scheme.error);

  List<Widget> _buildSinkRows(
    ColorScheme scheme,
    AppLocalizations l10n,
    AppPrefs prefs,
  ) {
    final rows = <Widget>[];
    final sinks = _sinks ?? const <_SinkDevice>[];
    final defaultDev = _defaultDevice(sinks);
    final neverExplicitAndDefaultCall =
        prefs.sink.isEmpty && defaultDev != null && defaultDev.isCall;
    if (neverExplicitAndDefaultCall) {
      rows.add(
        _SinkDefaultCallBanner(
          onUseQuality: _firstGoodDevice(sinks) == null
              ? null
              : _switchToGoodSink,
        ),
      );
    }
    rows.add(
      _EngineOptionTile(
        icon: EtaIcons.speakerOutline,
        title: l10n.settingsOutputDeviceDefault,
        desc: l10n.settingsOutputDeviceDefaultDesc,
        badges: defaultDev != null && defaultDev.isCall
            ? [_callBadge(scheme, l10n)]
            : const [],
        selected: prefs.sink.isEmpty,
        busy: _sinkBusy,
        onTap: () => _onChooseSink(''),
      ),
    );
    if (defaultDev != null &&
        defaultDev.isCall &&
        !neverExplicitAndDefaultCall) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(EtaIcons.warning, size: 13, color: scheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.settingsOutputDeviceDefaultRowCallNote,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_sinksFailed) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                EtaIcons.alertOutline,
                size: 14,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.settingsOutputDeviceLoadFailed,
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
      );
    }
    final sorted = [...sinks]
      ..sort((a, b) {
        if (a.isCall == b.isCall) return 0;
        return a.isCall ? 1 : -1;
      });
    for (final d in sorted) {
      rows.add(
        _EngineOptionTile(
          icon: d.isCall ? EtaIcons.bluetooth : EtaIcons.speakerOutline,
          title: d.name,
          desc: l10n.settingsOutputDeviceFormat(d.channels, d.rate),
          badges: [
            if (d.isDefault)
              (
                text: l10n.settingsOutputDeviceDefaultTag,
                color: scheme.primary,
              ),
            if (d.isCall) _callBadge(scheme, l10n),
          ],
          selected: prefs.sink == d.id,
          busy: _sinkBusy,
          onTap: () => _onChooseSink(d.id),
        ),
      );
      if (prefs.sink == d.id && d.isCall) {
        rows.add(const _SinkHfpNote());
        rows.add(const _A2dpGuideBlock());
      }
    }
    return rows;
  }

  Future<void> _selectEngine(String engine) async {
    if (_engineBusy || engine == ref.read(appPrefsProvider).engine) return;
    setState(() => _engineBusy = true);
    try {
      ref.read(appPrefsProvider.notifier).setEngine(engine);
      if (!mounted) return;
      if (await _promptRestartAfterEngineChange() && mounted) {
        await _restartApp();
      }
    } finally {
      if (mounted) setState(() => _engineBusy = false);
    }
  }

  Future<bool> _promptRestartAfterEngineChange() async {
    final l10n = context.l10n;
    final res = await SDialog.show<bool>(
      context,
      title: l10n.settingsEngineRestartTitle,
      description: l10n.settingsEngineRestartDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.settingsEngineRestartLater,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsEngineRestartNow,
          icon: EtaIcons.refreshAnticlockwise,
          variant: SButtonVariant.primary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    return res == true;
  }

  Future<void> _restartApp() async {
    try {
      await Process.start(
        Platform.resolvedExecutable,
        Platform.executableArguments,
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      debugPrint('[engine] 重启应用失败（请手动重启）：$e');
    }
    await quitApplication(ref);
  }

  Future<void> _pickMemoryLimitMb(int currentMb) async {
    final ctrl = TextEditingController(text: '$currentMb');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l10n = ctx.l10n;
        return AlertDialog(
          title: Text(l10n.settingsMemoryLimitTitle),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(hintText: l10n.settingsMemoryLimitHint),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.settingsMemoryCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.settingsMemoryConfirm),
            ),
          ],
        );
      },
    );
    final v = int.tryParse(ctrl.text.trim());
    if (ok == true && v != null && v >= 1) {
      ref.read(appPrefsProvider.notifier).setEngineMemory(
            policy: 'limit',
            limitMb: v.clamp(1, 1 << 18).toInt(),
          );
    }
  }

  /// 选择「无上限」：先弹显式内存过载警告，确认后才生效。
  Future<void> _pickMemoryUnlimited() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l10n = ctx.l10n;
        return AlertDialog(
          title: Text(l10n.settingsMemoryUnlimitedWarnTitle),
          content: Text(l10n.settingsMemoryUnlimitedWarnBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.settingsMemoryCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.settingsMemoryConfirm),
            ),
          ],
        );
      },
    );
    if (ok == true) {
      ref.read(appPrefsProvider.notifier).setEngineMemory(policy: 'unlimited');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSectionAudio,
          children: [
            SettingSwitchTile(
              icon: prefs.passthrough
                  ? EtaIcons.highQualityOutline
                  : EtaIcons.transfer,
              title: l10n.settingsPassthrough,
              subtitle: prefs.passthrough
                  ? l10n.settingsPassthroughOn
                  : l10n.settingsPassthroughOff,
              value: prefs.passthrough,
              onChanged: (value) {
                ref.read(appPrefsProvider.notifier).setPassthrough(value);
                ref.read(playbackProvider.notifier).reload();
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsOutputDevice,
          note: l10n.settingsOutputDeviceSectionNote,
          children: _buildSinkRows(scheme, l10n, prefs),
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsEngine,
          note: l10n.settingsEngineNote,
          children: [
            _EngineOptionTile(
              icon: EtaIcons.stopwatchOutline,
              title: 'Stable',
              desc: l10n.settingsEngineStableDesc,
              selected: prefs.engine == 'stable',
              busy: _engineBusy,
              onTap: () => _selectEngine('stable'),
            ),
            _EngineOptionTile(
              icon: EtaIcons.flaskOutline,
              title: 'EraAudio',
              desc: l10n.settingsEngineEraAudioDesc,
              badges: [
                (text: l10n.settingsEngineExperimental, color: scheme.error),
              ],
              selected: prefs.engine == 'eraudio',
              busy: _engineBusy,
              onTap: () => _selectEngine('eraudio'),
            ),
            if (prefs.engine == 'eraudio')
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(EtaIcons.asterisk, size: 14, color: scheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        l10n.settingsEngineEraAudioNote,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.4,
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsMemoryPlaySection,
          note: prefs.engineMemoryPlay
              ? null
              : l10n.settingsMemoryFileModeNote,
          children: [
            SettingSwitchTile(
              icon: EtaIcons.chipOutline,
              title: l10n.settingsMemoryPlayTitle,
              subtitle: prefs.engineMemoryPlay
                  ? l10n.settingsMemoryPlayOn
                  : l10n.settingsMemoryPlayOff,
              value: prefs.engineMemoryPlay,
              onChanged: (value) => ref
                  .read(appPrefsProvider.notifier)
                  .setEngineMemory(enabled: value),
            ),
            if (prefs.engineMemoryPlay) ...[
              _MemoryPolicyTile(
                label: l10n.settingsMemoryPolicyAuto,
                subtitle: l10n.settingsMemoryPolicyAutoSub,
                selected: prefs.pcmMemPolicy == 'auto',
                onTap: () =>
                    ref.read(appPrefsProvider.notifier).setEngineMemory(policy: 'auto'),
              ),
              _MemoryPolicyTile(
                label: l10n.settingsMemoryPolicyLimit,
                subtitle: '${prefs.pcmMemLimitMb} MB · '
                    '${l10n.settingsMemoryLimitHint}',
                selected: prefs.pcmMemPolicy == 'limit',
                onTap: () => _pickMemoryLimitMb(prefs.pcmMemLimitMb),
              ),
              _MemoryPolicyTile(
                label: l10n.settingsMemoryPolicyUnlimited,
                subtitle: l10n.settingsMemoryPolicyUnlimitedSub,
                selected: prefs.pcmMemPolicy == 'unlimited',
                onTap: _pickMemoryUnlimited,
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionMemory,
          children: [
            SettingSwitchTile(
              icon: prefs.sessionMemory
                  ? EtaIcons.history
                  : EtaIcons.history,
              title: l10n.settingsSessionMemory,
              subtitle: prefs.sessionMemory
                  ? l10n.settingsSessionMemoryOn
                  : l10n.settingsSessionMemoryOff,
              value: prefs.sessionMemory,
              onChanged: (value) =>
                  ref.read(appPrefsProvider.notifier).setMemoryEnabled(value),
            ),
            SettingSwitchTile(
              icon: prefs.autoPlayOnLaunch
                  ? EtaIcons.playCircleOutline
                  : EtaIcons.pauseCircleOutline,
              title: l10n.settingsAutoPlay,
              subtitle: !prefs.sessionMemory
                  ? l10n.settingsAutoPlayNeedMemory
                  : prefs.autoPlayOnLaunch
                  ? l10n.settingsAutoPlayOn
                  : l10n.settingsAutoPlayOff,
              value: prefs.sessionMemory && prefs.autoPlayOnLaunch,
              onChanged: prefs.sessionMemory
                  ? (value) => ref
                        .read(appPrefsProvider.notifier)
                        .setAutoPlayOnLaunch(value)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionClose,
          children: [
            SettingTile(
              icon: EtaIcons.powerOutline,
              title: l10n.settingsCloseBehavior,
              subtitle: switch (prefs.closeBehavior) {
                'background' => l10n.settingsCloseBehaviorBackground,
                'quit' => l10n.settingsCloseBehaviorQuit,
                _ => l10n.settingsCloseBehaviorAsk,
              },
              trailing: DropdownButton<String>(
                value: prefs.closeBehavior,
                isDense: true,
                underline: const SizedBox.shrink(),
                borderRadius: BorderRadius.circular(10),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                icon: Icon(
                  EtaIcons.downSmall,
                  color: scheme.onSurfaceVariant,
                ),
                onChanged: (v) {
                  if (v == null) return;
                  ref.read(appPrefsProvider.notifier).setCloseBehavior(v);
                },
                items: [
                  DropdownMenuItem(
                    value: 'ask',
                    child: Text(l10n.settingsCloseBehaviorAsk),
                  ),
                  DropdownMenuItem(
                    value: 'background',
                    child: Text(l10n.settingsCloseBehaviorBackground),
                  ),
                  DropdownMenuItem(
                    value: 'quit',
                    child: Text(l10n.settingsCloseBehaviorQuit),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionPower,
          children: [
            SettingSwitchTile(
              icon: prefs.powerSaver
                  ? EtaIcons.leaf
                  : EtaIcons.leafOutline,
              title: l10n.settingsPowerSaver,
              subtitle: prefs.powerSaver
                  ? l10n.settingsPowerSaverOn
                  : l10n.settingsPowerSaverOff,
              value: prefs.powerSaver,
              onChanged: (value) =>
                  ref.read(appPrefsProvider.notifier).setPowerSaver(value),
            ),
            SettingSwitchTile(
              icon: prefs.suppressSleep
                  ? EtaIcons.bedtimeOffOutline
                  : EtaIcons.moonStarsOutline,
              title: l10n.settingsSuppressSleep,
              subtitle: prefs.suppressSleep
                  ? l10n.settingsSuppressSleepOn
                  : l10n.settingsSuppressSleepOff,
              value: prefs.suppressSleep,
              onChanged: (value) =>
                  ref.read(appPrefsProvider.notifier).setSuppressSleep(value),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionSpectrum,
          children: [
            SettingSwitchTile(
              icon: prefs.enableSpectrum
                  ? EtaIcons.soundLine
                  : EtaIcons.soundLineOutline,
              title: l10n.settingsSpectrum,
              subtitle: prefs.enableSpectrum
                  ? l10n.settingsSpectrumOn
                  : l10n.settingsSpectrumOff,
              value: prefs.enableSpectrum,
              onChanged: (value) =>
                  ref.read(appPrefsProvider.notifier).setSpectrumEnabled(value),
            ),
            SettingSwitchTile(
              icon: prefs.coverBeatScale
                  ? EtaIcons.music
                  : EtaIcons.musicOutline,
              title: l10n.settingsCoverBeatScale,
              subtitle: prefs.coverBeatScale
                  ? l10n.settingsCoverBeatScaleOn
                  : l10n.settingsCoverBeatScaleOff,
              value: prefs.coverBeatScale,
              onChanged: (value) =>
                  ref.read(appPrefsProvider.notifier).setCoverBeatScale(value),
            ),
            SettingSliderTile(
              icon: EtaIcons.columnsOutline,
              title: l10n.settingsSpectrumBarWidth,
              subtitle: l10n.settingsSpectrumBarWidthDesc(
                prefs.spectrumBarWidth,
              ),
              value: prefs.spectrumBarWidth.toDouble(),
              min: 1,
              max: 12,
              divisions: 11,
              label: '${prefs.spectrumBarWidth}px',
              onChanged: (v) => ref
                  .read(appPrefsProvider.notifier)
                  .setSpectrumBarWidth(v.round()),
            ),
            SettingTile(
              icon: EtaIcons.soundLineOutline,
              title: l10n.settingsSpectrumStyle,
              subtitle: l10n.settingsSpectrumStyleDesc,
              trailing: SSegmented<String>(
                options: [
                  SSegmentedOption('bars', l10n.settingsSpectrumStyleBars),
                  SSegmentedOption('wave', l10n.settingsSpectrumStyleWave),
                  SSegmentedOption('waveUp', l10n.settingsSpectrumStyleWaveUp),
                ],
                selected: prefs.spectrumStyle,
                onChanged: (v) =>
                    ref.read(appPrefsProvider.notifier).setSpectrumStyle(v),
              ),
            ),
            SettingSwitchTile(
              icon: prefs.barSpectrum
                  ? EtaIcons.chartBar
                  : EtaIcons.chartBarOutline,
              title: l10n.settingsBarSpectrum,
              subtitle: prefs.barSpectrum
                  ? l10n.settingsBarSpectrumOn
                  : l10n.settingsBarSpectrumOff,
              value: prefs.barSpectrum,
              onChanged: (value) => ref
                  .read(appPrefsProvider.notifier)
                  .setBarDisplay(barSpectrum: value),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsTransitionStyle,
          children: [
            SettingTile(
              icon: EtaIcons.magic2Outline,
              title: l10n.settingsTransitionStyle,
              subtitle: l10n.settingsTransitionStyleDesc,
              trailing: SSegmented<String>(
                options: [
                  SSegmentedOption('scale', l10n.settingsTransitionStyleScale),
                  SSegmentedOption('slide', l10n.settingsTransitionStyleSlide),
                ],
                selected: prefs.transitionStyle,
                onChanged: (v) =>
                    ref.read(appPrefsProvider.notifier).setTransitionStyle(v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionShortcuts,
          children: [
            SettingTile(
              icon: EtaIcons.space,
              title: l10n.settingsShortcutSpace,
              subtitle: l10n.settingsShortcutSpaceDesc,
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: EtaIcons.transferHorizontal,
              title: l10n.settingsShortcutArrows,
              subtitle: l10n.settingsShortcutArrowsDesc,
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: EtaIcons.search2,
              title: l10n.settingsShortcutSearch,
              subtitle: l10n.commonSearch,
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: EtaIcons.music2Outline,
              title: l10n.settingsShortcutLibrary,
              subtitle: l10n.settingsShortcutLibraryDesc,
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: EtaIcons.cornerDownLeft,
              title: l10n.settingsShortcutEsc,
              subtitle: l10n.settingsShortcutEscDesc,
              trailing: const SizedBox.shrink(),
            ),
          ],
        ),
      ],
    );
  }
}

class _EngineOptionTile extends StatelessWidget {
  const _EngineOptionTile({
    required this.icon,
    required this.title,
    required this.desc,
    required this.selected,
    required this.busy,
    required this.onTap,
    this.badges = const [],
  });

  final IconData icon;
  final String title;
  final String desc;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;
  final List<({String text, Color color})> badges;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.primary : scheme.onSurface;
    final textFg = busy
        ? scheme.onSurface.withValues(alpha: 0.38)
        : scheme.onSurface;
    final subFg = busy
        ? scheme.onSurfaceVariant.withValues(alpha: 0.35)
        : scheme.onSurfaceVariant.withValues(alpha: 0.75);
    return MouseRegion(
      cursor: busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 18, color: fg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: textFg,
                            ),
                          ),
                        ),
                        for (var i = 0; i < badges.length; i++) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: badges[i].color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              badges[i].text,
                              style: TextStyle(
                                fontSize: 9.5,
                                color: badges[i].color,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: subFg),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                selected ? EtaIcons.dotCircle : EtaIcons.circleDash,
                size: 19,
                color: selected
                    ? scheme.primary
                    : busy
                    ? scheme.outlineVariant.withValues(alpha: 0.6)
                    : scheme.outlineVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SinkDefaultCallBanner extends StatelessWidget {
  const _SinkDefaultCallBanner({this.onUseQuality});

  final VoidCallback? onUseQuality;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final action = onUseQuality;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  EtaIcons.warning,
                  size: 18,
                  color: scheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.settingsOutputDeviceDefaultIsCall,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            if (action != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: SButton(
                  label: l10n.settingsOutputDeviceUseQuality,
                  icon: EtaIcons.highQualityOutline,
                  variant: SButtonVariant.primary,
                  size: SButtonSize.small,
                  onPressed: action,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SinkHfpNote extends StatelessWidget {
  const _SinkHfpNote();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(EtaIcons.warning, size: 14, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l10n.settingsOutputDeviceHfpNote,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _A2dpGuideBlock extends StatefulWidget {
  const _A2dpGuideBlock();

  @override
  State<_A2dpGuideBlock> createState() => _A2dpGuideBlockState();
}

class _A2dpGuideBlockState extends State<_A2dpGuideBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
            child: Row(
              children: [
                Icon(EtaIcons.bluetooth, size: 14, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.settingsOutputDeviceA2dpGuideTitle,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(
                    EtaIcons.downSmall,
                    size: 16,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Text(
              l10n.settingsOutputDeviceA2dpGuideDesc,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
      ],
    );
  }
}

/// PCM 内存保留策略选择行（radio-like；selected 高亮）。
class _MemoryPolicyTile extends StatelessWidget {
  const _MemoryPolicyTile({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    final textFg = scheme.onSurface;
    final subFg = scheme.onSurfaceVariant.withValues(alpha: 0.75);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(
              selected ? EtaIcons.checkCircle : EtaIcons.checkCircleOutline,
              size: 18,
              color: fg,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: textFg,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        style: TextStyle(fontSize: 11.5, color: subFg),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
