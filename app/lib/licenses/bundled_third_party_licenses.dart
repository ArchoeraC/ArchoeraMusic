// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 随包第三方开源组件与其许可正文（`assets/licenses/`）。
///
/// 「关于 → 第三方开源许可」弹窗展示**随包内嵌的原生 / 托管依赖**（各原生模块
/// 编译期内嵌或动态链接的第三方库，清单见根 `THIRD-PARTY-NOTICES.md`）以及
/// **Dart/Flutter 包（pub 依赖）**的许可正文。许可正文为法定文本，不随界面
/// 语言翻译；正文以资源文件形式随包分发，并随发布产物 `licenses/` 一并拷贝
/// （见 `app/core/bundle-licenses.sh`）。
///
/// - 原生依赖：本文件静态登记（编译期已知），按**同一份许可正文**分组聚合。
/// - pub 依赖：运行时聚合 Flutter 的 [LicenseRegistry]（各包经其 LICENSE 文件
///   自行注册），无需额外依赖。
///
/// 本清单只逐项登记**直接依赖**与少数关键传递依赖；大量传递依赖（Rust crates、
/// Go modules 等）按模块并入**分组条目**，逐项清单以随包
/// `licenses/<模块>-THIRD-PARTY-LICENSES.md` 为准（弹窗引言已声明）。
library;

import 'package:flutter/foundation.dart'
    show LicenseParagraph, LicenseRegistry, LicenseEntry;
import 'package:flutter/services.dart' show rootBundle;

/// 单条随包第三方依赖：组件名 +（可选）版本 + 许可标识 + 上游主页 + 许可正文资源。
///
/// [assetPath] 为空表示该组件以**公有领域 / 零条款宽松许可**分发，或为**动态链接的
/// 系统库**（其许可正文见上游、未随包附文本）；弹窗会并入「公有领域 / 无随包正文」说明段。
class BundledThirdPartyLicense {
  const BundledThirdPartyLicense({
    required this.name,
    this.version,
    required this.licenseId,
    required this.homeUrl,
    this.assetPath,
  });

  final String name;
  final String? version;
  final String licenseId;
  final String homeUrl;
  final String? assetPath;

  /// 名称 + 版本（用于分组标题与上游清单）。
  String get displayName => version == null ? name : '$name $version';
}

/// 随包第三方依赖清单（顺序即弹窗内分组出现顺序；同 [assetPath] 的条目合并为一组）。
const List<BundledThirdPartyLicense> bundledThirdPartyLicenses = [
  // ---- scanner / indexer（C#，NuGet） ---------------------------------------
  BundledThirdPartyLicense(
    name: 'ToolGood.Words',
    version: '3.1.0.3',
    licenseId: 'Apache-2.0',
    homeUrl: 'https://github.com/toolgood/ToolGood.Words',
    assetPath: 'assets/licenses/Apache-2.0.txt',
  ),
  BundledThirdPartyLicense(
    name: 'SQLitePCLRaw.lib.e_sqlite3',
    version: '3.53.3',
    licenseId: 'Apache-2.0',
    homeUrl: 'https://github.com/ericsink/SQLitePCL.raw',
    assetPath: 'assets/licenses/Apache-2.0.txt',
  ),
  BundledThirdPartyLicense(
    name: 'Microsoft.Data.Sqlite',
    version: '10.0.12',
    licenseId: 'MIT',
    homeUrl: 'https://github.com/dotnet/efcore',
    assetPath: 'assets/licenses/MIT.txt',
  ),
  BundledThirdPartyLicense(
    name: 'TagLibSharp',
    version: '2.3.0',
    licenseId: 'LGPL-2.1',
    homeUrl: 'https://github.com/mono/taglib-sharp',
    assetPath: 'assets/licenses/LGPL-2.1.txt',
  ),

  // ---- 随包内嵌 / 动态链接的运行库 ------------------------------------------
  BundledThirdPartyLicense(
    name: 'TagLib',
    licenseId: 'LGPL-2.1-or-later / MPL-1.1',
    homeUrl: 'https://taglib.org',
    assetPath: 'assets/licenses/LGPL-2.1.txt',
  ),
  BundledThirdPartyLicense(
    name: 'libopus',
    licenseId: 'BSD-3-Clause',
    homeUrl: 'https://opus-codec.org',
    assetPath: 'assets/licenses/BSD-3-Clause.txt',
  ),
  BundledThirdPartyLicense(
    name: 'FFmpeg',
    version: '9.0.1',
    licenseId: 'LGPL-3.0-or-later（Linux/macOS）/ LGPL-2.1-or-later（Windows）',
    homeUrl: 'https://ffmpeg.org',
    assetPath: 'assets/licenses/LGPL-3.0.txt',
  ),
  BundledThirdPartyLicense(
    name: 'SQLite / FTS5',
    licenseId: 'Public Domain（公有领域）',
    homeUrl: 'https://sqlite.org',
  ),
  BundledThirdPartyLicense(
    name: 'Unicode',
    version: 'Unihan kDefinition / NFKC 等数据',
    licenseId: 'Unicode License v3',
    homeUrl: 'https://www.unicode.org/license.txt',
    assetPath: 'assets/licenses/Unicode-License.txt',
  ),
  BundledThirdPartyLicense(
    name: 'miniaudio',
    licenseId: 'MIT-0 / Public Domain',
    homeUrl: 'https://github.com/mackron/miniaudio',
  ),

  // ---- audio-engine（C 引擎 + Zig 解码内核） --------------------------------
  BundledThirdPartyLicense(
    name: 'mbedTLS',
    version: '3.6.2',
    licenseId: 'Apache-2.0',
    homeUrl: 'https://github.com/Mbed-TLS/mbedtls',
    assetPath: 'assets/licenses/Apache-2.0.txt',
  ),
  BundledThirdPartyLicense(
    name: 'OpenCORE / PV-AMR',
    licenseId: 'Apache-2.0',
    homeUrl: 'https://android.googlesource.com/platform/external/opencore',
    assetPath: 'assets/licenses/Apache-2.0.txt',
  ),
  BundledThirdPartyLicense(
    name: 'signalsmith-stretch',
    version: '0.1.3',
    licenseId: 'MIT',
    homeUrl: 'https://github.com/Signalsmith-Audio/signalsmith-stretch',
    assetPath: 'assets/licenses/MIT.txt',
  ),
  BundledThirdPartyLicense(
    name: 'WavPack',
    licenseId: 'BSD-3-Clause',
    homeUrl: 'https://www.wavpack.com',
    assetPath: 'assets/licenses/BSD-3-Clause.txt',
  ),
  BundledThirdPartyLicense(
    name: 'dsd2pcm',
    licenseId: 'BSD-3-Clause',
    homeUrl: 'https://code.google.com/archive/p/dsd2pcm/',
    assetPath: 'assets/licenses/BSD-3-Clause.txt',
  ),
  BundledThirdPartyLicense(
    name: 'kissfft',
    licenseId: 'BSD-3-Clause',
    homeUrl: 'https://github.com/mborgerding/kissfft',
    assetPath: 'assets/licenses/BSD-3-Clause.txt',
  ),
  BundledThirdPartyLicense(
    name: 'minimp3',
    licenseId: 'CC0-1.0',
    homeUrl: 'https://github.com/lieff/minimp3',
    assetPath: 'assets/licenses/CC0-1.0.txt',
  ),
  BundledThirdPartyLicense(
    name: 'stb_vorbis',
    version: 'v1.22',
    licenseId: 'Public Domain / MIT-0',
    homeUrl: 'https://github.com/nothings/stb',
    assetPath: 'assets/licenses/MIT-0.txt',
  ),

  // ---- scraper（C++） ------------------------------------------------------
  BundledThirdPartyLicense(
    name: 'libcurl',
    licenseId: 'curl License（MIT/X 派生）',
    homeUrl: 'https://curl.se/docs/copyright.html',
  ),
  BundledThirdPartyLicense(
    name: 'OpenSSL',
    licenseId: 'Apache-2.0',
    homeUrl: 'https://www.openssl.org',
    assetPath: 'assets/licenses/Apache-2.0.txt',
  ),
  BundledThirdPartyLicense(
    name: 'SQLite3',
    licenseId: 'Public Domain（公有领域）',
    homeUrl: 'https://sqlite.org',
  ),
  BundledThirdPartyLicense(
    name: 'nlohmann_json',
    licenseId: 'MIT',
    homeUrl: 'https://github.com/nlohmann/json',
    assetPath: 'assets/licenses/MIT.txt',
  ),

  // ---- subsonic / transcoder（Rust） ---------------------------------------
  BundledThirdPartyLicense(
    name: 'symphonia',
    version: '0.5',
    licenseId: 'MPL-2.0',
    homeUrl: 'https://github.com/pdeljanov/Symphonia',
    assetPath: 'assets/licenses/MPL-2.0.txt',
  ),
  BundledThirdPartyLicense(
    name: 'mp3lame-encoder / mp3lame-sys',
    version: '0.2',
    licenseId: 'LGPL-3.0',
    homeUrl: 'https://crates.io/crates/mp3lame-encoder',
    assetPath: 'assets/licenses/LGPL-3.0.txt',
  ),

  // ---- downloader / shell / subsonic（Go）：大量传递依赖按模块归入分组条目 ---
  //      逐项清单（含传递依赖）随包 licenses/<模块>-THIRD-PARTY-LICENSES.md。
  BundledThirdPartyLicense(
    name: 'downloader — Rust crates（tokio/serde/RustCrypto 等）',
    licenseId: 'MIT / Apache-2.0',
    homeUrl: 'https://crates.io',
    assetPath: 'assets/licenses/Apache-2.0.txt',
  ),
  BundledThirdPartyLicense(
    name: 'shell — Rust crates（serde_json/indexmap/libc 等）',
    licenseId: 'MIT / Apache-2.0',
    homeUrl: 'https://crates.io',
    assetPath: 'assets/licenses/Apache-2.0.txt',
  ),
  BundledThirdPartyLicense(
    name: 'subsonic（Go）— Go modules（chi/uuid/modernc 等）',
    licenseId: 'MIT / BSD-3-Clause',
    homeUrl: 'https://pkg.go.dev',
    assetPath: 'assets/licenses/BSD-3-Clause.txt',
  ),
  BundledThirdPartyLicense(
    name: 'memchr',
    version: '2',
    licenseId: 'Unlicense / MIT',
    homeUrl: 'https://github.com/BurntSushi/memchr',
    assetPath: 'assets/licenses/Unlicense.txt',
  ),
  BundledThirdPartyLicense(
    name: 'ncm-api-rs',
    licenseId: 'WTFPL（默认关闭，仅 feature 切换时拉取）',
    homeUrl: 'https://github.com/SPlayer-Dev/ncm-api-rs',
    assetPath: 'assets/licenses/WTFPL.txt',
  ),
];

/// 随包分发的**通用许可正文**资源（不含字体 / 图标官方正文，那由「字体署名」
/// 弹窗负责，见 `bundled_font_licenses.dart`）。
///
/// 供 [loadBundledThirdPartyLicenseSections] 兜底：未被任何
/// [bundledThirdPartyLicenses] 条目直接引用的正文，以「其他随包许可正文」列出，
/// 避免随包文本有名无实。
const List<String> bundledLicenseTextAssets = [
  // 本程序自身的第一方许可（GNU AGPL-3.0-or-later，仓库根 `LICENSE` 的随包副本）；
  // 未被第三方组件引用，故在弹窗末尾以「其他随包许可正文」列出。
  'assets/licenses/AGPL-3.0.txt',
  'assets/licenses/Apache-2.0.txt',
  'assets/licenses/MIT.txt',
  'assets/licenses/BSD-3-Clause.txt',
  'assets/licenses/ISC.txt',
  'assets/licenses/MPL-2.0.txt',
  'assets/licenses/LGPL-2.1.txt',
  'assets/licenses/LGPL-3.0.txt',
  'assets/licenses/MIT-0.txt',
  'assets/licenses/CC0-1.0.txt',
  'assets/licenses/Unlicense.txt',
  'assets/licenses/WTFPL.txt',
  'assets/licenses/Unicode-License.txt',
];

/// 读出随包第三方依赖的许可正文，**按许可正文分组**供弹窗分段展示。
///
/// 同一 [BundledThirdPartyLicense.assetPath] 的多个组件合并为一条：标题为
/// `「许可标识」—「组件 a、组件 b」`，正文先列各组件上游链接，再附完整许可正文。
/// 正文以 `\n\n` 起始（弹窗把「标题 + 正文」渲染为同一段富文本，需显式换行）。
/// [BundledThirdPartyLicense.assetPath] 为空的条目归入一条「公有领域 / 无随包正文」说明；
/// [bundledLicenseTextAssets] 中未被引用的正文以「其他随包许可正文」兜底列出。
/// 资源缺失时降级为空正文（不阻断弹窗）。
Future<List<(String, String)>> loadBundledThirdPartyLicenseSections() async {
  final groups = <String, List<BundledThirdPartyLicense>>{};
  final noText = <BundledThirdPartyLicense>[];
  for (final license in bundledThirdPartyLicenses) {
    final path = license.assetPath;
    if (path == null) {
      noText.add(license);
    } else {
      groups.putIfAbsent(path, () => []).add(license);
    }
  }

  final sections = <(String, String)>[];
  for (final entry in groups.entries) {
    final licenses = entry.value;
    final title =
        '${licenses.first.licenseId} — '
        '${licenses.map((l) => l.displayName).join('、')}';
    String body;
    try {
      body = await rootBundle.loadString(entry.key);
    } catch (_) {
      body = '';
    }
    final upstream = licenses
        .map((l) => '· ${l.displayName}：${l.homeUrl}')
        .join('\n');
    sections.add((title, '\n\n上游项目：\n$upstream\n\n$body'));
  }

  if (noText.isNotEmpty) {
    final items = noText
        .map((l) => '· ${l.displayName}（${l.licenseId}）— ${l.homeUrl}')
        .join('\n');
    sections.add((
      '公有领域 / 无随包正文 — ${noText.map((l) => l.name).join('、')}',
      '\n\n以下组件以**公有领域（Public Domain）**、**零条款宽松许可**分发，或作为'
          '**系统库动态链接**（其许可正文见上游、未随包附文本）：\n$items\n\n'
          '（完整清单另见随包 `licenses/` 目录与 `THIRD-PARTY-NOTICES.md`。）',
    ));
  }

  // 兜底：随包分发但未被上方任何组件直接引用的许可正文（如经 pub 依赖或
  // 字体 / 图标来源使用），避免「有名无实」。
  for (final path in bundledLicenseTextAssets) {
    if (groups.containsKey(path)) continue;
    final name = path.split('/').last.replaceFirst(RegExp(r'\.txt$'), '');
    String body;
    try {
      body = await rootBundle.loadString(path);
    } catch (_) {
      body = '';
    }
    if (body.trim().isEmpty) continue;
    sections.add((
      '其他随包许可正文 — $name',
      '\n\n随包分发、但未被上方随包组件直接引用的许可正文'
          '（可能经 Dart / pub 依赖或字体 / 图标来源使用）：\n\n$body',
    ));
  }

  return sections;
}

/// 汇总 Flutter [LicenseRegistry] 中登记的许可，得到 **Dart/Flutter 包（pub 依赖）**
/// 的许可分组（按包名聚合其全部段落）。
///
/// 各包在编译期经其 `LICENSE` 文件向 [LicenseRegistry] 自行注册；此处运行时聚合，
/// 从而补齐 `pubspec.lock` 中「pub 依赖缺失的许可」。正文以 `\n\n` 起始（同上约定）；
/// 测试环境中 [LicenseRegistry] 可能为空，返回空列表（不抛异常）。
Future<List<(String, String)>> loadFlutterPackageLicenseSections() async {
  final byPackage = <String, List<String>>{};
  await for (final LicenseEntry entry in LicenseRegistry.licenses) {
    final text = _renderParagraphs(entry.paragraphs);
    if (text.isEmpty) continue;
    for (final package in entry.packages) {
      byPackage.putIfAbsent(package, () => []).add(text);
    }
  }
  final names = byPackage.keys.toList()..sort();
  return [
    for (final name in names) (name, '\n\n${byPackage[name]!.join('\n\n')}'),
  ];
}

/// 把 [LicenseParagraph] 序列渲染为纯文本（缩进用两个空格，居中按无缩进处理）。
String _renderParagraphs(Iterable<LicenseParagraph> paragraphs) {
  return paragraphs
      .map((p) {
        final indent = p.indent == LicenseParagraph.centeredIndent
            ? 0
            : p.indent;
        return '${'  ' * indent}${p.text}';
      })
      .join('\n\n');
}
