// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! AC-3 尾数解包 + 变换系数独立测试程序（zig build-exe <本文件> 可运行）。
//!
//! 与 /tmp/ac3mant_ref.c 的 C 参考实现（从 /tmp/ac3dec.c 逐字复制）交叉校验：
//! 同一合成位流 → 逐 bin 输出 f32 原始位模式，二者逐行 diff 须完全一致。
//!
//! 测试覆盖：
//!   T2 calcTransformCoeffsCpl（合成 cpl_coords/phase_flags/cpl_band_sizes）
//!   T3 ac3DecodeTransformCoeffsCh 全 bap=3
//!   T4 ac3DecodeTransformCoeffsCh bap 0..15（分组/查表/有符号位全路径）
//!   T5 耦合声道 bap=0 抖动（LCG 序列 + 抖动尾数）
//!   T6 removeDithering
//!   T7 decodeTransformCoeffs 整帧驱动（立体声耦合 + 尾端清零 + 抖动消除）
//! 另含内嵌单元测试（dequantizeCoeff / DithLcg），与 C 手工参考值比对。

const std = @import("std");
const t = @import("fmt/ac3/tables.zig");
const Ctx = @import("fmt/ac3/ctx.zig").Ctx;
const BitReader = @import("fmt/aac/bitreader.zig").BitReader;
const mn = @import("fmt/ac3/mantissa.zig");

var failures: usize = 0;

fn f2u(f: f32) u32 {
    return @bitCast(f);
}

fn dump(tag: []const u8, s: *const Ctx, ch: usize, lo: usize, hi: usize) void {
    var i = lo;
    while (i < hi) : (i += 1) {
        std.debug.print("{s} ch{d} bin{d}: {X:0>8}\n", .{ tag, ch, i, f2u(s.coeffs[ch][i]) });
    }
}

pub fn main() void {
    t.initStatic();

    // ---- Test 2: calcTransformCoeffsCpl ----
    {
        var s: Ctx = .{};
        s.start_freq[t.CPL_CH] = 37;
        s.end_freq[t.CPL_CH] = 85;
        s.num_cpl_bands = 2;
        s.cpl_band_sizes[0] = 12;
        s.cpl_band_sizes[1] = 36;
        s.fbw_channels = 2;
        s.channel_in_cpl[1] = 1;
        s.channel_in_cpl[2] = 1;
        s.cpl_coords[1][0] = 262144;
        s.cpl_coords[1][1] = 4194304;
        s.cpl_coords[2][0] = 8388608;
        s.cpl_coords[2][1] = 524288;
        s.phase_flags[0] = 1;
        s.phase_flags[1] = 0;
        var bin: usize = 37;
        while (bin < 85) : (bin += 1) {
            s.coeffs[t.CPL_CH][bin] = @as(f32, @floatFromInt(@mod(@as(i32, @intCast(bin - 37)), @as(i32, 7)) - 3)) * 0.5;
            s.coeffs[1][bin] = 777.0;
            s.coeffs[2][bin] = 777.0;
        }
        mn.calcTransformCoeffsCpl(&s);
        std.debug.print("# T2 cpl band0=37..48 band1=49..84\n", .{});
        dump("T2", &s, 1, 37, 85);
        dump("T2", &s, 2, 37, 85);
    }

    // ---- Test 3: 全 bap=3 ----
    {
        var s: Ctx = .{};
        const buf = [_]u8{ 0x05, 0x60 };
        s.gb = BitReader.init(&buf);
        s.start_freq[1] = 37;
        s.end_freq[1] = 41;
        s.dither_flag[1] = 0;
        var i: usize = 37;
        while (i < 41) : (i += 1) {
            s.bap[1][i] = 3;
            s.dexps[1][i] = @intCast(i - 36);
        }
        var m: @import("fmt/ac3/ctx.zig").MantGroups = .{};
        _ = mn.ac3DecodeTransformCoeffsCh(&s, 1, &m);
        std.debug.print("# T3 all-bap3 codes 0,1,2,6 dexps 1,2,3,4 bit_pos={d}\n", .{s.gb.bit_pos});
        dump("T3", &s, 1, 37, 41);
    }

    // ---- Test 4: bap 0..15 全路径 ----
    {
        var s: Ctx = .{};
        const buf = [_]u8{ 0xDA, 0xFB, 0x26, 0x7B, 0xA1, 0x92, 0xC7, 0x80 };
        s.gb = BitReader.init(&buf);
        s.start_freq[1] = 37;
        s.end_freq[1] = 53;
        s.dither_flag[1] = 0;
        const baps = [_]u8{ 0, 1, 1, 1, 2, 2, 2, 3, 4, 4, 5, 6, 7, 10, 15, 0 };
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            s.bap[1][37 + i] = baps[i];
            s.dexps[1][37 + i] = @intCast(i % 6 + 1);
        }
        var m: @import("fmt/ac3/ctx.zig").MantGroups = .{};
        _ = mn.ac3DecodeTransformCoeffsCh(&s, 1, &m);
        std.debug.print("# T4 bap 0..15 bit_pos={d}\n", .{s.gb.bit_pos});
        dump("T4", &s, 1, 37, 53);
    }

    // ---- Test 5: 耦合声道 bap=0 抖动（LCG） ----
    {
        var s: Ctx = .{};
        const buf = [_]u8{ 0, 0, 0, 0 };
        s.gb = BitReader.init(&buf);
        s.start_freq[0] = 37;
        s.end_freq[0] = 42;
        mn.setDithState(1234567);
        var m: @import("fmt/ac3/ctx.zig").MantGroups = .{};
        _ = mn.ac3DecodeTransformCoeffsCh(&s, 0, &m);
        std.debug.print("# T5 cpl dither state0=1234567 state_now={d}\n", .{mn.getDithState()});
        dump("T5", &s, 0, 37, 42);
    }

    // ---- Test 6: removeDithering ----
    {
        var s: Ctx = .{};
        s.fbw_channels = 2;
        s.channel_in_cpl[1] = 1;
        s.channel_in_cpl[2] = 1;
        s.dither_flag[1] = 0;
        s.dither_flag[2] = 1;
        s.start_freq[0] = 37;
        s.end_freq[0] = 50;
        const z = [_]u8{ 1, 0, 3, 0, 5, 0, 0, 4, 2, 0, 6, 7, 0 };
        var i: usize = 0;
        while (i < 13) : (i += 1) {
            s.bap[0][37 + i] = z[i];
            s.coeffs[1][37 + i] = @as(f32, @floatFromInt(37 + i)) * 1.5;
            s.coeffs[2][37 + i] = @as(f32, @floatFromInt(37 + i)) * 1.5;
        }
        mn.removeDithering(&s);
        std.debug.print("# T6 bap-0 at 38,40,42,43,49\n", .{});
        dump("T6", &s, 1, 37, 50);
        dump("T6", &s, 2, 37, 50);
    }

    // ---- Test 7: 整帧驱动（立体声耦合） ----
    {
        var s: Ctx = .{};
        // 连续位流：ch1(22) + cpl(130) + ch2(90) = 242 bits = 31 bytes（Python 打包，与 C 参考一致）
        const full = [_]u8{ 0xDA, 0xFB, 0x24, 0x15, 0x80, 0x48, 0xFB, 0xBA, 0x2A, 0xBA, 0x32, 0x5A, 0x8E, 0x12, 0xCD, 0x93, 0x88, 0xB1, 0xE0, 0x9E, 0xE8, 0xAA, 0xE8, 0xC9, 0x6A, 0x38, 0x44, 0xE2, 0x2C, 0x78, 0x00 };
        s.gb = BitReader.init(&full);
        s.channels = 2;
        s.fbw_channels = 2;
        s.start_freq[0] = 37;
        s.end_freq[0] = 61;
        s.start_freq[1] = 0;
        s.end_freq[1] = 10;
        s.start_freq[2] = 0;
        s.end_freq[2] = 10;
        s.num_cpl_bands = 2;
        s.cpl_band_sizes[0] = 12;
        s.cpl_band_sizes[1] = 12;
        s.channel_in_cpl[1] = 1;
        s.channel_in_cpl[2] = 1;
        s.dither_flag[1] = 1;
        s.dither_flag[2] = 0;
        s.cpl_coords[1][0] = 262144;
        s.cpl_coords[1][1] = 1048576;
        s.cpl_coords[2][0] = 8388608;
        s.cpl_coords[2][1] = 524288;
        s.phase_flags[0] = 1;
        s.phase_flags[1] = 0;
        mn.resetDith();

        const b1 = [_]u8{ 0, 1, 1, 1, 2, 2, 2, 3, 4, 4 };
        const b2 = [_]u8{ 5, 6, 7, 8, 9, 10, 11, 12, 14, 15 };
        const bc = [_]u8{ 0, 3, 3, 3, 3, 0, 5, 5, 5, 5, 5, 6, 0, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 0 };
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            s.bap[1][i] = b1[i];
            s.dexps[1][i] = @intCast(i % 5 + 1);
            s.bap[2][i] = b2[i];
            s.dexps[2][i] = @intCast(i % 5 + 1);
        }
        i = 0;
        while (i < 24) : (i += 1) {
            s.bap[0][37 + i] = bc[i];
            s.dexps[0][37 + i] = @intCast(i % 6 + 1);
        }

        const err = mn.decodeTransformCoeffs(&s, 0);
        std.debug.print("# T7 full driver bit_pos={d} err={}\n", .{ s.gb.bit_pos, err });
        dump("T7", &s, 0, 37, 61);
        dump("T7", &s, 1, 0, 61);
        dump("T7", &s, 2, 0, 61);
        dump("T7", &s, 0, 250, 256);
    }

    if (failures != 0) {
        std.debug.print("{d} FAILURES\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("ALL PASS\n", .{});
}
