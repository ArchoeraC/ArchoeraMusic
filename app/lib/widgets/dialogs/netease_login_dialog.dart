import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../common/glass_surface.dart';

/// 网易云扫码登录弹窗（QR 登录：unikey → qrurl → 2s 轮询 loginQrCheck）。
///
/// 803 确认成功后刷新 [neteaseAuthProvider] 并自动关闭；800 过期后显示
/// 「刷新二维码」按钮。
Future<void> showNeteaseLoginDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    barrierDismissible: true,
    builder: (_) => const _NeteaseLoginDialog(),
  );
}

class _NeteaseLoginDialog extends ConsumerStatefulWidget {
  const _NeteaseLoginDialog();

  @override
  ConsumerState<_NeteaseLoginDialog> createState() =>
      _NeteaseLoginDialogState();
}

class _NeteaseLoginDialogState extends ConsumerState<_NeteaseLoginDialog> {
  Timer? _poll;
  String _qrUrl = '';
  String _unikey = '';
  bool _loading = true;
  bool _expired = false;
  bool _confirmed = false;
  String _status = '';
  String _error = '';

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
      _status = '';
      _error = '';
    });
    try {
      final api = ref.read(neteaseApiProvider);
      final key = await api.loginQrKey();
      final url = await api.loginQrCreate(key);
      if (!mounted) return;
      setState(() {
        _qrUrl = url;
        _unikey = key;
        _loading = false;
      });
      _poll?.cancel();
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
    if (_unikey.isEmpty || _confirmed || _expired) return;
    try {
      final status = await ref.read(neteaseApiProvider).loginQrCheck(_unikey);
      if (!mounted) return;
      if (status.confirmed) {
        _poll?.cancel();
        setState(() => _confirmed = true);
        await ref.read(neteaseAuthProvider.notifier).refresh();
        if (!mounted) return;
        Navigator.of(context).pop();
      } else if (status.expired) {
        _poll?.cancel();
        setState(() => _expired = true);
      } else {
        setState(() {
          final l10n = context.l10n;
          _status = status.code == 802
              ? l10n.loginWaitingConfirm
              : l10n.loginNeteaseScanHint(l10n.brandNetease);
        });
      }
    } catch (_) {
      // 轮询失败静默，下一轮自动重试
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    return GlassDialogSurface(
      radius: BorderRadius.circular(16),
      color: scheme.surfaceContainerHigh,
      child: AlertDialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
        content: SizedBox(
          width: 260,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    l10n.loginNeteaseQrTitle(l10n.brandNetease),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.commonClose,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (_loading)
                const SizedBox(
                  width: 200,
                  height: 200,
                  child: Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                )
              else if (_error.isNotEmpty)
                Column(
                  children: [
                    Icon(Icons.error_outline,
                        size: 40, color: scheme.error),
                    const SizedBox(height: 12),
                    Text(
                      _error,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _createQr,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: Text(l10n.commonRetry),
                    ),
                  ],
                )
              else
                Stack(
                  alignment: Alignment.center,
                  children: [
                    // 白色底（二维码需浅色背景才能扫出）
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: QrImageView(
                          data: _qrUrl,
                          size: 200,
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                    if (_expired)
                      Container(
                        width: 200,
                        height: 200,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: FilledButton.icon(
                          onPressed: _createQr,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: Text(l10n.loginRefreshQr),
                        ),
                      ),
                    if (_confirmed)
                      Container(
                        width: 200,
                        height: 200,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.check_circle,
                            size: 48, color: Colors.white),
                      ),
                  ],
                ),
              const SizedBox(height: 16),
              SizedBox(
                height: 32,
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
    );
  }
}
