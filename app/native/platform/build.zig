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
    // Windows：user32（WndProc/EnumWindows/SetThreadExecutionState）+
    // powrprof（PowerSettingRegisterNotification）
    if (target.result.os.tag == .windows) {
        lib.root_module.linkSystemLibrary("user32", .{});
        lib.root_module.linkSystemLibrary("powrprof", .{});
    }
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/apl.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    tests.root_module.link_libc = true;
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
        smoke.root_module.linkSystemLibrary("user32", .{});
        smoke.root_module.linkSystemLibrary("powrprof", .{});
        const install_smoke = b.addInstallArtifact(smoke, .{});
        const smoke_step = b.step("win-smoke", "Build Windows backend smoke exe");
        smoke_step.dependOn(&install_smoke.step);
    }
}
