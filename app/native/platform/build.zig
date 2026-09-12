// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! archoera_platform 构建脚本（Zig 0.16.0 build API）
//!
//! 产物：libarchoera_platform.{so,dylib} / archoera_platform.dll
//! 平台能力原生桥接（SystemPower / SystemMedia / SystemWindow），C ABI（apl_*）
//! 供 Dart 经 dart:ffi 直调；架构与验收见 docs/platform-native-bridge.md。
//!
//! `zig build test`：core 事件分发 / 能力位图 / 结构体布局单元测试。

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 可选：原生 C++/WinRT 实现。需 C++/WinRT 头路径：
    //   -Dcppwinrt-include=<dir> 或环境变量 CPPWINRT_INCLUDE（vcpkg `cppwinrt`）。
    //   - win_toast.cpp：原生 Toast（Windows.UI.Notifications）。
    //   - win_smtc.cpp ：SMTC 媒体会话/按钮事件（C++/WinRT 标准委托）。
    // ⚠️ Zig 会把「同名弱符号兜底」内联，导致 C++ 强符号永不生效——故 Zig 侧
    // 用 build_options.win_cpp 编译期二选一（C++ extern / Zig 兜底），不再用弱符号。
    const inc_opt = b.option([]const u8, "cppwinrt-include", "C++/WinRT include dir (win_toast.cpp / win_smtc.cpp)");
    const win_cpp = target.result.os.tag == .windows and inc_opt != null;
    const build_options = b.addOptions();
    build_options.addOption(bool, "win_cpp", win_cpp);

    const lib = b.addLibrary(.{
        .name = "archoera_platform",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // libc：std.c.getenv（DBUS_SESSION_BUS_ADDRESS）+ c_allocator
    lib.root_module.link_libc = true;
    lib.root_module.addOptions("build_options", build_options);
    // Windows：user32（WndProc/EnumWindows/SetThreadExecutionState）+
    // powrprof（PowerSettingRegisterNotification）
    if (target.result.os.tag == .windows) {
        lib.root_module.linkSystemLibrary("user32", .{});
        lib.root_module.linkSystemLibrary("powrprof", .{});
        lib.root_module.linkSystemLibrary("advapi32", .{});
        lib.root_module.linkSystemLibrary("dwmapi", .{});
        if (inc_opt) |inc| {
            // cppwinrt 2.x 与 Zig clang 的兼容告警（详见 win_smtc.cpp 顶部注释）：
            // -Wnontrivial-memcall（com_array memset 分支）、-Wno-unused-command-line-argument
            // （-nostdinc++ driver 警告）。
            const cxx_flags = &.{
                "-std=c++20",
                "-Wno-nontrivial-memcall",
                "-Wno-unused-command-line-argument",
            };
            lib.root_module.addCSourceFile(.{
                .file = b.path("src/backend/win_toast.cpp"),
                .flags = cxx_flags,
            });
            lib.root_module.addCSourceFile(.{
                .file = b.path("src/backend/win_smtc.cpp"),
                .flags = cxx_flags,
            });
            lib.root_module.addIncludePath(.{ .cwd_relative = inc });
            lib.root_module.linkSystemLibrary("windowsapp", .{});
            // C++/WinRT 的 C++ 运行时初始化（__vcrt_*/__acrt_*）：Zig 的 `-lc`
            // 只链 msvcrt，不链 vcruntime/ucrt → 含 C++ 静态初始化/异常处理的
            // 目标会报 CRT 初始化符号未解析（见 win_smtc.cpp）。
            //
            // 且 Zig 内置的 windows-msvc 系统库搜索路径只含 VC Lib 与 SDK
            // `um\x64`，**不含 SDK `ucrt\x64`** → `-lucrt` 找不到。把 vcvars 的
            // `LIB` 目录全部加入搜索路径（与 cl.exe 一致）。
            if (b.graph.environ_map.get("LIB")) |lib_paths| {
                var it = std.mem.tokenizeAny(u8, lib_paths, ";");
                while (it.next()) |dir| {
                    if (dir.len > 0) lib.root_module.addLibraryPath(.{ .cwd_relative = dir });
                }
            }
            lib.root_module.linkSystemLibrary("vcruntime", .{});
            lib.root_module.linkSystemLibrary("ucrt", .{});
        }
    }
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/apl.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    tests.root_module.link_libc = true;
    tests.root_module.addOptions("build_options", build_options);
    if (target.result.os.tag == .windows) {
        tests.root_module.linkSystemLibrary("user32", .{});
        tests.root_module.linkSystemLibrary("powrprof", .{});
    }
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run platform bridge tests");
    test_step.dependOn(&run_tests.step);

    // Windows 后端真机冒烟（仅 Windows 目标；WSL 下经 interop 运行）
    if (target.result.os.tag == .windows) {
        const smoke = b.addExecutable(.{
            .name = "win_smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/win_smoke.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        smoke.root_module.link_libc = true;
        smoke.root_module.addOptions("build_options", build_options);
        smoke.root_module.linkSystemLibrary("user32", .{});
        smoke.root_module.linkSystemLibrary("powrprof", .{});
        const install_smoke = b.addInstallArtifact(smoke, .{});
        const smoke_step = b.step("win-smoke", "Build Windows backend smoke exe");
        smoke_step.dependOn(&install_smoke.step);
    }
}
