import 'package:flutter/material.dart' show IconData, Icons;

import '../../l10n/generated/app_localizations.dart';

/// 设置分类（公开：流媒体页「前往设置」需指定媒体源分类）。
enum SettingsCategory {
  appearance(Icons.palette_outlined),
  playback(Icons.play_circle_outline),
  lyrics(Icons.lyrics_outlined),
  preset(Icons.healing_outlined),
  download(Icons.download_outlined),
  storage(Icons.storage_outlined),
  scrape(Icons.auto_fix_high),
  mediaSource(Icons.dns_outlined),
  about(Icons.info_outline),

  /// 开发者（隐藏分类：仅开启开发者模式后可见；开启方式为关于页
  /// 长按「版本」10 秒）。
  developer(Icons.engineering_outlined);

  const SettingsCategory(this.icon);
  final IconData icon;

  String label(AppLocalizations l10n) => switch (this) {
    appearance => l10n.settingsCatAppearance,
    playback => l10n.settingsCatPlayback,
    lyrics => l10n.settingsCatLyrics,
    preset => l10n.settingsCatPreset,
    download => l10n.settingsCatDownload,
    storage => l10n.settingsCatStorage,
    scrape => l10n.settingsCatScrape,
    mediaSource => l10n.settingsCatMediaSource,
    about => l10n.settingsCatAbout,
    developer => l10n.settingsCatDeveloper,
  };

  String subtitle(AppLocalizations l10n) => switch (this) {
    appearance => l10n.settingsAppearanceSubtitle,
    playback => l10n.settingsPlaybackSubtitle,
    lyrics => l10n.settingsLyricsSubtitle,
    preset => l10n.settingsPresetSubtitle,
    download => l10n.settingsDownloadSubtitle,
    storage => l10n.settingsStorageSubtitle,
    scrape => l10n.settingsScrapeSubtitle,
    mediaSource => l10n.settingsMediaSourceSubtitle,
    about => l10n.settingsAboutSubtitle,
    developer => l10n.settingsDeveloperSubtitle,
  };

  /// 该分类是否在设置导航中显示：开发者分类仅在开启开发者模式后出现；
  /// 下载分类（下载接口）在开发者模式下才可见。
  bool visible(bool developerMode) {
    if (this == SettingsCategory.developer) return developerMode;
    if (this == SettingsCategory.download) return developerMode;
    return true;
  }
}
