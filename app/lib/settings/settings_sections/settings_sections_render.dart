// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 性能 / 渲染 ───────────────────────────────────────────────────────

/// 性能 / 渲染分类：水纹渲染器 / 动态层半分辨率 / 损伤区裁剪 / 歌词边缘渐隐。
class RenderSection extends ConsumerWidget {
  const RenderSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    final scheme = Theme.of(context).colorScheme;
    final fps = prefs.renderFps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsCatRender,
          children: [
            SettingSliderTile(
              icon: EtaIcons.stopwatchOutline,
              title: l10n.settingsRenderFps,
              // 超过 60 FPS 追加说明：滑块变色（黄/红）不是主题色，需要解释。
              subtitle: fps > kRenderFpsWarnFrom
                  ? '${l10n.settingsRenderFpsDesc(fps: fps)} '
                        '${l10n.settingsRenderFpsWarn}'
                  : l10n.settingsRenderFpsDesc(fps: fps),
              value: fps.toDouble(),
              min: kRenderFpsMin.toDouble(),
              max: kRenderFpsMax.toDouble(),
              divisions: kRenderFpsMax - kRenderFpsMin,
              label: '$fps FPS',
              accentColor: renderFpsSliderColor(scheme, fps),
              onChanged: (v) =>
                  ref.read(appPrefsProvider.notifier).setRenderFps(v.round()),
            ),
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
            SettingTile(
              icon: EtaIcons.blurOnOutline,
              title: l10n.settingsLyricsEdgeFade,
              subtitle: l10n.settingsLyricsEdgeFadeDesc,
              trailing: DropdownButton<String>(
                value: prefs.lyricsEdgeFade,
                isDense: true,
                underline: const SizedBox.shrink(),
                borderRadius: BorderRadius.circular(10),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                icon: Icon(EtaIcons.downSmall, color: scheme.onSurfaceVariant),
                onChanged: (v) {
                  if (v == null) return;
                  ref.read(appPrefsProvider.notifier).setLyricsEdgeFade(v);
                },
                items: [
                  DropdownMenuItem(
                    value: 'wall',
                    child: Text(l10n.settingsLyricsEdgeFadeWall),
                  ),
                  DropdownMenuItem(
                    value: 'shader',
                    child: Text(l10n.settingsLyricsEdgeFadeShader),
                  ),
                  DropdownMenuItem(
                    value: 'off',
                    child: Text(l10n.settingsLyricsEdgeFadeOff),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
