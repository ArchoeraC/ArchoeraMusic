// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic（实验性音源 `neko`）登录界面。
///
/// **模板 / 动效与 NT/KG/QM 登录一致**：全屏毛玻璃背景 + 居中登录卡片，
/// Tab 切换走「旧内容整体淡出 → 换内容并平滑动画高度 → 新内容淡入」
/// （AnimatedSize + AnimatedOpacity），点击卡片以外任意处关闭、无关闭键。
///
/// - 扫码：`/api/user/qrlogin/create` 取 `nekomusic://...`，本地自绘二维码；
///   状态经 SSE `/api/user/qrlogin/status` 推送，confirmed 即落盘并关闭。
/// - 账号密码：`/api/user/login`（请求体字段 `email` + `password`）。
///
/// **不含注册 / 邮箱验证码 / 滑块验证**（本项目不接入注册）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/neko/neko_api.dart';
import '../../services/neko/neko_types.dart';
import '../../stores/providers.dart';
import '../common/glass_blur.dart';
import '../common/qr_image_view.dart';
import '../common/toast.dart';
import 'login_risk_notice.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 打开 NekoMusic 登录界面（先弹登录风险提示）。返回 `true` 表示登录成功。
Future<bool?> showNekoLoginDialog(BuildContext context) async {
  if (!await showLoginRiskNotice(context)) return false;
  if (!context.mounted) return false;
  return showDialog<bool?>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    builder: (_) => const _NekoLoginDialog(),
  );
}

class _NekoLoginDialog extends ConsumerStatefulWidget {
  const _NekoLoginDialog();

  @override
  ConsumerState<_NekoLoginDialog> createState() => _NekoLoginDialogState();
}

class _NekoLoginDialogState extends ConsumerState<_NekoLoginDialog> {
  /// 当前选中 tab：0=扫码 / 1=账号密码（tab 栏高亮，立即切换）。
  int _tab = 0;

  /// 当前实际渲染的 tab（延后于 [_tab]：旧内容先淡出，再换内容淡入）。
  int _displayTab = 0;

  /// 切换中（旧内容淡出阶段，透明度 0）。
  bool _switching = false;

  // ── 扫码 ──────────────────────────────────────────────────────────
  NekoQrSession? _session;
  NekoQrState _qrState = NekoQrState.pending;
  StreamSubscription<NekoQrStatus>? _sub;
  bool _loading = true;
  bool _confirmed = false;
  String _error = '';

  // ── 账号密码 ──────────────────────────────────────────────────────
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _busy = false;
  String _loginError = '';

  NekoApi get _api => ref.read(nekoApiProvider);

  @override
  void initState() {
    super.initState();
    _createQr();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  /// 切换方式：**全部隐藏再显示**（与其他平台登录窗一致）——
  /// 旧内容先整体淡出（180ms）→ 换内容并平滑动画卡片高度 → 新内容淡入。
  Future<void> _switchTab(int tab) async {
    if (_tab == tab || _switching) return;
    setState(() {
      _tab = tab; // tab 栏高亮立即切换
      _switching = true; // 旧内容开始淡出
    });
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    setState(() => _displayTab = tab); // 换内容（此刻不可见）
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    setState(() => _switching = false); // 新内容淡入
  }

  // ── 扫码 ──────────────────────────────────────────────────────────
  Future<void> _createQr() async {
    setState(() {
      _loading = true;
      _confirmed = false;
      _error = '';
      _qrState = NekoQrState.pending;
      _session = null;
    });
    await _sub?.cancel();
    _sub = null;
    try {
      final session = await _api.qrCreate();
      if (!mounted) return;
      setState(() {
        _session = session;
        _loading = false;
      });
      _sub = _api.qrWatch(session.sessionId).listen(
        _onQrStatus,
        onError: (Object e) {
          if (mounted) setState(() => _error = '$e');
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _onQrStatus(NekoQrStatus status) {
    if (!mounted) return;
    setState(() => _qrState = status.state);
    if (status.state == NekoQrState.confirmed) {
      setState(() => _confirmed = true);
      Navigator.of(context).pop(true);
      toast(context.l10n.loginSuccess);
    }
  }

  bool get _qrTerminal =>
      _qrState == NekoQrState.expired || _qrState == NekoQrState.canceled;

  String _qrStatusText(AppLocalizations l10n) {
    if (_loading) return l10n.loginFetchingQr;
    if (_error.isNotEmpty) return _error;
    return switch (_qrState) {
      NekoQrState.scanned => l10n.nekoQrScanned,
      NekoQrState.confirmed => l10n.loginSuccess,
      NekoQrState.canceled => l10n.nekoQrCanceled,
      NekoQrState.expired => l10n.nekoQrExpired,
      _ => l10n.nekoLoginQrHint,
    };
  }

  // ── 账号密码 ──────────────────────────────────────────────────────
  Future<void> _passwordLogin() async {
    final l10n = context.l10n;
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    if (email.isEmpty || pass.isEmpty) {
      setState(() => _loginError = l10n.nekoLoginPasswordHint);
      return;
    }
    setState(() {
      _busy = true;
      _loginError = '';
    });
    try {
      await _api.loginPassword(email, pass);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      toast(l10n.loginSuccess);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loginError = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                            l10n.nekoLoginTitle,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _tabBar(scheme, l10n),
                          const SizedBox(height: 20),
                          // 切换方式：全部隐藏再显示（淡出 → 换内容 / 动画高度 → 淡入）。
                          AnimatedSize(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeInOutCubic,
                            alignment: Alignment.topCenter,
                            child: AnimatedOpacity(
                              opacity: _switching ? 0 : 1,
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeInOut,
                              child: _displayTab == 0
                                  ? _qrTab(theme, scheme, l10n)
                                  : _passwordTab(theme, scheme, l10n),
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
    final tabs = [l10n.nekoLoginTabQr, l10n.nekoLoginTabPassword];
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
    final session = _session;
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
                : _error.isNotEmpty && session == null
                ? _qrError(scheme, l10n)
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      if (session != null && session.qrContent.isNotEmpty)
                        QrImageView(
                          data: session.qrContent,
                          size: 248,
                          backgroundColor: Colors.white,
                        ),
                      if (_qrTerminal)
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
              _qrStatusText(l10n),
              style: theme.textTheme.bodySmall?.copyWith(
                color: _qrTerminal ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (!_loading &&
            session != null &&
            !_qrTerminal &&
            !_confirmed &&
            _error.isEmpty)
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

  // ── 账号密码 tab ──────────────────────────────────────────────────
  Widget _passwordTab(
    ThemeData theme,
    ColorScheme scheme,
    AppLocalizations l10n,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _emailCtrl,
          keyboardType: TextInputType.emailAddress,
          enabled: !_busy,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(EtaIcons.userOutline, size: 18),
            hintText: l10n.nekoLoginEmail,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passCtrl,
          obscureText: true,
          enabled: !_busy,
          onSubmitted: (_) => _passwordLogin(),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(EtaIcons.lockOutline, size: 18),
            hintText: l10n.nekoLoginPassword,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_loginError.isNotEmpty) _errorText(_loginError, scheme),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy ? null : _passwordLogin,
            child: _busy ? _spinner() : Text(l10n.nekoLoginSubmit),
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
