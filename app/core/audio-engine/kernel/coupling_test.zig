// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! AC-3 耦合解码独立测试程序（zig build-exe <本文件> 可运行）。
//!
//! 与 /tmp/ac3ref.c 的 C 参考实现（FFmpeg ac3dec.c coupling 三函数）交叉校验：
//! 同一合成位流 → 完全相同的 cpl_band_struct / cpl_band_sizes / cpl_coords /
//! phase_flags 等输出。

const std = @import("std");
const t = @import("fmt/ac3/tables.zig");
const Ctx = @import("fmt/ac3/ctx.zig").Ctx;
const BitReader = @import("fmt/aac/bitreader.zig").BitReader;
const cp = @import("fmt/ac3/coupling.zig");

var failures: usize = 0;

fn check(ok: bool, comptime name: []const u8) void {
    if (ok) {
        std.debug.print("PASS {s}\n", .{name});
    } else {
        failures += 1;
        std.debug.print("FAIL {s}\n", .{name});
    }
}

fn dumpBandSizes(sizes: []const u8, n: usize) void {
    for (sizes[0..n]) |v| std.debug.print("{},", .{v});
}

pub fn main() void {
    // ---- Test A: 默认带结构（eac3=1, blk=0, use-default 位=0）----
    {
        var buf = [_]u8{ 0x00, 0x00 };
        var gb = BitReader.init(&buf);
        var band_struct: [18]u8 = [_]u8{0} ** 18;
        var band_sizes: [18]u8 = [_]u8{0} ** 18;
        const err = cp.decodeBandStructure(&gb, 0, 1, 0, 18, &band_struct, &band_sizes);
        const default_match = std.mem.eql(u8, &band_struct, &t.eac3_default_cpl_band_struct);
        const sizes_match = band_sizes[0] == 12 and band_sizes[1] == 12 and band_sizes[2] == 12 and
            band_sizes[3] == 12 and band_sizes[4] == 12 and band_sizes[5] == 12 and
            band_sizes[6] == 12 and band_sizes[7] == 24 and band_sizes[8] == 36 and
            band_sizes[9] == 72;
        check(!err and gb.bit_pos == 1 and default_match and sizes_match, "A_default_band_struct");
        if (!(default_match and sizes_match)) {
            std.debug.print("    struct={s} sizes=", .{band_struct});
            dumpBandSizes(&band_sizes, 10);
            std.debug.print("\n", .{});
        }
    }

    // ---- Test B: 耦合策略（非 eac3 立体声）----
    {
        var buf = [_]u8{ 0xF1, 0x54, 0x80 };
        var ctx: Ctx = .{};
        ctx.gb = BitReader.init(&buf);
        ctx.eac3 = 0;
        ctx.channel_mode = t.AC3_CHMODE_STEREO;
        ctx.fbw_channels = 2;
        var stages: [t.AC3_MAX_CHANNELS]u8 = [_]u8{0} ** t.AC3_MAX_CHANNELS;
        const err = cp.couplingStrategy(&ctx, 0, &stages);
        const ok = !err and
            ctx.gb.bit_pos == 18 and
            ctx.cpl_in_use[0] == 1 and
            ctx.channel_in_cpl[1] == 1 and ctx.channel_in_cpl[2] == 1 and
            ctx.phase_flags_in_use == 1 and
            ctx.start_freq[0] == 49 and ctx.end_freq[0] == 133 and
            ctx.num_cpl_bands == 5 and
            ctx.cpl_band_sizes[0] == 12 and ctx.cpl_band_sizes[1] == 24 and
            ctx.cpl_band_sizes[2] == 12 and ctx.cpl_band_sizes[3] == 24 and
            ctx.cpl_band_sizes[4] == 12 and
            std.mem.eql(u8, &stages, &[_]u8{ 3, 3, 3, 3, 3, 3, 3 });
        check(ok, "B_coupling_strategy");
        if (!ok) {
            std.debug.print("    bit_pos={} nbands={} start={} end={} sizes=", .{
                ctx.gb.bit_pos, ctx.num_cpl_bands, ctx.start_freq[0], ctx.end_freq[0],
            });
            dumpBandSizes(&ctx.cpl_band_sizes, 10);
            std.debug.print("\n", .{});
        }
    }

    // ---- Test C: 耦合坐标 ----
    {
        var buf = [_]u8{ 0xC2, 0x5E, 0x65, 0xE0, 0x11, 0x14, 0x85, 0x0B, 0xFC, 0x44, 0x3A, 0xA0 };
        var ctx: Ctx = .{};
        ctx.gb = BitReader.init(&buf);
        ctx.eac3 = 0;
        ctx.channel_mode = t.AC3_CHMODE_STEREO;
        ctx.fbw_channels = 2;
        ctx.channel_in_cpl[1] = 1;
        ctx.channel_in_cpl[2] = 1;
        ctx.phase_flags_in_use = 1;
        ctx.num_cpl_bands = 5;
        const err = cp.couplingCoordinates(&ctx, 0);
        const ch1_ok = ctx.cpl_coords[1][0] == 294912 and ctx.cpl_coords[1][1] == 6 and
            ctx.cpl_coords[1][2] == 253952 and ctx.cpl_coords[1][3] == 524288 and
            ctx.cpl_coords[1][4] == 3072;
        const ch2_ok = ctx.cpl_coords[2][0] == 1114112 and ctx.cpl_coords[2][1] == 294912 and
            ctx.cpl_coords[2][2] == 240 and ctx.cpl_coords[2][3] == 2228224 and
            ctx.cpl_coords[2][4] == 7864320;
        const ph_ok = ctx.phase_flags[0] == 1 and ctx.phase_flags[1] == 0 and
            ctx.phase_flags[2] == 1 and ctx.phase_flags[3] == 0 and ctx.phase_flags[4] == 1;
        const ok = !err and ctx.gb.bit_pos == 91 and
            ctx.first_cpl_coords[1] == 0 and ctx.first_cpl_coords[2] == 0 and
            ch1_ok and ch2_ok and ph_ok;
        check(ok, "C_coupling_coordinates");
        if (!ok) {
            std.debug.print("    bit_pos={} ch1={any} ch2={any} ph={any}\n", .{
                ctx.gb.bit_pos,
                @as([]const i32, ctx.cpl_coords[1][0..5]),
                @as([]const i32, ctx.cpl_coords[2][0..5]),
                @as([]const i32, ctx.phase_flags[0..5]),
            });
        }
    }

    // ---- Test D: 耦合未使用（非 eac3, cplinu=0）----
    {
        var buf = [_]u8{ 0x00, 0x00 };
        var ctx: Ctx = .{};
        ctx.gb = BitReader.init(&buf);
        ctx.eac3 = 0;
        ctx.channel_mode = t.AC3_CHMODE_STEREO;
        ctx.fbw_channels = 2;
        ctx.first_cpl_coords[1] = 0;
        ctx.first_cpl_coords[2] = 0;
        ctx.channel_in_cpl[1] = 1;
        ctx.channel_in_cpl[2] = 1;
        var stages: [t.AC3_MAX_CHANNELS]u8 = [_]u8{0} ** t.AC3_MAX_CHANNELS;
        const err = cp.couplingStrategy(&ctx, 0, &stages);
        const ok = !err and ctx.gb.bit_pos == 1 and ctx.cpl_in_use[0] == 0 and
            ctx.channel_in_cpl[1] == 0 and ctx.channel_in_cpl[2] == 0 and
            ctx.first_cpl_coords[1] == 1 and ctx.first_cpl_coords[2] == 1 and
            ctx.first_cpl_leak == 0 and ctx.phase_flags_in_use == 0;
        check(ok, "D_coupling_not_in_use");
    }

    // ---- 错误路径 ----
    {
        // 位流越界：eac3=0 需读 17 个合并标志位，仅 1 字节 → true
        var buf = [_]u8{0xFF};
        var gb = BitReader.init(&buf);
        var band_struct: [18]u8 = [_]u8{0} ** 18;
        var band_sizes: [18]u8 = [_]u8{0} ** 18;
        check(cp.decodeBandStructure(&gb, 0, 0, 0, 18, &band_struct, &band_sizes), "err_A_truncated");
    }
    {
        // mono 不允许耦合：cplinu=1 → channel_mode < STEREO → true
        var buf = [_]u8{0x80};
        var ctx: Ctx = .{};
        ctx.gb = BitReader.init(&buf);
        ctx.eac3 = 0;
        ctx.channel_mode = t.AC3_CHMODE_MONO;
        ctx.fbw_channels = 1;
        var stages: [t.AC3_MAX_CHANNELS]u8 = [_]u8{0} ** t.AC3_MAX_CHANNELS;
        check(cp.couplingStrategy(&ctx, 0, &stages), "err_B_mono_coupling");
    }
    {
        // 耦合范围无效：cplstrt=15 ≥ cplend=0+3 → true
        // 位流: 1(cplinu) 1(ch1) 1(ch2) 1(phsflginu) 1111(cplstrt=15) 0000(cplend=0)
        var buf = [_]u8{ 0xFF, 0x00 };
        var ctx: Ctx = .{};
        ctx.gb = BitReader.init(&buf);
        ctx.eac3 = 0;
        ctx.channel_mode = t.AC3_CHMODE_STEREO;
        ctx.fbw_channels = 2;
        var stages: [t.AC3_MAX_CHANNELS]u8 = [_]u8{0} ** t.AC3_MAX_CHANNELS;
        check(cp.couplingStrategy(&ctx, 0, &stages), "err_C_invalid_range");
    }
    {
        // 增强耦合未实现：eac3=1, cplinu=1, enhcpl=1 → true
        var buf = [_]u8{0xC0};
        var ctx: Ctx = .{};
        ctx.gb = BitReader.init(&buf);
        ctx.eac3 = 1;
        ctx.channel_mode = t.AC3_CHMODE_STEREO;
        ctx.fbw_channels = 2;
        ctx.cpl_in_use[0] = 1;
        var stages: [t.AC3_MAX_CHANNELS]u8 = [_]u8{0} ** t.AC3_MAX_CHANNELS;
        check(cp.couplingStrategy(&ctx, 0, &stages), "err_D_enhanced_coupling");
    }
    {
        // blk0 缺少新耦合坐标：new_coords 位=0 → true
        var buf = [_]u8{0x00};
        var ctx: Ctx = .{};
        ctx.gb = BitReader.init(&buf);
        ctx.eac3 = 0;
        ctx.channel_mode = t.AC3_CHMODE_STEREO;
        ctx.fbw_channels = 2;
        ctx.channel_in_cpl[1] = 1;
        ctx.channel_in_cpl[2] = 1;
        check(cp.couplingCoordinates(&ctx, 0), "err_E_missing_coords_blk0");
    }
    {
        // 坐标位流越界：声明 5 带但缓冲不足 → true
        var buf = [_]u8{ 0xFF, 0xFF };
        var ctx: Ctx = .{};
        ctx.gb = BitReader.init(&buf);
        ctx.eac3 = 0;
        ctx.channel_mode = t.AC3_CHMODE_STEREO;
        ctx.fbw_channels = 2;
        ctx.channel_in_cpl[1] = 1;
        ctx.channel_in_cpl[2] = 1;
        ctx.num_cpl_bands = 5;
        check(cp.couplingCoordinates(&ctx, 0), "err_F_coords_truncated");
    }

    if (failures != 0) {
        std.debug.print("{d} FAILURES\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("ALL PASS\n", .{});
}
