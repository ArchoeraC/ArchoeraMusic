/// 一次性工具：全量重构后重写 lib/ 下的相对 import。
///
/// 三种路径逐一尝试（命中即停）：
///  1. 相对当前文件位置解析，目标存在 → 已正确，保留；
///  2. 去掉多余 `lib/` 段后相对当前位置解析（新文件手写时带入的垃圾路径）；
///  3. 相对旧文件位置解析 + 旧→新映射表重算（旧结构遗留路径）。
/// 运行后删除本文件（不随项目保留）。
library;

import 'dart:io';

/// 旧 lib 相对路径 → 新 lib 相对路径（目录前缀映射）
const _prefixMap = <String, String>{
  'core/apis/': 'apis/',
  'core/state/': 'stores/',
  'core/kugou/direct/': 'services/kugou/',
  'core/': 'services/',
  'ui/pages/': 'pages/',
  'ui/settings/': 'settings/',
  'ui/theme/': 'theme/',
  'ui/widgets/': 'widgets/',
};

/// ui/widgets 文件名 → 目标分组
const _widgetGroups = <String, String>{
  'side_bar': 'layout',
  'nav_header': 'layout',
  'player_bar': 'layout',
  'app_logo': 'layout',
  'queue_panel': 'player',
  'spectrum_view': 'player',
  'lyrics_view': 'player',
  'playback_slider': 'player',
  's_controls': 'player',
  's_dialog': 'dialogs',
  'comment_dialog': 'dialogs',
  'track_list_dialog': 'dialogs',
  'netease_login_dialog': 'dialogs',
  'kugou_login_button': 'dialogs',
  'folder_manager': 'dialogs',
  'track_context_menu': 'dialogs',
  's_context_menu': 'dialogs',
  'song_list': 'list',
  'cover_grid': 'list',
  'cover_image': 'list',
  'glass_surface': 'common',
  'toast': 'common',
  'app_shortcuts': 'common',
  'splash_screen': 'common',
  'placeholder_page': 'common',
  'tray_integration': 'common',
};

/// 单个文件的精确搬家（非目录前缀规则覆盖）
const _fileMoves = <String, String>{
  'ui/pages/streaming_page.dart': 'pages/streaming/streaming_page.dart',
  'ui/pages/streaming_detail_pages.dart': 'pages/streaming/album_detail_page.dart',
  'ui/app.dart': 'app/app.dart',
  'ui/app_shell.dart': 'app/shell.dart',
};

/// 反推旧文件路径（相对 lib），使旧 import 字符串能正确解析。
/// 新拆分文件（app/、streaming 详情拆分）没有旧实体，映射到其来源文件。
String oldRel(String newRel) {
  if (newRel == 'main.dart') return newRel;
  if (newRel.startsWith('app/')) return 'ui/app.dart';
  if (newRel.startsWith('pages/streaming/streaming_page.dart')) {
    return 'ui/pages/streaming_page.dart';
  }
  if (newRel.startsWith('pages/streaming/')) {
    return 'ui/pages/streaming_detail_pages.dart';
  }
  if (newRel.startsWith('pages/')) return 'ui/$newRel';
  if (newRel.startsWith('settings/')) return 'ui/$newRel';
  if (newRel.startsWith('theme/')) return 'ui/$newRel';
  if (newRel.startsWith('widgets/')) {
    final seg = newRel.split('/');
    return 'ui/widgets/${seg.sublist(2).join('/')}';
  }
  if (newRel.startsWith('stores/')) return 'core/state/${newRel.substring(7)}';
  if (newRel.startsWith('apis/')) return 'core/$newRel';
  if (newRel.startsWith('services/kugou/')) {
    return 'core/kugou/direct/${newRel.substring(15)}';
  }
  if (newRel.startsWith('services/')) return 'core/${newRel.substring(9)}';
  return newRel; // l10n/ 等已正确路径，原样保留
}

/// 目标路径映射：旧 lib 相对 → 新 lib 相对
String mapTarget(String oldTarget) {
  final move = _fileMoves[oldTarget];
  if (move != null) return move;
  for (final e in _prefixMap.entries) {
    if (oldTarget.startsWith(e.key)) {
      final rest = oldTarget.substring(e.key.length);
      final base = e.value;
      if (e.key == 'ui/widgets/') {
        final name = rest.split('/').first.replaceAll('.dart', '');
        final group = _widgetGroups[name];
        if (group == null) {
          throw StateError('widget 未分组: $rest');
        }
        return 'widgets/$group/$rest';
      }
      return '$base$rest';
    }
  }
  return oldTarget; // l10n/ 等已正确路径，原样保留
}

/// 计算 [fromRel]（lib 相对文件）到 [toRel]（lib 相对目标）的相对 import
String relativeImport(String fromRel, String toRel) {
  final fromSeg = fromRel.split('/')..removeLast();
  final toSeg = toRel.split('/');
  var i = 0;
  while (i < fromSeg.length &&
      i < toSeg.length &&
      fromSeg[i] == toSeg[i]) {
    i++;
  }
  return [
    ...List.filled(fromSeg.length - i, '..'),
    ...toSeg.sublist(i),
  ].join('/');
}

/// 去掉 import 路径中多余的 `lib/` 段（新文件手写时带入的垃圾路径）。
String stripLibSegments(String import) =>
    import.split('/').where((s) => s != 'lib').join('/');

/// 把 [import] 相对 [baseRel]（lib 相对文件）解析为 lib 相对目标路径。
/// 必须用绝对 base（Uri.file），否则相对 URI 的 resolve 对 `..` 的
/// 归并行为不一致（会把 base 当目录，多算一层），导致映射错位。
String? resolveRel(String baseRel, String import) {
  final target = Uri.file('/lib/$baseRel').resolve(import).path;
  var rel = target.startsWith('/') ? target.substring(1) : target;
  if (rel.startsWith('lib/')) rel = rel.substring(4);
  return rel;
}

void main() {
  // 覆盖 lib/（相对 import）+ tool/、test/（package: 引用 lib 的路径）。
  final roots = ['lib', 'tool', 'test'];
  var changed = 0;
  var rewritten = 0;
  final skipped = <String>[];
  for (final root in roots) {
    for (final file in Directory(root)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (file.path.contains('l10n/generated')) continue;
      final relPath = file.path.replaceAll('\\', '/');
      final isLib = relPath.startsWith('lib/');
      final newRel = isLib ? relPath.substring(4) : relPath;
      final oldRelPath = oldRel(newRel);
      var text = file.readAsStringSync();
      final lines = text.split('\n');
      final out = <String>[];
      var replaced = 0;
      for (final line in lines) {
        final m = RegExp(r"^import '([^']+)'").firstMatch(line.trimLeft());
        if (m == null) {
          out.add(line);
          continue;
        }
        final import = m.group(1)!;
        final indent = line.substring(0, line.length - line.trimLeft().length);

        // package:archoera_music/... —— 直接按 lib 相对路径映射
        const pkgPrefix = 'package:archoera_music/';
        if (import.startsWith(pkgPrefix)) {
          final libRel = import.substring(pkgPrefix.length);
          if (File('lib/$libRel').existsSync()) {
            out.add(line); // 已正确
            continue;
          }
          try {
            final mapped = mapTarget(libRel);
            if (mapped != libRel && File('lib/$mapped').existsSync()) {
              final newImport = '$pkgPrefix$mapped';
              out.add(
                  '$indent${line.trimLeft().replaceFirst(import, newImport)}');
              replaced++;
              continue;
            }
          } on StateError catch (e) {
            skipped.add('$newRel: ${e.message} (import: $import)');
          }
          out.add(line);
          continue;
        }

        if (import.contains(':')) {
          out.add(line); // 其他 package:/dart:
          continue;
        }
        // 非 lib 文件的相对 import（如 'package:...' 之外的 './x'）不处理
        if (!isLib) {
          out.add(line);
          continue;
        }

        // 1) 当前路径直接解析且目标存在 → 已正确
        final curTarget = resolveRel(newRel, import);
        if (curTarget != null && File('lib/$curTarget').existsSync()) {
          out.add(line);
          continue;
        }

        // 2) 去掉多余 lib/ 段后重试
        final stripped = stripLibSegments(import);
        if (stripped != import) {
          final strippedTarget = resolveRel(newRel, stripped);
          if (strippedTarget != null &&
              File('lib/$strippedTarget').existsSync()) {
            final newImport = relativeImport(newRel, strippedTarget);
            out.add('$indent${line.trimLeft().replaceFirst(import, newImport)}');
            replaced++;
            continue;
          }
        }

        // 3) 旧结构解析 + 映射
        try {
          final oldTarget = resolveRel(oldRelPath, import);
          if (oldTarget != null) {
            final mapped = mapTarget(oldTarget);
            if (mapped != oldTarget && File('lib/$mapped').existsSync()) {
              final newImport = relativeImport(newRel, mapped);
              out.add(
                  '$indent${line.trimLeft().replaceFirst(import, newImport)}');
              replaced++;
              continue;
            }
          }
        } on StateError catch (e) {
          skipped.add('$newRel: ${e.message} (import: $import)');
        }
        out.add(line);
      }
      if (replaced > 0) {
        file.writeAsStringSync(out.join('\n'));
        changed++;
        rewritten += replaced;
      }
    }
  }
  stdout.writeln('改写文件数: $changed');
  stdout.writeln('改写 import 数: $rewritten');
  if (skipped.isNotEmpty) {
    stdout.writeln('未处理:');
    for (final s in skipped) {
      stdout.writeln('  $s');
    }
  }
}
