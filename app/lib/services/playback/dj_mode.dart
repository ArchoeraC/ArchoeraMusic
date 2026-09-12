// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Fuck DJ Mode：DJ 版 / 口水歌识别（对齐原项目 `utils/preset/djMode.ts`，
/// 并做增强，扩展词由用户自行选择）。
///
/// 基础关键词始终生效；扩展关键词需用户开启「增强筛除」；用户还可在设置里
/// 追加自定义关键词（始终生效）。
///
/// 匹配规则：
/// - **ASCII 关键词**按词边界匹配（`DJ版`、`DJ Mix`、`Remix` 命中；
///   `Adjust`、`Adjacent` 这类含 `dj` 的普通词不误伤）；
/// - **中文关键词**子串匹配；
/// - **版本号模式**：`0.8` / `0.9`（变速）与 `N.Nx`（sped up / slowed 写法）；
/// - **自定义关键词**子串匹配（大小写不敏感）。
library;

import '../netease/track.dart';

/// 基础 ASCII 关键词（始终生效）。
const List<String> _basicAscii = ['DJ'];

/// 基础中文关键词（始终生效）。
const List<String> _basicCjk = ['抖音', '网红', '车载', '热歌', '慢摇'];

/// 扩展 ASCII 关键词（用户开启「增强筛除」后生效）。
///
/// 含指向性较弱、可能误伤普通歌名的词（`MIX` / `BOUNCE` / `HARDSTYLE`）——
/// 默认不启用，交由用户自行选择。
const List<String> _enhancedAscii = [
  'REMIX',
  'MIX',
  'NIGHTCORE',
  'MASHUP',
  'BOOTLEG',
  'BOUNCE',
  'HARDSTYLE',
  'SPED UP',
  'SLOWED',
  '8D',
];

/// 扩展中文关键词（用户开启「增强筛除」后生效）。
const List<String> _enhancedCjk = [
  '快手',
  '串烧',
  '喊麦',
  '土嗨',
  '口水',
  '电音',
  '蹦迪',
  '慢速',
  '加速',
  '降速',
];

/// 版本号模式：`0.8` / `0.9`（变速），或 `N.Nx`（sped up / slowed 常见写法）。
/// 边界约束避免命中 `10.8` 这类正常数字。
final RegExp _versionPattern = RegExp(
  r'(?<![0-9])0\.[89](?![0-9])|(?<![0-9A-Za-z])[0-9]\.[0-9]x(?![0-9A-Za-z])',
  caseSensitive: false,
);

/// 判断曲目是否为 DJ 混音 / 口水歌（Fuck DJ Mode 开启时跳过）。
///
/// [enhanced] 开启扩展关键词；[custom] 为自定义关键词（逗号 / 分号 / 换行分隔）。
bool shouldSkipDjTrack(
  Track track, {
  bool enhanced = false,
  String custom = '',
}) {
  final text = '${track.title} ${track.artistNames} ${track.album?.name ?? ''}';
  final upper = text.toUpperCase();

  for (final k in enhanced ? [..._basicAscii, ..._enhancedAscii] : _basicAscii) {
    if (_containsToken(upper, k)) return true;
  }
  for (final k in enhanced ? [..._basicCjk, ..._enhancedCjk] : _basicCjk) {
    if (text.contains(k)) return true;
  }
  if (_versionPattern.hasMatch(text)) return true;

  for (final k in _splitKeywords(custom)) {
    if (upper.contains(k.toUpperCase())) return true;
  }
  return false;
}

/// 拆分自定义关键词（逗号 / 分号 / 换行分隔）。
List<String> _splitKeywords(String s) {
  if (s.isEmpty) return const [];
  return s
      .split(RegExp(r'[,，;；\n\r]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

/// ASCII 关键词词边界匹配：关键词两侧不能是 ASCII 字母/数字
/// （`DJ版`、`DJ Mix` 命中；`Adjust` 不命中）。
bool _containsToken(String upper, String keyword) {
  final k = keyword.toUpperCase();
  var i = upper.indexOf(k);
  while (i >= 0) {
    final before = i == 0 ? 0x20 : upper.codeUnitAt(i - 1);
    final after = i + k.length >= upper.length
        ? 0x20
        : upper.codeUnitAt(i + k.length);
    if (!_isAsciiAlnum(before) && !_isAsciiAlnum(after)) return true;
    i = upper.indexOf(k, i + 1);
  }
  return false;
}

bool _isAsciiAlnum(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A);
