//! AC-3 / E-AC-3 尾数解包与变换系数（对照 FFmpeg ac3dec.c，float 路径 USE_FIXED=0）
//!
//! 移植的函数（以 /tmp/ac3dec.c 为唯一参考源）：
//!   dequantizeCoeff            — dequantize_coeff（407-419）：尾数 × 2^-exp
//!   calcTransformCoeffsCpl     — calc_transform_coeffs_cpl（363-396）：耦合声道
//!                                按 cpl_coord 比例展开各声道耦合区系数
//!   ac3DecodeTransformCoeffsCh — ac3_decode_transform_coeffs_ch（432-526）：单声道
//!                                尾数解包（分组/查表/有符号位）+ 反量化
//!   removeDithering            — remove_dithering（527-537）：零尾数抖动消除
//!   decodeTransformCoeffsCh    — decode_transform_coeffs_ch（540-556）：AHT 分发
//!   decodeTransformCoeffs      — decode_transform_coeffs（561-590）：整帧逐声道驱动
//!
//! 与 C 的差异（务必知悉）：
//!   - AVLFG 按任务契约简化为单状态 LCG state = 1664525*state + 1013904223（32 位），
//!     每次调用返回新状态；FFmpeg 现行 64 槽拉格斐式 PRNG 不在本移植范围。
//!   - Ctx 无 dith_state 字段（共享契约不可改），故抖动状态为模块级单例；
//!     解码器实例使用前须调用 resetDith()。
//!   - C 的 get_bits 越界静默返回 0；本实现 BitReader 越界抛 error.Corrupt，
//!     函数以 bool 表示错误（false=成功，true=位流损坏），与 coupling.zig 一致。
//!   - C 中 bap>15 时打印错误并钳位为 15，此处直接钳位（无日志）。
//!   - E-AC-3 AHT（ff_eac3_decode_transform_coeffs_aht_ch）不在本模块范围，
//!     AHT 分支仅对 pre_mantissa 做反量化（对照 C 540-556 的循环）。
//!
//! 数值说明：calc_transform_coeffs_cpl 的 float 路径不含 cos 表，只做
//!   coeffs[ch][bin] = coeffs[CPL_CH][bin] * (cpl_coords[ch][band] * 2^-23)，
//!   相位标志仅对 ch==2 所在带取反。

const t = @import("tables.zig");
const md5impl = @import("md5.zig");
const Ctx = @import("ctx.zig").Ctx;
const MantGroups = @import("ctx.zig").MantGroups;
const BitReader = @import("../aac/bitreader.zig").BitReader;

/// 每个解码指数的缩放系数：2^-exp（对照 C scale_factors[25]）。
pub const scale_factors = [25]f32{
    0x1p-0,  0x1p-1,  0x1p-2,  0x1p-3,  0x1p-4,
    0x1p-5,  0x1p-6,  0x1p-7,  0x1p-8,  0x1p-9,
    0x1p-10, 0x1p-11, 0x1p-12, 0x1p-13, 0x1p-14,
    0x1p-15, 0x1p-16, 0x1p-17, 0x1p-18, 0x1p-19,
    0x1p-20, 0x1p-21, 0x1p-22, 0x1p-23, 0x1p-24,
};

/// 抖动 AVLFG（对照 FFmpeg libavutil/lfg.h AVLFG：64 状态加性 LFG）。
pub const AvLfg = struct {
    state: [64]u32 = [_]u32{0} ** 64,
    index: u32 = 0,

    pub fn init(self: *AvLfg, seed: u32) void {
        var tmp: [16]u8 = [_]u8{0} ** 16;
        var i: usize = 8;
        while (i < 64) : (i += 4) {
            std.mem.writeInt(u32, tmp[0..4], seed, .little);
            tmp[4] = @intCast(i);
            var md5: md5impl.Md5 = .init(.{});
            md5.update(&tmp);
            md5.final(&tmp);
            self.state[i] = std.mem.readInt(u32, tmp[0..4], .little);
            self.state[i + 1] = std.mem.readInt(u32, tmp[4..8], .little);
            self.state[i + 2] = std.mem.readInt(u32, tmp[8..12], .little);
            self.state[i + 3] = std.mem.readInt(u32, tmp[12..16], .little);
        }
        self.index = 0;
    }

    pub fn next(self: *AvLfg) u32 {
        const v = self.state[@intCast(self.index & 63)] +% self.state[@intCast((self.index -% 24) & 63)] +% self.state[@intCast((self.index -% 55) & 63)];
        self.state[@intCast(self.index & 63)] = v;
        self.index +%= 1;
        return v;
    }
};

var dith: AvLfg = .{};

/// 重置抖动状态（对应 C 中 av_lfg_init(&s->dith_state, 0)）。
pub fn resetDith() void {
    dith.init(0);
}

/// 取下一个 AVLFG 值（对应 C `av_lfg_get`）。
pub fn nextDith() u32 {
    return dith.next();
}

/// 反量化：mantissa * 2^-exponent（对照 C dequantize_coeff float 路径）。
/// exponent 须在 0..24（C 直接查表，不做边界检查）。
inline fn dequantizeCoeff(mantissa: i32, exponent: i32) f32 {
    const e: usize = @intCast(std.math.clamp(exponent, 0, 24));
    return @as(f32, @floatFromInt(mantissa)) * scale_factors[e];
}

/// 读 n 位并符号扩展（对照 FFmpeg get_sbits）。
fn getSBits(gb: *BitReader, n: u6) !i32 {
    const raw = try gb.readBits(n);
    const sign_bit: u32 = @as(u32, 1) << @intCast(n - 1);
    if ((raw & sign_bit) != 0) {
        return @as(i32, @bitCast(raw | (~@as(u32, 0) << @intCast(n))));
    }
    return @intCast(raw);
}

/// 耦合变换系数（对照 C calc_transform_coeffs_cpl）。
/// 逐耦合带，把耦合声道系数按 cpl_coord 比例写入各在耦合中的声道；
/// 立体声中声道 ch==2 且该带 phase_flags 置位时取反。
pub fn calcTransformCoeffsCpl(s: *Ctx) void {
    var bin: usize = @intCast(s.start_freq[t.CPL_CH]);
    var band: usize = 0;
    while (band < @as(usize, @intCast(s.num_cpl_bands))) : (band += 1) {
        const band_start = bin;
        const band_end = bin + @as(usize, s.cpl_band_sizes[band]);
        var ch: usize = 1;
        while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
            if (s.channel_in_cpl[ch] != 0) {
                const cpl_coord: f32 = @as(f32, @floatFromInt(s.cpl_coords[ch][band])) * (1.0 / @as(f32, 1 << 23));
                var b: usize = band_start;
                while (b < band_end) : (b += 1) {
                    s.coeffs[ch][b] = s.coeffs[t.CPL_CH][b] * cpl_coord;
                }
                if (ch == 2 and s.phase_flags[band] != 0) {
                    var b2: usize = band_start;
                    while (b2 < band_end) : (b2 += 1) {
                        s.coeffs[2][b2] = -s.coeffs[2][b2];
                    }
                }
            }
        }
        bin = band_end;
    }
}

/// 单声道尾数解包 + 反量化（对照 C ac3_decode_transform_coeffs_ch）。
/// bap 分档：
///   0   ：无位数（抖动时用 LCG 伪随机尾数，否则 0）
///   1   ：3 值 5 位组，m.b1_mant 缓存（表 7.20）
///   2   ：3 值 7 位组，m.b2_mant 缓存（表 7.22）
///   3   ：bap3_mantissas[3 位]（7 级对称量化）
///   4   ：2 值 7 位组，m.b4_mant 缓存（表 7.21）
///   5   ：bap5_mantissas[4 位]（15 级对称量化）
///   6-15：get_sbits(quantization_tab[bap]) 有符号位，符号扩展至 24 位
/// 返回 true=位流损坏。
pub fn ac3DecodeTransformCoeffsCh(s: *Ctx, ch_index: usize, m: *MantGroups) bool {
    const start_freq: usize = @intCast(s.start_freq[ch_index]);
    const end_freq: usize = @intCast(s.end_freq[ch_index]);
    const dither = (ch_index == t.CPL_CH) or (s.dither_flag[ch_index] != 0);

    var freq: usize = start_freq;
    while (freq < end_freq) : (freq += 1) {
        const bap = s.bap[ch_index][freq];
        var mantissa: i32 = 0;
        switch (bap) {
            0 => {
                if (dither) {
                    const r = dith.next();

                    mantissa = @bitCast(@as(u32, ((r >> 8) *% 181) >> 8) -% 5931008);

                } else {
                    mantissa = 0;

                }
            },
            1 => {
                if (m.b1 != 0) {
                    m.b1 -= 1;
                    mantissa = m.b1_mant[@intCast(m.b1)];
                } else {
                    const bits = s.gb.readBits(5) catch return true;
                    mantissa = t.bap1_mantissas[bits][0];
                    m.b1_mant[1] = t.bap1_mantissas[bits][1];
                    m.b1_mant[0] = t.bap1_mantissas[bits][2];
                    m.b1 = 2;
                }
            },
            2 => {
                if (m.b2 != 0) {
                    m.b2 -= 1;
                    mantissa = m.b2_mant[@intCast(m.b2)];
                } else {
                    const bits = s.gb.readBits(7) catch return true;
                    mantissa = t.bap2_mantissas[bits][0];
                    m.b2_mant[1] = t.bap2_mantissas[bits][1];
                    m.b2_mant[0] = t.bap2_mantissas[bits][2];
                    m.b2 = 2;
                }
            },
            3 => {
                mantissa = t.bap3_mantissas[s.gb.readBits(3) catch return true];
            },
            4 => {
                if (m.b4 != 0) {
                    m.b4 = 0;
                    mantissa = m.b4_mant;
                } else {
                    const bits = s.gb.readBits(7) catch return true;
                    mantissa = t.bap4_mantissas[bits][0];
                    m.b4_mant = t.bap4_mantissas[bits][1];
                    m.b4 = 1;
                }
            },
            5 => {
                mantissa = t.bap5_mantissas[s.gb.readBits(4) catch return true];
            },
            else => {
                var b = bap;
                if (b > 15) b = 15;
                const qbits: u6 = @intCast(t.quantization_tab[b]);
                const sbits = getSBits(&s.gb, qbits) catch return true;

                // (unsigned)get_sbits << (24 - qbits)：32 位无符号左移，丢弃溢出高位
                const um: u32 = @as(u32, @bitCast(sbits)) << @intCast(24 - qbits);
                mantissa = @bitCast(um);
            },
        }
        s.coeffs[ch_index][freq] = dequantizeCoeff(mantissa, s.dexps[ch_index][freq]);
    }
    return false;
}

/// 消除耦合区零尾数抖动（对照 C remove_dithering）。
/// 在耦合中的声道若未用抖动，其耦合区内耦合声道 bap=0 的系数清零。
pub fn removeDithering(s: *Ctx) void {
    var ch: usize = 1;
    while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
        if (s.dither_flag[ch] == 0 and s.channel_in_cpl[ch] != 0) {
            var i: usize = @intCast(s.start_freq[t.CPL_CH]);
            const e: usize = @intCast(s.end_freq[t.CPL_CH]);
            while (i < e) : (i += 1) {
                if (s.bap[t.CPL_CH][i] == 0) {
                    s.coeffs[ch][i] = 0;
                }
            }
        }
    }
}

fn getSbits(gb: *BitReader, n: u6) !i32 {
    const v = try gb.readBits(n);
    const sign_bit: u32 = @as(u32, 1) << @intCast(n - 1);
    if ((v & sign_bit) != 0) {
        return @as(i32, @bitCast(v | (~@as(u32, 0) << @intCast(n))));
    }
    return @as(i32, @intCast(v));
}

/// AHT 6 点 IDCT（对照 C eac3dec.c idct6，24 位定点）。
/// 中间乘法用 i64 避免 i32 溢出（C 中 int 乘法理论 UB，实际值不越界）。
fn idct6(pre_mant: *[6]i32) void {
    const c0: i64 = t.aht_coeff_0;
    const c1: i64 = t.aht_coeff_1;
    const c2: i64 = t.aht_coeff_2;

    const odd1 = pre_mant[1] - pre_mant[3] - pre_mant[5];

    var even2: i32 = @intCast((@as(i64, pre_mant[2]) * c0) >> 23);
    const tmp: i32 = @intCast((@as(i64, pre_mant[4]) * c1) >> 23);
    const odd0: i32 = @intCast((@as(i64, pre_mant[1] + pre_mant[5]) * c2) >> 23);

    var even0 = pre_mant[0] + (tmp >> 1);
    const even1 = pre_mant[0] - tmp;

    var tmp2 = even0;
    even0 = tmp2 + even2;
    even2 = tmp2 - even2;

    tmp2 = odd0;
    const odd0b = tmp2 + pre_mant[1] + pre_mant[3];
    const odd2 = tmp2 + pre_mant[5] - pre_mant[3];

    pre_mant[0] = even0 + odd0b;
    pre_mant[1] = even1 + odd1;
    pre_mant[2] = even2 + odd2;
    pre_mant[3] = even2 - odd2;
    pre_mant[4] = even1 - odd1;
    pre_mant[5] = even0 - odd0b;
}

/// E-AC-3 AHT 变换系数解码（对照 C ff_eac3_decode_transform_coeffs_aht_ch）。
/// 解码全部 6 块的 pre_mantissa；调用方须在块 0 时调用。
fn decodeTransformCoeffsAht(s: *Ctx, ch: usize) bool {
    const gb = &s.gb;
    const start: usize = @intCast(s.start_freq[ch]);
    const end: usize = @intCast(s.end_freq[ch]);

    const gaq_mode: u32 = gb.readBits(2) catch return true;
    const end_bap: i32 = if (gaq_mode < 2) 12 else 17;

    var gaq_gain: [t.AC3_MAX_COEFS]i32 = undefined;
    var gs: usize = 0;
    if (gaq_mode == 1 or gaq_mode == 2) {
        var bin = start;
        while (bin < end) : (bin += 1) {
            const bap: i32 = s.bap[ch][bin];
            if (bap > 7 and bap < end_bap) {
                gaq_gain[gs] = @intCast((gb.readBits(1) catch return true) << @intCast(gaq_mode - 1));
                gs += 1;
            }
        }
    } else if (gaq_mode == 3) {
        var gc: i32 = 2;
        var bin = start;
        while (bin < end) : (bin += 1) {
            const bap: i32 = s.bap[ch][bin];
            if (bap > 7 and bap < 17) {
                gc += 1;
                if (gc == 3) {
                    var group_code: u32 = gb.readBits(5) catch return true;
                    if (group_code > 26) group_code = 26;
                    const row = t.ungroup_3_in_5_bits_tab[@as(usize, group_code)];
                    gaq_gain[gs] = row[0];
                    gs += 1;
                    gaq_gain[gs] = row[1];
                    gs += 1;
                    gaq_gain[gs] = row[2];
                    gs += 1;
                    gc = 0;
                }
            }
        }
    }

    gs = 0;
    var bin = start;
    while (bin < end) : (bin += 1) {
        const hebap: usize = @intCast(s.bap[ch][bin]);
        const bits: u32 = t.eac3_bits_vs_hebap[hebap];
        if (hebap == 0) {
            for (0..6) |blk| {
                s.pre_mantissa[ch][bin][blk] = @bitCast((nextDith() & 0x7FFFFF) -% 0x400000);
            }
        } else if (hebap < 8) {
            const v: usize = @intCast(gb.readBits(@intCast(bits)) catch return true);
            const vq: *const [6]i16 = switch (hebap) {
                1 => &t.vq_hebap1[v],
                2 => &t.vq_hebap2[v],
                3 => &t.vq_hebap3[v],
                4 => &t.vq_hebap4[v],
                5 => &t.vq_hebap5[v],
                6 => &t.vq_hebap6[v],
                else => &t.vq_hebap7[v],
            };
            for (0..6) |blk| {
                s.pre_mantissa[ch][bin][blk] = @as(i32, vq[blk]) << 8;
            }
        } else {
            const log_gain: u32 = if (gaq_mode != 0 and @as(i32, @intCast(hebap)) < end_bap) blk: {
                const lg: u32 = @intCast(gaq_gain[gs]);
                gs += 1;
                break :blk lg;
            } else 0;
            const gbits: u6 = @intCast(@as(i32, @intCast(bits)) - @as(i32, @intCast(log_gain)));
            for (0..6) |blk| {
                var mant: i32 = getSbits(gb, gbits) catch return true;
                if (log_gain != 0 and mant == -(@as(i32, 1) << @as(u5, @intCast(gbits - 1)))) {
                    const mbits: u6 = @intCast(@as(i32, @intCast(bits)) - (2 - @as(i32, @intCast(log_gain))));
                    mant = getSbits(gb, mbits) catch return true;
                    mant = @as(i32, @bitCast(@as(u32, @bitCast(mant)) << @as(u5, @intCast(23 - (mbits - 1)))));
                    const b: i32 = if (mant >= 0)
                        @as(i32, 1) << @as(u5, @intCast(23 - log_gain))
                    else
                        @as(i32, t.eac3_gaq_remap_2_4_b[hebap - 8][log_gain - 1]) << 8;
                    mant += @as(i32, @intCast((@as(i64, t.eac3_gaq_remap_2_4_a[hebap - 8][log_gain - 1]) * mant) >> 15)) + b;
                } else {
                    mant *= @as(i32, 1) << @as(u5, @intCast(24 - bits));
                    if (log_gain == 0) {
                        mant += @as(i32, @intCast((@as(i64, t.eac3_gaq_remap_1[hebap - 8]) * mant) >> 15));
                    }
                }
                s.pre_mantissa[ch][bin][blk] = mant;
            }
        }
        idct6(&s.pre_mantissa[ch][bin]);
    }
    return false;
}

/// 单声道变换系数分发（对照 C decode_transform_coeffs_ch）。
/// channel_uses_aht 时块 0 解码全部 6 块 pre_mantissa，每块反量化。
pub fn decodeTransformCoeffsCh(s: *Ctx, blk: i32, ch: usize, m: *MantGroups) bool {
    if (s.channel_uses_aht[ch] == 0) {
        return ac3DecodeTransformCoeffsCh(s, ch, m);
    }
    if (blk == 0) {
        if (decodeTransformCoeffsAht(s, ch)) return true;
    }
    const blk_u: usize = @intCast(blk);
    var bin: usize = @intCast(s.start_freq[ch]);
    const end: usize = @intCast(s.end_freq[ch]);
    while (bin < end) : (bin += 1) {
        s.coeffs[ch][bin] = dequantizeCoeff(s.pre_mantissa[ch][bin][blk_u], s.dexps[ch][bin]);
    }
    return false;
}

/// 整帧变换系数解码（对照 C decode_transform_coeffs）。
/// 逐声道解码；首个在耦合中的声道之后紧跟耦合声道与 calcTransformCoeffsCpl；
/// 每声道把 [end_freq, 256) 清零；最后 removeDithering。
/// 返回 true=位流损坏。
pub fn decodeTransformCoeffs(s: *Ctx, blk: i32) bool {
    var m: MantGroups = .{};
    var got_cplchan = false;

    const n_ch: usize = @intCast(s.channels);
    var ch: usize = 1;
    while (ch <= n_ch) : (ch += 1) {
        if (decodeTransformCoeffsCh(s, blk, ch, &m)) return true;
        var end: usize = undefined;
        if (s.channel_in_cpl[ch] != 0) {
            if (!got_cplchan) {
                if (decodeTransformCoeffsCh(s, blk, t.CPL_CH, &m)) return true;
                calcTransformCoeffsCpl(s);
                got_cplchan = true;
            }
            end = @intCast(s.end_freq[t.CPL_CH]);
        } else {
            end = @intCast(s.end_freq[ch]);
        }
        while (end < t.AC3_MAX_COEFS) : (end += 1) {
            s.coeffs[ch][end] = 0;
        }
    }

    removeDithering(s);
    return false;
}

// ---------------------------------------------------------------------------
// 单元测试（`zig test mantissa.zig`）
// ---------------------------------------------------------------------------

const std = @import("std");

test "dequantizeCoeff: mantissa=1000 exp=2 → 250.0" {
    // 1000 * 2^-2 = 250.0
    try std.testing.expectEqual(@as(f32, 250.0), dequantizeCoeff(1000, 2));
    try std.testing.expectEqual(@as(f32, 1.0), dequantizeCoeff(1, 0));
    try std.testing.expectEqual(@as(f32, -0.5), dequantizeCoeff(-1, 1));
    try std.testing.expectEqual(@as(f32, 16777216.0), dequantizeCoeff(16777216, 0));
    try std.testing.expectEqual(@as(f32, 1.0), dequantizeCoeff(16777216, 24));
}

test "AvLfg: av_lfg_init(0) 前 5 步与 C 参考一致" {
    var lcg: AvLfg = .{};
    lcg.init(0);
    const expected = [_]u32{ 3871727025, 2377540866, 3249482316, 1094828782, 1054253117 };
    for (expected) |e| {
        try std.testing.expectEqual(e, lcg.next());
    }
}

test "tables: bap3/bap5 表与 symmetric dequant 一致" {
    t.initStatic();
    try std.testing.expectEqual(@as(i32, -7190235), t.bap3_mantissas[0]);
    try std.testing.expectEqual(@as(i32, 7190235), t.bap3_mantissas[6]);
    try std.testing.expectEqual(@as(i32, -7829367), t.bap5_mantissas[0]);
    try std.testing.expectEqual(@as(i32, 7829367), t.bap5_mantissas[14]);
    try std.testing.expectEqual(@as(i32, 0), t.bap5_mantissas[15]);
}
