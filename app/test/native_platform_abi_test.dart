// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 平台桥接「契约符号无条件性」守卫（SEC-48 回归，2026-10-14）。
///
/// `src/backend.h` 声明的是一组**跨平台无条件契约**，由 `src/apl.cpp`（无条件
/// 编译）直接引用。若某个后端的实现被误写进条件编译区（如
/// `#ifdef ARCHOERA_WINRT`）或嵌进了别的 `namespace`，该平台在对应配置下就会在
/// **链接期**报 `LNK2019` / `undefined reference`。
///
/// 这类错误 Dart 侧测试与 Linux 本机都看不见——Windows 后端在 Linux 上根本不
/// 参与编译，`dart analyze` / `flutter test` 也不链接该库——只能烧掉一次全平台
/// CI 才能发现（2026-10-14 实录：`hardenProcess()` 被插进
/// `#ifdef ARCHOERA_WINRT` + `namespace winrt_smtc`，Windows 链接失败）。
///
/// 故在纯文本层复算一遍不变量：对 `backend.h` 的每个契约函数，要求**每个后端
/// 源文件**都存在一处满足「预处理深度 0 且直接位于 `namespace archoera`」的定义。
///
/// 纯静态分析，不需要任何原生产物，三端 `flutter test` 均可运行；
/// 契约与产物布局见 `docs/platform-native-bridge.md`。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一个契约函数的定义点。
class _Definition {
  const _Definition(this.line, this.preprocessorDepth, this.namespaces);

  /// 1 起的源码行号。
  final int line;

  /// 所在位置的 `#if/#ifdef/#ifndef` 嵌套深度（0 = 无条件参与编译）。
  final int preprocessorDepth;

  /// 外层命名空间路径（匿名命名空间被忽略；`archoera` 即后端契约层）。
  final List<String> namespaces;
}

/// 去掉注释与字符串字面量（换成等量空白，**保留换行**以维持行号/下标不变）。
///
/// 必须先剥掉才能安全地数花括号与扫描 `namespace`：否则注释里的 `{`、字符串里
/// 的 `namespace` 都会污染判定。
String _stripCommentsAndStrings(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    if (c == '/' && i + 1 < source.length && source[i + 1] == '/') {
      var j = source.indexOf('\n', i);
      if (j == -1) j = source.length;
      out.write(' ' * (j - i));
      i = j;
    } else if (c == '/' && i + 1 < source.length && source[i + 1] == '*') {
      final close = source.indexOf('*/', i + 2);
      final j = close == -1 ? source.length : close + 2;
      for (var k = i; k < j; k++) {
        out.write(source[k] == '\n' ? '\n' : ' ');
      }
      i = j;
    } else if (c == '"' || c == "'") {
      var j = i + 1;
      while (j < source.length && source[j] != c) {
        if (source[j] == '\\') j++;
        j++;
      }
      j = j < source.length ? j + 1 : source.length;
      for (var k = i; k < j; k++) {
        out.write(source[k] == '\n' ? '\n' : ' ');
      }
      i = j;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// `backend.h` 中 `namespace archoera` 契约函数的声明名集合。
///
/// 契约层都是「返回类型 + 名字 + 参数 + `;`」的普通声明（参数可跨行），头文件里
/// 没有别的同类语句，故可直接整文件匹配。返回类型不做白名单——避免将来新增
/// 返回类型时守卫**静默漏检**。
final RegExp _declarationRe = RegExp(
  r'([A-Za-z_][A-Za-z0-9_:<>\s*&,]*?)\s+(\w+)\s*\([^;{}]*\)\s*;',
  dotAll: true,
);

Set<String> _contractDeclarations(String header) => {
      for (final m in _declarationRe.allMatches(header)) m.group(2)!,
    };

/// 定义行允许的返回类型（含限定符）；用于把「定义」与「调用/引用」区分开。
final RegExp _returnTypeRe = RegExp(
  r'(?:static\s+|inline\s+|constexpr\s+)*'
  r'(?:int32_t|int64_t|uint32_t|uint64_t|bool|void|size_t|double|float|'
  r'const\s+char\s*\*|char\s*\*)',
);

final RegExp _preprocessorRe = RegExp(
  r'^[ \t]*#[ \t]*(if|ifdef|ifndef|endif)\b',
  multiLine: true,
);

bool _isWordChar(String c) => RegExp(r'[A-Za-z0-9_]').hasMatch(c);

/// 统计 [index] 之前的 `#if/#ifdef/#ifndef` 嵌套深度（`#endif` 递减）。
int _preprocessorDepthAt(String source, int index) {
  var depth = 0;
  for (final m in _preprocessorRe.allMatches(source.substring(0, index))) {
    if (m.group(1) == 'endif') {
      depth--;
    } else {
      depth++;
    }
  }
  return depth;
}

/// [end] 位置所处的命名空间路径（忽略匿名命名空间）。
List<String> _namespacePathAt(String source, int end) {
  final stack = <String>[];
  String? pending;
  var i = 0;
  while (i < end) {
    final c = source[i];
    if (c == '{') {
      stack.add(pending ?? '');
      pending = null;
      i++;
      continue;
    }
    if (c == '}') {
      if (stack.isNotEmpty) stack.removeLast();
      i++;
      continue;
    }
    final atNs = source.startsWith('namespace', i) &&
        (i == 0 || !_isWordChar(source[i - 1])) &&
        (i + 9 >= source.length || !_isWordChar(source[i + 9]));
    if (!atNs) {
      i++;
      continue;
    }
    // `using namespace X;` 不是命名空间定义，跳过。
    var k = i - 1;
    while (k >= 0 && ' \t\r\n'.contains(source[k])) {
      k--;
    }
    final wordEnd = k;
    while (k >= 0 && _isWordChar(source[k])) {
      k--;
    }
    final prevWord = source.substring(k + 1, wordEnd + 1);
    var j = i + 'namespace'.length;
    if (prevWord == 'using') {
      i = j;
      continue;
    }
    while (j < end && ' \t\r\n'.contains(source[j])) {
      j++;
    }
    // 罕见形式 `namespace inline`；本仓库未用，稳妥起见仍处理。
    if (j + 6 <= source.length &&
        source.startsWith('inline', j) &&
        (j + 6 >= source.length || !_isWordChar(source[j + 6]))) {
      j += 6;
      while (j < end && ' \t\r\n'.contains(source[j])) {
        j++;
      }
    }
    final nameStart = j;
    while (j < end && (_isWordChar(source[j]) || source[j] == ':')) {
      j++;
    }
    final name = source.substring(nameStart, j);
    var after = j;
    while (after < end && ' \t\r\n'.contains(source[after])) {
      after++;
    }
    if (after < end && source[after] == '{') {
      pending = name.isEmpty ? '__anon__' : name;
      i = after;
    } else {
      pending = null; // `namespace X = Y;` 等别名，不是定义
      i = j;
    }
  }
  return [
    for (final name in stack)
      if (name.isNotEmpty && name != '__anon__') name,
  ];
}

/// 在 [source]（已剥注释/字符串）中找出 [name] 的**定义**（`返回类型 name(…) {`）。
///
/// 调用点（`name(…)`、`archoera::name(…)`）因行首前缀不是返回类型而被排除。
List<_Definition> _findDefinitions(String source, String name) {
  final re = RegExp(r'\b' + RegExp.escape(name) + r'\s*\(');
  final found = <_Definition>[];
  for (final m in re.allMatches(source)) {
    final lineStart = source.lastIndexOf('\n', m.start - 1) + 1;
    final prefix = source.substring(lineStart, m.start).trim();
    final typeMatch = _returnTypeRe.matchAsPrefix(prefix);
    if (typeMatch == null || typeMatch.end != prefix.length) continue;
    // 跳过参数列表，要求紧随 `{`（定义体）而不是 `;`（声明）或表达式。
    var i = m.end;
    var parens = 1;
    while (i < source.length && parens > 0) {
      final ch = source[i];
      if (ch == '(') {
        parens++;
      } else if (ch == ')') {
        parens--;
      }
      i++;
    }
    var j = i;
    while (j < source.length && ' \t\r\n'.contains(source[j])) {
      j++;
    }
    if (j >= source.length || source[j] != '{') continue;
    final line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
    found.add(_Definition(
      line,
      _preprocessorDepthAt(source, m.start),
      _namespacePathAt(source, m.start),
    ));
  }
  return found;
}

/// 后端源文件（与 `CMakeLists.txt` 的平台二选一保持同一组）。
const List<String> _backends = <String>[
  'backend_windows.cpp',
  'backend_macos.mm',
  'backend_linux.cpp',
  'backend_stub.cpp',
];

/// 契约层：`backend.h` 声明所处的命名空间路径。
const List<String> _contractNamespace = <String>['archoera'];

/// 从 `flutter test` 的 cwd（包根 `app/`）向上定位 `native/platform/src`。
Directory? _findPlatformSrcDir() {
  var dir = Directory.current;
  // 从包根起最多向上 5 级，兼容从仓库根 / 其它 cwd 运行的场景。
  for (var i = 0; i < 6; i++) {
    final candidate = Directory('${dir.path}/native/platform/src');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

bool _samePath(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  final srcDir = _findPlatformSrcDir();

  test('backend.h 契约函数在每个后端均「无条件 + 直接位于 namespace archoera」定义', () {
    if (srcDir == null) {
      markTestSkipped('未找到 app/native/platform/src（非仓库内运行？）');
      return;
    }

    final header = _stripCommentsAndStrings(
      File('${srcDir.path}/backend.h').readAsStringSync(),
    );
    final declared = _contractDeclarations(header);
    // 解析器退化保护：若 regex 失灵导致声明集为空/骤减，这里直接失败，
    // 避免下面的循环「零个函数全部通过」而假绿。
    expect(
      declared.length,
      greaterThanOrEqualTo(25),
      reason: 'backend.h 契约声明解析异常（只解析出 ${declared.length} 个）',
    );

    final problems = <String>[];
    for (final backend in _backends) {
      final file = File('${srcDir.path}/$backend');
      expect(file.existsSync(), isTrue, reason: '缺少后端源文件 $backend');
      final source = _stripCommentsAndStrings(file.readAsStringSync());
      for (final name in declared) {
        final definitions = _findDefinitions(source, name);
        final ok = definitions.any(
          (d) =>
              d.preprocessorDepth == 0 &&
              _samePath(d.namespaces, _contractNamespace),
        );
        if (ok) continue;
        final where = definitions.isEmpty
            ? '未找到任何定义'
            : definitions
                .map((d) =>
                    'L${d.line} depth=${d.preprocessorDepth} '
                    'ns=${d.namespaces.join("::")}')
                .join('; ');
        problems.add('$backend: $name —— 缺「深度 0 且位于 namespace archoera」'
            '的定义（$where）');
      }
    }

    expect(
      problems,
      isEmpty,
      reason: '后端契约实现必须无条件提供（apl.cpp 无条件引用它）：\n'
          '${problems.join("\n")}\n'
          '提示：把定义移到 `namespace archoera {` 之后、任何 #if 之外；'
          '详见 docs/platform-native-bridge.md。',
    );
  });
}
