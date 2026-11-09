// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 酷狗 SSA 安全验证弹窗。
///
/// 短信（v_type=32）可以在应用内完成；腾讯 TCaptcha（v_type=23）必须运行
/// 腾讯 JS，当前桌面端没有 WebView，因此明确提示用户去酷狗官方客户端完成，
/// 而不是伪造 ticket。验证结果回传给 [KugouApi]，由它在成功后只重试一次。
library;

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import '../../services/kugou/kugou_api.dart';
import '../../services/log/log.dart';
import 's_dialog.dart';

/// 弹出 SSA 验证对话框并等待用户操作。
Future<KgRiskVerifyOutcome> showKugouRiskVerifyDialog(
  BuildContext context, {
  required KugouApi api,
  required KgVerifyInfo info,
}) async {
  if (info.isSms) {
    final result = await showDialog<KgRiskVerifyOutcome>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      useRootNavigator: false,
      builder: (_) => _KugouSmsVerifyDialog(api: api, info: info),
    );
    return result ?? KgRiskVerifyOutcome.cancelled;
  }

  final l10n = context.l10n;
  final result = await SDialog.show<KgRiskVerifyOutcome>(
    context,
    title: info.isTencentCaptcha
        ? l10n.kugouRiskVerifyTcaptchaTitle
        : l10n.kugouRiskVerifyTitle,
    width: 460,
    actions: [
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, KgRiskVerifyOutcome.unsupported),
        child: Text(l10n.commonConfirm),
      ),
    ],
    child: Text(
      info.isTencentCaptcha
          ? l10n.kugouRiskVerifyTcaptchaBody
          : l10n.kugouRiskVerifyUnsupported(type: info.vType),
      style: const TextStyle(fontSize: 13, height: 1.7),
    ),
  );
  return result ?? KgRiskVerifyOutcome.cancelled;
}

class _KugouSmsVerifyDialog extends StatefulWidget {
  const _KugouSmsVerifyDialog({required this.api, required this.info});

  final KugouApi api;
  final KgVerifyInfo info;

  @override
  State<_KugouSmsVerifyDialog> createState() => _KugouSmsVerifyDialogState();
}

class _KugouSmsVerifyDialogState extends State<_KugouSmsVerifyDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    final code = _controller.text.trim();
    if (code.isEmpty) {
      setState(() => _error = l10n.kugouRiskVerifyCodeRequired);
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await widget.api.submitRiskVerify(
        widget.info,
        verifyCode: code,
      );
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(KgRiskVerifyOutcome.verified);
      } else {
        setState(() => _error = l10n.kugouRiskVerifyFailed);
      }
    } catch (e) {
      Log.e('kugou', 'SSA 短信验证提交失败: $e');
      if (mounted) setState(() => _error = l10n.kugouRiskVerifyFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SDialog(
      title: l10n.kugouRiskVerifyTitle,
      description: l10n.kugouRiskVerifySmsDescription,
      width: 420,
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => Navigator.of(context).pop(KgRiskVerifyOutcome.cancelled),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(l10n.kugouRiskVerifySubmit),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.kugouRiskVerifySmsHint,
              errorText: _error,
            ),
          ),
        ],
      ),
    );
  }
}
