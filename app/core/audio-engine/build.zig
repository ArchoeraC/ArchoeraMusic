// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! archoera_kernel 构建脚本（Zig 0.17.0 build API）
//!
//! 目标产物：
//!   - archoera_kernel：纯 Zig 音频解码内核（静态库）
//!     —— 由 C 壳（audio-engine/src/*.c）经 kernel_bridge.h（zk_* C ABI）
//!        链接调用，作为 FFmpeg 解码器的渐进替换后端（见 docs/audio-kernel-zig.md）。
//!   - `zig build test`：内核单元测试（wav 黄金样本 / probe 魔数嗅探等）。

const std = @import("std");

const amr_sources = [_][]const u8{
    "kernel/c/amr/wrapper.c",
    "kernel/c/amr/amr_nb/dec/src/agc.c",
    "kernel/c/amr/amr_nb/dec/src/amrdecode.c",
    "kernel/c/amr/amr_nb/dec/src/a_refl.c",
    "kernel/c/amr/amr_nb/dec/src/b_cn_cod.c",
    "kernel/c/amr/amr_nb/dec/src/bgnscd.c",
    "kernel/c/amr/amr_nb/dec/src/c_g_aver.c",
    "kernel/c/amr/amr_nb/dec/src/d1035pf.c",
    "kernel/c/amr/amr_nb/dec/src/d2_11pf.c",
    "kernel/c/amr/amr_nb/dec/src/d2_9pf.c",
    "kernel/c/amr/amr_nb/dec/src/d3_14pf.c",
    "kernel/c/amr/amr_nb/dec/src/d4_17pf.c",
    "kernel/c/amr/amr_nb/dec/src/d8_31pf.c",
    "kernel/c/amr/amr_nb/dec/src/dec_amr.c",
    "kernel/c/amr/amr_nb/dec/src/dec_gain.c",
    "kernel/c/amr/amr_nb/dec/src/dec_input_format_tab.c",
    "kernel/c/amr/amr_nb/dec/src/dec_lag3.c",
    "kernel/c/amr/amr_nb/dec/src/dec_lag6.c",
    "kernel/c/amr/amr_nb/dec/src/d_gain_c.c",
    "kernel/c/amr/amr_nb/dec/src/d_gain_p.c",
    "kernel/c/amr/amr_nb/dec/src/d_plsf_3.c",
    "kernel/c/amr/amr_nb/dec/src/d_plsf_5.c",
    "kernel/c/amr/amr_nb/dec/src/d_plsf.c",
    "kernel/c/amr/amr_nb/dec/src/dtx_dec.c",
    "kernel/c/amr/amr_nb/dec/src/ec_gains.c",
    "kernel/c/amr/amr_nb/dec/src/ex_ctrl.c",
    "kernel/c/amr/amr_nb/dec/src/if2_to_ets.c",
    "kernel/c/amr/amr_nb/dec/src/int_lsf.c",
    "kernel/c/amr/amr_nb/dec/src/lsp_avg.c",
    "kernel/c/amr/amr_nb/dec/src/ph_disp.c",
    "kernel/c/amr/amr_nb/dec/src/post_pro.c",
    "kernel/c/amr/amr_nb/dec/src/preemph.c",
    "kernel/c/amr/amr_nb/dec/src/pstfilt.c",
    "kernel/c/amr/amr_nb/dec/src/qgain475_tab.c",
    "kernel/c/amr/amr_nb/dec/src/sp_dec.c",
    "kernel/c/amr/amr_nb/dec/src/wmf_to_ets.c",
    "kernel/c/amr/amr_nb/common/src/add.c",
    "kernel/c/amr/amr_nb/common/src/az_lsp.c",
    "kernel/c/amr/amr_nb/common/src/bitno_tab.c",
    "kernel/c/amr/amr_nb/common/src/bitreorder_tab.c",
    "kernel/c/amr/amr_nb/common/src/c2_9pf_tab.c",
    "kernel/c/amr/amr_nb/common/src/div_s.c",
    "kernel/c/amr/amr_nb/common/src/extract_h.c",
    "kernel/c/amr/amr_nb/common/src/extract_l.c",
    "kernel/c/amr/amr_nb/common/src/gains_tbl.c",
    "kernel/c/amr/amr_nb/common/src/gc_pred.c",
    "kernel/c/amr/amr_nb/common/src/get_const_tbls.c",
    "kernel/c/amr/amr_nb/common/src/gmed_n.c",
    "kernel/c/amr/amr_nb/common/src/gray_tbl.c",
    "kernel/c/amr/amr_nb/common/src/grid_tbl.c",
    "kernel/c/amr/amr_nb/common/src/int_lpc.c",
    "kernel/c/amr/amr_nb/common/src/inv_sqrt.c",
    "kernel/c/amr/amr_nb/common/src/inv_sqrt_tbl.c",
    "kernel/c/amr/amr_nb/common/src/l_deposit_h.c",
    "kernel/c/amr/amr_nb/common/src/l_deposit_l.c",
    "kernel/c/amr/amr_nb/common/src/log2.c",
    "kernel/c/amr/amr_nb/common/src/log2_norm.c",
    "kernel/c/amr/amr_nb/common/src/log2_tbl.c",
    "kernel/c/amr/amr_nb/common/src/lsfwt.c",
    "kernel/c/amr/amr_nb/common/src/l_shr_r.c",
    "kernel/c/amr/amr_nb/common/src/lsp_az.c",
    "kernel/c/amr/amr_nb/common/src/lsp.c",
    "kernel/c/amr/amr_nb/common/src/lsp_lsf.c",
    "kernel/c/amr/amr_nb/common/src/lsp_lsf_tbl.c",
    "kernel/c/amr/amr_nb/common/src/lsp_tab.c",
    "kernel/c/amr/amr_nb/common/src/mult_r.c",
    "kernel/c/amr/amr_nb/common/src/negate.c",
    "kernel/c/amr/amr_nb/common/src/norm_l.c",
    "kernel/c/amr/amr_nb/common/src/norm_s.c",
    "kernel/c/amr/amr_nb/common/src/overflow_tbl.c",
    "kernel/c/amr/amr_nb/common/src/ph_disp_tab.c",
    "kernel/c/amr/amr_nb/common/src/pow2.c",
    "kernel/c/amr/amr_nb/common/src/pow2_tbl.c",
    "kernel/c/amr/amr_nb/common/src/pred_lt.c",
    "kernel/c/amr/amr_nb/common/src/q_plsf_3.c",
    "kernel/c/amr/amr_nb/common/src/q_plsf_3_tbl.c",
    "kernel/c/amr/amr_nb/common/src/q_plsf_5.c",
    "kernel/c/amr/amr_nb/common/src/q_plsf_5_tbl.c",
    "kernel/c/amr/amr_nb/common/src/q_plsf.c",
    "kernel/c/amr/amr_nb/common/src/qua_gain_tbl.c",
    "kernel/c/amr/amr_nb/common/src/reorder.c",
    "kernel/c/amr/amr_nb/common/src/residu.c",
    "kernel/c/amr/amr_nb/common/src/round.c",
    "kernel/c/amr/amr_nb/common/src/set_zero.c",
    "kernel/c/amr/amr_nb/common/src/shr.c",
    "kernel/c/amr/amr_nb/common/src/shr_r.c",
    "kernel/c/amr/amr_nb/common/src/sqrt_l.c",
    "kernel/c/amr/amr_nb/common/src/sqrt_l_tbl.c",
    "kernel/c/amr/amr_nb/common/src/sub.c",
    "kernel/c/amr/amr_nb/common/src/syn_filt.c",
    "kernel/c/amr/amr_nb/common/src/weight_a.c",
    "kernel/c/amr/amr_nb/common/src/window_tab.c",
};
// total: 92 files

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // 单元测试构建模式：默认 ReleaseSafe。Debug 下 fmt.m4a.open 被编译器分配约
    // 60MB 栈帧（大函数 Debug 临时量病理），默认 8MB 线程栈即段错误；ReleaseSafe
    // 正常分配小帧、保持安全检查，8MB 栈下全绿。可用 -Dtest-optimize 覆盖。
    const test_optimize = b.option(
        std.builtin.Optimize,
        "test-optimize",
        "单元测试构建优化模式（默认 safe = ReleaseSafe 语义）",
    ) orelse .safe;

    // ---- C 头翻译（Zig 0.17 移除了 @cImport）----
    // 0.17 起 C 翻译改由构建期显式完成：源码侧 @import("c_amr") / ("c_vorbis")。
    // 说明：官方推荐改用 translate-c 外部包（Step.TranslateC 已标记 deprecated），
    // 这里保留内置步骤以维持**离线可构建、不新增第三方依赖**；待 0.18 移除前再迁移。
    const tc_vorbis = b.addTranslateC(.{
        .root_source_file = b.path("kernel/c/stb_vorbis.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_vorbis.addIncludePath(b.path("kernel/c"));
    const tc_amr = b.addTranslateC(.{
        .root_source_file = b.path("kernel/c/amr/interf_dec.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_amr.addIncludePath(b.path("kernel/c/amr"));
    tc_amr.addIncludePath(b.path("kernel/c/amr/amr_nb/dec/include"));
    tc_amr.addIncludePath(b.path("kernel/c/amr/amr_nb/common/include"));
    tc_amr.addIncludePath(b.path("kernel/c/amr/common/dec/include"));
    tc_amr.addIncludePath(b.path("kernel/c/amr/oscl"));

    // ---- 内核静态库 ----
    const kernel = b.addLibrary(.{
        .name = "archoera_kernel",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/kernel.zig"),
            .target = target,
            .optimize = optimize,
            // C ABI 桥接（engine.zig）使用 std.heap.c_allocator（宿主 CRT malloc/free）
            .link_libc = true,
        }),
    });
    kernel.root_module.addImport("c_amr", tc_amr.createModule());
    kernel.root_module.addImport("c_vorbis", tc_vorbis.createModule());
    // vendored 单文件 C 库：stb_vorbis（public domain，Vorbis 解码，§9.12）
    // -fno-sanitize=undefined：vendored C 含有符号左移（OpenCORE/stb 风格），
    // zig 对 C 的 UB 检测在 Debug 下会 panic（生产 ReleaseFast 亦不检测）
    kernel.root_module.addCSourceFile(.{
        .file = b.path("kernel/c/stb_vorbis.c"),
        .flags = &.{ "-O3", "-fno-sanitize=undefined" },
    });
    kernel.root_module.addIncludePath(b.path("kernel/c"));
    kernel.root_module.addIncludePath(b.path("kernel/c/amr"));
    kernel.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/dec/src"));
    kernel.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/dec/include"));
    kernel.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/common/include"));
    kernel.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/common/src"));
    kernel.root_module.addIncludePath(b.path("kernel/c/amr/common/dec/include"));
    // vendored OpenCORE AMR-NB 解码器（Apache-2.0，§9.13；按 -x c 编译）
    const amr_flags = [_][]const u8{
        "-O2", "-DDISABLE_AMRNB_ENCODER",         "-fwrapv", "-fno-sanitize=undefined",
        "-I",  "kernel/c/amr/oscl",               "-I",      "kernel/c/amr/amr_nb/dec/src",
        "-I",  "kernel/c/amr/amr_nb/dec/include", "-I",      "kernel/c/amr/amr_nb/common/include",
        "-I",  "kernel/c/amr/amr_nb/common/src",  "-I",      "kernel/c/amr/amr_nb/enc/src",
        "-I",  "kernel/c/amr/common/dec/include", "-I",      "kernel/c/amr",
    };
    kernel.root_module.addCSourceFiles(.{
        .files = &amr_sources,
        .flags = &amr_flags,
    });
    // 注意：Windows 下静态库与动态 import 库同名（均为 zig-out/lib/archoera_kernel.lib）。
    // mediaengine 链接该文件，且必须是**静态库**（Zig 静态库带 .drectve，为 MSVC 链接
    // 补齐 UCRT/CRT 默认库）；若落到 import lib，链接会报 82 个 CRT 未解析符号。
    // 两个 installArtifact 写同一路径会**竞态**（实测约 6/8 次 import lib 覆盖静态库），
    // 故 Windows 上只 installArtifact 静态库，动态库仅安装 DLL（见下方 kernel_shared）。
    b.installArtifact(kernel);
    // ---- 内核动态库（scanner NativeAOT P/Invoke：zk_metadata_* 结构化 ABI，无 JSON）----
    // 与静态库同源同配置；scanner 侧 DllImport("archoera_kernel")，随包分发 .so。
    const kernel_shared = b.addLibrary(.{
        .name = "archoera_kernel",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/kernel.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    kernel_shared.root_module.addImport("c_amr", tc_amr.createModule());
    kernel_shared.root_module.addImport("c_vorbis", tc_vorbis.createModule());
    kernel_shared.root_module.addCSourceFile(.{
        .file = b.path("kernel/c/stb_vorbis.c"),
        .flags = &.{ "-O3", "-fno-sanitize=undefined" },
    });
    kernel_shared.root_module.addIncludePath(b.path("kernel/c"));
    kernel_shared.root_module.addIncludePath(b.path("kernel/c/amr"));
    kernel_shared.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/dec/src"));
    kernel_shared.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/dec/include"));
    kernel_shared.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/common/include"));
    kernel_shared.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/common/src"));
    kernel_shared.root_module.addIncludePath(b.path("kernel/c/amr/common/dec/include"));
    kernel_shared.root_module.addCSourceFiles(.{
        .files = &amr_sources,
        .flags = &amr_flags,
    });

    // Windows VERSIONINFO：统一制作者/版本号（与 app/pubspec.yaml 同步）。
    // 自包含 RC（数字常量）避免依赖 Windows SDK 头；非 Windows 目标忽略。
    if (target.result.os.tag == .windows) {
        // 读取 app/pubspec.yaml 的版本（build 根为 app/core/audio-engine）。
        const pubspec = std.Io.Dir.cwd().readFileAlloc(
            b.graph.io,
            "../../pubspec.yaml",
            b.allocator,
            std.Io.Limit.limited(1 << 20),
        ) catch "";
        var version: []const u8 = "0.0.0+0";
        var lines = std.mem.splitScalar(u8, pubspec, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "version:")) {
                version = std.mem.trim(u8, trimmed["version:".len..], " \t");
                break;
            }
        }
        const plus = std.mem.indexOfScalar(u8, version, '+') orelse version.len;
        const base = version[0..plus];
        const build_num = if (plus < version.len) version[plus + 1 ..] else "0";
        var parts = std.mem.splitScalar(u8, base, '.');
        const major = parts.next() orelse "0";
        const minor = parts.next() orelse "0";
        const patch = parts.next() orelse "0";
        const comma = b.fmt("{s},{s},{s},{s}", .{ major, minor, patch, build_num });
        const rc_text = b.fmt(
            \\1 VERSIONINFO
            \\ FILEVERSION {s}
            \\ PRODUCTVERSION {s}
            \\ FILEFLAGSMASK 0x3fL
            \\ FILEFLAGS 0x0L
            \\ FILEOS 0x40004L
            \\ FILETYPE 2
            \\ FILESUBTYPE 0x0L
            \\BEGIN
            \\    BLOCK "StringFileInfo"
            \\    BEGIN
            \\        BLOCK "040904e4"
            \\        BEGIN
            \\            VALUE "CompanyName", "io.awa.archoera.betastudio2"
            \\            VALUE "FileDescription", "ArchoeraMusic audio kernel"
            \\            VALUE "FileVersion", "{s}"
            \\            VALUE "InternalName", "archoera_kernel"
            \\            VALUE "LegalCopyright", "Copyright (C) 2026 io.awa.archoera.betastudio2"
            \\            VALUE "OriginalFilename", "archoera_kernel.dll"
            \\            VALUE "ProductName", "ArchoeraMusic"
            \\            VALUE "ProductVersion", "{s}"
            \\            VALUE "Comments", "https://github.com/ArchoeraC/ArchoeraMusic"
            \\        END
            \\    END
            \\    BLOCK "VarFileInfo"
            \\    BEGIN
            \\        VALUE "Translation", 0x409, 1252
            \\    END
            \\END
        , .{ comma, comma, version, version });
        const write_files = b.addWriteFiles();
        const rc = write_files.add("archoera_kernel.rc", rc_text);
        kernel_shared.root_module.addWin32ResourceFile(.{ .file = rc });
    }

    // Windows：动态库只装 DLL（scanner DllImport 运行期加载），不装 import lib，
    // 避免与静态库同名竞态覆盖（见上）。非 Windows 无同名冲突，正常安装。
    if (target.result.os.tag == .windows) {
        const install_kernel_dll = b.addInstallFileWithDir(
            kernel_shared.getEmittedBin(),
            .bin,
            "archoera_kernel.dll",
        );
        b.getInstallStep().dependOn(&install_kernel_dll.step);
    } else {
        b.installArtifact(kernel_shared);
    }

    // ---- 内核单元测试 ----
    const kernel_tests = b.addTest(.{
        .name = "archoera-kernel-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/kernel.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
        }),
    });
    kernel_tests.root_module.addImport("c_amr", tc_amr.createModule());
    kernel_tests.root_module.addImport("c_vorbis", tc_vorbis.createModule());
    kernel_tests.root_module.addCSourceFile(.{
        .file = b.path("kernel/c/stb_vorbis.c"),
        .flags = &.{ "-O3", "-fno-sanitize=undefined" },
    });
    kernel_tests.root_module.addIncludePath(b.path("kernel/c"));
    kernel_tests.root_module.addIncludePath(b.path("kernel/c/amr"));
    kernel_tests.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/dec/src"));
    kernel_tests.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/dec/include"));
    kernel_tests.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/common/include"));
    kernel_tests.root_module.addIncludePath(b.path("kernel/c/amr/amr_nb/common/src"));
    kernel_tests.root_module.addIncludePath(b.path("kernel/c/amr/common/dec/include"));
    kernel_tests.root_module.addCSourceFiles(.{
        .files = &amr_sources,
        .flags = &amr_flags,
    });

    const test_step = b.step("test", "运行内核单元测试（zig build test）");
    // 直接执行测试产物（不经 build runner 的 test-server/listen 协议）：
    // 0.17 的 listen 协议路径在本内核 7xx 用例下偶发「process terminated with
    // signal SEGV」（同一二进制直接执行稳定通过）。直接执行仍是标准测试入口
    // （失败以非 0 退出码收敛），CI 语义不变，且日志按用例逐行输出更易定位。
    const run_tests = b.addRunFile(kernel_tests.getEmittedBin());
    test_step.dependOn(&run_tests.step);
}
