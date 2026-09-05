/// QM扫码登录对话框（仅支持手机 QQ 扫码；微信扫码已停用，入口随之移除）。
///
/// 流程：qrKey() 取 base64 二维码 → 1~2s 轮询 qrCheck() → status=4 登录成功
/// （cookie 已落盘）→ 刷新资料并关闭。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/qqmusic/qqmusic_api.dart';
import '../../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../common/toast.dart';

/// 打开 QM扫码登录弹窗。
Future<bool?> showQqMusicLoginDialog(BuildContext context) {
  return showDialog<bool?>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    builder: (_) => const _QqMusicLoginDialog(),
  );
}

class _QqMusicLoginDialog extends ConsumerStatefulWidget {
  const _QqMusicLoginDialog();

  @override
  ConsumerState<_QqMusicLoginDialog> createState() =>
      _QqMusicLoginDialogState();
}

class _QqMusicLoginDialogState extends ConsumerState<_QqMusicLoginDialog> {
  Timer? _poll;

  String _key = '';
  Uint8List? _qrBytes;
  bool _loading = true;
  bool _expired = false;
  bool _confirmed = false;
  String _error = '';
  String _hint = '';

  QqMusicApi get _api => ref.read(qqMusicApiProvider);

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
      _qrBytes = null;
    });
    _poll?.cancel();
    try {
      final qr = await _api.qrKey('qq');
      if (!mounted) return;
      final content = qr['content'] as String? ?? '';
      final bytes = _dataUrlToBytes(content);
      if (bytes == null) throw QqApiException('二维码内容格式异常');
      setState(() {
        _key = (qr['key'] ?? '').toString();
        _qrBytes = bytes;
        _loading = false;
      });
      _poll = Timer.periodic(
        const Duration(milliseconds: 1800),
        (_) => _check(),
      );
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
    if (_key.isEmpty || _confirmed || _expired) return;
    try {
      final state = await _api.qrCheck('qq', _key);
      if (!mounted) return;
      final status = (state['status'] as num?)?.toInt() ?? 1;
      if (status == 4) {
        _poll?.cancel();
        setState(() => _confirmed = true);
        await _api.afterLogin();
        if (!mounted) return;
        Navigator.of(context).pop(true);
        toast(context.l10n.loginSuccess);
      } else if (status == 0) {
        _poll?.cancel();
        setState(() {
          _expired = true;
          _error = context.l10n.loginQrExpiredRegenerate;
        });
      } else {
        setState(() {
          _hint = status == 2
              ? context.l10n.loginWaitingConfirm
              : context.l10n.loginQqScanHint;
        });
      }
    } catch (_) {
      // 轮询失败静默，下一轮自动重试
    }
  }

  /// `data:image/png;base64,...` → 图片字节。
  static Uint8List? _dataUrlToBytes(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    if (comma <= 0) return null;
    try {
      return base64Decode(dataUrl.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  String _statusText(AppLocalizations l10n) {
    if (_loading) return l10n.loginFetchingQr;
    if (_expired) return l10n.loginQrExpired;
    if (_confirmed) return l10n.loginSuccess;
    return _hint;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // 全屏毛玻璃 + 居中实体化二维码卡片（对齐 netease/kugou 登录样式）。
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
                            l10n.loginQqQrLogin,
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
                                  : _error.isNotEmpty && _qrBytes == null
                                  ? _buildError(scheme, l10n)
                                  : _qrBytes != null
                                  ? Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        Image.memory(
                                          _qrBytes!,
                                          width: 260,
                                          height: 260,
                                          fit: BoxFit.contain,
                                        ),
                                        if (_expired)
                                          Container(
                                            width: 260,
                                            height: 260,
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(
                                                alpha: 0.55,
                                              ),
                                              borderRadius: BorderRadius.circular(
                                                12,
                                              ),
                                            ),
                                            child: FilledButton.icon(
                                              onPressed: _createQr,
                                              icon: const Icon(
                                                Icons.refresh,
                                                size: 18,
                                              ),
                                              label: Text(
                                                l10n.loginRefreshQr,
                                              ),
                                            ),
                                          ),
                                        if (_confirmed)
                                          Container(
                                            width: 260,
                                            height: 260,
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(
                                                alpha: 0.55,
                                              ),
                                              borderRadius: BorderRadius.circular(
                                                12,
                                              ),
                                            ),
                                            child: const Icon(
                                              Icons.check_circle,
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

  /// 错误状态（实体卡片内部）：图标 + 限行文本 + 重试按钮。
  Widget _buildError(ColorScheme scheme, AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline, size: 48, color: scheme.error),
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
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(l10n.commonRetry),
        ),
      ],
    );
  }
}
