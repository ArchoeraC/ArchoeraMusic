// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// ArchoeraOS 安装向导（Live 介质上的独立全屏应用）。
///
/// 启动路径：Live 的会话脚本在检测到 `/run/archoera-install/request` 后，以
/// `ARCHOERA_MODE=installer` 启动**同一个** Flutter 二进制；`main` 据此只跑本
/// 向导，不初始化播放器栈（凭据保险库 / 音频引擎 / 托盘都不需要）。
///
/// 步骤：语言 → 时区 → 键盘 → 磁盘 → 加密 → 用户 → 摘要 → 进度 → 完成。
/// 所有系统操作都走桥接（`apl_live_*` 写计划并启动安装单元、`apl_os_*` 重启/
/// 关机），Dart 侧不跑子进程。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/platform/os_session.dart';
import '../../services/platform/platform_capabilities.dart';
import '../../services/platform/live_install.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common/touch_keyboard/touch_keyboard.dart';
import 'installer_draft.dart';
import 'installer_options.dart';

/// 安装向导应用根（自带主题与语言环境；与播放器互不干扰）。
class InstallerApp extends StatefulWidget {
  const InstallerApp({super.key});

  @override
  State<InstallerApp> createState() => _InstallerAppState();
}

class _InstallerAppState extends State<InstallerApp> {
  /// 向导界面语言（null = 跟随系统）；语言步骤选中后立即生效。
  Locale? _locale;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: _locale,
      theme: buildAppTheme(AppPalette.light, Brightness.light),
      darkTheme: buildAppTheme(AppPalette.dark, Brightness.dark),
      themeMode: ThemeMode.dark,
      home: TouchKeyboardHost(
        child: InstallerWizard(
          onLocaleChanged: (locale) => setState(() => _locale = locale),
        ),
      ),
    );
  }
}

/// 向导主体：持有草稿、当前步骤与进度轮询。
class InstallerWizard extends ConsumerStatefulWidget {
  const InstallerWizard({super.key, this.onLocaleChanged});

  final ValueChanged<Locale>? onLocaleChanged;

  @override
  ConsumerState<InstallerWizard> createState() => _InstallerWizardState();
}

class _InstallerWizardState extends ConsumerState<InstallerWizard> {
  late final InstallerDraft _draft;
  InstallerStep _step = InstallerStep.language;
  LiveInstallStatus _status = const LiveInstallStatus();
  List<LiveDisk> _disks = const <LiveDisk>[];
  Timer? _poll;
  bool _starting = false;

  LiveInstallService get _live => ref.read(liveInstallProvider);

  @override
  void initState() {
    super.initState();
    // 默认语言跟随当前界面语言（Live 上通常是 en/zh）。
    final current = WidgetsBinding.instance.platformDispatcher.locale;
    InstallerLanguage? match;
    for (final l in installerLanguages) {
      final ui = l.uiLocale.split('_').first;
      if (l.uiLocale == current.toString() || ui == current.languageCode) {
        match = l;
        break;
      }
    }
    _draft = InstallerDraft(language: match);
    _disks = ref.read(liveInstallProvider).disks();
    // 初始界面语言要等本帧结束再通知父级：initState 里调用会触发
    // 「setState() called during build」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onLocaleChanged?.call(_localeOf(_draft.language));
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Locale _localeOf(InstallerLanguage language) {
    final parts = language.uiLocale.split('_');
    return parts.length > 1 ? Locale(parts[0], parts[1]) : Locale(parts[0]);
  }

  void _go(InstallerStep step) {
    setState(() {
      _draft.normalize();
      _step = step;
    });
  }

  void _next() {
    final i = InstallerStep.values.indexOf(_step);
    if (i >= InstallerStep.values.length - 1) return;
    _go(InstallerStep.values[i + 1]);
  }

  void _back() {
    final i = InstallerStep.values.indexOf(_step);
    if (i <= 0) return;
    _go(InstallerStep.values[i - 1]);
  }

  /// 提交计划并开始安装（进入进度步骤后轮询）。
  Future<void> _start() async {
    final plan = _draft.toPlan();
    setState(() {
      _starting = true;
      _step = InstallerStep.progress;
      _status = const LiveInstallStatus(running: true, percent: 0);
    });
    final ok = _live.start(plan);
    if (!mounted) return;
    setState(() => _starting = false);
    if (!ok) {
      setState(
        () => _status = const LiveInstallStatus(failed: true, percent: -1),
      );
      return;
    }
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 800), (_) async {
      final status = _live.status();
      if (!mounted) return;
      setState(() => _status = status);
      if (status.done) {
        _poll?.cancel();
        setState(() => _step = InstallerStep.done);
      } else if (status.failed) {
        _poll?.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final showNav =
        _step != InstallerStep.progress && _step != InstallerStep.done;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF10131A), Color(0xFF1A2130)],
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(step: _step),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
                  child: _buildStep(l10n),
                ),
              ),
              if (showNav)
                _NavBar(
                  l10n: l10n,
                  step: _step,
                  canNext: _canAdvance(l10n),
                  onBack: _step == InstallerStep.language ? null : _back,
                  onNext: _step == InstallerStep.summary
                      ? (_draft.canStart ? () => unawaited(_start()) : null)
                      : _next,
                  starting: _starting,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 各步骤「下一步」是否可用（校验集中在草稿里）。
  bool _canAdvance(AppLocalizations l10n) {
    switch (_step) {
      case InstallerStep.disk:
        return _draft.disk != null;
      case InstallerStep.encryption:
        return _draft.passphraseError(
              tooShort: l10n.installerPassphraseTooShort,
              mismatch: l10n.installerPassphraseMismatch,
            ) ==
            null;
      case InstallerStep.user:
        return _draft.nameError(
                  _draft.username,
                  invalid: l10n.installerInvalidName,
                ) ==
                null &&
            _draft.nameError(
                  _draft.hostname,
                  invalid: l10n.installerInvalidName,
                ) ==
                null;
      case InstallerStep.summary:
        return _draft.canStart;
      default:
        return true;
    }
  }

  Widget _buildStep(AppLocalizations l10n) {
    switch (_step) {
      case InstallerStep.language:
        return _LanguageStep(
          selected: _draft.language,
          onSelected: (value) {
            setState(() => _draft.language = value);
            widget.onLocaleChanged?.call(_localeOf(value));
          },
        );
      case InstallerStep.timezone:
        return _TimezoneStep(
          selected: _draft.timezone,
          onSelected: (value) => setState(() => _draft.timezone = value),
        );
      case InstallerStep.keyboard:
        return _KeyboardStep(
          selected: _draft.keymap,
          onSelected: (value) => setState(() => _draft.keymap = value),
        );
      case InstallerStep.disk:
        return _DiskStep(
          draft: _draft,
          disks: _disks,
          onChanged: () => setState(() {}),
        );
      case InstallerStep.encryption:
        return _EncryptionStep(draft: _draft, onChanged: () => setState(() {}));
      case InstallerStep.user:
        return _UserStep(draft: _draft, onChanged: () => setState(() {}));
      case InstallerStep.summary:
        return _SummaryStep(draft: _draft);
      case InstallerStep.progress:
        return _ProgressStep(
          status: _status,
          onRetry: () => unawaited(_start()),
        );
      case InstallerStep.done:
        return const _DoneStep();
    }
  }
}

// ── 框架外观 ──────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.step});

  final InstallerStep step;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final steps = InstallerStep.values
        .where((s) => s != InstallerStep.progress && s != InstallerStep.done)
        .toList();
    final index = steps.indexOf(step);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.installerTitle,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${index < 0 ? steps.length : index + 1} / ${steps.length}',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white70.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: index < 0 ? 1 : (index + 1) / steps.length,
              minHeight: 4,
              backgroundColor: Colors.white12,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _stepTitle(l10n, step),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  static String _stepTitle(AppLocalizations l10n, InstallerStep step) =>
      switch (step) {
        InstallerStep.language => l10n.installerStepLanguage,
        InstallerStep.timezone => l10n.installerStepTimezone,
        InstallerStep.keyboard => l10n.installerStepKeyboard,
        InstallerStep.disk => l10n.installerStepDisk,
        InstallerStep.encryption => l10n.installerStepEncryption,
        InstallerStep.user => l10n.installerStepUser,
        InstallerStep.summary => l10n.installerStepSummary,
        InstallerStep.progress => l10n.installerStepProgress,
        InstallerStep.done => l10n.installerStepDone,
      };
}

class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.l10n,
    required this.step,
    required this.canNext,
    required this.onBack,
    required this.onNext,
    required this.starting,
  });

  final AppLocalizations l10n;
  final InstallerStep step;
  final bool canNext;
  final VoidCallback? onBack;
  final VoidCallback? onNext;
  final bool starting;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 6, 28, 20),
      child: Row(
        children: [
          if (onBack != null)
            TextButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back, size: 18),
              label: Text(l10n.installerBack),
            ),
          const Spacer(),
          FilledButton.icon(
            onPressed: canNext && !starting ? onNext : null,
            icon: starting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_forward, size: 18),
            label: Text(
              step == InstallerStep.summary
                  ? l10n.installerStart
                  : l10n.installerNext,
            ),
          ),
        ],
      ),
    );
  }
}

// ── 步骤：语言 / 时区 / 键盘 ──────────────────────────────────────────

class _LanguageStep extends StatelessWidget {
  const _LanguageStep({required this.selected, required this.onSelected});

  final InstallerLanguage selected;
  final ValueChanged<InstallerLanguage> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final language in installerLanguages)
          _ChoiceTile(
            title: language.label,
            subtitle: '${language.detail} · ${language.locale}',
            selected: language.locale == selected.locale,
            onTap: () => onSelected(language),
          ),
      ],
    );
  }
}

class _TimezoneStep extends StatefulWidget {
  const _TimezoneStep({required this.selected, required this.onSelected});

  final String selected;
  final ValueChanged<String> onSelected;

  @override
  State<_TimezoneStep> createState() => _TimezoneStepState();
}

class _TimezoneStepState extends State<_TimezoneStep> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final q = _query.text.trim().toLowerCase();
    final groups = <String, List<String>>{};
    installerTimezones.forEach((region, zones) {
      final hits = q.isEmpty
          ? zones
          : zones.where((z) => z.toLowerCase().contains(q)).toList();
      if (hits.isNotEmpty) groups[region] = hits;
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SearchField(
          controller: _query,
          hint: l10n.installerSearchHint,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        if (groups.isEmpty)
          _Hint(l10n.installerSearchEmpty)
        else
          for (final entry in groups.entries) ...[
            _GroupLabel(entry.key),
            for (final zone in entry.value)
              _ChoiceTile(
                title: zone,
                selected: zone == widget.selected,
                onTap: () => widget.onSelected(zone),
              ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _KeyboardStep extends StatelessWidget {
  const _KeyboardStep({required this.selected, required this.onSelected});

  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final keymap in installerKeymaps)
          _ChoiceTile(
            title: keymap.label,
            subtitle: keymap.name,
            selected: keymap.name == selected,
            onTap: () => onSelected(keymap.name),
          ),
      ],
    );
  }
}

// ── 步骤：磁盘 / 加密 / 用户 / 摘要 ───────────────────────────────────

class _DiskStep extends StatelessWidget {
  const _DiskStep({
    required this.draft,
    required this.disks,
    required this.onChanged,
  });

  final InstallerDraft draft;
  final List<LiveDisk> disks;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final disk in disks)
          _ChoiceTile(
            title: disk.model.isEmpty
                ? disk.device
                : '${disk.device} · ${disk.model}',
            subtitle: [
              disk.sizeLabel,
              if (disk.transport.isNotEmpty) disk.transport,
              if (disk.isLive) l10n.installerDiskLive,
            ].join(' · '),
            selected: draft.disk == disk.device,
            enabled: !disk.isLive,
            onTap: () {
              draft.disk = disk.device;
              onChanged();
            },
          ),
        if (disks.every((d) => d.isLive)) _Hint(l10n.installerDiskNone),
        const SizedBox(height: 18),
        _GroupLabel(l10n.installerFilesystem),
        Wrap(
          spacing: 8,
          children: [
            for (final fs in installerFilesystems)
              ChoiceChip(
                label: Text(fs),
                selected: draft.fs == fs,
                onSelected: (_) {
                  draft.fs = fs;
                  if (fs == 'btrfs') draft.swap = 'none';
                  onChanged();
                },
              ),
          ],
        ),
        if (draft.fs == 'btrfs') _Hint(l10n.installerBtrfsNote),
        const SizedBox(height: 14),
        _GroupLabel(l10n.installerSwap),
        Wrap(
          spacing: 8,
          children: [
            for (final swap in installerSwaps)
              ChoiceChip(
                label: Text(
                  swap == 'none'
                      ? l10n.installerSwapNone
                      : l10n.installerSwapFile,
                ),
                // btrfs 上安装器不支持交换文件。
                onSelected: draft.fs == 'btrfs' && swap == 'file'
                    ? null
                    : (_) {
                        draft.swap = swap;
                        onChanged();
                      },
                selected: draft.swap == swap,
              ),
          ],
        ),
        const SizedBox(height: 18),
        _Warning(text: l10n.installerDiskWarning),
      ],
    );
  }
}

class _EncryptionStep extends StatelessWidget {
  const _EncryptionStep({required this.draft, required this.onChanged});

  final InstallerDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final error = draft.passphraseError(
      tooShort: l10n.installerPassphraseTooShort,
      mismatch: l10n.installerPassphraseMismatch,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          value: draft.encrypt,
          onChanged: (v) {
            draft.encrypt = v;
            onChanged();
          },
          title: Text(l10n.installerEncryptTitle),
          subtitle: Text(l10n.installerEncryptHint),
        ),
        if (draft.encrypt) ...[
          const SizedBox(height: 14),
          // 输入即让父级重建：口令长度/一致性会直接影响「下一步」是否可用。
          _Field(
            label: l10n.installerLuksPassphrase,
            initial: draft.luksPassphrase,
            obscure: true,
            onChanged: (v) {
              draft.luksPassphrase = v;
              onChanged();
            },
          ),
          _Field(
            label: l10n.installerLuksConfirm,
            initial: draft.luksConfirm,
            obscure: true,
            error: error,
            onChanged: (v) {
              draft.luksConfirm = v;
              onChanged();
            },
          ),
          _Warning(text: l10n.installerEncryptWarning),
        ],
      ],
    );
  }
}

class _UserStep extends StatelessWidget {
  const _UserStep({required this.draft, required this.onChanged});

  final InstallerDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Field(
          label: l10n.installerUsername,
          initial: draft.username,
          error: draft.nameError(
            draft.username,
            invalid: l10n.installerInvalidName,
          ),
          onChanged: (v) {
            draft.username = v;
            onChanged();
          },
        ),
        _Field(
          label: l10n.installerHostname,
          initial: draft.hostname,
          error: draft.nameError(
            draft.hostname,
            invalid: l10n.installerInvalidName,
          ),
          onChanged: (v) {
            draft.hostname = v;
            onChanged();
          },
        ),
        _Field(
          label: l10n.installerUserPassword,
          initial: draft.userPassword,
          obscure: true,
          hint: l10n.installerPasswordOptional,
          onChanged: (v) => draft.userPassword = v,
        ),
        _Field(
          label: l10n.installerRootPassword,
          initial: draft.rootPassword,
          obscure: true,
          hint: l10n.installerPasswordOptional,
          onChanged: (v) => draft.rootPassword = v,
        ),
        SwitchListTile(
          value: draft.autologin,
          onChanged: (v) {
            draft.autologin = v;
            onChanged();
          },
          title: Text(l10n.installerAutologin),
          subtitle: Text(l10n.installerAutologinHint),
        ),
      ],
    );
  }
}

class _SummaryStep extends StatelessWidget {
  const _SummaryStep({required this.draft});

  final InstallerDraft draft;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rows = <(String, String)>[
      (l10n.installerStepLanguage, draft.language.label),
      (l10n.installerStepTimezone, draft.timezone),
      (l10n.installerStepKeyboard, draft.keymap),
      (l10n.installerStepDisk, draft.disk ?? l10n.installerDiskNone),
      (l10n.installerFilesystem, draft.fs),
      (
        l10n.installerSwap,
        draft.swap == 'none' ? l10n.installerSwapNone : l10n.installerSwapFile,
      ),
      (
        l10n.installerStepEncryption,
        draft.encrypt ? l10n.installerEncryptOn : l10n.installerEncryptOff,
      ),
      (l10n.installerUsername, draft.username),
      (l10n.installerHostname, draft.hostname),
      (
        l10n.installerAutologin,
        draft.autologin ? l10n.installerEnabled : l10n.installerDisabled,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Warning(text: l10n.installerSummaryEraseWarning),
        const SizedBox(height: 14),
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 160,
                  child: Text(
                    label,
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                ),
                Expanded(
                  child: Text(
                    value,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ── 步骤：进度 / 完成 ─────────────────────────────────────────────────

class _ProgressStep extends StatelessWidget {
  const _ProgressStep({required this.status, required this.onRetry});

  final LiveInstallStatus status;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final value = status.percent >= 0 ? status.percent / 100 : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(value: value, minHeight: 8),
        ),
        const SizedBox(height: 16),
        Text(
          status.failed
              ? l10n.installerProgressFailed
              : (status.message.isEmpty
                    ? l10n.installerProgressPreparing
                    : status.message),
          style: const TextStyle(fontSize: 14, color: Colors.white),
        ),
        const SizedBox(height: 6),
        Text(
          status.percent >= 0 ? '${status.percent}%' : '',
          style: const TextStyle(fontSize: 12, color: Colors.white54),
        ),
        if (status.failed) ...[
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(l10n.installerProgressRetry),
            ),
          ),
        ],
      ],
    );
  }
}

class _DoneStep extends ConsumerWidget {
  const _DoneStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final os = ref.watch(osSessionControllerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const Icon(Icons.check_circle, size: 56, color: Color(0xFF6EE7A8)),
        const SizedBox(height: 16),
        Text(
          l10n.installerDoneBody,
          style: const TextStyle(fontSize: 14, color: Colors.white),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            FilledButton.icon(
              onPressed: () => os.reboot(),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: Text(l10n.installerRebootNow),
            ),
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: () => os.powerOff(),
              icon: const Icon(Icons.power_settings_new, size: 18),
              label: Text(l10n.installerPowerOffNow),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _Hint(l10n.installerDoneHint),
      ],
    );
  }
}

// ── 小组件 ────────────────────────────────────────────────────────────

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.18)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: enabled
                      ? (selected ? scheme.primary : Colors.white38)
                      : Colors.white24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: enabled ? Colors.white : Colors.white38,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: enabled ? Colors.white60 : Colors.white24,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 14, color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
        prefixIcon: const Icon(Icons.search, size: 18, color: Colors.white38),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.initial,
    required this.onChanged,
    this.obscure = false,
    this.hint,
    this.error,
  });

  final String label;
  final String initial;
  final ValueChanged<String> onChanged;
  final bool obscure;
  final String? hint;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        initialValue: initial,
        obscureText: obscure,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 14, color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white60, fontSize: 12.5),
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
          errorText: error,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: Colors.white60,
      ),
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12.5, color: Colors.white60),
    ),
  );
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: const Color(0xFFEF5350).withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFEF5350).withValues(alpha: 0.4)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.warning_amber_rounded,
          size: 18,
          color: Color(0xFFEF9A9A),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFFFFCDD2)),
          ),
        ),
      ],
    ),
  );
}
