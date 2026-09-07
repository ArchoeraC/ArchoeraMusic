// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM扫码登录对话框（仅支持手机 QQ 扫码）。
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
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'qqmusic_login_dialog/qqmusic_login_dialog_view.dart';

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
      final qr = await _api.qrKey();
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
      final state = await _api.qrCheck(_key);
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
  Widget build(BuildContext context) => _buildQqMusicLoginDialog(context);
}
