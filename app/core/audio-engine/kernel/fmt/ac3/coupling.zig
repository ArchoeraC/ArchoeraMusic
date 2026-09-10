// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! AC-3 / E-AC-3 耦合（coupling）解码（对照 FFmpeg ac3dec.c）
//!
//! 三个函数（float 路径）：
//!   decodeBandStructure  — 解码耦合带结构，写 band_struct / band_sizes
//!   couplingStrategy     — 耦合策略，写 cpl_in_use / channel_in_cpl /
//!                           phase_flags_in_use / start_freq / end_freq / num_cpl_bands
//!   couplingCoordinates  — 耦合坐标，写 cpl_coords / phase_flags
//!
//! cpl_coords 沿用 C 的 1<<23 归一化整数表示（float 路径在使用处乘以 1/(1<<23)），
//! 本模块只做位流解析与移位累加，不引入浮点。
//!
//! 返回约定：bool（false=成功，对应 C 返回 0；true=错误，对应 C 返回负值）。
//! 位读取越界（BitReader 的 error.Corrupt）一律映射为 true。

const std = @import("std");
const t = @import("tables.zig");
const Ctx = @import("ctx.zig").Ctx;
const BitReader = @import("../aac/bitreader.zig").BitReader;
/// 内部完整实现（对照 C `decode_band_structure`）。
///
/// start_subband / end_subband 为子带号（不是 bin 频率）。band_sizes 以 bin 计：
/// 每个子带默认 12 bin（ecpl 增强耦合前 4 个子带为 6 bin），被合并的子带累加进
/// 前一个带。返回带数 n_bands（= 写出的 band_sizes 有效项数）。
pub fn decodeBandStructureInner(
    gb: *BitReader,
    blk: i32,
    eac3: i32,
    ecpl: i32,
    start_subband: i32,
    end_subband: i32,
    default_band_struct: []const u8,
    band_struct: []u8,
    band_sizes: []u8,
) !i32 {
    var bnd_sz: [22]u8 = [_]u8{0} ** 22;
    const n_subbands: i32 = end_subband - start_subband;

    // blk==0：整段 band_struct 用默认带结构填充（后续 blk 复用未改写部分）
    if (blk == 0) {
        const n = @min(band_struct.len, default_band_struct.len);
        @memcpy(band_struct[0..n], default_band_struct[0..n]);
    }
    std.debug.assert(band_struct.len >= @as(usize, @intCast(start_subband)) + @as(usize, @intCast(n_subbands)));

    // band_struct += start_subband + 1（per-subband 合并标志从下一个子带起）
    const bsf = band_struct[@as(usize, @intCast(start_subband + 1)) ..];

    // 从位流解码带结构；eac3 时首位为"是否用新带结构"（0=沿用默认/历史）
    if (eac3 == 0 or try gb.readBits(1) == 1) {
        var subbnd: usize = 0;
        while (subbnd < @as(usize, @intCast(n_subbands)) - 1) : (subbnd += 1) {
            bsf[subbnd] = @intCast(try gb.readBits(1));
        }
    }

    // 依据带结构计算带数与带宽（bin 数）
    var n_bands: i32 = n_subbands;
    bnd_sz[0] = if (ecpl != 0) 6 else 12;
    var bnd: usize = 0;
    var subbnd: usize = 1;
    while (subbnd < @as(usize, @intCast(n_subbands))) : (subbnd += 1) {
        const subbnd_size: u8 = if (ecpl != 0 and subbnd < 4) 6 else 12;
        if (bsf[subbnd - 1] != 0) {
            n_bands -= 1;
            bnd_sz[bnd] += subbnd_size;
        } else {
            bnd += 1;
            bnd_sz[bnd] = subbnd_size;
        }
    }

    const nb: usize = @intCast(n_bands);
    @memcpy(band_sizes[0..nb], bnd_sz[0..nb]);
    return n_bands;
}

/// 解码耦合带结构。blk=0 时用默认带结构展开；eac3=1 且首位为 0 时沿用默认/历史，
/// 否则从位流读 per-subband 合并标志（对应 C `decode_band_structure`）。
/// cpl_start_freq / cpl_end_freq 为子带号；band_sizes 以 bin 计。
/// 返回 true=错误（位流越界）。
pub fn decodeBandStructure(
    gb: *BitReader,
    blk: i32,
    eac3: i32,
    cpl_start_freq: i32,
    cpl_end_freq: i32,
    band_struct: []u8,
    band_sizes: []u8,
) bool {
    _ = decodeBandStructureInner(gb, blk, eac3, 0, cpl_start_freq, cpl_end_freq, &t.eac3_default_cpl_band_struct, band_struct, band_sizes) catch return true;
    return false;
}

/// 耦合策略（对照 C `coupling_strategy`）。
/// 先按 C `memset(bit_alloc_stages, 3, AC3_MAX_CHANNELS)` 置位分配阶段；
/// 非 eac3 时读 cpl_in_use；耦合启用时逐声道读 channel_in_cpl、相位标志、
/// 耦合频率范围（写 start_freq[CPL_CH]/end_freq[CPL_CH]），再经 decodeBandStructure
/// 得 num_cpl_bands 与 cpl_band_sizes；未启用时清空耦合状态。
/// 返回 true=错误（非法模式/无效范围/增强耦合未实现/位流越界）。
pub fn couplingStrategy(s: *Ctx, blk: i32, bit_alloc_stages: []u8) bool {
    const fbw_channels = s.fbw_channels;
    const channel_mode = s.channel_mode;
    const blk_u: usize = @intCast(blk);

    @memset(bit_alloc_stages[0..@min(bit_alloc_stages.len, t.AC3_MAX_CHANNELS)], 3);

    if (s.eac3 == 0) {
        s.cpl_in_use[blk_u] = @intCast(s.gb.readBits(1) catch return true);
    }

    if (s.cpl_in_use[blk_u] != 0) {
        // mono / dual-mono 不允许耦合
        if (channel_mode < @as(i32, t.AC3_CHMODE_STEREO)) return true;

        // 增强耦合（enhanced coupling）未实现
        if (s.eac3 != 0 and (s.gb.readBits(1) catch return true) != 0) return true;

        // 确定哪些声道在耦合中
        if (s.eac3 != 0 and channel_mode == @as(i32, t.AC3_CHMODE_STEREO)) {
            s.channel_in_cpl[1] = 1;
            s.channel_in_cpl[2] = 1;
        } else {
            var ch: usize = 1;
            while (ch <= @as(usize, @intCast(fbw_channels))) : (ch += 1) {
                s.channel_in_cpl[ch] = @intCast(s.gb.readBits(1) catch return true);
            }
        }

        // 相位标志是否使用
        if (channel_mode == @as(i32, t.AC3_CHMODE_STEREO)) {
            s.phase_flags_in_use = @intCast(s.gb.readBits(1) catch return true);
        }

        // 耦合频率范围（子带号）
        const range: struct { start: i32, end: i32 } = rng: {
            const cpl_start_subband: i32 = @intCast(s.gb.readBits(4) catch return true);
            const cpl_end_subband: i32 = if (s.spx_in_use != 0)
                @divTrunc(s.spx_src_start_freq - 37, 12)
            else
                @as(i32, @intCast(s.gb.readBits(4) catch return true)) + 3;
            break :rng .{ .start = cpl_start_subband, .end = cpl_end_subband };
        };

        if (range.start >= range.end) return true;

        s.start_freq[t.CPL_CH] = range.start * 12 + 37;
        s.end_freq[t.CPL_CH] = range.end * 12 + 37;

        s.num_cpl_bands = decodeBandStructureInner(
            &s.gb,
            blk,
            s.eac3,
            0,
            range.start,
            range.end,
            &t.eac3_default_cpl_band_struct,
            &s.cpl_band_struct,
            &s.cpl_band_sizes,
        ) catch return true;
    } else {
        // 耦合未使用
        var ch: usize = 1;
        while (ch <= @as(usize, @intCast(fbw_channels))) : (ch += 1) {
            s.channel_in_cpl[ch] = 0;
            s.first_cpl_coords[ch] = 1;
        }
        s.first_cpl_leak = s.eac3;
        s.phase_flags_in_use = 0;
    }

    return false;
}

/// 耦合坐标（对照 C `coupling_coordinates`）。
/// 每个在耦合中的声道读 master 坐标与每带 (exp, mant) 坐标；
/// exp==15 时 cpl_coords = mant<<22，否则 (mant+16)<<21，再右移 (exp+master)。
/// 立体声且存在新坐标时读相位标志 phase_flags。
/// 返回 true=错误（blk==0 缺少新坐标 / 位流越界）。
pub fn couplingCoordinates(s: *Ctx, blk: i32) bool {
    const fbw_channels = s.fbw_channels;
    var cpl_coords_exist = false;

    var ch: usize = 1;
    while (ch <= @as(usize, @intCast(fbw_channels))) : (ch += 1) {
        if (s.channel_in_cpl[ch] != 0) {
            const new_coords = (s.eac3 != 0 and s.first_cpl_coords[ch] != 0) or
                (s.gb.readBits(1) catch return true) != 0;
            if (new_coords) {
                s.first_cpl_coords[ch] = 0;
                cpl_coords_exist = true;
                const master_cpl_coord: i32 = 3 * @as(i32, @intCast(s.gb.readBits(2) catch return true));
                var bnd: usize = 0;
                while (bnd < @as(usize, @intCast(s.num_cpl_bands))) : (bnd += 1) {
                    const cpl_coord_exp: i32 = @intCast(s.gb.readBits(4) catch return true);
                    const cpl_coord_mant: i32 = @intCast(s.gb.readBits(4) catch return true);
                    if (cpl_coord_exp == 15)
                        s.cpl_coords[ch][bnd] = cpl_coord_mant << 22
                    else
                        s.cpl_coords[ch][bnd] = (cpl_coord_mant + 16) << 21;
                    s.cpl_coords[ch][bnd] >>= @intCast(cpl_coord_exp + master_cpl_coord);
                }
            } else if (blk == 0) {
                return true; // 块 0 必须携带新耦合坐标
            }
        } else {
            s.first_cpl_coords[ch] = 1;
        }
    }

    // 相位标志
    if (s.channel_mode == @as(i32, t.AC3_CHMODE_STEREO) and cpl_coords_exist) {
        var bnd: usize = 0;
        while (bnd < @as(usize, @intCast(s.num_cpl_bands))) : (bnd += 1) {
            s.phase_flags[bnd] = if (s.phase_flags_in_use != 0)
                @intCast(s.gb.readBits(1) catch return true)
            else
                0;
        }
    }

    return false;
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------
test "decodeBandStructure：blk0 用默认带结构" {
    t.initStatic();
    var buf = [_]u8{ 0x00, 0x00 };
    var gb = BitReader.init(&buf);
    var band_struct: [18]u8 = [_]u8{0} ** 18;
    var band_sizes: [18]u8 = [_]u8{0} ** 18;
    const err = decodeBandStructure(&gb, 0, 1, 0, 18, &band_struct, &band_sizes);
    try std.testing.expect(!err);
    try std.testing.expectEqual(@as(usize, 1), gb.bit_pos);
    try std.testing.expectEqualSlices(u8, &t.eac3_default_cpl_band_struct, &band_struct);
    try std.testing.expectEqual(@as(u8, 12), band_sizes[0]);
    try std.testing.expectEqual(@as(u8, 24), band_sizes[7]);
    try std.testing.expectEqual(@as(u8, 72), band_sizes[9]);
}

test "couplingStrategy：立体声启用耦合" {
    t.initStatic();
    var buf = [_]u8{ 0xF1, 0x54, 0x80 };
    var ctx: Ctx = .{};
    ctx.gb = BitReader.init(&buf);
    ctx.eac3 = 0;
    ctx.channel_mode = t.AC3_CHMODE_STEREO;
    ctx.fbw_channels = 2;
    var stages: [t.AC3_MAX_CHANNELS]u8 = [_]u8{0} ** t.AC3_MAX_CHANNELS;
    const err = couplingStrategy(&ctx, 0, &stages);
    try std.testing.expect(!err);
    try std.testing.expectEqual(@as(usize, 18), ctx.gb.bit_pos);
    try std.testing.expectEqual(@as(i32, 1), ctx.cpl_in_use[0]);
    try std.testing.expectEqual(@as(i32, 1), ctx.channel_in_cpl[1]);
    try std.testing.expectEqual(@as(i32, 1), ctx.channel_in_cpl[2]);
    try std.testing.expectEqual(@as(i32, 1), ctx.phase_flags_in_use);
    try std.testing.expectEqual(@as(i32, 49), ctx.start_freq[0]);
    try std.testing.expectEqual(@as(i32, 133), ctx.end_freq[0]);
    try std.testing.expectEqual(@as(i32, 5), ctx.num_cpl_bands);
}

test "couplingCoordinates：立体声双声道坐标" {
    t.initStatic();
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
    const err = couplingCoordinates(&ctx, 0);
    try std.testing.expect(!err);
    try std.testing.expectEqual(@as(usize, 91), ctx.gb.bit_pos);
    try std.testing.expectEqual(@as(i32, 294912), ctx.cpl_coords[1][0]);
    try std.testing.expectEqual(@as(i32, 1114112), ctx.cpl_coords[2][0]);
    try std.testing.expectEqual(@as(i32, 1), ctx.phase_flags[0]);
    try std.testing.expectEqual(@as(i32, 0), ctx.phase_flags[1]);
}

test "couplingStrategy：耦合未使用（cpl_in_use=0）" {
    t.initStatic();
    var buf = [_]u8{ 0x00, 0x00 };
    var ctx: Ctx = .{};
    ctx.gb = BitReader.init(&buf);
    ctx.eac3 = 0;
    ctx.channel_mode = t.AC3_CHMODE_STEREO;
    ctx.fbw_channels = 2;
    var stages: [t.AC3_MAX_CHANNELS]u8 = [_]u8{0} ** t.AC3_MAX_CHANNELS;
    const err = couplingStrategy(&ctx, 0, &stages);
    try std.testing.expect(!err);
    try std.testing.expectEqual(@as(usize, 1), ctx.gb.bit_pos);
    try std.testing.expectEqual(@as(i32, 0), ctx.cpl_in_use[0]);
    try std.testing.expectEqual(@as(i32, 0), ctx.channel_in_cpl[1]);
}
