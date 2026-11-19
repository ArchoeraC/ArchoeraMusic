// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic（实验性音源 `neko`）登录界面。
///
/// 两种方式，都不打开系统浏览器：
///
/// - **账号密码**（需在设置里显式开启「应用内账号密码登录」，默认关闭）：
///   交给 [NekoApi.loginWithPassword]，内部由 `NekoAuthClient` 复刻官方 PC
///   客户端的 SSO 链路（start → 登录 → 授权码 → 回调 handoff → claim）。
///   密码只在本次请求里出现，不落盘。
/// - **扫码**：`/api/user/qrlogin/create` 取服务端渲染好的二维码 PNG
///   （`qrImage` data URL，无须本地自绘）；状态经 SSE
///   `/api/user/qrlogin/status` 推送，`confirmed` 后由 [NekoApi.qrWatch]
///   用 `deliveryKey` 领取 token 并落盘。
///
/// 二维码只在切到扫码页时生成（避免开窗即发请求），离开登录界面即取消订阅。
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
import '../../stores/app_prefs.dart';
import '../../stores/providers.dart';
import '../common/glass_blur.dart';
import '../common/toast.dart';
import 'login_risk_notice.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 打开 NekoMusic 登录界面（先弹登录风险提示）。返回 `true` 表示登录成功。
///
/// 没有显式「取消」按钮：**离开登录界面即取消**（关闭时停止二维码状态订阅）。
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

/// 登录方式（界面 tab）。
enum _NekoLoginTab { password, qr }

class _NekoLoginDialog extends ConsumerStatefulWidget {
  const _NekoLoginDialog();

  @override
  ConsumerState<_NekoLoginDialog> createState() => _NekoLoginDialogState();
}

class _NekoLoginDialogState extends ConsumerState<_NekoLoginDialog> {
  late final NekoApi _api;

  /// 用户是否打开了「应用内账号密码登录」（默认关 → 只提供扫码）。
  late final bool _passwordEnabled;

  late _NekoLoginTab _tab;

  // 账号密码
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure = true;
  bool _submitting = false;
  String _formError = '';

  // 扫码
  NekoQrSession? _session;
  NekoQrState _qrState = NekoQrState.pending;
  StreamSubscription<NekoQrStatus>? _sub;
  bool _loading = false;
  bool _confirmed = false;
  String _qrError = '';

  @override
  void initState() {
    super.initState();
    _api = ref.read(nekoApiProvider);
    _passwordEnabled = ref
        .read(appPrefsProvider)
        .nekoPasswordLoginEnabled;
    _tab = _passwordEnabled ? _NekoLoginTab.password : _NekoLoginTab.qr;
    // 只有扫码可用时，打开即开始申请二维码。
    if (!_passwordEnabled) unawaited(_createQr());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // ── 切换 tab ─────────────────────────────────────────────────

  void _switchTab(_NekoLoginTab tab) {
    if (_tab == tab || _submitting) return;
    if (tab == _NekoLoginTab.password) {
      // 离开扫码页即取消订阅，避免后台继续轮询 / 领取。
      unawaited(_sub?.cancel());
      _sub = null;
      setState(() {
        _tab = tab;
        _session = null;
        _qrState = NekoQrState.pending;
        _qrError = '';
        _confirmed = false;
        _loading = false;
      });
      return;
    }
    setState(() => _tab = tab);
    unawaited(_createQr());
  }

  // ── 账号密码 ─────────────────────────────────────────────────

  Future<void> _submitPassword() async {
    if (_submitting) return;
    final l10n = context.l10n;
    final identifier = _identifierCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (identifier.isEmpty) {
      setState(() => _formError = l10n.nekoLoginAccountRequired);
      return;
    }
    if (password.isEmpty) {
      setState(() => _formError = l10n.nekoLoginPasswordRequired);
      return;
    }
    setState(() {
      _submitting = true;
      _formError = '';
    });
    try {
      await _api.loginWithPassword(identifier: identifier, password: password);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      toast(context.l10n.loginSuccess);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _formError = '$e';
      });
    }
  }

  // ── 扫码 ─────────────────────────────────────────────────────

  Future<void> _createQr() async {
    setState(() {
      _loading = true;
      _confirmed = false;
      _qrError = '';
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
      _sub = _api
          .qrWatch(session)
          .listen(
            _onQrStatus,
            onError: (Object e) {
              if (mounted) setState(() => _qrError = '$e');
            },
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _qrError = '$e';
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
    if (_qrError.isNotEmpty) return _qrError;
    return switch (_qrState) {
      NekoQrState.scanned => l10n.nekoQrScanned,
      NekoQrState.confirmed => l10n.loginSuccess,
      NekoQrState.canceled => l10n.nekoQrCanceled,
      NekoQrState.expired => l10n.nekoQrExpired,
      _ => l10n.nekoLoginQrHint,
    };
  }

  // ── 渲染 ─────────────────────────────────────────────────────

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
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      // InkWell（tab / 按钮水波纹）需要一个 Material 祖先。
                      child: Material(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(20),
                        clipBehavior: Clip.antiAlias,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
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
                              if (_passwordEnabled) ...[
                                _tabs(theme, scheme, l10n),
                                const SizedBox(height: 16),
                              ],
                              if (_passwordEnabled &&
                                  _tab == _NekoLoginTab.password)
                                _passwordTab(theme, scheme, l10n)
                              else
                                _qrTab(theme, scheme, l10n),
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
        ),
      ),
    );
  }

  Widget _tabs(ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    Widget item(String label, _NekoLoginTab tab) {
      final selected = _tab == tab;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: _submitting ? null : () => _switchTab(tab),
          child: Container(
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          item(l10n.nekoLoginTabPassword, _NekoLoginTab.password),
          item(l10n.nekoLoginTabQr, _NekoLoginTab.qr),
        ],
      ),
    );
  }

  Widget _passwordTab(
    ThemeData theme,
    ColorScheme scheme,
    AppLocalizations l10n,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _identifierCtrl,
          enabled: !_submitting,
          autofillHints: const [AutofillHints.username],
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(EtaIcons.userOutline, size: 18),
            hintText: l10n.nekoLoginAccountHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordCtrl,
          enabled: !_submitting,
          obscureText: _obscure,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => unawaited(_submitPassword()),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(EtaIcons.lockOutline, size: 18),
            hintText: l10n.nekoLoginPasswordHint,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              onPressed: _submitting
                  ? null
                  : () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure ? EtaIcons.eyeOutline : EtaIcons.eyeCloseOutline,
                size: 18,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          l10n.nekoLoginPasswordNote,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontSize: 11,
            height: 1.5,
          ),
        ),
        if (_formError.isNotEmpty) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _formError,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        ],
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _submitting ? null : () => unawaited(_submitPassword()),
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.nekoLoginSubmit),
          ),
        ),
      ],
    );
  }

  Widget _qrTab(ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    final session = _session;
    final qrBytes = session?.qrImageBytes;
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
                : _qrError.isNotEmpty && session == null
                ? _qrErrorBox(scheme, l10n)
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      if (qrBytes != null && qrBytes.isNotEmpty)
                        Image.memory(
                          qrBytes,
                          width: 248,
                          height: 248,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                          gaplessPlayback: true,
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
            _qrError.isEmpty)
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

  Widget _qrErrorBox(ColorScheme scheme, AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(EtaIcons.alertOutline, size: 44, color: scheme.error),
        const SizedBox(height: 12),
        Text(
          _qrError,
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
}
