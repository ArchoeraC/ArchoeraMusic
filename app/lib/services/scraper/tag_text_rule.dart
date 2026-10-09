// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 标签文本规则：标题 / 艺术家的「查找替换 / 加前缀 / 加后缀」纯逻辑。
///
/// 单曲编辑弹窗与批量编辑弹窗共用本模块，避免规则语义（尤其占位符）两处
/// 各写一份而漂移。占位符用于前缀/后缀模板：
///   `[index]`       当前处理序号（批量=1 起；单曲=1）
///   `[track]`       原音轨号（无 → 空）
///   `[disc]`        原碟片号（无 → 空）
///   `[title]`       原标题
///   `[artist]`      原艺术家
///   `[album]`       原专辑
///   `[year]`        原年份（无 → 空）
library;

import 'package:material_ui/material_ui.dart';

import 'tag_editor_service.dart';

/// 文本规则操作。
enum TagTextOp { none, findReplace, prefix, suffix }

/// 单条文本规则的编辑态（控制器 + 当前操作）。
///
/// 由两个弹窗共享；`op` 的变更由宿主经 `setState` 驱动（控件本身无状态）。
class TagTextRuleControllers {
  TagTextRuleControllers({this.op = TagTextOp.none});

  final TextEditingController find = TextEditingController();
  final TextEditingController replace = TextEditingController();
  final TextEditingController affix = TextEditingController();

  TagTextOp op;

  /// 查找替换是否按正则表达式（仅 [TagTextOp.findReplace] 生效）。
  bool regex = false;

  /// 查找替换是否区分大小写（仅 [TagTextOp.findReplace] 生效）。
  bool caseSensitive = true;

  bool get active => op != TagTextOp.none;

  void dispose() {
    find.dispose();
    replace.dispose();
    affix.dispose();
  }
}

/// 一条规则的不可变快照（应用开始前从控制器固定，避免在途被改动影响）。
class TagTextRuleSnapshot {
  const TagTextRuleSnapshot({
    required this.op,
    this.find = '',
    this.replace = '',
    this.affix = '',
    this.regex = false,
    this.caseSensitive = true,
  });

  factory TagTextRuleSnapshot.of(TagTextRuleControllers rule) =>
      TagTextRuleSnapshot(
        op: rule.op,
        find: rule.find.text,
        replace: rule.replace.text,
        affix: rule.affix.text,
        regex: rule.regex,
        caseSensitive: rule.caseSensitive,
      );

  final TagTextOp op;
  final String find;
  final String replace;
  final String affix;
  final bool regex;
  final bool caseSensitive;

  bool get active => op != TagTextOp.none;

  /// 对 [input] 应用本规则。
  String apply(String input, Map<String, String> vars) => applyTagTextOp(
    op: op,
    input: input,
    find: find,
    replace: replace,
    affix: affix,
    regex: regex,
    caseSensitive: caseSensitive,
    vars: vars,
  );
}

/// 由当前标签 + 序号构造占位符取值表。
Map<String, String> tagTextVars(TrackTags cur, int index) => {
  'index': '$index',
  'track': cur.trackNumber > 0 ? '${cur.trackNumber}' : '',
  'disc': cur.discNumber > 0 ? '${cur.discNumber}' : '',
  'title': cur.title,
  'artist': cur.artist,
  'album': cur.album,
  'albumartist': cur.albumArtist,
  'year': cur.year > 0 ? '${cur.year}' : '',
};

/// 用 [vars] 解析模板中的 `[token]` 占位符。
String resolveTagTokens(String template, Map<String, String> vars) {
  if (!template.contains('[')) return template;
  var out = template;
  vars.forEach((k, v) {
    out = out.replaceAll('[$k]', v);
  });
  return out;
}

/// 对 [input] 应用规则。
///
/// [find]/[replace]/[affix] 为该规则的参数（传空则视为无操作）；[vars] 为
/// 占位符取值表（见 [tagTextVars]）。
String applyTagTextOp({
  required TagTextOp op,
  required String input,
  required String find,
  required String replace,
  required String affix,
  required Map<String, String> vars,
  bool regex = false,
  bool caseSensitive = true,
}) {
  switch (op) {
    case TagTextOp.none:
      return input;
    case TagTextOp.findReplace:
      return _replaceAll(input, find, replace, regex, caseSensitive);
    case TagTextOp.prefix:
      return resolveTagTokens(affix, vars) + input;
    case TagTextOp.suffix:
      return input + resolveTagTokens(affix, vars);
  }
}

/// 查找替换：支持正则（`$1` 反向引用）与大小写敏感开关。
///
/// 非法正则表达式时返回原值（不修改，避免整批失败）。
String _replaceAll(
  String input,
  String find,
  String replace,
  bool regex,
  bool caseSensitive,
) {
  if (find.isEmpty) return input;
  if (regex) {
    try {
      final re = RegExp(find, caseSensitive: caseSensitive);
      return input.replaceAllMapped(re, (m) => _expandReplacement(replace, m));
    } catch (_) {
      return input;
    }
  }
  if (caseSensitive) return input.replaceAll(find, replace);
  return input.replaceAll(
    RegExp(RegExp.escape(find), caseSensitive: false),
    replace,
  );
}

/// 展开正则替换模板中的反向引用：`$1`..`$99`、`${n}`、`$&`（整体匹配）、
/// `$$`（字面 `$`）。Dart 的 [String.replaceAll] 不解释 `$`，故自行展开。
String _expandReplacement(String template, Match match) {
  final out = StringBuffer();
  var i = 0;
  while (i < template.length) {
    final c = template.codeUnitAt(i);
    if (c != _dollar) {
      out.writeCharCode(c);
      i++;
      continue;
    }
    if (i + 1 >= template.length) {
      out.writeCharCode(_dollar);
      i++;
      continue;
    }
    final n = template.codeUnitAt(i + 1);
    if (n == _dollar) {
      out.writeCharCode(_dollar);
      i += 2;
      continue;
    }
    if (n == _amp) {
      out.write(match[0] ?? '');
      i += 2;
      continue;
    }
    if (n == _brace) {
      final end = template.indexOf('}', i + 2);
      if (end != -1) {
        final idx = int.tryParse(template.substring(i + 2, end));
        if (idx != null && idx >= 0 && idx <= match.groupCount) {
          out.write(match[idx] ?? '');
          i = end + 1;
          continue;
        }
      }
      out.writeCharCode(_dollar);
      i++;
      continue;
    }
    var j = i + 1;
    while (j < template.length &&
        j < i + 3 &&
        _isAsciiDigit(template.codeUnitAt(j))) {
      j++;
    }
    final idx = int.tryParse(template.substring(i + 1, j));
    if (idx != null && idx >= 1 && idx <= match.groupCount) {
      out.write(match[idx] ?? '');
      i = j;
      continue;
    }
    out.writeCharCode(_dollar);
    i++;
  }
  return out.toString();
}

const int _dollar = 0x24; // $
const int _amp = 0x26; // &
const int _brace = 0x7B; // {

bool _isAsciiDigit(int c) => c >= 0x30 && c <= 0x39;

/// 文本差异分段（内联高亮预览用）：公共前缀 + 删除段 + 新增段 + 公共后缀。
class TextDiff {
  const TextDiff({
    required this.prefix,
    required this.removed,
    required this.added,
    required this.suffix,
  });

  final String prefix;
  final String removed;
  final String added;
  final String suffix;

  /// 是否存在差异（无差异时 [removed]/[added] 均为空）。
  bool get changed => removed.isNotEmpty || added.isNotEmpty;
}

/// 以最长公共前缀/后缀切分 `[before] → [after]` 的差异。
///
/// 用于预览的「删除段（原值）+ 新增段（结果）」内联高亮；无差异时
/// [TextDiff.prefix] 即完整结果、[TextDiff.changed] 为 false。
TextDiff computeTextDiff(String before, String after) {
  final minLen = before.length < after.length ? before.length : after.length;
  var prefix = 0;
  while (prefix < minLen &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < minLen - prefix &&
      before.codeUnitAt(before.length - 1 - suffix) ==
          after.codeUnitAt(after.length - 1 - suffix)) {
    suffix++;
  }
  return TextDiff(
    prefix: after.substring(0, prefix),
    removed: before.substring(prefix, before.length - suffix),
    added: after.substring(prefix, after.length - suffix),
    suffix: after.substring(after.length - suffix),
  );
}

// ── 自定义预设列表操作（纯函数；偏好存 List<Map<String, dynamic>>） ──

/// 把 [index] 项移动 [delta]（-1 上移 / +1 下移）；越界返回原列表的副本。
List<Map<String, dynamic>> movePresetEntry(
  List<Map<String, dynamic>> list,
  int index,
  int delta,
) {
  final out = [...list];
  final j = index + delta;
  if (index < 0 || index >= out.length || j < 0 || j >= out.length) {
    return out;
  }
  final tmp = out[index];
  out[index] = out[j];
  out[j] = tmp;
  return out;
}

/// 把名为 [oldName] 的预设改名为 [newName]：去掉与目标同名的既有项（合并），
/// 被改名项就地保留顺序；[oldName] 不存在或与 [newName] 相同时原样返回。
List<Map<String, dynamic>> renamePresetEntry(
  List<Map<String, dynamic>> list,
  String oldName,
  String newName,
) {
  if (oldName == newName) return [...list];
  Map<String, dynamic>? source;
  for (final m in list) {
    if (m['name'] == oldName) {
      source = m;
      break;
    }
  }
  if (source == null) return [...list];
  final renamed = Map<String, dynamic>.from(source)..['name'] = newName;
  return [
    for (final m in list)
      if (m['name'] != newName) (m['name'] == oldName ? renamed : m),
  ];
}
