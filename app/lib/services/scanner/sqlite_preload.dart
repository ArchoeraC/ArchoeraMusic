import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../native_lib_paths.dart';

/// 预加载内置 SQLite（`libe_sqlite3`），统一 dart sqlite3 包与
/// scanner-ffi（SQLitePCLRaw）所用的 SQLite 实例。
///
/// 背景：dart sqlite3 包（3.5.x）默认在构建期编译/下载自己的 SQLite
/// （如 3.53.x），与 scanner-ffi 内置的 `libe_sqlite3`（3.50.x）版本不一致。
/// 同一进程内两个不同版本的 SQLite 并行操作同一 WAL 数据库时，版本较新的
/// 实例一旦打开连接（checkpoint/读 WAL），较旧实例的写入提交会静默丢失
/// （表现为增量扫描的删除不生效）。通过 pubspec `hooks.user_defines.sqlite3`
/// 将 dart sqlite3 包指向 `source: system, name: e_sqlite3`（运行期按名
/// `dlopen("libe_sqlite3.so")`），再在本函数中按绝对路径先加载一次
/// （Linux 用 `RTLD_DEEPBIND` 防系统 `libsqlite3.so` 全局符号遮蔽），
/// 使后续按名 dlopen 命中同一库实例，版本完全一致。
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
    DynamicLibrary.open(resolved);
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
  final cstr = resolved.toNativeUtf8();
  try {
    final handle = dlopen(cstr, rtldNow | rtldGlobal | rtldDeepbind);
    if (handle == nullptr) {
      throw StateError('dlopen($resolved) 失败');
    }
  } finally {
    calloc.free(cstr);
  }
}
