// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../netease_login_dialog.dart';

extension _NeteaseLoginDialogView on _NeteaseLoginDialogState {
  Widget _buildNeteaseLoginDialog(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // 全屏毛玻璃背景 + 居中登录卡片；点击卡片以外任意处直接关闭（无关闭键）。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(),
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
                            l10n.loginTitleBrand(l10n.brandNetease),
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
            child: _loading
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : _error.isNotEmpty
                ? _qrError(scheme, l10n)
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      QrImageView(
                        data: _qrUrl,
                        size: 248,
                        backgroundColor: Colors.white,
                      ),
                      if (_expired)
                        _qrOverlay(
                          child: FilledButton.icon(
                            onPressed: _createQr,
                            icon: const Icon(EtaIcons.refresh, size: 18),
                            label: Text(l10n.loginRefreshQr),
                          ),
                        ),
                      if (_confirmed)
                        _qrOverlay(
                          child: const Icon(
                            EtaIcons.checkCircle,
                            size: 48,
                            color: Colors.white,
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 22,
          child: Center(
            child: Text(
              _confirmed
                  ? l10n.loginSuccess
                  : _expired
                  ? l10n.loginQrExpired
                  : _status.isEmpty
                  ? l10n.loginFetchingQr
                  : _status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _expired ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (!_loading && _error.isEmpty && !_expired && !_confirmed)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(
              onPressed: _createQr,
              icon: const Icon(EtaIcons.refresh, size: 18),
              label: Text(l10n.loginRefreshQr),
            ),
          ),
      ],
    );
  }

  Widget _qrOverlay({required Widget child}) {
    return Container(
      width: 248,
      height: 248,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

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
        FilledButton.icon(
          onPressed: _createQr,
          icon: const Icon(EtaIcons.refresh, size: 18),
          label: Text(l10n.commonRetry),
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
            prefixIcon: const Icon(EtaIcons.messageOutline, size: 18),
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
