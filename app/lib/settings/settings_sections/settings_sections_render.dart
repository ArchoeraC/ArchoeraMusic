// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 性能 / 渲染 ───────────────────────────────────────────────────────

/// 性能 / 渲染分类：水纹渲染器 / 动态层半分辨率 / 损伤区裁剪。
class RenderSection extends ConsumerWidget {
  const RenderSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsCatRender,
          children: [
            SettingSwitchTile(
              icon: EtaIcons.dashboard4Outline,
              title: l10n.settingsRippleShader,
              subtitle: l10n.settingsRippleShaderDesc,
              value: prefs.rippleShaderEnabled,
              onChanged: (value) => ref
                  .read(appPrefsProvider.notifier)
                  .setRippleRender(shader: value),
            ),
            SettingSwitchTile(
              icon: EtaIcons.magic2Outline,
              title: l10n.settingsRippleLowRes,
              subtitle: l10n.settingsRippleLowResDesc,
              value: prefs.rippleLowRes,
              onChanged: (value) => ref
                  .read(appPrefsProvider.notifier)
                  .setRippleRender(lowRes: value),
            ),
            SettingSwitchTile(
              icon: EtaIcons.flashOutline,
              title: l10n.settingsRippleDamageClip,
              subtitle: l10n.settingsRippleDamageClipDesc,
              value: prefs.rippleDamageClip,
              onChanged: (value) => ref
                  .read(appPrefsProvider.notifier)
                  .setRippleRender(damageClip: value),
            ),
          ],
        ),
      ],
    );
  }
}
