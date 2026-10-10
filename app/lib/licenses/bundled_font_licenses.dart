// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 随包内嵌的字体 / 图标许可正文（`assets/licenses/`）。
///
/// 「关于 → 字体署名」弹窗在本地化简介之后**完整展示这些官方许可正文原文**
/// （许可正文为法定文本，不随界面语言翻译）：MiSans、Manrope（SIL OFL 1.1）
/// 与自建 `EtaIcons` 的上游字形集许可（MingCute / Tabler / Lucide——均为实际
/// 并入 `EtaIcons.ttf` 的字形来源）。
///
/// 正文以资源文件形式随包分发，既满足 OFL「许可可被用户轻易查看」的要求，也便于
/// 随发布产物 `licenses/` 一并拷贝（见 `app/core/bundle-licenses.sh`）。
library;

import 'package:flutter/services.dart' show rootBundle;

/// 单条内嵌许可：`title` 为许可名（含字体/图标集与官方许可标识），
/// `assetPath` 为内嵌文本资源路径。
class BundledFontLicense {
  const BundledFontLicense(this.title, this.assetPath);

  final String title;
  final String assetPath;
}

/// 内嵌许可清单（顺序即弹窗展示顺序）。
const List<BundledFontLicense> bundledFontLicenses = [
  BundledFontLicense(
    'MiSans — MiSans Font Intellectual Property License Agreement (© Xiaomi)',
    'assets/licenses/MiSans-LICENSE.txt',
  ),
  BundledFontLicense(
    'Manrope — SIL Open Font License 1.1 (© The Manrope Project Authors)',
    'assets/licenses/Manrope-OFL-1.1.txt',
  ),
  BundledFontLicense(
    'EtaIcons — MingCute (Apache-2.0) · Tabler (MIT) · Lucide (ISC)',
    'assets/licenses/EtaIcons-LICENSES.txt',
  ),
];

/// 读出全部内嵌许可正文，供「字体署名」弹窗分段展示。
///
/// 每条正文前补 `\n\n`：弹窗把「标题 + 正文」渲染为同一段富文本，需显式换行。
/// 资源缺失时降级为空正文（不阻断弹窗）。
Future<List<(String, String)>> loadBundledFontLicenseSections() async {
  final sections = <(String, String)>[];
  for (final license in bundledFontLicenses) {
    String body;
    try {
      body = await rootBundle.loadString(license.assetPath);
    } catch (_) {
      body = '';
    }
    sections.add((license.title, '\n\n$body'));
  }
  return sections;
}
