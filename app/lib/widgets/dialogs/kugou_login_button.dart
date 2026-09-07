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
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'kugou_login_button/kugou_login_button_view.dart';

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
  Widget build(BuildContext context) => _buildKugouLoginButton(context);
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
  Widget build(BuildContext context) => _buildKgQrLoginDialog(context);
}
