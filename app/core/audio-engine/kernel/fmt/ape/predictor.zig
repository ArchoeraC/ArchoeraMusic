//! APE 预测解码器 + 长滤波器 + 终级滤波器（docs/audio-kernel-zig.md §9.10）
//!
//! 参考重构对照 FFmpeg libavcodec/apedec.c：filter_fast_3320 / filter_3800 /
//! long_filter_high_3800 / long_filter_ehigh_3830 / predictor_update_3930 /
//! predictor_update_filter（64-bit）/ do_apply_filter / do_init_filter，
//! 逐位复刻（含所有 (unsigned)/uint32/uint64 回绕与算术右移语义）保证 bit-exact；
//! 参考对照非复制（§3.3）。
//!
//! 版本分派（对齐 ape_decode_init）：
//!   < 3930 → 3800 系列（FAST=1000 走 filter_fast_3320；HIGH/EXTRA_HIGH 先做长滤波）
//!   3930-3949 → predictor_update_3930（先终级滤波）
//!   >= 3950 → predictor_update_filter（64-bit，先终级滤波；24-bit 走 interim 双趟）

const std = @import("std");

const HISTORY_SIZE = 512;
const PREDICTOR_SIZE = 50;
const PREDICTOR_BUF = HISTORY_SIZE + PREDICTOR_SIZE;

const YDELAYA = 18 + 4 * 8; // 50
const YDELAYB = 18 + 3 * 8; // 42
const XDELAYA = 18 + 2 * 8; // 34
const XDELAYB = 18 + 1 * 8; // 26
const YADAPTCOEFFSA = 18;
const XADAPTCOEFFSA = 14;
const YADAPTCOEFFSB = 10;
const XADAPTCOEFFSB = 5;

pub const APE_FILTER_LEVELS = 3;

pub const COMPRESSION_LEVEL_FAST = 1000;
pub const COMPRESSION_LEVEL_NORMAL = 2000;
pub const COMPRESSION_LEVEL_HIGH = 3000;
pub const COMPRESSION_LEVEL_EXTRA_HIGH = 4000;
pub const COMPRESSION_LEVEL_INSANE = 5000;

/// 各压缩级别的终级滤波阶数（[5][3]，0 表示该级不启用）
const filter_orders = [5][APE_FILTER_LEVELS]u16{
    .{ 0, 0, 0 },
    .{ 16, 0, 0 },
    .{ 64, 0, 0 },
    .{ 32, 256, 0 },
    .{ 16, 256, 1280 },
};

/// 各压缩级别的终级滤波小数位（[5][3]）
const filter_fracbits = [5][APE_FILTER_LEVELS]u8{
    .{ 0, 0, 0 },
    .{ 11, 0, 0 },
    .{ 11, 0, 0 },
    .{ 10, 13, 0 },
    .{ 11, 13, 15 },
};

/// 逆符号（APESIGN：负 → +1，正 → -1，零 → 0）
pub inline fn apeSign(x: i32) i32 {
    return (if (x < 0) @as(i32, 1) else 0) - (if (x > 0) @as(i32, 1) else 0);
}

/// APESIGN 作用于 int64（C 隐式截断为 int32 后判定）
pub inline fn apeSign64(x: i64) i32 {
    return apeSign(@truncate(x));
}

/// 32-bit 预测器（fileversion < 3950 的最终重建）
pub const Predictor = struct {
    buf: [PREDICTOR_BUF]i32 = [_]i32{0} ** PREDICTOR_BUF,
    buf_off: usize = 0,
    sample_pos: u32 = 0,
    lastA: [2]i32 = .{ 0, 0 },
    filterA: [2]i32 = .{ 0, 0 },
    filterB: [2]i32 = .{ 0, 0 },
    coeffsA: [2][4]u32 = [_][4]u32{.{0} ** 4} ** 2,
    coeffsB: [2][5]u32 = [_][5]u32{.{0} ** 5} ** 2,

    pub inline fn at(self: *const Predictor, i: usize) i32 {
        return self.buf[self.buf_off + i];
    }

    pub inline fn set(self: *Predictor, i: usize, v: i32) void {
        self.buf[self.buf_off + i] = v;
    }

    /// buf++ + sample_pos++，到 HISTORY_SIZE 时把末 50 元素搬回起点
    pub fn step(self: *Predictor) void {
        self.buf_off += 1;
        self.sample_pos +%= 1;
        if (self.buf_off == HISTORY_SIZE) {
            std.mem.copyForwards(i32, self.buf[0..PREDICTOR_SIZE], self.buf[HISTORY_SIZE..][0..PREDICTOR_SIZE]);
            self.buf_off = 0;
        }
    }

    /// 仅 buf++（3930 之后系列不追踪 sample_pos）
    pub fn stepNoPos(self: *Predictor) void {
        self.buf_off += 1;
        if (self.buf_off == HISTORY_SIZE) {
            std.mem.copyForwards(i32, self.buf[0..PREDICTOR_SIZE], self.buf[HISTORY_SIZE..][0..PREDICTOR_SIZE]);
            self.buf_off = 0;
        }
    }

    /// init_predictor_decoder：按版本/压缩级别初始化系数与状态
    pub fn init(self: *Predictor, fileversion: u32, compression_level: u32) void {
        self.buf = [_]i32{0} ** PREDICTOR_BUF;
        self.buf_off = 0;
        self.sample_pos = 0;
        self.lastA = .{ 0, 0 };
        self.filterA = .{ 0, 0 };
        self.filterB = .{ 0, 0 };
        if (fileversion < 3930) {
            const ca = if (compression_level == COMPRESSION_LEVEL_FAST)
                [4]u32{ 375, 0, 0, 0 }
            else
                [4]u32{ 64, 115, 64, 0 };
            self.coeffsA = .{ ca, ca };
            self.coeffsB = .{ .{ 740, 0, 0, 0, 0 }, .{ 740, 0, 0, 0, 0 } };
        } else {
            const ca: [4]u32 = .{ 360, 317, @bitCast(@as(i32, -109)), 98 };
            self.coeffsA = .{ ca, ca };
            self.coeffsB = [_][5]u32{.{0} ** 5} ** 2;
        }
    }
};

/// 64-bit 预测器（fileversion >= 3950）
pub const Predictor64 = struct {
    buf: [PREDICTOR_BUF]i64 = [_]i64{0} ** PREDICTOR_BUF,
    buf_off: usize = 0,
    lastA: [2]i64 = .{ 0, 0 },
    filterA: [2]i64 = .{ 0, 0 },
    filterB: [2]i64 = .{ 0, 0 },
    coeffsA: [2][4]u64 = [_][4]u64{.{0} ** 4} ** 2,
    coeffsB: [2][5]u64 = [_][5]u64{.{0} ** 5} ** 2,

    pub inline fn at(self: *const Predictor64, i: usize) i64 {
        return self.buf[self.buf_off + i];
    }

    pub inline fn set(self: *Predictor64, i: usize, v: i64) void {
        self.buf[self.buf_off + i] = v;
    }

    pub fn stepNoPos(self: *Predictor64) void {
        self.buf_off += 1;
        if (self.buf_off == HISTORY_SIZE) {
            std.mem.copyForwards(i64, self.buf[0..PREDICTOR_SIZE], self.buf[HISTORY_SIZE..][0..PREDICTOR_SIZE]);
            self.buf_off = 0;
        }
    }

    pub fn init(self: *Predictor64) void {
        self.buf = [_]i64{0} ** PREDICTOR_BUF;
        self.buf_off = 0;
        self.lastA = .{ 0, 0 };
        self.filterA = .{ 0, 0 };
        self.filterB = .{ 0, 0 };
        const ca: [4]u64 = .{ 360, 317, @bitCast(@as(i64, -109)), 98 };
        self.coeffsA = .{ ca, ca };
        self.coeffsB = [_][5]u64{.{0} ** 5} ** 2;
    }
};

/// 终级滤波器（压缩级别决定阶数；两声道共用一块缓冲）
pub const Filters = struct {
    pub const Level = struct {
        buf: []i16 = &.{},
        order: usize = 0,
        fracbits: u8 = 0,
        /// 每声道状态：coeffs 起始偏移 / delay 指针 / adapt 指针 / avg
        f: [2]FilterState = .{ .{}, .{} },
        pub const FilterState = struct {
            base: usize = 0,
            dp: usize = 0,
            ap: usize = 0,
            avg: u32 = 0,
        };
    };

    levels: [APE_FILTER_LEVELS]Level = .{ .{}, .{}, .{} },

    /// 按 fset 分配各级缓冲（每级两声道各 order*3+HISTORY_SIZE 个 i16）
    pub fn init(self: *Filters, allocator: std.mem.Allocator, fset: usize) Error!void {
        for (0..APE_FILTER_LEVELS) |i| {
            const order = filter_orders[fset][i];
            if (order == 0) break;
            const per = @as(usize, order) * 3 + HISTORY_SIZE;
            const buf = try allocator.alloc(i16, per * 2);
            @memset(buf, 0);
            self.levels[i] = .{
                .buf = buf,
                .order = order,
                .fracbits = filter_fracbits[fset][i],
                .f = .{
                    .{ .base = 0, .dp = @as(usize, order) * 3, .ap = @as(usize, order) * 2, .avg = 0 },
                    .{ .base = per, .dp = per + @as(usize, order) * 3, .ap = per + @as(usize, order) * 2, .avg = 0 },
                },
            };
        }
    }

    pub fn deinit(self: *Filters, allocator: std.mem.Allocator) void {
        for (0..APE_FILTER_LEVELS) |i| {
            if (self.levels[i].buf.len > 0) allocator.free(self.levels[i].buf);
        }
        self.* = undefined;
    }

    /// 每帧重置（init_filter 语义：清 coeffs/history、复位指针）
    pub fn reset(self: *Filters) void {
        for (0..APE_FILTER_LEVELS) |i| {
            const lv = &self.levels[i];
            if (lv.order == 0) break;
            @memset(lv.buf, 0);
            lv.f[0] = .{ .base = 0, .dp = lv.order * 3, .ap = lv.order * 2, .avg = 0 };
            lv.f[1] = .{ .base = lv.buf.len / 2, .dp = lv.buf.len / 2 + lv.order * 3, .ap = lv.buf.len / 2 + lv.order * 2, .avg = 0 };
        }
    }
};

const Error = @import("../../error.zig").Error;

/// filter_fast_3320（< 3930 且 FAST 级别）
fn filterFast3320(p: *Predictor, decoded: i32, filter: usize, delayA: usize) i32 {
    p.set(delayA, p.lastA[filter]);
    if (p.sample_pos < 3) {
        p.lastA[filter] = decoded;
        p.filterA[filter] = decoded;
        return decoded;
    }
    const predictionA: i32 = p.at(delayA) *% 2 -% p.at(delayA - 1);
    const sh: i32 = @as(i32, @bitCast(@as(u32, @bitCast(predictionA)) *% p.coeffsA[filter][0])) >> 9;
    p.lastA[filter] = decoded +% sh;
    if ((decoded ^ predictionA) > 0) {
        p.coeffsA[filter][0] +%= 1;
    } else {
        p.coeffsA[filter][0] -%= 1;
    }
    p.filterA[filter] +%= p.lastA[filter];
    return p.filterA[filter];
}

/// filter_3800（< 3930 且非 FAST）
fn filter3800(p: *Predictor, decoded: i32, filter: usize, delayA: usize, delayB: usize, start: u32, shift: u5) i32 {
    p.set(delayA, p.lastA[filter]);
    p.set(delayB, p.filterB[filter]);
    if (p.sample_pos < start) {
        const predictionA = decoded +% p.filterA[filter];
        p.lastA[filter] = decoded;
        p.filterB[filter] = decoded;
        p.filterA[filter] = predictionA;
        return predictionA;
    }
    const a0: u32 = @bitCast(p.at(delayA));
    const a1: u32 = @bitCast(p.at(delayA - 1));
    const a2: u32 = @bitCast(p.at(delayA - 2));
    const b0: u32 = @bitCast(p.at(delayB));
    const b1: u32 = @bitCast(p.at(delayB - 1));
    const d0: i32 = @bitCast(a0 +% (a2 -% a1) *% 8);
    const d1: i32 = @bitCast((a0 -% a1) *% 2);
    const d2: i32 = p.at(delayA);
    const d3: i32 = @bitCast(b0 *% 2 -% b1);
    const d4: i32 = p.at(delayB);

    const pa: u32 = @as(u32, @bitCast(d0)) *% p.coeffsA[filter][0] +%
        @as(u32, @bitCast(d1)) *% p.coeffsA[filter][1] +%
        @as(u32, @bitCast(d2)) *% p.coeffsA[filter][2];
    const predictionA: i32 = @bitCast(pa);

    const sign = apeSign(decoded);
    p.coeffsA[filter][0] +%= @bitCast((((d0 >> 30) & 2) - 1) * sign);
    p.coeffsA[filter][1] +%= @bitCast((((d1 >> 28) & 8) - 4) * sign);
    p.coeffsA[filter][2] +%= @bitCast((((d2 >> 28) & 8) - 4) * sign);

    const pb: u32 = @as(u32, @bitCast(d3)) *% p.coeffsB[filter][0] -% @as(u32, @bitCast(d4)) *% p.coeffsB[filter][1];
    const predictionB: i32 = @bitCast(pb);
    p.lastA[filter] = decoded +% (predictionA >> 11);
    const signB = apeSign(p.lastA[filter]);
    p.coeffsB[filter][0] +%= @bitCast((((d3 >> 29) & 4) - 2) * signB);
    p.coeffsB[filter][1] -%= @bitCast((((d4 >> 30) & 2) - 1) * signB);

    p.filterB[filter] = p.lastA[filter] +% (predictionB >> shift);
    p.filterA[filter] = p.filterB[filter] +% (@as(i32, @bitCast(@as(u32, @bitCast(p.filterA[filter])) *% 31)) >> 5);
    return p.filterA[filter];
}

/// long_filter_high_3800（长 FIR 自适应滤波，< 3930 的 HIGH/EXTRA_HIGH）
fn longFilterHigh3800(buffer: []i32, order: usize, shift: u5, length: usize) void {
    if (order >= length) return;
    var coeffs = [_]i32{0} ** 256;
    var delay = [_]i32{0} ** 512;
    for (0..order) |i| delay[i] = buffer[i];
    var dp: usize = 0;
    var i: usize = order;
    while (i < length) : (i += 1) {
        var dotprod: i32 = 0;
        const sign = apeSign(buffer[i]);
        if (sign == 1) {
            for (0..order) |j| {
                dotprod +%= @as(i32, @bitCast(@as(u32, @bitCast(delay[dp + j])) *% @as(u32, @bitCast(coeffs[j]))));
                coeffs[j] +%= (delay[dp + j] >> 31) | 1;
            }
        } else if (sign == -1) {
            for (0..order) |j| {
                dotprod +%= @as(i32, @bitCast(@as(u32, @bitCast(delay[dp + j])) *% @as(u32, @bitCast(coeffs[j]))));
                coeffs[j] -%= (delay[dp + j] >> 31) | 1;
            }
        } else {
            for (0..order) |j| {
                dotprod +%= @as(i32, @bitCast(@as(u32, @bitCast(delay[dp + j])) *% @as(u32, @bitCast(coeffs[j]))));
            }
        }
        buffer[i] -%= dotprod >> shift;
        dp += 1;
        delay[dp + order - 1] = buffer[i];
        if (dp == 256) {
            std.mem.copyForwards(i32, delay[0..256], delay[256..512]);
            dp = 0;
        }
    }
}

/// long_filter_ehigh_3830（< 3930 的 EXTRA_HIGH 前置 8 阶）
fn longFilterEhigh3830(buffer: []i32, length: usize) void {
    var delay = [_]i32{0} ** 8;
    var coeffs = [_]u32{0} ** 8;
    for (0..length) |i| {
        var dotprod: i32 = 0;
        const sign = apeSign(buffer[i]);
        var j: usize = 8;
        while (j > 0) {
            j -= 1;
            dotprod +%= @as(i32, @bitCast(@as(u32, @bitCast(delay[j])) *% coeffs[j]));
            coeffs[j] +%= @as(u32, @bitCast((@as(i32, (delay[j] >> 31) | 1)) *% sign));
        }
        var k: usize = 7;
        while (k > 0) : (k -= 1) delay[k] = delay[k - 1];
        delay[0] = buffer[i];
        buffer[i] -%= dotprod >> 9;
    }
}

/// predictor_decode_*_3800 的前置长滤波（按压缩级别；返回 filter_3800 的 start/shift）
fn longFilters3800(dec: []i32, count: usize, comp: u32, fileversion: u32) struct { start: i32, shift: u5 } {
    var start: i32 = 4;
    var shift: u5 = 10;
    if (comp == COMPRESSION_LEVEL_HIGH) {
        start = 16;
        longFilterHigh3800(dec, 16, 9, count);
    } else if (comp == COMPRESSION_LEVEL_EXTRA_HIGH) {
        var order: usize = 128;
        var shift2: u5 = 11;
        if (fileversion >= 3830) {
            order <<= 1;
            shift += 1;
            shift2 += 1;
            if (count > order) longFilterEhigh3830(dec[order..count], count - order);
        }
        start = @intCast(order);
        longFilterHigh3800(dec, order, shift2, count);
    }
    return .{ .start = start, .shift = shift };
}

/// predictor_decode_stereo_3800
pub fn predictStereo3800(p: *Predictor, dec0: []i32, dec1: []i32, comp: u32, fileversion: u32, count: usize) void {
    const lf = longFilters3800(dec0, count, comp, fileversion);
    _ = longFilters3800(dec1, count, comp, fileversion);
    const fast = comp == COMPRESSION_LEVEL_FAST;
    for (0..count) |i| {
        const X = dec0[i];
        const Y = dec1[i];
        dec0[i] = if (fast) filterFast3320(p, Y, 0, YDELAYA) else filter3800(p, Y, 0, YDELAYA, YDELAYB, @intCast(lf.start), lf.shift);
        dec1[i] = if (fast) filterFast3320(p, X, 1, XDELAYA) else filter3800(p, X, 1, XDELAYA, XDELAYB, @intCast(lf.start), lf.shift);
        p.step();
    }
}

/// predictor_decode_mono_3800
pub fn predictMono3800(p: *Predictor, dec0: []i32, comp: u32, fileversion: u32, count: usize) void {
    const lf = longFilters3800(dec0, count, comp, fileversion);
    const fast = comp == COMPRESSION_LEVEL_FAST;
    for (0..count) |i| {
        dec0[i] = if (fast) filterFast3320(p, dec0[i], 0, YDELAYA) else filter3800(p, dec0[i], 0, YDELAYA, YDELAYB, @intCast(lf.start), lf.shift);
        p.step();
    }
}

/// predictor_update_3930（3930-3949）
fn predictorUpdate3930(p: *Predictor, decoded: i32, filter: usize, delayA: usize) i32 {
    p.set(delayA, p.lastA[filter]);
    const d0: u32 = @bitCast(p.at(delayA));
    const d1: u32 = d0 -% @as(u32, @bitCast(p.at(delayA - 1)));
    const d2: u32 = @as(u32, @bitCast(p.at(delayA - 1))) -% @as(u32, @bitCast(p.at(delayA - 2)));
    const d3: u32 = @as(u32, @bitCast(p.at(delayA - 2))) -% @as(u32, @bitCast(p.at(delayA - 3)));
    const pa: u32 = d0 *% p.coeffsA[filter][0] +% d1 *% p.coeffsA[filter][1] +% d2 *% p.coeffsA[filter][2] +% d3 *% p.coeffsA[filter][3];
    const predictionA: i32 = @bitCast(pa);
    p.lastA[filter] = decoded +% (predictionA >> 9);
    p.filterA[filter] = p.lastA[filter] +% (@as(i32, @bitCast(@as(u32, @bitCast(p.filterA[filter])) *% 31)) >> 5);
    const sign = apeSign(decoded);
    p.coeffsA[filter][0] +%= @bitCast((if (@as(i32, @bitCast(d0)) < 0) @as(i32, 1) else -1) * sign);
    p.coeffsA[filter][1] +%= @bitCast((if (@as(i32, @bitCast(d1)) < 0) @as(i32, 1) else -1) * sign);
    p.coeffsA[filter][2] +%= @bitCast((if (@as(i32, @bitCast(d2)) < 0) @as(i32, 1) else -1) * sign);
    p.coeffsA[filter][3] +%= @bitCast((if (@as(i32, @bitCast(d3)) < 0) @as(i32, 1) else -1) * sign);
    return p.filterA[filter];
}

/// predictor_decode_stereo_3930（调用方已做终级滤波）
pub fn predictStereo3930(p: *Predictor, dec0: []i32, dec1: []i32, count: usize) void {
    for (0..count) |i| {
        const Y = dec1[i];
        const X = dec0[i];
        dec0[i] = predictorUpdate3930(p, Y, 0, YDELAYA);
        dec1[i] = predictorUpdate3930(p, X, 1, XDELAYA);
        p.stepNoPos();
    }
}

/// predictor_decode_mono_3930（调用方已做终级滤波）
pub fn predictMono3930(p: *Predictor, dec0: []i32, count: usize) void {
    for (0..count) |i| {
        dec0[i] = predictorUpdate3930(p, dec0[i], 0, YDELAYA);
        p.stepNoPos();
    }
}

/// predictor_update_filter（>= 3950，64-bit；interim_mode < 1 走 int32 截断路径）
fn predictorUpdateFilter(
    p: *Predictor64,
    decoded: i32,
    filter: usize,
    delayA: usize,
    delayB: usize,
    adaptA: usize,
    adaptB: usize,
    interim_mode: i32,
) i32 {
    p.set(delayA, p.lastA[filter]);
    p.set(adaptA, apeSign64(p.at(delayA)));
    p.set(delayA - 1, p.at(delayA) -% p.at(delayA - 1));
    p.set(adaptA - 1, apeSign64(p.at(delayA - 1)));
    const pa: u64 = @as(u64, @bitCast(p.at(delayA))) *% p.coeffsA[filter][0] +%
        @as(u64, @bitCast(p.at(delayA - 1))) *% p.coeffsA[filter][1] +%
        @as(u64, @bitCast(p.at(delayA - 2))) *% p.coeffsA[filter][2] +%
        @as(u64, @bitCast(p.at(delayA - 3))) *% p.coeffsA[filter][3];
    const predictionA: i64 = @bitCast(pa);

    p.set(delayB, p.filterA[filter ^ 1] - ((p.filterB[filter] *% 31) >> 5));
    p.set(adaptB, apeSign64(p.at(delayB)));
    p.set(delayB - 1, p.at(delayB) -% p.at(delayB - 1));
    p.set(adaptB - 1, apeSign64(p.at(delayB - 1)));
    p.filterB[filter] = p.filterA[filter ^ 1];
    const pb: u64 = @as(u64, @bitCast(p.at(delayB))) *% p.coeffsB[filter][0] +%
        @as(u64, @bitCast(p.at(delayB - 1))) *% p.coeffsB[filter][1] +%
        @as(u64, @bitCast(p.at(delayB - 2))) *% p.coeffsB[filter][2] +%
        @as(u64, @bitCast(p.at(delayB - 3))) *% p.coeffsB[filter][3] +%
        @as(u64, @bitCast(p.at(delayB - 4))) *% p.coeffsB[filter][4];
    const predictionB: i64 = @bitCast(pb);

    if (interim_mode < 1) {
        const pa32: i32 = @truncate(predictionA);
        const pb32: i32 = @truncate(predictionB);
        const sum: i64 = @as(i64, pa32) + (@as(i64, pb32) >> 1);
        const sh: i32 = @as(i32, @truncate(sum)) >> 10;
        p.lastA[filter] = @as(i32, @bitCast(@as(u32, @bitCast(decoded)) +% @as(u32, @bitCast(sh))));
    } else {
        const tmp: u64 = @as(u64, @bitCast(predictionA)) +% @as(u64, @bitCast(predictionB >> 1));
        const sh: i64 = @as(i64, @bitCast(tmp)) >> 10;
        p.lastA[filter] = decoded +% sh;
    }
    p.filterA[filter] = p.lastA[filter] +% (@as(i64, @bitCast(@as(u64, @bitCast(p.filterA[filter])) *% 31)) >> 5);

    const sign = apeSign(decoded);
    p.coeffsA[filter][0] +%= @as(u64, @bitCast(p.at(adaptA) *% sign));
    p.coeffsA[filter][1] +%= @as(u64, @bitCast(p.at(adaptA - 1) *% sign));
    p.coeffsA[filter][2] +%= @as(u64, @bitCast(p.at(adaptA - 2) *% sign));
    p.coeffsA[filter][3] +%= @as(u64, @bitCast(p.at(adaptA - 3) *% sign));
    p.coeffsB[filter][0] +%= @as(u64, @bitCast(p.at(adaptB) *% sign));
    p.coeffsB[filter][1] +%= @as(u64, @bitCast(p.at(adaptB - 1) *% sign));
    p.coeffsB[filter][2] +%= @as(u64, @bitCast(p.at(adaptB - 2) *% sign));
    p.coeffsB[filter][3] +%= @as(u64, @bitCast(p.at(adaptB - 3) *% sign));
    p.coeffsB[filter][4] +%= @as(u64, @bitCast(p.at(adaptB - 4) *% sign));

    return @truncate(p.filterA[filter]);
}

/// predictor_decode_stereo_3950（含 24-bit interim 双趟）
pub fn predictStereo3950(
    p_default: *Predictor64,
    interim_mode_state: *i32,
    dec0: []i32,
    dec1: []i32,
    interim0: []i32,
    interim1: []i32,
    count: usize,
) void {
    var num_passes: usize = 1;
    var p_interim: Predictor64 = undefined;
    if (interim_mode_state.* == -1) {
        if (interim0.len < count or interim1.len < count) return; // 24-bit 必须分配 interim
        p_interim = p_default.*;
        num_passes = 2;
        @memcpy(interim0[0..count], dec0[0..count]);
        @memcpy(interim1[0..count], dec1[0..count]);
    }
    var pass: usize = 0;
    while (pass < num_passes) : (pass += 1) {
        const interim_mode: i32 = if (interim_mode_state.* > 0 or pass != 0) 1 else 0;
        var p: *Predictor64 = undefined;
        var d0: []i32 = undefined;
        var d1: []i32 = undefined;
        if (pass != 0) {
            p = &p_interim;
            d0 = interim0;
            d1 = interim1;
        } else {
            p = p_default;
            d0 = dec0;
            d1 = dec1;
        }
        p.buf_off = 0;
        for (0..count) |i| {
            const a0 = predictorUpdateFilter(p, d0[i], 0, YDELAYA, YDELAYB, YADAPTCOEFFSA, YADAPTCOEFFSB, interim_mode);
            const a1 = predictorUpdateFilter(p, d1[i], 1, XDELAYA, XDELAYB, XADAPTCOEFFSA, XADAPTCOEFFSB, interim_mode);
            d0[i] = a0;
            d1[i] = a1;
            if (num_passes > 1) {
                const left: i32 = a1 -% @divTrunc(a0, 2);
                const right: i32 = left +% a0;
                if (@max(@abs(left), @abs(right)) > (1 << 23)) {
                    interim_mode_state.* = if (interim_mode == 0) 1 else 0;
                    break;
                }
            }
            p.stepNoPos();
        }
    }
    if (num_passes > 1 and interim_mode_state.* > 0) {
        @memcpy(dec0[0..count], interim0[0..count]);
        @memcpy(dec1[0..count], interim1[0..count]);
        p_default.* = p_interim;
        p_default.buf_off = 0;
    }
}

/// predictor_decode_mono_3950（64-bit，仅 A 系数 / Y 延迟）
pub fn predictMono3950(p: *Predictor64, dec0: []i32, count: usize) void {
    var currentA: i32 = @truncate(p.lastA[0]);
    for (0..count) |i| {
        const A = dec0[i];
        p.set(YDELAYA, currentA);
        p.set(YDELAYA - 1, p.at(YDELAYA) -% p.at(YDELAYA - 1));
        const pa: u64 = @as(u64, @bitCast(p.at(YDELAYA))) *% p.coeffsA[0][0] +%
            @as(u64, @bitCast(p.at(YDELAYA - 1))) *% p.coeffsA[0][1] +%
            @as(u64, @bitCast(p.at(YDELAYA - 2))) *% p.coeffsA[0][2] +%
            @as(u64, @bitCast(p.at(YDELAYA - 3))) *% p.coeffsA[0][3];
        const predictionA: i32 = @truncate(@as(i64, @bitCast(pa)));
        currentA = A +% (predictionA >> 10);
        p.set(YADAPTCOEFFSA, apeSign64(p.at(YDELAYA)));
        p.set(YADAPTCOEFFSA - 1, apeSign64(p.at(YDELAYA - 1)));
        const sign = apeSign(A);
        p.coeffsA[0][0] +%= @as(u64, @bitCast(p.at(YADAPTCOEFFSA) *% sign));
        p.coeffsA[0][1] +%= @as(u64, @bitCast(p.at(YADAPTCOEFFSA - 1) *% sign));
        p.coeffsA[0][2] +%= @as(u64, @bitCast(p.at(YADAPTCOEFFSA - 2) *% sign));
        p.coeffsA[0][3] +%= @as(u64, @bitCast(p.at(YADAPTCOEFFSA - 3) *% sign));
        p.stepNoPos();
        p.filterA[0] = @as(i64, currentA) +% ((p.filterA[0] *% 31) >> 5);
        dec0[i] = @truncate(p.filterA[0]);
    }
    p.lastA[0] = currentA;
}

/// do_apply_filter：单声道单级终级滤波（version >= 3980 与 < 3980 两套自适应）
fn doApplyFilter(lv: *Filters.Level, ch: usize, data: []i32, version: u32) void {
    const o = lv.order;
    const st = &lv.f[ch];
    const buf = lv.buf;
    for (data) |*sample| {
        // scalarproduct_and_madd_int16：res = Σ coeffs[j]·delay[j]，coeffs[j] += sign·adapt[j]
        const mul = apeSign(sample.*);
        var res: i32 = 0;
        for (0..o) |j| {
            const c: i32 = buf[st.base + j];
            const d: i32 = buf[st.dp - o + j];
            res +%= c * d;
            buf[st.base + j] = @truncate(c +% mul * @as(i32, buf[st.ap - o + j]));
        }
        const r64: i64 = (@as(i64, res) + (@as(i64, 1) << @intCast(lv.fracbits - 1))) >> @intCast(lv.fracbits);
        res = @truncate(r64);
        res +%= sample.*;
        sample.* = res;
        buf[st.dp] = clipInt16(res);
        st.dp += 1;

        if (version < 3980) {
            buf[st.ap] = if (res == 0) 0 else @truncate(((res >> 28) & 8) - 4);
            buf[st.ap - 4] >>= 1;
            buf[st.ap - 8] >>= 1;
        } else {
            const absres: u32 = @abs(res);
            if (absres != 0) {
                // C 语义：avg * 3LL 为 int64，避免 u32 溢出；两布尔相加需 u3 域
                const shift: u3 = @as(u3, @intFromBool(@as(i64, absres) > @as(i64, @intCast(st.avg)) * 3)) +
                    @as(u3, @intFromBool(absres > (st.avg +% (st.avg / 3))));
                buf[st.ap] = @truncate(apeSign(res) * (@as(i32, 8) << @intCast(shift)));
            } else {
                buf[st.ap] = 0;
            }
            st.avg +%= @as(u32, @bitCast(@divTrunc(@as(i32, @bitCast(absres -% st.avg)), 16)));
            buf[st.ap - 1] >>= 1;
            buf[st.ap - 2] >>= 1;
            buf[st.ap - 8] >>= 1;
        }
        st.ap += 1;

        if (st.dp == st.base + o * 3 + HISTORY_SIZE) {
            std.mem.copyForwards(i16, buf[st.base + o ..][0 .. o * 2], buf[st.dp - o * 2 ..][0 .. o * 2]);
            st.dp = st.base + o * 3;
            st.ap = st.base + o * 2;
        }
    }
}

/// apply_filter：对 data0（必）与 data1（可选）各声道施加一级滤波
fn applyFilter(fs: *Filters, level: usize, dec0: []i32, dec1: ?[]i32, count: usize, version: u32) void {
    doApplyFilter(&fs.levels[level], 0, dec0[0..count], version);
    if (dec1) |d1| doApplyFilter(&fs.levels[level], 1, d1[0..count], version);
}

/// ape_apply_filters：按 fset 逐级施加（dec1 为 null 时仅声道 0）
pub fn applyFilters(fs: *Filters, dec0: []i32, dec1: ?[]i32, count: usize, version: u32) void {
    for (0..APE_FILTER_LEVELS) |i| {
        if (fs.levels[i].order == 0) break;
        applyFilter(fs, i, dec0, dec1, count, version);
    }
}

/// av_clip_int16
inline fn clipInt16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}
