// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! AC-3 / E-AC-3 指数解码（对照 FFmpeg ac3dec.c decode_exponents）
//!
//! §7.1.3 Exponent Decoding。三种策略统一以 7 位组编码 3 个基数 5 的增量码字
//! （各码字 0..4，delta = 码字 - 2），解码后按 group_size 展开为绝对指数：
//!   D15（策略 1）：每码字 1 个 bin；D25（策略 2）：每码字 2 个 bin；
//!   D45（策略 3）：每码字 4 个 bin。
//! 绝对指数范围 0..24；越界（组码 ≥125 / 指数 >24 或 <0 / 位读取越界）→ 返回 true。

const t = @import("tables.zig");
const Ctx = @import("ctx.zig").Ctx;

/// 指数解码。exp1 为起始指数值；exponent_strategy 1=D15 2=D25 3=D45；num_groups 组数；
/// dexps[0] 写起始指数，之后按策略解码。返回是否有误（false=成功，对应 C 返回 0）。
pub fn decodeExponents(s: *Ctx, exponent_strategy: u8, num_groups: i32, exp1: i32, dexps: []i8) bool {
    var dexp: [256]i32 = undefined;

    // unpack groups：每组 7 位、3 个基数 5 码字
    const group_size: i32 = @as(i32, exponent_strategy) + @intFromBool(exponent_strategy == t.EXP_D45);
    var grp: i32 = 0;
    var i: usize = 0;
    while (grp < num_groups) : (grp += 1) {
        const expacc = s.gb.readBits(7) catch return true;

        if (expacc >= 125) return true;
        const row = t.ungroup_3_in_7_bits_tab[@as(usize, expacc)];
        dexp[i] = row[0];
        i += 1;
        dexp[i] = row[1];
        i += 1;
        dexp[i] = row[2];
        i += 1;
    }

    // convert to absolute exps and expand groups
    //（dexps[0] 由调用方写起始指数 exp1；此处仅写展开后的指数）
    var prevexp: i32 = exp1;
    var j: usize = 0;
    i = 0;
    while (i < @as(usize, @intCast(num_groups)) * 3) : (i += 1) {
        prevexp += dexp[i] - 2;
        if (prevexp > 24 or prevexp < 0) return true;
        if (group_size == 4) {
            dexps[j] = @intCast(prevexp);
            j += 1;
            dexps[j] = @intCast(prevexp);
            j += 1;
        }
        if (group_size >= 2) {
            dexps[j] = @intCast(prevexp);
            j += 1;
        }
        dexps[j] = @intCast(prevexp);
        j += 1;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 测试（合成位流，与 /tmp/ac3exp_test.c 的 C 参考实现交叉校验）
// ---------------------------------------------------------------------------

const BitReader = @import("../aac/bitreader.zig").BitReader;
const std = @import("std");

test "ac3 exponents: D15 全同值" {
    t.initStatic();
    // 3 组 × 7 位 = 21 位组码 62（(2,2,2) → delta 0），exp1=5 → 全部 5
    const buf = [_]u8{ 0x7C, 0xF9, 0xF0 };
    var ctx: Ctx = .{};
    ctx.gb = BitReader.init(&buf);
    var dexps: [10]i8 = undefined;
    dexps[0] = 5;
    try std.testing.expect(!decodeExponents(&ctx, t.EXP_D15, 3, 5, dexps[1..]));
    try std.testing.expectEqualSlices(i8, &[_]i8{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 }, &dexps);
    try std.testing.expectEqual(@as(usize, 21), ctx.gb.bit_pos);
}

test "ac3 exponents: D25 全同值（每码字展开 2 bin）" {
    t.initStatic();
    // 2 组 × 7 位组码 62（delta 0），group_size=2，exp1=7 → 1 + 3×2×2 = 13 个 7
    const buf = [_]u8{ 0x7C, 0xF8 };
    var ctx: Ctx = .{};
    ctx.gb = BitReader.init(&buf);
    var dexps: [13]i8 = undefined;
    dexps[0] = 7;
    try std.testing.expect(!decodeExponents(&ctx, t.EXP_D25, 2, 7, dexps[1..]));
    try std.testing.expectEqualSlices(i8, &[_]i8{ 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7 }, &dexps);
    try std.testing.expectEqual(@as(usize, 14), ctx.gb.bit_pos);
}

test "ac3 exponents: D45 全同值（每码字展开 4 bin）" {
    t.initStatic();
    // 1 组 × 7 位组码 62（delta 0），group_size=4，exp1=9 → 1 + 3×4 = 13 个 9
    const buf = [_]u8{ 0x7C };
    var ctx: Ctx = .{};
    ctx.gb = BitReader.init(&buf);
    var dexps: [13]i8 = undefined;
    dexps[0] = 9;
    try std.testing.expect(!decodeExponents(&ctx, t.EXP_D45, 1, 9, dexps[1..]));
    try std.testing.expectEqualSlices(i8, &[_]i8{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 }, &dexps);
    try std.testing.expectEqual(@as(usize, 7), ctx.gb.bit_pos);
}

test "ac3 exponents: D15 变增量累加" {
    t.initStatic();
    // 组码 22=(0,4,2) → delta(-2,+2,0)；组码 83=(3,1,3) → delta(+1,-1,+1)；exp1=8
    // 绝对指数：8 → 6 → 8 → 8 → 9 → 8 → 9
    const buf = [_]u8{ 0x2D, 0x4C };
    var ctx: Ctx = .{};
    ctx.gb = BitReader.init(&buf);
    var dexps: [7]i8 = undefined;
    dexps[0] = 8;
    try std.testing.expect(!decodeExponents(&ctx, t.EXP_D15, 2, 8, dexps[1..]));
    try std.testing.expectEqualSlices(i8, &[_]i8{ 8, 6, 8, 8, 9, 8, 9 }, &dexps);
    try std.testing.expectEqual(@as(usize, 14), ctx.gb.bit_pos);
}

test "ac3 exponents: 组码越界（≥125）→ 错误" {
    t.initStatic();
    // 组码 125 = 0b1111101，越界 → true
    const buf = [_]u8{ 0xFA };
    var ctx: Ctx = .{};
    ctx.gb = BitReader.init(&buf);
    var dexps: [4]i8 = undefined;
    try std.testing.expect(decodeExponents(&ctx, t.EXP_D15, 1, 5, &dexps));
}

test "ac3 exponents: 绝对指数越上限（>24）→ 错误" {
    t.initStatic();
    // 组码 100=(4,0,0) → delta +2；exp1=24 → 24+2=26 > 24 → true
    const buf = [_]u8{ 0xC8 };
    var ctx: Ctx = .{};
    ctx.gb = BitReader.init(&buf);
    var dexps: [4]i8 = undefined;
    try std.testing.expect(decodeExponents(&ctx, t.EXP_D15, 1, 24, &dexps));
}

test "ac3 exponents: 位读取越界 → 错误" {
    t.initStatic();
    // 声称 3 组但仅 2 字节（16 位），第 3 组 readBits(7) 越界 → true
    const buf = [_]u8{ 0x7C, 0xF3 };
    var ctx: Ctx = .{};
    ctx.gb = BitReader.init(&buf);
    var dexps: [10]i8 = undefined;
    try std.testing.expect(decodeExponents(&ctx, t.EXP_D15, 3, 5, &dexps));
}
