// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 登录风险提示：用户点击登录时先明确告知风险，确认后才进入登录流程。
///
/// 所有平台（NetEase / Kugou / QQ）登录入口统一先弹本提示，避免用户在不知情
/// 的情况下授权第三方客户端访问账号。
library;

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import 's_dialog.dart';

/// 弹出登录风险提示。返回 `true` 表示用户已阅读并同意继续登录。
Future<bool> showLoginRiskNotice(BuildContext context) async {
  final l10n = context.l10n;
  final ok = await SDialog.show<bool>(
    context,
    title: l10n.loginRiskTitle,
    width: 460,
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(l10n.commonCancel),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        child: Text(l10n.loginRiskAgree),
      ),
    ],
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 340),
      child: SingleChildScrollView(
        child: Text(
          l10n.loginRiskBody,
          style: const TextStyle(fontSize: 13, height: 1.7),
        ),
      ),
    ),
  );
  return ok == true;
}
