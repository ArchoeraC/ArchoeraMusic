/// 酷狗登录入口 + 扫码登录对话框。
///
/// 对齐 SPlayer / MoeKoeMusic 方案：扫码登录拿 token/userid 后注入
/// v5/url 请求，即可获取 VIP 曲目。登录态存 [KugouApi.session]
///（内存；持久化后续接 drift）。
///
/// 流程：qrKey() 拿 key → 拼 `$kgQrLoginPage?qrcode=$key` 本地渲染二维码
/// → 1s 轮询 qrCheck() → status=4 时 saveSession(token, userid)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/kugou/kugou_api.dart';
import '../../services/kugou/kugou_request.dart';
import '../../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../common/glass_surface.dart';
import '../common/toast.dart';
import '../common/anim.dart';

/// 顶栏登录入口（未登录 → 「扫码登录」；已登录 → 昵称 + 「退出登录」）。
class KugouLoginButton extends ConsumerStatefulWidget {
  const KugouLoginButton({super.key});

  @override
  ConsumerState<KugouLoginButton> createState() => _KugouLoginButtonState();
}

class _KugouLoginButtonState extends ConsumerState<KugouLoginButton> {
  KugouApi get _api => ref.read(kugouApiProvider);

  Future<void> _openLogin() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      barrierDismissible: false,
      builder: (_) => const KgQrLoginDialog(),
    );
    if (ok == true && mounted) {
      setState(() {});
      _toast(context.l10n.loginKugouSuccessVip(context.l10n.brandKugou));
    }
  }

  void _logout() {
    _api.clearSession();
    setState(() {});
    _toast(context.l10n.loginLoggedOut(context.l10n.brandKugou));
  }

  void _toast(String message) => toast(message);

  @override
  Widget build(BuildContext context) {
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
              ? l10n.loginKugouQrLogin(l10n.brandKugou)
              : l10n.loginKugouSession(l10n.brandKugou),
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
                      l10n.loginLogoutWithId(nickname ?? session.userid),
                    ),
                  ),
                ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  session == null ? Icons.person_outline : Icons.person,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  session == null
                      ? l10n.loginKugouLogin(l10n.brandKugou)
                      : (nickname ?? l10n.loginKugouLoggedIn(l10n.brandKugou)),
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

/// 扫码登录对话框：展示二维码并轮询扫码状态，成功后自动关闭。
class KgQrLoginDialog extends ConsumerStatefulWidget {
  const KgQrLoginDialog({super.key});

  @override
  ConsumerState<KgQrLoginDialog> createState() => _KgQrLoginDialogState();
}

class _KgQrLoginDialogState extends ConsumerState<KgQrLoginDialog> {
  String? _key;
  String _error = '';
  bool _loadingKey = true;
  int _status = 1;
  Timer? _timer;

  KugouApi get _api => ref.read(kugouApiProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_initQr());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _initQr() async {
    setState(() {
      _loadingKey = true;
      _error = '';
      _key = null;
      _status = 1;
    });
    try {
      final key = await _api.qrKey();
      if (!mounted) return;
      setState(() {
        _key = key;
        _loadingKey = false;
      });
      _startPolling(key);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingKey = false;
        _error = '$e';
      });
    }
  }

  void _startPolling(String key) {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final state = await _api.qrCheck(key);
        if (!mounted) return;
        final status = (state['status'] as num?)?.toInt() ?? -1;
        if (status == 4) {
          _timer?.cancel();
          final token = state['token']?.toString() ?? '';
          final userid = state['userid']?.toString() ?? '';
          if (token.isEmpty || userid.isEmpty) {
            setState(
              () => _error = context.l10n.loginKugouResponseMissingToken,
            );
            return;
          }
          _api.saveSession(
            token,
            userid,
            nickname: state['nickname']?.toString(),
          );
          // 拉取头像/昵称（失败静默，头像回退昵称首字）
          unawaited(_api.refreshUserInfo());
          Navigator.of(context).pop(true);
        } else if (status == 0) {
          _timer?.cancel();
          setState(() {
            _status = 0;
            _error = context.l10n.loginQrExpiredRegenerate;
          });
        } else {
          setState(() => _status = status);
        }
      } catch (_) {
        // 轮询偶发网络错误忽略，等下一轮
      }
    });
  }

  String _statusText(AppLocalizations l10n) => switch (_status) {
    2 => l10n.loginWaitingConfirm,
    _ => l10n.loginKugouScanHint(l10n.brandKugou),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // 弹窗高度上限：视口 85%，防小窗口/高 DPI 下弹窗超过可视高度被截断
    //（内容有垂直滚动兜底，超高时滚动而非溢出）。
    final maxH = MediaQuery.sizeOf(context).height * 0.85;
    // 同网易弹窗：新版 Flutter DialogRoute 不包 Dialog（tight 全屏约束），
    // M3 AlertDialog IntrinsicWidth 会被长文本固有宽度撑到全屏；ConstrainedBox
    // 在 tight 约束下失效（enforce clamp），须先 Align 转 loose 再限宽。
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 460, maxHeight: maxH),
        child: GlassDialogSurface(
          radius: BorderRadius.circular(16),
          color: theme.colorScheme.surfaceContainerHigh,
          child: AlertDialog(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            title: Text(l10n.loginKugouQrLogin(l10n.brandKugou)),
            content: SingleChildScrollView(
              // 长错误文本（网络异常含 URL）可能在有限高度下溢出，
              // 包一层垂直滚动兜底（宽度仍由内层 SizedBox 固定 260）。
              child: SizedBox(
                width: 260,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_loadingKey)
                      const Padding(
                        padding: EdgeInsets.all(48),
                        child: CircularProgressIndicator(),
                      )
                    else if (_key != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: QrImageView(
                          data: '$kgQrLoginPage?qrcode=$_key',
                          version: QrVersions.auto,
                          size: 200,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _statusText(l10n),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      Icon(
                        Icons.error_outline,
                        size: 40,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _error,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        onPressed: _initQr,
                        icon: const Icon(Icons.refresh),
                        label: Text(l10n.loginRegenerate),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.commonCancel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
