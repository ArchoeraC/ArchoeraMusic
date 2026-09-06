// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! AC-3 指数解码独立测试程序（zig build-exe <本文件> 可运行）。
//!
//! 与 /tmp/ac3exp_test.c 的 C 参考实现（FFmpeg ac3dec.c decode_exponents）交叉校验：
//! 同一合成位流 → 完全相同的 dexps 输出。

const std = @import("std");
const t = @import("fmt/ac3/tables.zig");
const Ctx = @import("fmt/ac3/ctx.zig").Ctx;
const BitReader = @import("fmt/aac/bitreader.zig").BitReader;
const ex = @import("fmt/ac3/exponents.zig");

var failures: usize = 0;

fn checkCase(
    name: []const u8,
    strategy: u8,
    ngrps: i32,
    exp1: i32,
    buf: []const u8,
    expected: []const i8,
) void {
    t.initStatic();
    var ctx: Ctx = .{};
    ctx.gb = BitReader.init(buf);
    var dexps: [300]i8 = undefined;
    const err = ex.decodeExponents(&ctx, strategy, ngrps, exp1, dexps[0..expected.len]);
    const ok = !err and std.mem.eql(i8, dexps[0..expected.len], expected);
    if (ok) {
        std.debug.print("PASS {s}\n", .{name});
    } else {
        failures += 1;
        std.debug.print("FAIL {s} (err={}, got=", .{ name, err });
        for (dexps[0..expected.len]) |v| std.debug.print("{},", .{v});
        std.debug.print(")\n", .{});
    }
}

pub fn main() !void {
    // D15 全同值：3 组 × 7 位组码 62（(2,2,2) → delta 0），exp1=5 → 全部 5
    checkCase("D15_all5", t.EXP_D15, 3, 5, &[_]u8{ 0x7C, 0xF9, 0xF0 }, &[_]i8{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 });
    // D25 全同值：2 组组码 62，group_size=2，exp1=7 → 13 个 7
    checkCase("D25_all7", t.EXP_D25, 2, 7, &[_]u8{ 0x7C, 0xF8 }, &[_]i8{ 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7 });
    // D45 全同值：1 组组码 62，group_size=4，exp1=9 → 13 个 9
    checkCase("D45_all9", t.EXP_D45, 1, 9, &[_]u8{0x7C}, &[_]i8{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 });
    // D15 变增量：组码 22(delta -2,+2,0)、83(delta +1,-1,+1)，exp1=8
    checkCase("D15_var", t.EXP_D15, 2, 8, &[_]u8{ 0x2D, 0x4C }, &[_]i8{ 8, 6, 8, 8, 9, 8, 9 });

    // 错误路径：组码 ≥125、绝对指数 >24、位读取越界
    {
        t.initStatic();
        var ctx: Ctx = .{};
        ctx.gb = BitReader.init(&[_]u8{0xFA});
        var dexps: [4]i8 = undefined;
        if (ex.decodeExponents(&ctx, t.EXP_D15, 1, 5, &dexps)) {
            std.debug.print("PASS err_bad125\n", .{});
        } else {
            failures += 1;
            std.debug.print("FAIL err_bad125\n", .{});
        }
    }
    {
        t.initStatic();
        var ctx: Ctx = .{};
        ctx.gb = BitReader.init(&[_]u8{0xC8});
        var dexps: [4]i8 = undefined;
        if (ex.decodeExponents(&ctx, t.EXP_D15, 1, 24, &dexps)) {
            std.debug.print("PASS err_gt24\n", .{});
        } else {
            failures += 1;
            std.debug.print("FAIL err_gt24\n", .{});
        }
    }
    {
        t.initStatic();
        var ctx: Ctx = .{};
        ctx.gb = BitReader.init(&[_]u8{ 0x7C, 0xF3 });
        var dexps: [10]i8 = undefined;
        if (ex.decodeExponents(&ctx, t.EXP_D15, 3, 5, &dexps)) {
            std.debug.print("PASS err_trunc\n", .{});
        } else {
            failures += 1;
            std.debug.print("FAIL err_trunc\n", .{});
        }
    }

    if (failures != 0) {
        std.debug.print("{d} FAILURES\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("ALL PASS\n", .{});
}
