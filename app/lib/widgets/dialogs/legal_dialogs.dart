// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 关于页的三份长文弹窗：软件声明 / 隐私政策 / 字体署名。
///
/// 三者原本直接内联在关于页，篇幅很长会撑开页面；改为「点按钮才展开」的
/// 弹窗（复用 [SDialog] 的可滚动内容区）。文案来自 ARB，目前仅 zh_CN 为
/// 最新版本，其余语言待维护者补齐（缺失键会回退模板文案）。
library;

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import 's_dialog.dart';

/// 打开「软件声明」弹窗。
Future<void> showSoftwareDeclarationDialog(BuildContext context) {
  final l10n = context.l10n;
  return _showDocument(
    context,
    title: l10n.settingsSectionDeclaration,
    intro: l10n.settingsDeclineText,
    sections: [
      (l10n.settingsDecline1Title, l10n.settingsDecline1Body),
      (l10n.settingsDeclineLicenseTitle, l10n.settingsDeclineLicenseBody),
      (l10n.settingsDecline2Title, l10n.settingsDecline2Body),
      (l10n.settingsDecline3Title, l10n.settingsDecline3Body),
      (l10n.settingsDecline4Title, l10n.settingsDecline4Body),
      (l10n.settingsDeclineLoginTitle, l10n.settingsDeclineLoginBody),
      (
        l10n.settingsDeclineThirdPartyTitle,
        l10n.settingsDeclineThirdPartyBody,
      ),
      (l10n.settingsDeclineMinorTitle, l10n.settingsDeclineMinorBody),
      (l10n.settingsDecline5Title, l10n.settingsDecline5Body),
    ],
    footer: l10n.settingsDeclineFooter,
  );
}

/// 打开「隐私政策」弹窗。
Future<void> showPrivacyPolicyDialog(BuildContext context) {
  final l10n = context.l10n;
  return _showDocument(
    context,
    title: l10n.settingsSectionPrivacy,
    intro: l10n.settingsPrivacyIntro,
    sections: [
      (l10n.settingsPrivacy1Title, l10n.settingsPrivacy1Body),
      (l10n.settingsPrivacy2Title, l10n.settingsPrivacy2Body),
      (l10n.settingsPrivacy3Title, l10n.settingsPrivacy3Body),
      (l10n.settingsPrivacy4Title, l10n.settingsPrivacy4Body),
      (l10n.settingsPrivacy5Title, l10n.settingsPrivacy5Body),
      (l10n.settingsPrivacy6Title, l10n.settingsPrivacy6Body),
      (l10n.settingsPrivacy7Title, l10n.settingsPrivacy7Body),
      (l10n.settingsPrivacy8Title, l10n.settingsPrivacy8Body),
      (l10n.settingsPrivacy9Title, l10n.settingsPrivacy9Body),
    ],
    footer: l10n.settingsPrivacyFooter,
  );
}

/// 打开「字体署名」弹窗。
Future<void> showFontCreditsDialog(BuildContext context) {
  final l10n = context.l10n;
  return _showDocument(
    context,
    title: l10n.settingsSectionFontCredits,
    intro: l10n.settingsFontCreditsText,
    sections: const [],
  );
}

/// 弹出长文弹窗（标题 + 引言 + 分节 + 可选页脚）。
Future<void> _showDocument(
  BuildContext context, {
  required String title,
  required String intro,
  required List<(String, String)> sections,
  String? footer,
}) {
  return SDialog.show<void>(
    context,
    title: title,
    width: 560,
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.commonClose),
      ),
    ],
    child: _LegalDocument(intro: intro, sections: sections, footer: footer),
  );
}

/// 长文正文：引言 + 若干「小标题 + 正文」段落 + 页脚。
///
/// 正文支持 `**强调**`（成对星号内文本加粗为正文色），避免长段落全灰。
class _LegalDocument extends StatelessWidget {
  const _LegalDocument({
    required this.intro,
    required this.sections,
    this.footer,
  });

  final String intro;
  final List<(String, String)> sections;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const base = TextStyle(fontSize: 12.5, height: 1.75);
    final bodyColor = scheme.onSurfaceVariant.withValues(alpha: 0.88);
    final titleColor = scheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (intro.isNotEmpty)
          Text.rich(
            TextSpan(children: _emphasis(intro, scheme, base)),
            style: base.copyWith(color: bodyColor),
          ),
        for (final (title, body) in sections)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: title,
                    style: base.copyWith(
                      fontWeight: FontWeight.w700,
                      color: titleColor,
                    ),
                  ),
                  ..._emphasis(body, scheme, base),
                ],
              ),
              style: base.copyWith(color: bodyColor),
            ),
          ),
        if (footer != null && footer!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              footer!,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
      ],
    );
  }
}

/// 把 `**文本**` 解析为加粗 span（奇数段为强调），其余按默认正文样式。
List<InlineSpan> _emphasis(String text, ColorScheme scheme, TextStyle base) {
  final parts = text.split('**');
  return [
    for (var i = 0; i < parts.length; i++)
      if (parts[i].isNotEmpty)
        TextSpan(
          text: parts[i],
          style: i.isOdd
              ? base.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                )
              : null,
        ),
  ];
}
