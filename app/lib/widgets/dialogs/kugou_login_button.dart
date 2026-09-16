// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// KG登录入口 + 扫码登录对话框。
///
/// 对齐 SPlayer / MoeKoeMusic 方案：扫码登录拿 token/userid 后注入
/// v5/url 请求，即可获取 VIP 曲目。登录态存 [KugouApi.session]
///（内存；持久化后续接 drift）。
///
/// 流程：qrKey() 拿 key → 拼 `$kgQrLoginPage?qrcode=$key` 本地渲染二维码
/// → 用户扫码并在手机确认后点「我已确认」触发一次 qrCheck() →
/// status=4 时 saveSession(token, userid)。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../common/glass_blur.dart';
import '../common/qr_image_view.dart';

import '../../services/kugou/kugou_api.dart';
import '../../services/kugou/kugou_request.dart';
import '../../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../common/toast.dart';
import '../common/anim.dart';
import 'login_risk_notice.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'kugou_login_button/kugou_login_button_view.dart';

/// 打开 KG 登录对话框（先弹登录风险提示，用户确认后才进入扫码登录）。
/// 返回 true 表示登录成功。
Future<bool> showKugouLoginDialog(BuildContext context) async {
  if (!await showLoginRiskNotice(context)) return false;
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    builder: (_) => const KgQrLoginDialog(),
  );
  return ok == true;
}

/// 顶栏登录入口（未登录 → 「扫码登录」；已登录 → 昵称 + 「退出登录」）。
class KugouLoginButton extends ConsumerStatefulWidget {
  const KugouLoginButton({super.key});

  @override
  ConsumerState<KugouLoginButton> createState() => _KugouLoginButtonState();
}

class _KugouLoginButtonState extends ConsumerState<KugouLoginButton> {
  KugouApi get _api => ref.read(kugouApiProvider);

  Future<void> _openLogin() async {
    final ok = await showKugouLoginDialog(context);
    if (ok && mounted) {
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
  Widget build(BuildContext context) => _buildKugouLoginButton(context);
}

/// 扫码登录对话框：展示二维码并轮询扫码状态，成功后自动关闭。
class KgQrLoginDialog extends ConsumerStatefulWidget {
  const KgQrLoginDialog({super.key});

  @override
  ConsumerState<KgQrLoginDialog> createState() => _KgQrLoginDialogState();
}

class _KgQrLoginDialogState extends ConsumerState<KgQrLoginDialog> {
  /// 当前选中 tab：0=扫码 / 1=手机号 / 2=邮箱（tab 栏高亮，立即切换）。
  int _tab = 0;

  /// 当前实际渲染的 tab（延后于 [_tab]：旧内容先淡出，再换内容淡入）。
  int _displayTab = 0;

  /// 切换中（旧内容淡出阶段，透明度 0）。
  bool _switching = false;

  // 扫码
  String? _key;
  String _error = '';
  bool _loadingKey = true;
  int _status = 1;
  Timer? _timer;

  // 手机号
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _phoneBusy = false;
  int _codeCountdown = 0;
  Timer? _codeTimer;
  String _phoneError = '';

  // 邮箱
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _emailBusy = false;
  String _emailError = '';

  KugouApi get _api => ref.read(kugouApiProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_initQr());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeTimer?.cancel();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  /// 切换方式：**全部隐藏再显示**（对齐 WebWord 登录窗）——
  /// 旧内容先整体淡出（180ms）→ 换内容并平滑动画卡片高度 → 新内容淡入。
  Future<void> _switchTab(int tab) async {
    if (_tab == tab || _switching) return;
    setState(() {
      _tab = tab;
      _switching = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    setState(() => _displayTab = tab);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    setState(() => _switching = false);
  }

  Future<void> _sendCode() async {
    final l10n = context.l10n;
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty) {
      setState(() => _phoneError = l10n.loginPhoneRequired);
      return;
    }
    setState(() {
      _phoneBusy = true;
      _phoneError = '';
    });
    try {
      await _api.captchaSent(mobile: phone);
      if (!mounted) return;
      _codeTimer?.cancel();
      setState(() => _codeCountdown = 60);
      _codeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {
          _codeCountdown--;
          if (_codeCountdown <= 0) t.cancel();
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _phoneError = '$e');
    } finally {
      if (mounted) setState(() => _phoneBusy = false);
    }
  }

  Future<void> _phoneLogin() async {
    final l10n = context.l10n;
    final phone = _phoneCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (phone.isEmpty) {
      setState(() => _phoneError = l10n.loginPhoneRequired);
      return;
    }
    if (code.isEmpty) {
      setState(() => _phoneError = l10n.loginCodeRequired);
      return;
    }
    setState(() {
      _phoneBusy = true;
      _phoneError = '';
    });
    try {
      await _api.loginByVerifyCode(mobile: phone, code: code);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _phoneError = '$e');
    } finally {
      if (mounted) setState(() => _phoneBusy = false);
    }
  }

  Future<void> _emailLogin() async {
    final l10n = context.l10n;
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    if (email.isEmpty) {
      setState(() => _emailError = l10n.loginEmailRequired);
      return;
    }
    if (pass.isEmpty) {
      setState(() => _emailError = l10n.loginPasswordRequired);
      return;
    }
    setState(() {
      _emailBusy = true;
      _emailError = '';
    });
    try {
      await _api.loginByPwd(username: email, password: pass);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _emailError = '$e');
    } finally {
      if (mounted) setState(() => _emailBusy = false);
    }
  }

  Future<void> _initQr() async {
    setState(() {
      _loadingKey = true;
      _error = '';
      _key = null;
      _status = 1;
    });
    _timer?.cancel();
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
      } catch (e) {
        debugPrint('[kugou] 检查登录异常: $e');
        if (mounted) setState(() => _error = '$e');
      }
    });
  }

  String _statusText(AppLocalizations l10n) => switch (_status) {
    2 => l10n.loginWaitingConfirm,
    _ => l10n.loginKugouScanHint(l10n.brandKugou),
  };

  @override
  Widget build(BuildContext context) => _buildKgQrLoginDialog(context);
}
