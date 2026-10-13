// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 随包第三方开源依赖与其许可正文（`assets/licenses/`）回归测试：
/// 资源随包可得、分组聚合正确，且满足「第三方开源许可」弹窗的排版约定。
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/licenses/bundled_third_party_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('第三方依赖清单完整且元数据非空', () {
    expect(bundledThirdPartyLicenses, isNotEmpty);
    for (final license in bundledThirdPartyLicenses) {
      expect(license.name.trim(), isNotEmpty, reason: '组件名不应为空');
      expect(license.licenseId.trim(), isNotEmpty, reason: '许可标识不应为空');
      expect(license.homeUrl.trim(), isNotEmpty, reason: '上游链接不应为空');
    }
    // 覆盖随包原生 / 托管依赖的关键组件。
    final names = bundledThirdPartyLicenses.map((l) => l.name).toList();
    // scanner / indexer
    expect(names, contains('ToolGood.Words'));
    expect(names, contains('Microsoft.Data.Sqlite'));
    expect(names, contains('TagLibSharp'));
    // 运行库
    expect(names, contains('libopus'));
    expect(names, contains('FFmpeg'));
    expect(names, contains('Unicode'));
    // audio-engine 逐项
    expect(names, contains('mbedTLS'));
    expect(names, contains('WavPack'));
    expect(names, contains('dsd2pcm'));
    expect(names, contains('kissfft'));
    expect(names, contains('signalsmith-stretch'));
    expect(names, contains('OpenCORE / PV-AMR'));
    expect(names, contains('minimp3'));
    expect(names, contains('stb_vorbis'));
    expect(names, contains('miniaudio'));
    // scraper
    expect(names, contains('libcurl'));
    expect(names, contains('OpenSSL'));
    expect(names, contains('SQLite3'));
    expect(names, contains('nlohmann_json'));
    // subsonic / transcoder
    expect(names, contains('symphonia'));
    expect(names, contains('mp3lame-encoder / mp3lame-sys'));
    // downloader / shell / subsonic（Go）分组条目
    expect(names.any((n) => n.startsWith('downloader —')), isTrue);
    expect(names.any((n) => n.startsWith('shell —')), isTrue);
    expect(names.any((n) => n.startsWith('subsonic（Go）')), isTrue);
    expect(names, contains('memchr'));
    expect(names, contains('ncm-api-rs'));
  });

  test('assetPath 非空者对应资源随包可得且正文非空', () async {
    for (final license in bundledThirdPartyLicenses) {
      final path = license.assetPath;
      expect(
        path,
        anyOf(isNull, startsWith('assets/licenses/')),
        reason: '${license.name} 的许可正文须位于 assets/licenses/',
      );
      if (path == null) continue;
      final body = await rootBundle.loadString(path);
      expect(body.trim(), isNotEmpty, reason: '「$path」正文不应为空');
    }
  });

  test('通用许可正文清单（bundledLicenseTextAssets）全部随包可得', () async {
    // 13 类随包许可正文（含本程序第一方 AGPL-3.0；字体 / 图标正文由「字体署名」弹窗负责，不在此列）。
    expect(bundledLicenseTextAssets, hasLength(13));
    for (final path in bundledLicenseTextAssets) {
      expect(path, startsWith('assets/licenses/'));
      final body = await rootBundle.loadString(path);
      expect(body.trim(), isNotEmpty, reason: '「$path」正文不应为空');
    }
  });

  test('原生依赖分组：按许可正文合并、正文以换行起始', () async {
    final sections = await loadBundledThirdPartyLicenseSections();
    expect(sections, isNotEmpty);

    final titles = sections.map((s) => s.$1).toList();
    // Apache-2.0 组应合并 ToolGood.Words 与 SQLitePCLRaw（及 mbedTLS / OpenSSL …）。
    final apache = titles.firstWhere((t) => t.startsWith('Apache-2.0'));
    expect(apache, contains('ToolGood.Words'));
    expect(apache, contains('SQLitePCLRaw.lib.e_sqlite3'));
    expect(apache, contains('mbedTLS'));
    expect(apache, contains('OpenSSL'));
    // BSD-3-Clause 组应合并 libopus / WavPack / kissfft 等。
    final bsd = titles.firstWhere((t) => t.startsWith('BSD-3-Clause'));
    expect(bsd, contains('libopus'));
    expect(bsd, contains('WavPack'));
    expect(bsd, contains('kissfft'));

    final all = sections.map((s) => s.$2).join('\n');
    expect(all, contains('Apache License'));
    expect(all, contains('MIT License'));
    expect(all, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
    expect(all, contains('UNICODE LICENSE V3'));
    expect(all, contains('Redistribution and use in source and binary forms'));
    expect(all, contains('Mozilla Public License Version 2.0'));

    for (final (title, body) in sections) {
      expect(title.trim(), isNotEmpty);
      expect(body.trim(), isNotEmpty, reason: '「$title」正文不应为空');
      expect(body.startsWith('\n\n'), isTrue, reason: '正文须以换行起始（与标题分段渲染）');
    }
  });

  test('空 assetPath 条目归入「公有领域 / 无随包正文」说明且不崩', () async {
    final noText = bundledThirdPartyLicenses
        .where((l) => l.assetPath == null)
        .toList();
    // 公有领域 / 系统库动态链接：SQLite、miniaudio、libcurl 等。
    expect(noText, isNotEmpty);
    expect(noText.map((l) => l.name), contains('libcurl'));

    final sections = await loadBundledThirdPartyLicenseSections();
    final titles = sections.map((s) => s.$1).toList();
    final noteTitle = titles.firstWhere(
      (t) => t.startsWith('公有领域 / 无随包正文'),
      orElse: () => '',
    );
    expect(noteTitle, isNotEmpty, reason: '空 assetPath 条目须归入说明段');

    final note = sections.firstWhere((s) => s.$1 == noteTitle).$2;
    for (final license in noText) {
      expect(
        note,
        contains(license.name),
        reason: '「${license.name}」应出现在无正文说明中',
      );
    }
  });

  test('13 类随包许可正文：要么被组件引用、要么弹窗末尾兜底列出', () async {
    final sections = await loadBundledThirdPartyLicenseSections();
    final titles = sections.map((s) => s.$1).toList();

    for (final path in bundledLicenseTextAssets) {
      final referenced = bundledThirdPartyLicenses.any(
        (l) => l.assetPath == path,
      );
      final name = path.split('/').last.replaceFirst(RegExp(r'\.txt$'), '');
      if (!referenced) {
        // 未被任何组件引用者，必须在弹窗末尾兜底列出。
        expect(
          titles,
          contains('其他随包许可正文 — $name'),
          reason: '未被引用的「$path」应在弹窗末尾兜底列出',
        );
      }
    }
    // ISC 当前未被任何随包原生组件直接引用 → 走兜底分支。
    expect(
      titles,
      contains('其他随包许可正文 — ISC'),
      reason: 'ISC 正文应被兜底列出',
    );
  });

  test('Dart/Flutter 包分组：可解析（测试环境可能为空）', () async {
    // LicenseRegistry 在测试环境通常无登记；此调用不得抛异常。
    final sections = await loadFlutterPackageLicenseSections();
    for (final (title, body) in sections) {
      expect(title.trim(), isNotEmpty);
      expect(body.startsWith('\n\n'), isTrue);
    }
  });
}
