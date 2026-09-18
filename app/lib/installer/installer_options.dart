// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// ArchoeraOS 安装向导的候选项数据（语言 / 时区 / 键盘 / 文件系统 / 交换）。
///
/// 设计取舍：
/// - **语言**同时决定「装到目标系统的 locale」与「向导自身的界面语言」——真实
///   安装器都这么做；locale 取镜像里可用的 UTF-8 变体，界面语言映射到
///   [AppLocalizations] 支持的语言。
/// - **时区**必须是 `/usr/share/zoneinfo` 下真实存在的名字（安装器据此建
///   `/etc/localtime` 软链），所以这里是一份经校对的常用清单，而非自由输入。
/// - **键盘**是 `/usr/share/kbd/keymaps` 的布局名（写入 `/etc/vconsole.conf`）。
library;

/// 一种可选语言：系统 locale + 向导界面语言。
class InstallerLanguage {
  const InstallerLanguage({
    required this.locale,
    required this.uiLocale,
    required this.label,
    required this.detail,
  });

  /// 写入目标的 locale（如 `zh_CN.UTF-8`）。
  final String locale;

  /// 向导界面语言（[AppLocalizations] 的 locale，如 `zh_CN`）。
  final String uiLocale;

  /// 母语写法。
  final String label;

  /// 英文写法（列表副标题）。
  final String detail;
}

/// 语言清单（顺序即展示顺序）。
const installerLanguages = <InstallerLanguage>[
  InstallerLanguage(
    locale: 'zh_CN.UTF-8',
    uiLocale: 'zh_CN',
    label: '简体中文',
    detail: 'Chinese (Simplified)',
  ),
  InstallerLanguage(
    locale: 'en_US.UTF-8',
    uiLocale: 'en',
    label: 'English (US)',
    detail: 'English (United States)',
  ),
  InstallerLanguage(
    locale: 'zh_TW.UTF-8',
    uiLocale: 'zh_TW',
    label: '繁體中文',
    detail: 'Chinese (Traditional)',
  ),
  InstallerLanguage(
    locale: 'ja_JP.UTF-8',
    uiLocale: 'ja',
    label: '日本語',
    detail: 'Japanese',
  ),
  InstallerLanguage(
    locale: 'ko_KR.UTF-8',
    uiLocale: 'ko',
    label: '한국어',
    detail: 'Korean',
  ),
  InstallerLanguage(
    locale: 'de_DE.UTF-8',
    uiLocale: 'de',
    label: 'Deutsch',
    detail: 'German',
  ),
  InstallerLanguage(
    locale: 'fr_FR.UTF-8',
    uiLocale: 'fr',
    label: 'Français',
    detail: 'French',
  ),
  InstallerLanguage(
    locale: 'es_ES.UTF-8',
    uiLocale: 'es',
    label: 'Español',
    detail: 'Spanish',
  ),
];

/// 一种可选键盘布局。
class InstallerKeymap {
  const InstallerKeymap(this.name, this.label);

  /// 写入 `/etc/vconsole.conf` 的布局名。
  final String name;

  /// 展示名。
  final String label;
}

/// 键盘布局清单（常用布局；名字用 kbd 的规范名）。
const installerKeymaps = <InstallerKeymap>[
  InstallerKeymap('us', 'English (US)'),
  InstallerKeymap('gb', 'English (UK)'),
  InstallerKeymap('cn', 'Chinese'),
  InstallerKeymap('de', 'German'),
  InstallerKeymap('de-latin1', 'German (Latin-1)'),
  InstallerKeymap('fr', 'French'),
  InstallerKeymap('es', 'Spanish'),
  InstallerKeymap('it', 'Italian'),
  InstallerKeymap('pt', 'Portuguese'),
  InstallerKeymap('br-abnt2', 'Portuguese (Brazil, ABNT2)'),
  InstallerKeymap('nl', 'Dutch'),
  InstallerKeymap('be-latin1', 'Belgian'),
  InstallerKeymap('dk', 'Danish'),
  InstallerKeymap('no', 'Norwegian'),
  InstallerKeymap('se', 'Swedish'),
  InstallerKeymap('fi', 'Finnish'),
  InstallerKeymap('pl', 'Polish'),
  InstallerKeymap('cz', 'Czech'),
  InstallerKeymap('hu', 'Hungarian'),
  InstallerKeymap('ro', 'Romanian'),
  InstallerKeymap('gr', 'Greek'),
  InstallerKeymap('tr', 'Turkish'),
  InstallerKeymap('ru', 'Russian'),
  InstallerKeymap('ua', 'Ukrainian'),
  InstallerKeymap('il', 'Hebrew'),
  InstallerKeymap('jp106', 'Japanese (106)'),
  InstallerKeymap('kr', 'Korean'),
  InstallerKeymap('th', 'Thai'),
  InstallerKeymap('vn', 'Vietnamese'),
  InstallerKeymap('cf', 'Canadian French'),
  InstallerKeymap('la-latin1', 'Latin American'),
];

/// 时区清单（分组展示：区域 → 常用城市）。所有名字都在 zoneinfo 里存在。
const installerTimezones = <String, List<String>>{
  'Asia': [
    'Asia/Shanghai',
    'Asia/Urumqi',
    'Asia/Hong_Kong',
    'Asia/Taipei',
    'Asia/Tokyo',
    'Asia/Seoul',
    'Asia/Singapore',
    'Asia/Bangkok',
    'Asia/Jakarta',
    'Asia/Manila',
    'Asia/Kolkata',
    'Asia/Dubai',
    'Asia/Tehran',
    'Asia/Jerusalem',
    'Asia/Riyadh',
    'Asia/Karachi',
    'Asia/Dhaka',
    'Asia/Ho_Chi_Minh',
  ],
  'Europe': [
    'Europe/London',
    'Europe/Dublin',
    'Europe/Paris',
    'Europe/Berlin',
    'Europe/Madrid',
    'Europe/Rome',
    'Europe/Amsterdam',
    'Europe/Brussels',
    'Europe/Vienna',
    'Europe/Zurich',
    'Europe/Stockholm',
    'Europe/Oslo',
    'Europe/Copenhagen',
    'Europe/Helsinki',
    'Europe/Warsaw',
    'Europe/Prague',
    'Europe/Budapest',
    'Europe/Bucharest',
    'Europe/Athens',
    'Europe/Istanbul',
    'Europe/Kyiv',
    'Europe/Moscow',
  ],
  'America': [
    'America/New_York',
    'America/Chicago',
    'America/Denver',
    'America/Los_Angeles',
    'America/Phoenix',
    'America/Anchorage',
    'America/Toronto',
    'America/Vancouver',
    'America/Mexico_City',
    'America/Bogota',
    'America/Lima',
    'America/Santiago',
    'America/Sao_Paulo',
    'America/Argentina/Buenos_Aires',
    'America/Honolulu',
  ],
  'Africa': [
    'Africa/Cairo',
    'Africa/Johannesburg',
    'Africa/Lagos',
    'Africa/Nairobi',
    'Africa/Casablanca',
    'Africa/Algiers',
  ],
  'Oceania': [
    'Australia/Sydney',
    'Australia/Melbourne',
    'Australia/Brisbane',
    'Australia/Perth',
    'Australia/Adelaide',
    'Pacific/Auckland',
    'Pacific/Fiji',
  ],
  'Other': ['UTC'],
};

/// 扁平化的时区列表（用于搜索）。
final installerTimezoneList = <String>[
  for (final zones in installerTimezones.values) ...zones,
];

/// 根文件系统候选项（与安装器脚本的 `fs=ext4|btrfs|xfs|f2fs` 一致）。
///
/// btrfs 会建立 `@` / `@home` / `@opt` / `@cache` / `@log` 子卷布局（与维护者本机
/// 同构，见安装器脚本），因此它的交换选项只能是不使用。
const installerFilesystems = <String>['ext4', 'btrfs', 'xfs', 'f2fs'];

/// 交换候选项（`swap=none|file`；btrfs 上不支持交换文件）。
const installerSwaps = <String>['none', 'file'];

/// 主机名 / 用户名校验：小写字母开头，允许小写字母、数字、连字符，长度 1-32。
/// 与 systemd 的 hostname 规则和 useradd 的命名规则取交集。
bool isValidName(String value) =>
    RegExp(r'^[a-z][a-z0-9-]{0,31}$').hasMatch(value.trim());
