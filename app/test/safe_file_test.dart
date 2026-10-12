// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/security/data_destroyer.dart';
import 'package:archoera_music/utils/safe_file.dart';

/// [SafeFile] 回归：App 层「裸文件调用」收口后的核心语义。
///
/// 动机（实测过的两条同用户攻击路径）：
///   - 配置目录里植入 **FIFO** → `readAsStringSync`/`openSync` 阻塞在打开阶段（界面冻结）；
///   - 植入 **符号链接** → 读被重定向；写会**穿透**覆盖链接目标（擦除器更会抹掉任意文件）。
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('safe-file-'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String p(String name) => '${tmp.path}/$name';

  test('普通文件：按上限读取（超限拒绝）', () {
    File(p('a.json')).writeAsStringSync('{"k":1}');
    expect(SafeFile.readString(p('a.json')), '{"k":1}');
    expect(SafeFile.readBytes(p('a.json')), isNotNull);
    expect(SafeFile.readString(p('a.json'), maxBytes: 2), isNull, reason: '超过上限应拒绝');
    expect(SafeFile.readString(p('missing.json')), isNull, reason: '缺失 → null');
  });

  test('目录 / 符号链接：读拒绝（allowSymlink 控制是否跟随）', () {
    Directory(p('adir')).createSync();
    expect(SafeFile.readString(p('adir')), isNull, reason: '目录不是普通文件');

    File(p('real.json')).writeAsStringSync('{"ok":true}');
    Link(p('link.json')).createSync(p('real.json'));
    expect(SafeFile.readString(p('link.json')), '{"ok":true}', reason: '默认跟随链接（兼容 dotfiles）');
    expect(SafeFile.readString(p('link.json'), allowSymlink: false), isNull,
        reason: 'refuse 模式不跟随链接');
    expect(SafeFile.isRegularFile(p('link.json'), allowSymlink: false), isFalse);
    expect(SafeFile.isRegularFile(p('link.json')), isTrue);
  });

  test('writeAtomic：创建 / 覆盖，且对符号链接目标**只替换链接、不穿透写目标**', () {
    expect(SafeFile.writeAtomicString(p('w.json'), '{"v":1}'), isTrue);
    expect(File(p('w.json')).readAsStringSync(), '{"v":1}');
    expect(SafeFile.writeAtomicString(p('w.json'), '{"v":2}'), isTrue);
    expect(File(p('w.json')).readAsStringSync(), '{"v":2}');

    // 关键：目标是符号链接 → 只替换链接本身，链接指向的「受害文件」必须保持原样。
    final victim = File(p('victim.bin'))..writeAsBytesSync(utf8.encode('ORIGINAL'));
    Link(p('slink.json')).createSync(victim.path);
    expect(SafeFile.writeAtomicString(p('slink.json'), '{"v":3}'), isTrue);
    expect(victim.readAsStringSync(), 'ORIGINAL', reason: '写入不得穿透符号链接覆盖目标');
    expect(File(p('slink.json')).readAsStringSync(), '{"v":3}');
    expect(Link(p('slink.json')).existsSync(), isFalse, reason: '链接已被普通文件替换');
  });

  test('writeAtomic：目标为目录 → 失败但不抛（不留临时文件）', () {
    Directory(p('dir2')).createSync();
    expect(SafeFile.writeAtomicString(p('dir2'), 'x'), isFalse);
    final leftovers = tmp
        .listSync()
        .where((e) => e.path.contains('.tmp.'))
        .toList();
    expect(leftovers, isEmpty, reason: '失败不得残留临时文件');
  });

  test('FIFO：读不阻塞且返回 null；写被拒（Linux）', () {
    if (!Platform.isLinux) {
      markTestSkipped('仅 Linux（mkfifo）');
      return;
    }
    final fifo = p('f.fifo');
    try {
      final r = Process.runSync('mkfifo', [fifo]);
      if (r.exitCode != 0) {
        markTestSkipped('mkfifo 不可用');
        return;
      }
    } catch (_) {
      markTestSkipped('mkfifo 不可用');
      return;
    }
    // 读：类型判定先返回 null（若实现退化为直接读会永久阻塞 → 用例超时即失败）。
    expect(SafeFile.readString(fifo), isNull);
    expect(SafeFile.isRegularFile(fifo, allowSymlink: false), isFalse);
  });

  test('擦除器：符号链接不擦（否则会顺链抹掉目标文件）', () {
    final victim = File(p('victim2.bin'))..writeAsBytesSync(utf8.encode('KEEP-ME'));
    final link = Link(p('shred-link.json'))..createSync(victim.path);
    final r = shredFile(link.path);
    expect(r.existed, isTrue);
    expect(r.shredded, isFalse, reason: '非普通文件不得进入覆盖销毁流程');
    expect(victim.readAsStringSync(), 'KEEP-ME', reason: '链接目标必须毫发无损');
  });
}
