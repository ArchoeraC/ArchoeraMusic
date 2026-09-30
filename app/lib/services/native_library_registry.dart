// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 统一「可关闭原生库」注册表：模块级引用计数 + `DynamicLibrary.close()` 真正卸载。
///
/// 背景（2026-10-01 更正）：`dart:ffi` 自 Dart 3.1 起提供 `DynamicLibrary.close()`
/// （对应 `dlclose`），在无其它引用时**真正卸载** `.so` 代码段。此前各绑定直接
/// `DynamicLibrary.open` 且从不关闭，导致用过即常驻（见
/// docs/module-on-demand-load-plan.md §3）。
///
/// 语义：
/// - [acquire]：该模块首次调用时 `open()`，之后复用同一 [DynamicLibrary]；引用 +1；
/// - [release]：引用 -1；归零时 `close()` 并移出表（**真正卸载**）；
/// - 每个 isolate 有独立的注册表与静态态；但 `open/close` 的 OS 引用计数是
///   进程级的——因此**每个 isolate 内 open 的都要在本 isolate 内配对 close**，
///   全部 isolate 都归零后该库才会被卸载（见下「多 isolate」）；
/// - 释放必须与「无在途调用」互斥，且释放后**作废对应绑定实例**（其
///   `lookupFunction` 指针在 close 后失效）；调用方通过绑定单例的 reset/ dispose
///   完成。
///
/// 已注册但**永不释放**的模块（[acquirePermanent]）：sqlite/log/platform 等进程级
/// 常驻能力（sqlite 与 dart sqlite3 共享同一实例，卸载会破坏契约）。
library;

import 'dart:ffi';

import 'log/log.dart';
import 'native_lib_paths.dart';

class _Entry {
  _Entry(this.lib, {required this.permanent});
  final DynamicLibrary lib;
  final bool permanent;
  int refs = 0;
}

/// 模块 → 当前打开的库与引用计数（每 isolate 一份）。
final Map<NativeModule, _Entry> _entries = <NativeModule, _Entry>{};

/// 打开（或复用）模块库并引用 +1。
///
/// 首次调用 `DynamicLibrary.open(path ?? resolve(m))`；之后复用同一对象。
/// 解析失败抛 [StateError]（同 [NativeLibPaths.resolveRequired]）。
DynamicLibrary acquire(NativeModule m, {String? path}) {
  final existing = _entries[m];
  if (existing != null) {
    existing.refs++;
    return existing.lib;
  }
  final lib = DynamicLibrary.open(path ?? NativeLibPaths.resolveRequired(m));
  _entries[m] = _Entry(lib, permanent: false)..refs = 1;
  return lib;
}

/// 打开常驻模块（永不自动卸载；引用计数仍记录，便于诊断）。
DynamicLibrary acquirePermanent(NativeModule m, {String? path}) {
  final existing = _entries[m];
  if (existing != null) {
    existing.refs++;
    return existing.lib;
  }
  final lib = DynamicLibrary.open(path ?? NativeLibPaths.resolveRequired(m));
  _entries[m] = _Entry(lib, permanent: true)..refs = 1;
  return lib;
}

/// 释放一次引用；归零时 `close()`（真正卸载；常驻模块不关）。
///
/// 返回是否因此在本次调用中关闭了库。
bool release(NativeModule m) {
  final e = _entries[m];
  if (e == null) return false;
  e.refs--;
  if (e.refs > 0 || e.permanent) return false;
  _entries.remove(m);
  try {
    e.lib.close();
    Log.i('ffi', '已卸载 ${m.fileName}（引用归零）');
  } catch (err) {
    Log.w('ffi', '卸载 ${m.fileName} 失败: $err');
  }
  return true;
}

/// 当前引用计数（0 = 未打开）。仅诊断/测试用。
int refsOf(NativeModule m) => _entries[m]?.refs ?? 0;

/// 模块当前是否已打开。仅诊断/测试用。
bool isOpen(NativeModule m) => _entries.containsKey(m);
