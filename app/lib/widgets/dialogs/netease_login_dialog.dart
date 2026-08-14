import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';

/// 网易云扫码登录（全屏毛玻璃页，QR 居中放大：unikey → qrurl → 2s 轮询
/// loginQrCheck）。
///
/// 803 确认成功后刷新 [neteaseAuthProvider] 并自动关闭；800 过期后显示
/// 「刷新二维码」按钮；点击二维码以外任意处（含 Esc）关闭，无关闭键。
Future<void> showNeteaseLoginDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
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
    // 全屏毛玻璃背景 + 居中实体化二维码卡片（白底 + 阴影悬浮）：
    // 标题在卡片上方、状态在下方，点击卡片以外任意处直接关闭（无关闭键）。
    // 毛玻璃直接自建 BackdropFilter（不依赖 GlassDialogSurface——它仅在
    // 图片风格下 blur，且传不透明色时 blur 会被完全盖住，两风格都显示为
    // 实底面板，看不到毛玻璃效果）。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(),
      child: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: ColoredBox(
            // 半透明面板色：主界面内容透过模糊可见，毛玻璃质感
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.8),
            child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              // 卡片区域（含上下文字）消费点击，避免误触外层关闭
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.loginNeteaseQrTitle(l10n.brandNetease),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 20),
                      // 实体化卡片：白底圆角 + 阴影悬浮，二维码需浅色底
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
                              : _error.isNotEmpty
                              ? _buildError(scheme, l10n)
                              : Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    QrImageView(
                                      data: _qrUrl,
                                      size: 260,
                                      backgroundColor: Colors.white,
                                    ),
                                    if (_expired)
                                      Container(
                                        width: 260,
                                        height: 260,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: Colors.black
                                              .withValues(alpha: 0.55),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: FilledButton.icon(
                                          onPressed: _createQr,
                                          icon: const Icon(
                                            Icons.refresh,
                                            size: 18,
                                          ),
                                          label: Text(l10n.loginRefreshQr),
                                        ),
                                      ),
                                    if (_confirmed)
                                      Container(
                                        width: 260,
                                        height: 260,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: Colors.black
                                              .withValues(alpha: 0.55),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: const Icon(
                                          Icons.check_circle,
                                          size: 48,
                                          color: Colors.white,
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 24,
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
          // 网络异常消息可能很长（含 URL/堆栈），限 4 行截断保持版面紧凑
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
