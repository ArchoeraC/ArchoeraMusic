// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 关于 ──────────────────────────────────────────────────────────────

/// 关于分类：版本（长按 10 秒开启开发者模式）+ 引擎/服务端说明 +
/// 字体声明 + 免责声明。
///
/// 开发者长按逻辑（Timer/Stopwatch 计时与分类切换）由设置弹窗主 state
/// 持有，本组件通过回调接入并按需展示按住进度。
class AboutSection extends ConsumerStatefulWidget {
  const AboutSection({
    super.key,
    required this.version,
    required this.devHolding,
    required this.devHoldProgress,
    required this.onDevHoldStart,
    required this.onDevHoldCancel,
  });

  final String version;
  final bool devHolding;
  final double devHoldProgress;
  final VoidCallback onDevHoldStart;
  final VoidCallback onDevHoldCancel;

  @override
  ConsumerState<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends ConsumerState<AboutSection> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.appName,
          note: l10n.settingsAboutDesc,
          children: [
            // 长按「版本」10 秒开启开发者模式（隐藏下载接口的入口）。
            // Listener 对鼠标按住 / 触摸长按通用；悬浮弹提示 + 进度条反馈。
            Listener(
              onPointerDown: (_) => widget.onDevHoldStart(),
              onPointerUp: (_) => widget.onDevHoldCancel(),
              onPointerCancel: (_) => widget.onDevHoldCancel(),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Tooltip(
                  message: l10n.settingsDeveloperHoldHint,
                  waitDuration: const Duration(seconds: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SettingTile(
                        icon: EtaIcons.musicOutline,
                        title: l10n.settingsVersion,
                        subtitle: widget.version.isEmpty
                            ? l10n.settingsVersionUnknown
                            : l10n.settingsVersionFormat(widget.version),
                        // 官方构建徽标：二进制内水印验签通过才显示该图标；
                        // 失败/缺失则不显示（无文字、无悬浮提示）。
                        trailing: ref.watch(archoeraOfficialBuildProvider)
                            ? Icon(
                                EtaIcons.safetyCertificateOutline,
                                size: 18,
                                color: scheme.primary,
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (widget.devHolding)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: widget.devHoldProgress,
                              minHeight: 3,
                              backgroundColor: scheme.primary.withValues(
                                alpha: 0.12,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            SettingTile(
              icon: EtaIcons.chipOutline,
              title: l10n.settingsAudioEngine,
              subtitle: l10n.settingsAudioEngineDesc,
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: EtaIcons.serverOutline,
              title: l10n.settingsSubsonicServer,
              subtitle: l10n.settingsSubsonicDesc,
              trailing: const SizedBox.shrink(),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SettingSection(
          title: l10n.settingsSectionFontCredits,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Text(
                l10n.settingsFontCreditsText,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SettingSection(
          title: l10n.settingsSectionDeclaration,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Text.rich(
                TextSpan(
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                  children: [
                    TextSpan(text: l10n.settingsDeclineText),
                    _dense(
                      l10n.settingsDecline1Title,
                      l10n.settingsDecline1Body,
                    ),
                    _dense(
                      l10n.settingsDecline2Title,
                      l10n.settingsDecline2Body,
                    ),
                    _dense(
                      l10n.settingsDecline3Title,
                      l10n.settingsDecline3Body,
                    ),
                    _dense(
                      l10n.settingsDecline4Title,
                      l10n.settingsDecline4Body,
                    ),
                    _dense(
                      l10n.settingsDecline5Title,
                      l10n.settingsDecline5Body,
                    ),
                    TextSpan(text: l10n.settingsDeclineFooter),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  TextSpan _dense(String title, String body) {
    return TextSpan(
      children: [
        TextSpan(
          text: title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: body),
      ],
    );
  }
}
