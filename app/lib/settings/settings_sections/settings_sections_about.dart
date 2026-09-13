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
        // ── 环境信息（版本 / 平台 / 运行时，可一键复制）──────────────
        SettingSection(
          title: l10n.settingsSectionEnvInfo,
          children: [
            _envRow(
              l10n.settingsEnvVersion,
              widget.version.isEmpty
                  ? l10n.settingsVersionUnknown
                  : widget.version,
            ),
            _envRow(
              l10n.settingsEnvPlatform,
              '${Platform.operatingSystem} '
              '${Platform.operatingSystemVersion}',
            ),
            _envRow(
              l10n.settingsEnvRuntime,
              'Dart ${Platform.version.split(' ').first}',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
              child: Align(
                alignment: Alignment.centerRight,
                child: SettingCopyButton(
                  value: _envText(l10n),
                  label: l10n.settingsSectionEnvInfo,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // ── 社区与资讯（仅 GitHub 仓库地址，可复制）──────────────────
        SettingSection(
          title: l10n.settingsSectionCommunity,
          children: [
            SettingTile(
              icon: EtaIcons.serverOutline,
              title: l10n.settingsCommunityRepo,
              subtitle: _kRepoUrl,
              trailing: SettingCopyButton(
                value: _kRepoUrl,
                label: l10n.settingsCommunityRepo,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // ── 特别致谢（按类别分组列出使用 / 参考的开源项目；点条目复制链接）──
        SettingSection(
          title: l10n.settingsSectionThanks,
          children: [
            for (final group in <(String, List<_ThanksItem>)>[
              (l10n.settingsThanksDesign, _kThanksDesign),
              (l10n.settingsThanksCore, _kThanksCore),
              (l10n.settingsThanksDecoder, _kThanksDecoder),
              (l10n.settingsThanksIcons, _kThanksIcons),
            ]) ...[
              _thanksGroupLabel(group.$1, scheme),
              for (final item in group.$2) _thanksRow(item, scheme),
            ],
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
                      l10n.settingsDeclineLoginTitle,
                      l10n.settingsDeclineLoginBody,
                    ),
                    _dense(
                      l10n.settingsDeclinePrivacyTitle,
                      l10n.settingsDeclinePrivacyBody,
                    ),
                    _dense(
                      l10n.settingsDeclineThirdPartyTitle,
                      l10n.settingsDeclineThirdPartyBody,
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

  /// 项目 GitHub 仓库地址（仅展示 / 复制，不打开链接）。
  static const String _kRepoUrl =
      'https://github.com/BetaStudio2/ArchoeraMusic';

  Widget _envRow(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  String _envText(AppLocalizations l10n) {
    final v = widget.version.isEmpty
        ? l10n.settingsVersionUnknown
        : widget.version;
    return '${l10n.settingsEnvVersion}: $v\n'
        '${l10n.settingsEnvPlatform}: ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}\n'
        '${l10n.settingsEnvRuntime}: Dart '
        '${Platform.version.split(' ').first}';
  }

  /// 特别致谢分组小标题（按类别，带主题色）。
  Widget _thanksGroupLabel(String label, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }

  /// 特别致谢条目：名称 + 许可证；点击复制该项目的链接（不打开网页）。
  Widget _thanksRow(_ThanksItem item, ColorScheme scheme) {
    return InkWell(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: item.url));
        if (!mounted) return;
        toast(
          context.l10n.toastCopied(item.name),
          type: ToastType.success,
          duration: const Duration(milliseconds: 1200),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: item.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (item.license.isNotEmpty)
                      TextSpan(
                        text: '  ${item.license}',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              EtaIcons.link,
              size: 15,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}

/// 特别致谢条目（名称 / 许可证 / 链接；点条目复制链接，不打开网页）。
class _ThanksItem {
  const _ThanksItem(this.name, this.license, this.url);

  final String name;
  final String license;
  final String url;
}

const List<_ThanksItem> _kThanksDesign = [
  _ThanksItem('KuGouMusicApi', 'MIT', 'https://github.com/MakcRe/KuGouMusicApi'),
  _ThanksItem('NeteaseCloudMusicApi', 'MIT', 'https://github.com/Binaryify/NeteaseCloudMusicApi'),
  _ThanksItem('ncm-api-rs', 'WTFPL', 'https://github.com/SPlayer-Dev/ncm-api-rs'),
  _ThanksItem('MoeKoeMusic', '', 'https://github.com/MoeKoeMusic/MoeKoeMusic'),
  _ThanksItem('Mineradio', '', 'https://github.com/XxHuberrr/Mineradio'),
  _ThanksItem('AMLL (Apple Music-like Lyrics)', 'MIT', 'https://github.com/Steve-xmh/applemusic-like-lyrics'),
];

const List<_ThanksItem> _kThanksCore = [
  _ThanksItem('Flutter', 'BSD-3-Clause', 'https://flutter.dev'),
  _ThanksItem('FFmpeg', 'LGPL-2.1+', 'https://ffmpeg.org'),
  _ThanksItem('libopus', 'BSD-3-Clause', 'https://opus-codec.org'),
  _ThanksItem('TagLib', 'LGPL-2.1+ / MPL-1.1', 'https://taglib.org'),
  _ThanksItem('miniaudio', 'MIT-0 / Public Domain', 'https://github.com/mackron/miniaudio'),
  _ThanksItem('signalsmith-stretch', 'MIT', 'https://github.com/Signalsmith-Audio/signalsmith-stretch'),
  _ThanksItem('SQLite', 'Public Domain', 'https://sqlite.org'),
  _ThanksItem('libcurl', '', 'https://curl.se/libcurl/'),
  _ThanksItem('OpenSSL', 'Apache-2.0', 'https://www.openssl.org'),
  _ThanksItem('nlohmann/json', 'MIT', 'https://github.com/nlohmann/json'),
];

const List<_ThanksItem> _kThanksDecoder = [
  _ThanksItem('minimp3', 'CC0-1.0', 'https://github.com/lieff/minimp3'),
  _ThanksItem('stb_vorbis', 'Public Domain / MIT-0', 'https://github.com/nothings/stb'),
  _ThanksItem('kissfft', 'BSD-3-Clause', 'https://github.com/mborgerding/kissfft'),
  _ThanksItem('WavPack', 'BSD-3-Clause', 'https://www.wavpack.com'),
  _ThanksItem('dsd2pcm', 'BSD', 'https://github.com/Sacred-Cow/dsd2pcm'),
  _ThanksItem('OpenCORE / PV-AMR', 'Apache-2.0', 'https://android.googlesource.com/platform/external/opencore'),
];

const List<_ThanksItem> _kThanksIcons = [
  _ThanksItem('MingCute Icons', 'Apache-2.0', 'https://github.com/mingcute-design/mingcute-icons'),
  _ThanksItem('Tabler Icons', 'MIT', 'https://tabler.io/icons'),
  _ThanksItem('Lucide', 'ISC', 'https://lucide.dev'),
  _ThanksItem('line-md', 'MIT', 'https://github.com/cyberalien/line-md'),
];
