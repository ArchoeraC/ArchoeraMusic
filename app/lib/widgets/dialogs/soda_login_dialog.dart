// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水扫码登录对话框（扫码 + 2046 短信 MFA）。
///
/// 流程：`qrKey()` 取二维码 → 2s 轮询 `qrCheck()`；若需 MFA 则切换到短信
/// 验证（下发 + 输入验证码）；成功后 cookie 已落 vault → 关闭并提示。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/soda/soda_auth.dart';
import '../../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../common/toast.dart';
import 'login_risk_notice.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 打开汽水扫码登录弹窗（先弹登录风险提示，确认后才继续）。
Future<bool?> showSodaLoginDialog(BuildContext context) async {
  if (!await showLoginRiskNotice(context)) return false;
  if (!context.mounted) return false;
  return showDialog<bool?>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    builder: (_) => const _SodaLoginDialog(),
  );
}

class _SodaLoginDialog extends ConsumerStatefulWidget {
  const _SodaLoginDialog();

  @override
  ConsumerState<_SodaLoginDialog> createState() => _SodaLoginDialogState();
}

class _SodaLoginDialogState extends ConsumerState<_SodaLoginDialog> {
  Timer? _poll;
  final TextEditingController _codeCtrl = TextEditingController();

  Uint8List? _qrBytes;
  bool _loading = true;
  bool _expired = false;
  bool _confirmed = false;
  bool _mfa = false;
  bool _smsSent = false;
  bool _sending = false;
  String _error = '';
  String _hint = '';
  String _mobile = '';

  SodaAuth get _auth => ref.read(sodaAuthProvider);

  @override
  void initState() {
    super.initState();
    _createQr();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _createQr() async {
    setState(() {
      _loading = true;
      _expired = false;
      _confirmed = false;
      _mfa = false;
      _smsSent = false;
      _error = '';
      _hint = '';
      _mobile = '';
      _qrBytes = null;
    });
    _poll?.cancel();
    try {
      final session = await _auth.qrKey();
      if (!mounted) return;
      setState(() {
        _qrBytes = _dataUrlToBytes(session.imageUrl);
        _loading = false;
        if (_qrBytes == null) {
          _error = '二维码获取失败（无图片数据）';
        }
      });
      if (_qrBytes == null) return;
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
    if (_expired || _confirmed || _mfa || _loading) return;
    try {
      final r = await _auth.qrCheck();
      if (!mounted) return;
      switch (r.status) {
        case SodaLoginStatus.success:
          _poll?.cancel();
          setState(() {
            _confirmed = true;
            _hint = context.l10n.loginSuccess;
          });
          Navigator.of(context).pop(true);
          toast(context.l10n.loginSuccess);
        case SodaLoginStatus.expired:
          _poll?.cancel();
          setState(() {
            _expired = true;
            _error = context.l10n.loginQrExpiredRegenerate;
          });
        case SodaLoginStatus.mfaRequired:
          _poll?.cancel();
          setState(() {
            _mfa = true;
            _mobile = r.mobile;
            _hint = '该账号需要短信验证';
          });
          unawaited(_sendCode());
        case SodaLoginStatus.scanned:
          setState(() => _hint = context.l10n.loginWaitingConfirm);
        case SodaLoginStatus.waiting:
          setState(() => _hint = _scanHint(context.l10n));
        case SodaLoginStatus.smsSent:
        case SodaLoginStatus.failed:
          break;
      }
    } catch (_) {
      // 轮询失败静默，下一轮自动重试
    }
  }

  Future<void> _sendCode() async {
    if (_sending || _smsSent) return;
    setState(() => _sending = true);
    try {
      final r = await _auth.sendSmsCode();
      if (!mounted) return;
      setState(() {
        _sending = false;
        if (r.status == SodaLoginStatus.smsSent) {
          _smsSent = true;
          _hint = r.message;
        } else {
          _error = r.message;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = '$e';
      });
    }
  }

  Future<void> _validate() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = context.l10n.loginCodeRequired);
      return;
    }
    setState(() {
      _sending = true;
      _error = '';
    });
    try {
      final r = await _auth.validateSmsCode(code);
      if (!mounted) return;
      if (r.status == SodaLoginStatus.success) {
        setState(() {
          _confirmed = true;
          _sending = false;
          _hint = context.l10n.loginSuccess;
        });
        Navigator.of(context).pop(true);
        toast(context.l10n.loginSuccess);
      } else {
        setState(() {
          _sending = false;
          _error = r.message.isNotEmpty ? r.message : context.l10n.loginFailed;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = '$e';
      });
    }
  }

  static Uint8List? _dataUrlToBytes(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    if (comma <= 0) return null;
    try {
      return base64Decode(dataUrl.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  String _scanHint(AppLocalizations l10n) =>
      '请使用汽水音乐 App 扫码登录';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(),
      child: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
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
                            '${l10n.platformSoda} · ${l10n.navHeaderQrLogin}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: 300,
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
                            child: _mfa
                                ? _buildMfa(scheme, l10n)
                                : _buildQr(scheme, l10n),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 24,
                            child: Center(
                              child: Text(
                                _loading
                                    ? l10n.loginFetchingQr
                                    : _confirmed
                                    ? l10n.loginSuccess
                                    : _hint,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _expired
                                      ? scheme.error
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
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

  Widget _buildQr(ColorScheme scheme, AppLocalizations l10n) {
    if (_loading) {
      return const SizedBox(
        height: 260,
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (_error.isNotEmpty && _qrBytes == null) {
      return SizedBox(height: 260, child: _buildError(scheme, l10n));
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        Image.memory(
          _qrBytes!,
          width: 260,
          height: 260,
          fit: BoxFit.contain,
        ),
        if (_expired)
          _overlay(
            scheme,
            FilledButton.icon(
              onPressed: _createQr,
              icon: const Icon(EtaIcons.refresh, size: 18),
              label: Text(l10n.loginRefreshQr),
            ),
          ),
      ],
    );
  }

  Widget _buildMfa(ColorScheme scheme, AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(EtaIcons.safetyCertificateOutline, size: 40, color: Colors.black87),
        const SizedBox(height: 12),
        Text(
          _mobile.isEmpty
              ? '需要短信验证'
              : '验证码已发送至 $_mobile',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black87, fontSize: 13),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeCtrl,
          keyboardType: TextInputType.number,
          maxLength: 6,
          enabled: !_confirmed,
          decoration: InputDecoration(
            counterText: '',
            hintText: l10n.loginCodeHint,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: (_sending || !_smsSent || _confirmed)
                    ? null
                    : _sendCode,
                child: Text(l10n.loginSendCode),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: (_sending || _confirmed) ? null : _validate,
                child: Text(l10n.loginSubmit),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _overlay(ColorScheme scheme, Widget child) => Container(
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
