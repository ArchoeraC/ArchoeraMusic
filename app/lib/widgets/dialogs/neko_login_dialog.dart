// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic（实验性音源 `neko`）登录界面。
///
/// **仅扫码登录**：`/api/user/qrlogin/create` 取服务端渲染好的二维码 PNG
/// （`qrImage` data URL，无须本地自绘）；状态经 SSE
/// `/api/user/qrlogin/status` 推送，`confirmed` 后由 [NekoApi.qrWatch]
/// 用 `deliveryKey` 领取 token 并落盘。
///
/// **破坏性变更（2026-11-09）**：NekoAuth OAuth（浏览器回调 +
/// `nekomusic://` 深链）与传统账号密码登录已整体移除，界面不再提供对应入口。
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

class _NekoLoginDialog extends ConsumerStatefulWidget {
  const _NekoLoginDialog();

  @override
  ConsumerState<_NekoLoginDialog> createState() => _NekoLoginDialogState();
}

class _NekoLoginDialogState extends ConsumerState<_NekoLoginDialog> {
  late final NekoApi _api;

  NekoQrSession? _session;
  NekoQrState _qrState = NekoQrState.pending;
  StreamSubscription<NekoQrStatus>? _sub;
  bool _loading = false;
  bool _confirmed = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _api = ref.read(nekoApiProvider);
    unawaited(_createQr());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

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
      _sub = _api
          .qrWatch(session)
          .listen(
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
                          const SizedBox(height: 20),
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
                : _error.isNotEmpty && session == null
                ? _qrError(scheme, l10n)
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
}
