// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../kugou_login_button.dart';

extension _KugouLoginButtonView on _KugouLoginButtonState {
  Widget _buildKugouLoginButton(BuildContext context) {
    final api = _api;
    return ListenableBuilder(
      listenable: api,
      builder: (context, _) {
        final theme = Theme.of(context);
        final l10n = context.l10n;
        final session = api.session;
        final nickname = session?.nickname;
        return PopupMenuButton<String>(
          tooltip: session == null
              ? l10n.loginKugouQrLogin(platform: l10n.brandKugou)
              : l10n.loginKugouSession(platform: l10n.brandKugou),
          // 性能模式：菜单直出，无淡入/弹出动效
          popUpAnimationStyle: noAnim(context)
              ? AnimationStyle.noAnimation
              : null,
          onSelected: (v) {
            if (v == 'login') _openLogin();
            if (v == 'logout') _logout();
          },
          itemBuilder: (context) => session == null
              ? [PopupMenuItem(value: 'login', child: Text(l10n.loginQrLogin))]
              : [
                  PopupMenuItem(
                    value: 'logout',
                    child: Text(
                      l10n.loginLogoutWithId(id: nickname ?? session.userid),
                    ),
                  ),
                ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  session == null ? EtaIcons.userOutline : EtaIcons.user,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  session == null
                      ? l10n.loginKugouLogin(platform: l10n.brandKugou)
                      : (nickname ?? l10n.loginKugouLoggedIn(platform: l10n.brandKugou)),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

extension _KgQrLoginDialogView on _KgQrLoginDialogState {
  Widget _buildKgQrLoginDialog(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // 全屏毛玻璃背景 + 居中登录卡片（tab：扫码 / 手机号 / 邮箱）；
    // 点击卡片以外任意处直接关闭（无关闭键）。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(false),
      child: ClipRect(
        child: GlassBlur(
          sigma: 16,
          child: ColoredBox(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.8),
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: Container(
                      width: 360,
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.loginTitleBrand(platform: l10n.brandKugou),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _tabBar(scheme, l10n),
                          const SizedBox(height: 20),
                          // 切换方式：**全部隐藏再显示**（对齐 WebWord 登录窗）——
                          // AnimatedOpacity 整体淡出/淡入 + AnimatedSize 动画高度。
                          AnimatedSize(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeInOutCubic,
                            alignment: Alignment.topCenter,
                            child: AnimatedOpacity(
                              opacity: _switching ? 0 : 1,
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeInOut,
                              child: switch (_displayTab) {
                                0 => _qrTab(theme, scheme, l10n),
                                1 => _phoneTab(theme, scheme, l10n),
                                _ => _emailTab(theme, scheme, l10n),
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabBar(ColorScheme scheme, AppLocalizations l10n) {
    final tabs = [l10n.loginTabQr, l10n.loginTabPhone, l10n.loginTabEmail];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < tabs.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: TextButton(
              onPressed: () => _switchTab(i),
              style: TextButton.styleFrom(
                foregroundColor: _tab == i
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
                textStyle: TextStyle(
                  fontWeight: _tab == i ? FontWeight.w600 : FontWeight.w400,
                ),
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(tabs[i]),
            ),
          ),
      ],
    );
  }

  // ── 扫码 tab ──────────────────────────────────────────────────────
  Widget _qrTab(ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 280,
          height: 280,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Center(
            child: _loadingKey
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : _key != null
                ? QrImageView(data: '$kgQrLoginPage?qrcode=$_key', size: 248)
                : _qrError(scheme, l10n),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 22,
          child: Center(
            child: Text(
              _statusText(l10n),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (!_loadingKey && _key != null && _status != 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(
              onPressed: _initQr,
              icon: const Icon(EtaIcons.refresh, size: 18),
              label: Text(l10n.loginRegenerate),
            ),
          ),
      ],
    );
  }

  /// 错误状态（实体卡片内部）：图标 + 限行文本 + 重新生成按钮。
  Widget _qrError(ColorScheme scheme, AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(EtaIcons.alertOutline, size: 44, color: scheme.error),
        const SizedBox(height: 12),
        Text(
          _error,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 14),
        FilledButton.tonalIcon(
          onPressed: _initQr,
          icon: const Icon(EtaIcons.refresh),
          label: Text(l10n.loginRegenerate),
        ),
      ],
    );
  }

  // ── 手机号 tab ────────────────────────────────────────────────────
  Widget _phoneTab(ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          enabled: !_phoneBusy,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(EtaIcons.userOutline, size: 18),
            hintText: l10n.loginPhoneHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _codeCtrl,
                keyboardType: TextInputType.number,
                enabled: !_phoneBusy,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(EtaIcons.lockOutline, size: 18),
                  hintText: l10n.loginCodeHint,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 48,
              child: FilledButton.tonal(
                onPressed: (_phoneBusy || _codeCountdown > 0) ? null : _sendCode,
                child: Text(
                  _codeCountdown > 0
                      ? '${_codeCountdown}s'
                      : l10n.loginSendCode,
                ),
              ),
            ),
          ],
        ),
        if (_phoneError.isNotEmpty) _errorText(_phoneError, scheme),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _phoneBusy ? null : _phoneLogin,
            child: _phoneBusy ? _spinner() : Text(l10n.loginSubmit),
          ),
        ),
      ],
    );
  }

  // ── 邮箱 tab ──────────────────────────────────────────────────────
  Widget _emailTab(ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _emailCtrl,
          keyboardType: TextInputType.emailAddress,
          enabled: !_emailBusy,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(EtaIcons.userOutline, size: 18),
            hintText: l10n.loginEmailHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passCtrl,
          obscureText: true,
          enabled: !_emailBusy,
          onSubmitted: (_) => _emailLogin(),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(EtaIcons.lockOutline, size: 18),
            hintText: l10n.loginPasswordHint,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_emailError.isNotEmpty) _errorText(_emailError, scheme),
        const SizedBox(height: 10),
        // 说明：平台可能在邮箱登录时下发短信验证（服务端安全策略）
        Row(
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
                l10n.loginEmailRiskHint,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _emailBusy ? null : _emailLogin,
            child: _emailBusy ? _spinner() : Text(l10n.loginSubmit),
          ),
        ),
      ],
    );
  }

  Widget _errorText(String message, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Icon(EtaIcons.alertOutline, size: 14, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: scheme.error),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _spinner() => const SizedBox(
    width: 18,
    height: 18,
    child: CircularProgressIndicator(strokeWidth: 2.2),
  );
}
