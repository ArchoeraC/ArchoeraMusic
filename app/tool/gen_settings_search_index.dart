// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 设置搜索索引生成器（**生成器，不是检查脚本**）。
///
/// 为什么需要它：设置项横跨 17 个 section、约 250 个标题，手工维护索引必然
/// 漏项/失效（曾出现「搜得到但跳不过」）。这里把**设置源码本身**当作唯一
/// 事实来源：扫描各 section 里 `SettingTile` / `SettingSwitchTile` /
/// `SettingSliderTile` / `SettingSection(Title)` 的 `title:` 与 `subtitle:`，
/// 生成 `lib/settings/settings/settings_search_index.g.dart`。
///
/// 设计约束：
/// - **纯文本分析**，不引入 build_runner / analyzer 依赖，产物是普通 Dart 源码；
/// - **不改变任何运行期行为**：只产出搜索用的标题表，设置页 Widget、开发者模式、
///   关于页长按 10 秒等彩蛋逻辑完全不受影响；
/// - 跳过动态标题（如 `l10n.settingsPeqBand(index: …)`）与非常量表达式，
///   避免生成编译不过的代码；
/// - 幂等：内容未变时不写文件（便于 CI 判断是否有未提交的生成结果）。
///
/// 用法（由各平台构建脚本在 `flutter build` 前调用；本地也可手动执行）：
///   dart run tool/gen_settings_search_index.dart
///   dart run tool/gen_settings_search_index.dart --check   # 仅校验是否最新
library;

import 'dart:io';

/// section 源码 → 设置分类（与 `settings_dialog_view.dart` 的分类分支一致）。
const _fileCategory = <String, String>{
  'settings_sections_appearance.dart': 'appearance',
  'settings_sections_playback.dart': 'playback',
  'settings_sections_audio_fx.dart': 'audioEffects',
  'settings_sections_lyrics.dart': 'lyrics',
  'settings_sections_preset.dart': 'preset',
  'settings_sections_render.dart': 'render',
  'settings_sections_download.dart': 'download',
  'settings_sections_storage.dart': 'storage',
  'cache_section.dart': 'storage',
  'history_section.dart': 'storage',
  'scans_section.dart': 'scanner',
  'settings_sections_scrape.dart': 'scrape',
  'search_section.dart': 'searchIndex',
  'settings_sections_mcp.dart': 'mcp',
  'settings_sections_about.dart': 'about',
  'settings_sections_developer.dart': 'developer',
  'settings_sections_experimental_source.dart': 'experimentalSource',
};

/// 分类枚举顺序（生成结果按此分组，便于人工阅读 diff）。
const _categoryOrder = <String>[
  'appearance',
  'playback',
  'audioEffects',
  'shortcuts',
  'lyrics',
  'preset',
  'render',
  'download',
  'storage',
  'scrape',
  'scanner',
  'searchIndex',
  'mediaSource',
  'experimentalSource',
  'mcp',
  'about',
  'developer',
];

/// 带标题的设置 Widget（与 `settings_widgets*.dart` 对应）。
const _titleWidgets = [
  'SettingTile',
  'SettingSwitchTile',
  'SettingSliderTile',
  'SettingSectionTitle',
  'SettingSection',
];

const _outFile = 'lib/settings/settings/settings_search_index.g.dart';

class _Entry {
  _Entry(this.category, this.titleKey, this.subtitleKey);
  final String category;
  final String titleKey;
  final String? subtitleKey;
}

void main(List<String> args) {
  final checkOnly = args.contains('--check');

  final entries = _scan();
  final generated = _render(entries);

  final file = File(_outFile);
  final exists = file.existsSync();
  final current = exists ? file.readAsStringSync() : '';

  if (current == generated) {
    stdout.writeln('[gen-settings-index] 已是最新：${entries.length} 条');
    return;
  }
  if (checkOnly) {
    stderr.writeln('[gen-settings-index] 生成结果已过期，请运行：'
        'dart run tool/gen_settings_search_index.dart');
    exit(1);
  }
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(generated);
  stdout.writeln('[gen-settings-index] 已更新 ${_outFile}：${entries.length} 条');
}

/// 扫描 `lib/settings` 下所有 section 源码。
List<_Entry> _scan() {
  final dir = Directory('lib/settings');
  if (!dir.existsSync()) {
    stderr.writeln('请在 app/ 目录下运行（找不到 lib/settings）');
    exit(2);
  }

  final seen = <String>{};
  final entries = <_Entry>[];

  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => _fileCategory.containsKey(_basename(f.path)))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final f in files) {
    final category = _fileCategory[_basename(f.path)]!;
    final source = f.readAsStringSync();
    for (final call in _widgetCalls(source)) {
      final title = _namedArg(source, call, 'title');
      if (title == null) continue;
      // 只接受「无参数」的 l10n getter：l10n.settingsXxx（后面紧跟 , 或 )）
      final titleKey = _simpleL10n(title);
      if (titleKey == null) continue;
      final subtitleKey = _simpleL10n(_namedArg(source, call, 'subtitle') ?? '');
      // 同一分类内按标题去重（锚点表也按标题文本定位，重复无意义）。
      if (!seen.add('$category\u0000$titleKey')) continue;
      entries.add(_Entry(category, titleKey, subtitleKey));
    }
  }

  // 按分类枚举顺序稳定排序，分类内保持源码顺序。
  int rank(String c) {
    final i = _categoryOrder.indexOf(c);
    return i < 0 ? _categoryOrder.length : i;
  }

  final ordered = [...entries];
  mergeSort(ordered, (a, b) {
    final r = rank(a.category) - rank(b.category);
    return r != 0 ? r : entries.indexOf(a) - entries.indexOf(b);
  });
  return ordered;
}

/// 逐个找出 `WidgetName(` 的起始偏移（忽略注释与字符串里的同名文本）。
List<int> _widgetCalls(String source) {
  final offsets = <int>[];
  final pattern = RegExp('\\b(${_titleWidgets.join('|')})\\(');
  for (final m in pattern.allMatches(source)) {
    if (!_isCodePosition(source, m.start)) continue;
    offsets.add(m.end);
  }
  return offsets;
}

/// 粗略判断 [index] 是否位于代码区（不在 `//` 注释或字符串字面量里）。
///
/// 只做行内判断：设置源码里注释不会跨行包裹 `title:`，足以避免误判。
bool _isCodePosition(String source, int index) {
  var lineStart = source.lastIndexOf('\n', index);
  if (lineStart < 0) lineStart = 0;
  final prefix = source.substring(lineStart, index);
  final comment = prefix.indexOf('//');
  if (comment >= 0) return false;
  // 奇数个引号视为处在字符串内部
  final quotes = RegExp("'").allMatches(prefix).length;
  return quotes.isEven;
}

/// 从 [start] 起读取 `name: <expr>`，返回 expr 的原文（不含尾逗号）。
String? _namedArg(String source, int start, String name) {
  final pattern = RegExp('\\b$name:\\s*');
  final m = pattern.firstMatch(source.substring(start));
  if (m == null) return null;
  // 限制在同一层调用内：遇到 ')' 就停止查找
  final exprStart = start + m.end;
  var i = exprStart;
  var depth = 0;
  while (i < source.length) {
    final ch = source[i];
    if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      if (depth == 0) break;
      depth--;
    } else if (ch == ',' && depth == 0) {
      break;
    } else if (ch == '\n') {
      // 参数可以跨行，但跨行出现新的 widget 调用说明已经越界
      break;
    }
    i++;
  }
  return source.substring(exprStart, i).trim();
}

/// `l10n.xxx` → `xxx`；带参数或非 l10n 表达式返回 null。
String? _simpleL10n(String expr) {
  final m = RegExp(r'^l10n\.([A-Za-z0-9_]+)$').firstMatch(expr.trim());
  return m?.group(1);
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

String _render(List<_Entry> entries) {
  final b = StringBuffer()
    ..writeln('// ArchoeraMusic')
    ..writeln('// Copyright (C) 2026 Archoera && BetaStudio2')
    ..writeln('// SPDX-License-Identifier: AGPL-3.0-or-later')
    ..writeln()
    ..writeln('// GENERATED FILE — 请勿手改。')
    ..writeln('//')
    ..writeln('// 来源：lib/settings 下各 section 的 SettingTile / SettingSwitchTile /')
    ..writeln('//       SettingSliderTile / SettingSection(Title) 的 title: 与 subtitle:。')
    ..writeln('// 重新生成：dart run tool/gen_settings_search_index.dart')
    ..writeln('//')
    ..writeln('// 说明：标题取自设置页真实渲染的文案，因此新增设置项无需手工登记；')
    ..writeln('//       图标统一用分类图标；快捷键分类的标题由 ShortcutAction 动态生成，')
    ..writeln('//       不在此文件中。')
    ..writeln()
    ..writeln("part of '../settings_dialog.dart';")
    ..writeln()
    ..writeln('/// 由设置源码生成的搜索索引（${entries.length} 条）。')
    ..writeln(
      'List<_SearchEntry> _generatedSettingsSearchIndex(AppLocalizations l10n) => [',
    )
    ..writeln('  // 设置行与小节标题（按分类顺序）。');

  // 逐行多行输出，宽度与 `dart format`（80 列）一致：生成即格式化，
  // 避免「生成 → format → 内容变化 → 下次再生成」的抖动。
  for (final e in entries) {
    final sub = e.subtitleKey == null ? "''" : 'l10n.${e.subtitleKey}';
    b
      ..writeln('  _SearchEntry(')
      ..writeln('    SettingsCategory.${e.category},')
      ..writeln('    l10n.${e.titleKey},')
      ..writeln('    $sub,')
      ..writeln('    SettingsCategory.${e.category}.icon,')
      ..writeln('  ),');
  }
  b.writeln('];');
  return b.toString();
}

/// 稳定归并排序（避免依赖 package:collection）。
void mergeSort<T>(List<T> list, int Function(T a, T b) compare) {
  if (list.length < 2) return;
  final mid = list.length ~/ 2;
  final left = list.sublist(0, mid);
  final right = list.sublist(mid);
  mergeSort(left, compare);
  mergeSort(right, compare);
  var i = 0, j = 0, k = 0;
  while (i < left.length && j < right.length) {
    list[k++] = compare(left[i], right[j]) <= 0 ? left[i++] : right[j++];
  }
  while (i < left.length) {
    list[k++] = left[i++];
  }
  while (j < right.length) {
    list[k++] = right[j++];
  }
}
