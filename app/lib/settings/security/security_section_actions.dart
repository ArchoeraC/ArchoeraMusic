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
        hint: l10n.settingsSecurityConfirmHint(word: word),
        cancelLabel: l10n.commonCancel,
        confirmLabel: l10n.settingsSecurityDestroy,
      ),
    );
  }

  Future<void> _destroyStreaming() async {
    final l10n = context.l10n;
    final ok = await _confirmShred(
      context,
      l10n.settingsSecurityConfirmTitle(name: l10n.settingsSecurityStreaming),
      l10n.settingsSecurityConfirmDesc(word: l10n.settingsSecurityConfirmWord),
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
      l10n.settingsSecurityConfirmTitle(name: l10n.settingsSecuritySession),
      l10n.settingsSecurityConfirmDesc(word: l10n.settingsSecurityConfirmWord),
    );
    if (ok != true || !context.mounted) return;
    await _revokeAll();
    try {
      VaultProcess.destroy(resolveDataDir());
    } catch (_) {}
    // SEC-10：MCP 访问密钥随 vault 销毁（uid `mcp:accessKey`）一并失效；
    // 清内存缓存并移除历史 prefs.json 明文键。
    McpKeyStore.reset();
    McpKeyStore.clearLegacy(resolveDataDir());
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
      l10n.settingsSecurityConfirmTitle(name: l10n.settingsSecurityUserDb),
      l10n.settingsSecurityConfirmDesc(word: l10n.settingsSecurityConfirmWord),
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
      l10n.settingsSecurityConfirmDesc(word: l10n.settingsSecurityConfirmWord),
    );
    if (ok != true || !context.mounted) return;
    await _revokeAll();
    try {
      VaultProcess.destroy(resolveDataDir());
    } catch (_) {}
    // SEC-10：MCP 访问密钥随 vault 销毁（uid `mcp:accessKey`）一并失效；
    // 清内存缓存并移除历史 prefs.json 明文键。
    McpKeyStore.reset();
    McpKeyStore.clearLegacy(resolveDataDir());
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
        l10n.toastSecurityDestroyFailed(path: failed.join(', ')),
        type: ToastType.error,
      );
      return;
    }
    toast(
      name == null
          ? l10n.toastSecurityAllDestroyed
          : l10n.toastSecurityDestroyed(name: name),
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

  /// 切换 Argon2id 强度预设：验证当前口令 → `set-kdf` 重封装口令槽
  /// （主密钥与条目不变）→ 持久化预设。失败显示 vault 返回的错误。
  Future<void> _onKdfPresetChanged(String preset) async {
    if (_deviceBusy || preset == ref.read(appPrefsProvider).vaultKdfPreset) {
      return;
    }
    final l10n = context.l10n;
    final pw = await _promptRecoveryPassword(
      title: l10n.settingsKdfPasswordTitle,
      description: l10n.settingsKdfPasswordDesc,
      hint: l10n.settingsKdfPasswordHint,
    );
    if (pw == null || pw.isEmpty || !mounted) return;
    setState(() => _deviceBusy = true);
    try {
      final s = getRuntime().sessionStore;
      if (s is VaultSessionStore) {
        await s.setKdfPreset(preset, password: pw);
      } else {
        await StreamingStore.setKdfPreset(preset, password: pw);
      }
      ref.read(appPrefsProvider.notifier).setVaultKdfPreset(preset);
      if (!mounted) return;
      toast(l10n.toastKdfRepacked, type: ToastType.success);
    } on VaultException catch (e) {
      if (!mounted) return;
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }

  /// 切换凭据加密方案：确认（销毁重建，无迁移）→（m1/m2a）设置口令 →
  /// 销毁现有保险库 + 备份 + device.key → 按新方案初始化 →（m2a）一次性展示
  /// 恢复码 → 冷切重启。方案间加密结构不兼容，旧凭据随销毁清空需重新登录。
  Future<void> _switchScheme(String target) async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsSchemeSwitchTitle,
      description: [
        if (target == 'file') l10n.settingsSchemeSwitchToFileWarning,
        l10n.settingsSchemeSwitchRebuildDesc,
        l10n.settingsSchemeSwitchEraseWarning,
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
          icon: EtaIcons.warningOutline,
          variant: SButtonVariant.primary,
          size: SButtonSize.small,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true || !mounted) return;

    // m1/m2a：初始化前先取解锁口令（用户取消则中止，此时尚未销毁现有数据）。
    String? password;
    if (target == 'm1' || target == 'm2a') {
      password = await _promptNewPassword();
      if (password == null || password.isEmpty || !mounted) return;
    }

    setState(() => _deviceBusy = true);
    VaultInitM2a? m2a;
    try {
      final s = getRuntime().sessionStore;
      if (s is VaultSessionStore) await s.flush();
      await StreamingStore.flush();
      // 全量销毁：vault 文件 + 授权侧份额 + `.bak` + device.key + 本地锚点/标记。
      VaultProcess.destroy(resolveDataDir());
      // m1/m2a 初始化按当前 Argon2id 预设选取参数（非密文，走 argv）。
      final kdf = vaultKdfPresetById(
          ref.read(appPrefsProvider).vaultKdfPreset);
      switch (target) {
        case 'file':
          await VaultProcess.initFile(resolveDataDir());
        case 'm1':
          await VaultProcess.initM1(resolveDataDir(), password!,
              kdfM: kdf.mKiB, kdfT: kdf.t, kdfP: kdf.p);
        case 'm2a':
          m2a = await VaultProcess.initM2a(resolveDataDir(), password!,
              kdfM: kdf.mKiB, kdfT: kdf.t, kdfP: kdf.p);
        case 'm2b':
          await VaultProcess.initM2b(resolveDataDir());
        case 'crypto':
        default:
          await VaultProcess.initCrypto(resolveDataDir());
      }
      ref.read(appPrefsProvider.notifier).setCredentialScheme(target);
      if (target == 'm2a') {
        // m2a 恢复码随新库重新生成：作废旧确认标记 → 强制重新备份。
        ref.read(appPrefsProvider.notifier).setM2aRecoveryAcked(false);
      }
      if (target == 'm2a' && m2a != null && m2a.recoveryCode.isNotEmpty) {
        if (!mounted) return;
        await _showRecoveryCode(m2a.recoveryCode);
      }
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

  /// 新口令输入（含二次确认）；不一致/为空时确认按钮禁用。返回 null = 取消。
  Future<String?> _promptNewPassword() {
    final l10n = context.l10n;
    return SDialog.show<String>(
      context,
      title: l10n.settingsSchemePasswordTitle,
      description: l10n.settingsSchemePasswordDesc,
      child: _NewPasswordField(
        hint: l10n.settingsSchemePasswordHint,
        confirmHint: l10n.settingsSchemePasswordConfirmHint,
        mismatch: l10n.settingsSchemePasswordMismatch,
        cancelLabel: l10n.commonCancel,
        confirmLabel: l10n.commonConfirm,
      ),
    );
  }

  /// m2a 恢复码一次性展示（不可关闭/不可返回键 dismiss，唯一按钮 = 已抄写确认）。
  /// 确认后持久化 ack 标记并移除设置页的持久备份提醒。
  ///
  /// 注：刻意**不提供**「重新生成恢复码」动作——vault 侧无 regenerate 命令，
  /// 恢复槽只在 `init-m2a` 时一次性封装；伪造一个半可用动作（失败/无效果）
  /// 不如不提供。恢复码遗失仅能销毁重建（重新初始化 m2a 会生成新恢复码）。
  Future<void> _showRecoveryCode(String code) async {
    final l10n = context.l10n;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          icon: const Icon(EtaIcons.shieldOutline),
          title: Text(l10n.settingsSchemeRecoveryDialogTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.settingsSchemeRecoveryDialogDesc,
                style: const TextStyle(height: 1.45),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(ctx)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  code,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: SButton(
                  label: l10n.settingsSchemeRecoveryCopy,
                  variant: SButtonVariant.ghost,
                  size: SButtonSize.small,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (!ctx.mounted) return;
                    toast(
                      l10n.settingsSchemeRecoveryCopied,
                      type: ToastType.success,
                    );
                  },
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () {
                ref.read(appPrefsProvider.notifier).setM2aRecoveryAcked(true);
                Navigator.of(ctx).pop();
              },
              child: Text(l10n.settingsSchemeRecoveryDialogAck),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 设置页持久提醒的「我已保存」动作（用户在别处已抄写恢复码时消费提醒）。
  void _ackRecoveryCode() {
    ref.read(appPrefsProvider.notifier).setM2aRecoveryAcked(true);
    setState(() {});
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
      Log.e('vault', '重启应用失败（请手动重启）：$e');
    }
    await quitApplication(ref);
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
    } on VaultException catch (e) {
      toast(e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _deviceBusy = false);
      await _refreshVault();
    }
  }
}
