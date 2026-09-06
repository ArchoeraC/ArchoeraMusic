// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../security_section.dart';

extension _SecuritySectionActions on _SecuritySectionState {
  Future<void> _revokeNetease() async {
    try {
      await ref.read(neteaseApiProvider).logout();
    } catch (_) {
      try {
        nmClearNeteaseCookies();
      } catch (_) {}
    }
  }

  Future<void> _revokeAll() async {
    await _revokeNetease();
    ref.read(kugouApiProvider).clearSession();
    ref.read(neteaseAuthProvider.notifier).clear();
    await ref.read(streamingProvider.notifier).clearAll();
  }

  Future<bool?> _confirmShred(BuildContext context, String title, String desc) {
    final l10n = context.l10n;
    final word = l10n.settingsSecurityConfirmWord;
    return SDialog.show<bool>(
      context,
      title: title,
      description: desc,
      child: _WordConfirmField(
        word: word,
        hint: l10n.settingsSecurityConfirmHint(word),
        cancelLabel: l10n.commonCancel,
        confirmLabel: l10n.settingsSecurityDestroy,
      ),
    );
  }

  Future<void> _destroyStreaming() async {
    final l10n = context.l10n;
    final ok = await _confirmShred(
      context,
      l10n.settingsSecurityConfirmTitle(l10n.settingsSecurityStreaming),
      l10n.settingsSecurityConfirmDesc(l10n.settingsSecurityConfirmWord),
    );
    if (ok != true || !context.mounted) return;
    await ref.read(streamingProvider.notifier).clearAll();
    final r = destroySensitiveFiles([streamingServersPath()]);
    _afterDestroyed(l10n.settingsSecurityStreaming, r);
  }

  Future<void> _destroySession() async {
    final l10n = context.l10n;
    final ok = await _confirmShred(
      context,
      l10n.settingsSecurityConfirmTitle(l10n.settingsSecuritySession),
      l10n.settingsSecurityConfirmDesc(l10n.settingsSecurityConfirmWord),
    );
    if (ok != true || !context.mounted) return;
    await _revokeAll();
    try {
      VaultProcess.destroy(resolveDataDir());
    } catch (_) {}
    final r = destroySensitiveFiles([vaultFilePath(), sessionStorePath()]);
    _afterDestroyed(l10n.settingsSecuritySession, r);
  }

  Future<void> _destroyBrokenVault() async {
    await _destroySession();
    if (!mounted) return;
    await _restartApp();
  }

  Future<void> _destroyUserDb() async {
    final l10n = context.l10n;
    final ok = await _confirmShred(
      context,
      l10n.settingsSecurityConfirmTitle(l10n.settingsSecurityUserDb),
      l10n.settingsSecurityConfirmDesc(l10n.settingsSecurityConfirmWord),
    );
    if (ok != true || !context.mounted) return;
    final r = destroySensitiveFiles(sqliteFilePaths(userDbPath()));
    _afterDestroyed(l10n.settingsSecurityUserDb, r);
  }

  Future<void> _destroyAll() async {
    final l10n = context.l10n;
    final ok = await _confirmShred(
      context,
      l10n.settingsSecurityConfirmAllTitle,
      l10n.settingsSecurityConfirmDesc(l10n.settingsSecurityConfirmWord),
    );
    if (ok != true || !context.mounted) return;
    await _revokeAll();
    try {
      VaultProcess.destroy(resolveDataDir());
    } catch (_) {}
    final r = destroySensitiveFiles([
      streamingServersPath(),
      vaultFilePath(),
      sessionStorePath(),
      ...sqliteFilePaths(userDbPath()),
    ]);
    _afterDestroyed(null, r);
  }

  void _afterDestroyed(String? name, List<ShredResult> results) {
    _refresh();
    final failed = results
        .where((r) => r.existed && !r.shredded)
        .map((r) => r.path);
    if (!mounted) return;
    final l10n = context.l10n;
    if (failed.isNotEmpty) {
      toast(
        l10n.toastSecurityDestroyFailed(failed.join(', ')),
        type: ToastType.error,
      );
      return;
    }
    toast(
      name == null
          ? l10n.toastSecurityAllDestroyed
          : l10n.toastSecurityDestroyed(name),
      type: ToastType.success,
    );
  }

  Future<String?> _promptRecoveryPassword({
    required String title,
    required String description,
    String? hint,
    bool optional = false,
  }) {
    final l10n = context.l10n;
    return SDialog.show<String>(
      context,
      title: title,
      description: description,
      child: _RecoveryPasswordField(
        hint: hint ?? l10n.settingsDeviceBindRecoveryHint,
        optional: optional,
        skipLabel: l10n.settingsDeviceBindSkip,
        confirmLabel: l10n.commonConfirm,
      ),
    );
  }

  Future<void> _enableDeviceBind() async {
    final l10n = context.l10n;
    final privacyOk = await SDialog.show<bool>(
      context,
      title: l10n.settingsDeviceBindPrivacyTitle,
      description: l10n.settingsDeviceBindPrivacyDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsDeviceBindEnable,
          icon: Icons.security_outlined,
          variant: SButtonVariant.primary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (privacyOk != true || !mounted) return;
    final res = await _promptRecoveryPassword(
      title: l10n.settingsDeviceBindRecoveryTitle,
      description: l10n.settingsDeviceBindRecoveryDesc,
      optional: true,
    );
    if (res == null || !mounted) return;
    final dataDir = resolveDataDir();
    setState(() => _deviceBusy = true);
    try {
      final s0 = getRuntime().sessionStore;
      if (s0 is VaultSessionStore) await s0.flush();
      await StreamingStore.flush();
      if (_vaultMode == null) {
        if (res.isEmpty) {
          await VaultProcess.initDevice(dataDir);
        } else {
          await VaultProcess.initDevice(dataDir, recoveryPassword: res);
        }
      } else {
        final s = getRuntime().sessionStore;
        final password = s is VaultSessionStore ? s.sessionPassword : null;
        if (res.isEmpty) {
          await VaultProcess.upgradeDevice(dataDir, password: password);
        } else {
          await VaultProcess.upgradeDevice(
            dataDir,
            recoveryPassword: res,
            password: password,
          );
        }
      }
      final s = getRuntime().sessionStore;
      if (s is VaultSessionStore) s.syncMode('multiseal');
      StreamingStore.syncPasswordState(null);
      if (!mounted) return;
      if (await _promptRestartAfterModeChange() && mounted) {
        await _restartApp();
        return;
      }
      toast(l10n.toastDeviceBindEnabled, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }

  Future<void> _disableDeviceBind() async {
    final l10n = context.l10n;
    final dataDir = resolveDataDir();
    final hasRecovery = await VaultProcess.hasRecovery(dataDir);
    if (!mounted) return;
    String? res;
    if (hasRecovery) {
      res = await _promptRecoveryPassword(
        title: l10n.settingsDeviceBindCloseTitle,
        description: l10n.settingsDeviceBindCloseConfirmDesc,
        hint: l10n.settingsDeviceBindCloseHint,
      );
      if (res == null || res.isEmpty || !context.mounted) return;
    } else {
      res = await _promptNewV2Password();
      if (res == null || res.isEmpty || !context.mounted) return;
    }
    setState(() => _deviceBusy = true);
    try {
      final s0 = getRuntime().sessionStore;
      if (s0 is VaultSessionStore) await s0.flush();
      await StreamingStore.flush();
      final ok = await VaultProcess.clearDeviceSeal(dataDir, res);
      if (ok) {
        final s = getRuntime().sessionStore;
        if (s is VaultSessionStore) {
          s.syncMode('password', sessionPassword: res);
        }
        StreamingStore.syncPasswordState(res);
        if (!mounted) return;
        if (await _promptRestartAfterModeChange() && mounted) {
          await _restartApp();
          return;
        }
      }
      toast(
        ok ? l10n.toastDeviceBindClosed : l10n.toastDeviceBindRecoveryNeeded,
        type: ok ? ToastType.success : ToastType.warning,
      );
    } on VaultException catch (e) {
      toast(l10n.toastDeviceBindCloseFailed(e.message), type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }

  Future<String?> _promptNewV2Password() {
    final l10n = context.l10n;
    return SDialog.show<String>(
      context,
      title: l10n.settingsVaultCloseV3PasswordTitle,
      description: l10n.settingsVaultCloseV3PasswordDesc,
      child: _NewPasswordField(
        newHint: l10n.settingsVaultSwitchToPasswordNewHint,
        confirmHint: l10n.settingsVaultSwitchToPasswordConfirmHint,
        mismatchText: l10n.settingsVaultSwitchToPasswordMismatch,
      ),
    );
  }

  Future<void> _switchScheme(String target) async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsSchemeSwitchTitle,
      description: [
        if (target == 'vault') l10n.settingsSchemeSwitchToVaultWarning,
        if (target == 'file') l10n.settingsSchemeSwitchToFileWarning,
        l10n.settingsSchemeSwitchRebuildDesc,
      ].join('\n\n'),
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.settingsSchemeSwitchKeep,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsSchemeSwitchConfirm,
          icon: Icons.sync_problem_outlined,
          variant: SButtonVariant.primary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true || !mounted) return;
    setState(() => _deviceBusy = true);
    try {
      final s = getRuntime().sessionStore;
      if (s is VaultSessionStore) await s.flush();
      await StreamingStore.flush();
      VaultProcess.destroy(resolveDataDir());
      if (target == 'vault') {
        await VaultProcess.init(resolveDataDir());
      } else if (target == 'file') {
        await VaultProcess.initFile(resolveDataDir());
      } else {
        await VaultProcess.initCrypto(resolveDataDir());
      }
      ref.read(appPrefsProvider.notifier).setCredentialScheme(target);
      if (s is VaultSessionStore) {
        s.syncMode(target == 'vault' ? 'os' : 'crypto');
      }
      StreamingStore.syncPasswordState(null);
      if (!mounted) return;
      if (await _promptRestartAfterModeChange() && mounted) {
        await _restartApp();
        return;
      }
      toast(l10n.toastSchemeSwitched, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }

  Future<void> _onModeSelected(String target) async {
    final l10n = context.l10n;
    if (_deviceBusy || target == _vaultMode) return;
    if (_vaultMode == 'password' && !_v2Unlocked) {
      toast(l10n.settingsVaultNeedUnlockFirst, type: ToastType.warning);
      return;
    }
    switch (target) {
      case 'os':
        if (_vaultMode == 'multiseal') {
          toast(l10n.settingsVaultV3NoDirectV1, type: ToastType.warning);
        } else {
          await _switchToOs();
        }
      case 'password':
        if (_vaultMode == 'multiseal') {
          await _disableDeviceBind();
        } else {
          await _switchToPassword();
        }
      case 'multiseal':
        await _enableDeviceBind();
    }
    await _refreshVault();
  }

  Future<void> _switchToPassword() async {
    final l10n = context.l10n;
    final res = await SDialog.show<String>(
      context,
      title: l10n.settingsVaultSwitchToPasswordTitle,
      description: l10n.settingsVaultSwitchToPasswordDesc,
      child: _NewPasswordField(
        newHint: l10n.settingsVaultSwitchToPasswordNewHint,
        confirmHint: l10n.settingsVaultSwitchToPasswordConfirmHint,
        mismatchText: l10n.settingsVaultSwitchToPasswordMismatch,
      ),
    );
    if (res == null || res.isEmpty || !mounted) return;
    final s = getRuntime().sessionStore;
    if (s is! VaultSessionStore) return;
    setState(() => _deviceBusy = true);
    try {
      await s.flush();
      await StreamingStore.flush();
      await s.switchMode('password', newPassword: res);
      StreamingStore.syncPasswordState(res);
      if (!mounted) return;
      if (await _promptRestartAfterModeChange() && mounted) {
        await _restartApp();
        return;
      }
      toast(l10n.toastVaultSwitchedToPassword, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }

  Future<void> _switchToOs() async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsVaultSwitchToOsTitle,
      description: l10n.settingsVaultSwitchToOsDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.commonConfirm,
          icon: Icons.check,
          variant: SButtonVariant.primary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true || !mounted) return;
    final s = getRuntime().sessionStore;
    if (s is! VaultSessionStore) return;
    setState(() => _deviceBusy = true);
    try {
      await s.flush();
      await StreamingStore.flush();
      await s.switchMode('os');
      StreamingStore.syncPasswordState(null);
      if (!mounted) return;
      if (await _promptRestartAfterModeChange() && mounted) {
        await _restartApp();
        return;
      }
      toast(l10n.toastVaultSwitchedToOs, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }

  Future<bool> _promptRestartAfterModeChange() async {
    final l10n = context.l10n;
    final res = await SDialog.show<bool>(
      context,
      title: l10n.settingsVaultRestartTitle,
      description: l10n.settingsVaultRestartDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.settingsVaultRestartLater,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsVaultRestartNow,
          icon: Icons.restart_alt,
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
      debugPrint('[vault] 重启应用失败（请手动重启）：$e');
    }
    await quitApplication(ref);
  }

  Future<void> _changeRecoveryPassword() async {
    final l10n = context.l10n;
    final res = await _promptRecoveryPassword(
      title: l10n.settingsDeviceBindChangeRecoveryTitle,
      description: l10n.settingsDeviceBindChangeRecoveryDesc,
    );
    if (res == null || res.isEmpty || !context.mounted) return;
    setState(() => _deviceBusy = true);
    try {
      await VaultProcess.setRecoveryPassword(resolveDataDir(), res);
      toast(l10n.toastDeviceBindRecoverySet, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
    }
  }

  Future<void> _rebindDevice() async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsDeviceBindRebindTitle,
      description: l10n.settingsDeviceBindRebindDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsDeviceBindRebindConfirm,
          icon: Icons.sync_lock_outlined,
          variant: SButtonVariant.primary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true || !context.mounted) return;
    setState(() => _deviceBusy = true);
    try {
      await VaultProcess.rebind(resolveDataDir());
      toast(l10n.toastDeviceBindRebound, type: ToastType.success);
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
    }
  }

  Future<void> _recoverVault() async {
    final l10n = context.l10n;
    final res = await _promptRecoveryPassword(
      title: l10n.settingsDeviceBindRecoverTitle,
      description: l10n.settingsDeviceBindRecoverDesc,
    );
    if (res == null || res.isEmpty || !context.mounted) return;
    setState(() => _deviceBusy = true);
    try {
      var ok = false;
      final s = getRuntime().sessionStore;
      if (s is VaultSessionStore) ok = await s.recover(res);
      if (await StreamingStore.recover(res)) ok = true;
      if (!ok) {
        toast(l10n.toastDeviceBindRecoverFailed, type: ToastType.error);
        return;
      }
      if (!mounted) return;
      toast(l10n.toastDeviceBindRecovered, type: ToastType.success);
      final rebind = await SDialog.show<bool>(
        context,
        title: l10n.settingsDeviceBindRebindTitle,
        description: l10n.settingsDeviceBindRebindDesc,
        child: const SizedBox.shrink(),
        actions: [
          SButton(
            label: l10n.commonCancel,
            variant: SButtonVariant.secondary,
            size: SButtonSize.small,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          SButton(
            label: l10n.settingsDeviceBindRebindConfirm,
            icon: Icons.sync_lock_outlined,
            variant: SButtonVariant.primary,
            size: SButtonSize.small,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      );
      if (rebind == true && mounted) await _rebindDevice();
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }
}
