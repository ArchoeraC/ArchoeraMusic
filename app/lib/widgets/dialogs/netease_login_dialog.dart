// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../common/qr_image_view.dart';

import '../../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import 'login_risk_notice.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'netease_login_dialog/netease_login_dialog_view.dart';

/// NT 登录（全屏毛玻璃页，三种方式 tab：扫码 / 手机号 / 邮箱）。
///
/// - 扫码：unikey → qrurl → 用户扫码并在手机确认后手动触发 loginQrCheck，803 成功；
/// - 手机号：captcha_sent 发验证码 → login_cellphone；
/// - 邮箱：login（邮箱 + 密码）。
///
/// 登录成功后刷新 [neteaseAuthProvider] 并自动关闭；点击面板以外任意处
/// （含 Esc）关闭，无关闭键。进入前先弹「登录风险提示」。
Future<void> showNeteaseLoginDialog(BuildContext context) async {
  if (!await showLoginRiskNotice(context)) return;
  if (!context.mounted) return;
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
  /// 当前选中 tab：0=扫码 / 1=手机号 / 2=邮箱（tab 栏高亮，立即切换）。
  int _tab = 0;

  /// 当前实际渲染的 tab（延后于 [_tab]：旧内容先淡出，再换内容淡入）。
  int _displayTab = 0;

  /// 切换中（旧内容淡出阶段，透明度 0）。
  bool _switching = false;

  // ── 扫码 ──────────────────────────────────────────────────────────
  Timer? _poll;
  String _qrUrl = '';
  String _unikey = '';
  bool _loading = true;
  bool _checking = false;
  bool _expired = false;
  bool _confirmed = false;
  String _status = '';
  String _error = '';

  // ── 手机号 ────────────────────────────────────────────────────────
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _phoneBusy = false;
  int _codeCountdown = 0;
  Timer? _codeTimer;
  String _phoneError = '';

  // ── 邮箱 ──────────────────────────────────────────────────────────
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _emailBusy = false;
  String _emailError = '';

  @override
  void initState() {
    super.initState();
    _createQr();
  }

  @override
  void dispose() {
    _poll?.cancel();
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
      _tab = tab; // tab 栏高亮立即切换
      _switching = true; // 旧内容开始淡出
    });
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    setState(() => _displayTab = tab); // 换内容（此刻不可见）
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    setState(() => _switching = false); // 新内容淡入
  }

  // ── 扫码 ──────────────────────────────────────────────────────────
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
    if (_unikey.isEmpty || _confirmed || _expired || _checking) return;
    _checking = true;
    try {
      final status = await ref.read(neteaseApiProvider).loginQrCheck(_unikey);
      if (!mounted) return;
      if (status.confirmed) {
        _poll?.cancel();
        setState(() => _confirmed = true);
        await _onLoginSuccess();
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
    } catch (e) {
      debugPrint('[netease] 检查登录异常: $e');
      if (mounted) setState(() => _status = '${context.l10n.loginFailed}: $e');
    } finally {
      _checking = false;
    }
  }

  // ── 手机号 ────────────────────────────────────────────────────────
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
      final body = await ref
          .read(neteaseApiProvider)
          .captchaSent(phone: phone);
      if (!mounted) return;
      if ((body?['code'] as num?)?.toInt() == 200) {
        _startCodeCountdown();
      } else {
        setState(
          () => _phoneError =
              body?['message']?.toString() ?? l10n.loginCodeSendFailed,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _phoneError = '$e');
    } finally {
      if (mounted) setState(() => _phoneBusy = false);
    }
  }

  void _startCodeCountdown() {
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
      final body = await ref
          .read(neteaseApiProvider)
          .loginCellphone(phone: phone, captcha: code);
      if (!mounted) return;
      if ((body?['code'] as num?)?.toInt() == 200) {
        await _onLoginSuccess();
      } else {
        setState(
          () => _phoneError = body?['message']?.toString() ?? l10n.loginFailed,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _phoneError = '$e');
    } finally {
      if (mounted) setState(() => _phoneBusy = false);
    }
  }

  // ── 邮箱 ──────────────────────────────────────────────────────────
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
      final body = await ref
          .read(neteaseApiProvider)
          .loginEmail(email: email, password: pass);
      if (!mounted) return;
      if ((body?['code'] as num?)?.toInt() == 200) {
        await _onLoginSuccess();
      } else {
        setState(
          () => _emailError = body?['message']?.toString() ?? l10n.loginFailed,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _emailError = '$e');
    } finally {
      if (mounted) setState(() => _emailBusy = false);
    }
  }

  Future<void> _onLoginSuccess() async {
    await ref.read(neteaseAuthProvider.notifier).refresh();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => _buildNeteaseLoginDialog(context);
}
