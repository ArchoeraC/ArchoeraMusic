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
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'netease_login_dialog/netease_login_dialog_view.dart';

/// NT扫码登录（全屏毛玻璃页，QR 居中放大：unikey → qrurl → 2s 轮询
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
  Widget build(BuildContext context) => _buildNeteaseLoginDialog(context);
}
