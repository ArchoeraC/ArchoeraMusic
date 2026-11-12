// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../log/log.dart';
import '../native_integrity.dart';
import '../native_lib_paths.dart';

/// 预加载内置 SQLite（`libe_sqlite3`），统一 dart sqlite3 包与
/// scanner-ffi / indexer-ffi（SQLitePCLRaw）所用的 SQLite 实例。
///
/// 背景：同一进程内出现两套 SQLite 实例时，POSIX 文件锁按**进程**计，双方互相
/// 看不见对方的锁与 WAL，同一 `library.db` 上的写入会丢、读取停在旧快照。
///
/// Linux 的结论（2026-11-12 实测）：**不能依赖全局符号顺序**。GTK 的依赖链
/// `libgtk-3 → libtinysparql-3.0 → libsqlite3.so.0` 在 `main()` 之前就把系统
/// SQLite 装进全局作用域，而 ELF 全局符号按加载顺序查找——后加载的内置库赢不过
/// 它，`source: process` 的 dart sqlite3 实际绑到的是系统库。因此 Linux 在
/// `pubspec.yaml` 里改成 `source: system` + `name: e_sqlite3`，由本函数先按绝对
/// 路径加载内置库（其 SONAME 为 `libe_sqlite3.so`），dart sqlite3 再按名 dlopen
/// 时命中同一句柄，全进程只剩一套实例。
///
/// macOS / Windows 仍走 `source: process`：两级命名空间 / 每模块导入表不存在
/// 上述全局符号遮蔽，这里只需把内置库按绝对路径加载进进程。
///
/// 必须在任何 `sqlite3.open` 之前调用（应用入口 [main] 最早处）。
void preloadBundledSqlite({String? path}) {
  String resolved;
  try {
    resolved = path ?? NativeLibPaths.resolveRequired(NativeModule.sqlite);
  } catch (_) {
    // 开发环境未找到时静默（fallback 到系统库，仅 dev）
    return;
  }
  if (!File(resolved).existsSync()) return;

  if (!Platform.isLinux) {
    // macOS（两级命名空间）与 Windows（每模块导入表）不存在全局符号
    // 遮蔽问题，走默认加载。
    NativeIntegrity.verifyOrThrow(resolved);
    DynamicLibrary.open(resolved);
    _logBoundSqliteVersion();
    return;
  }

  // Linux glibc dlfcn.h 标志（bits/dlfcn.h）
  const rtldNow = 0x2;
  const rtldGlobal = 0x100;
  const rtldDeepbind = 0x8;

  DynamicLibrary libdl() {
    // glibc ≥ 2.34 将 dlopen 并入 libc；旧版本在 libdl.so.2
    try {
      return DynamicLibrary.open('libdl.so.2');
    } catch (_) {}
    return DynamicLibrary.open('libc.so.6');
  }

  final dlopen = libdl().lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>, Int32),
      Pointer<Void> Function(Pointer<Utf8>, int)>('dlopen');
  NativeIntegrity.verifyOrThrow(resolved);
  final cstr = resolved.toNativeUtf8();
  try {
    // RTLD_GLOBAL 使符号进入全局符号表（macOS / Windows 的 native assets 仍按
    // `source: process` 命中）；RTLD_DEEPBIND 防系统 libsqlite3.so 全局符号遮蔽
    // 内置库的内部符号解析。Linux 的 dart sqlite3 已改为按 SONAME 命中本句柄
    // （见 pubspec.yaml 的 hooks 说明），不再依赖全局符号顺序。
    final handle = dlopen(cstr, rtldNow | rtldGlobal | rtldDeepbind);
    if (handle == nullptr) {
      throw StateError('dlopen($resolved) 失败');
    }
  } finally {
    calloc.free(cstr);
  }

  // 诊断：Dart 侧实际绑定的 SQLite 版本必须与内置库一致（3.53.x）。若打出系统
  // 版本（如 3.54.1），说明进程里又出现了第二套实例 —— 那会让扫描写入与列表读取
  // 落在不同实例上（WAL 的 -wal/-shm 互不可见），表现为「刷新后数量不变」。
  _logBoundSqliteVersion();
}

/// 是否已打印过绑定版本（预加载会被 main / scanner / indexer 各调一次，只记一行）。
bool _sqliteVersionLogged = false;

/// 记录 dart sqlite3 实际绑定的版本（诊断用；失败不影响启动）。
void _logBoundSqliteVersion() {
  if (_sqliteVersionLogged) return;
  _sqliteVersionLogged = true;
  try {
    Log.i('sqlite', 'dart sqlite3 = ${sqlite.sqlite3.version.libVersion}');
  } catch (err) {
    Log.w('sqlite', 'dart sqlite3 绑定失败: $err');
  }
}
