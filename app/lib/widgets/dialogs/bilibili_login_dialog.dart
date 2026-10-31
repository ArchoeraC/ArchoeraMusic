// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 扫码登录对话框。
///
/// 二维码 URL 由官方 passport 接口生成；用户用哔哩哔哩手机客户端扫码并确认。
/// 登录成功前不关闭弹窗，成功后再用 nav 核实身份。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apis/bilibili/core/types.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/log/log.dart';
import '../../stores/providers.dart';
import '../common/glass_blur.dart';
import '../common/qr_image_view.dart';
import '../common/toast.dart';
import 'login_risk_notice.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

Future<bool?> showBilibiliLoginDialog(BuildContext context) async {
  if (!await showLoginRiskNotice(context)) return false;
  if (!context.mounted) return false;
  return showDialog<bool?>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    builder: (_) => const _BilibiliLoginDialog(),
  );
}

class _BilibiliLoginDialog extends ConsumerStatefulWidget {
  const _BilibiliLoginDialog();

  @override
  ConsumerState<_BilibiliLoginDialog> createState() =>
      _BilibiliLoginDialogState();
}

class _BilibiliLoginDialogState extends ConsumerState<_BilibiliLoginDialog> {
  Timer? _poll;
  String _key = '';
  String _url = '';
  bool _loading = true;
  bool _checking = false;
  bool _expired = false;
  bool _confirmed = false;
  String _error = '';
  String _hint = '';

  @override
  void initState() {
    super.initState();
    _createQr();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _createQr() async {
    setState(() {
      _loading = true;
      _expired = false;
      _confirmed = false;
      _error = '';
      _hint = '';
      _key = '';
      _url = '';
    });
    _poll?.cancel();
    try {
      final challenge = await ref.read(bilibiliApiProvider).qrGenerate();
      if (!mounted) return;
      setState(() {
        _key = challenge.key;
        _url = challenge.url;
        _loading = false;
      });
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
      unawaited(_check());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _check() async {
    if (_key.isEmpty || _confirmed || _expired || _checking) return;
    _checking = true;
    try {
      final state = await ref.read(bilibiliApiProvider).qrPoll(_key);
      if (!mounted) return;
      switch (state) {
        case BilibiliQrState.signedIn:
          _poll?.cancel();
          setState(() => _confirmed = true);
          Navigator.of(context).pop(true);
          toast(context.l10n.loginSuccess);
        case BilibiliQrState.expired:
          _poll?.cancel();
          setState(() {
            _expired = true;
            _error = context.l10n.loginQrExpiredRegenerate;
          });
        case BilibiliQrState.scanned:
          setState(() => _hint = context.l10n.loginWaitingConfirm);
        case BilibiliQrState.waiting:
          setState(() => _hint = context.l10n.loginBilibiliScanHint);
      }
    } catch (e) {
      Log.e('bilibili', '检查登录异常: $e');
      if (mounted) setState(() => _hint = '${context.l10n.loginFailed}: $e');
    } finally {
      _checking = false;
    }
  }

  String _statusText(AppLocalizations l10n) {
    if (_loading) return l10n.loginFetchingQr;
    if (_expired) return l10n.loginQrExpired;
    if (_confirmed) return l10n.loginSuccess;
    return _hint.isEmpty ? l10n.loginBilibiliScanHint : _hint;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
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
                    child: SizedBox(
                      width: 320,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.loginQrLogin,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: 300,
                            height: 300,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.25),
                                  blurRadius: 24,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            child: Center(
                              child: _loading
                                  ? const SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                      ),
                                    )
                                  : _error.isNotEmpty && _url.isEmpty
                                  ? _buildError(scheme, l10n)
                                  : _url.isNotEmpty
                                  ? Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        QrImageView(
                                          data: _url,
                                          size: 260,
                                          padding: 8,
                                        ),
                                        if (_expired)
                                          _overlay(
                                            FilledButton.icon(
                                              onPressed: _createQr,
                                              icon: const Icon(
                                                EtaIcons.refresh,
                                                size: 18,
                                              ),
                                              label: Text(l10n.loginRefreshQr),
                                            ),
                                          ),
                                        if (_confirmed)
                                          _overlay(
                                            const Icon(
                                              EtaIcons.checkCircle,
                                              size: 48,
                                              color: Colors.white,
                                            ),
                                          ),
                                      ],
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 24,
                            child: Center(
                              child: Text(
                                _statusText(l10n),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _expired
                                      ? scheme.error
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                          if (!_loading &&
                              !_confirmed &&
                              !_expired &&
                              _url.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: OutlinedButton.icon(
                                onPressed: _createQr,
                                icon: const Icon(EtaIcons.refresh, size: 18),
                                label: Text(l10n.loginRefreshQr),
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

  Widget _overlay(Widget child) => Container(
    width: 260,
    height: 260,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );

  Widget _buildError(ColorScheme scheme, AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(EtaIcons.alertOutline, size: 48, color: scheme.error),
        const SizedBox(height: 12),
        Text(
          _error,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _createQr,
          icon: const Icon(EtaIcons.refresh, size: 18),
          label: Text(l10n.commonRetry),
        ),
      ],
    );
  }
}
