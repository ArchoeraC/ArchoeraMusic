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
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/kugou/kugou_api.dart';
import '../../services/kugou/kugou_request.dart';
import '../../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
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
      barrierColor: Colors.transparent,
      // 空白点击由登录页全屏层处理；true 额外支持 Esc 关闭
      barrierDismissible: true,
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
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // 全屏毛玻璃背景 + 居中实体化二维码卡片（白底 + 阴影悬浮）：
    // 标题在卡片上方、状态在下方，点击卡片以外任意处直接关闭（无关闭键）。
    // 毛玻璃直接自建 BackdropFilter（不依赖 GlassDialogSurface——它仅在
    // 图片风格下 blur，且传不透明色时 blur 会被完全盖住，两风格都显示为
    // 实底面板，看不到毛玻璃效果）。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(false),
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
                        l10n.loginKugouQrLogin(l10n.brandKugou),
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
                          child: _loadingKey
                              ? const SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : _key != null
                              ? QrImageView(
                                  data: '$kgQrLoginPage?qrcode=$_key',
                                  version: QrVersions.auto,
                                  size: 260,
                                )
                              : _buildError(scheme, l10n),
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 24,
                        child: Center(
                          child: Text(
                            _statusText(l10n),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
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

  /// 错误状态（实体卡片内部）：图标 + 限行文本 + 重新生成按钮。
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
        FilledButton.tonalIcon(
          onPressed: _initQr,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.loginRegenerate),
        ),
      ],
    );
  }
}
