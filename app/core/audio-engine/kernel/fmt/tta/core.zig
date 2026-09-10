// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! TTA (True Audio, .tta) 帧解码核心（逐句对齐 FFmpeg n9.0.1 libavcodec/tta.c）。
//!
//! 语义要点（纯整数、无浮点）：
//!   - 位流为 **LSB-first**（BITSTREAM_READER_LE）；帧内通道按时间步交错，
//!     但滤波器/预测器/Rice 状态在**每帧起始归零**（帧间无耦合，可随机访问）；
//!   - 每样本：unary(1 前缀，0 终止) → 分段 Rice(k0/k1 双自适应) → 逆 zigzag
//!     映射 → 8 抽头自适应 LMS（qm/dx/dl，round/shift 定点舍入）→ 一阶定点
//!     预测 PRED（(1-2^-k) 偏差）→ 多声道差分去相关；
//!   - 溢出/无符号减法语义完全复刻 C（uint32 回绕 + int32 算术移位），逐位一致。
//!
//! 位深语义（bytes_per_sample 对齐 ffmpeg s->bps）：1=8bit、2=16bit、3=24bit；
//! 滤波 shift = ff_tta_filter_configs[bps-1] = {10,9,10,12}；预测系数 k：
//! 8bit→4、16/24bit→5。输出布局对齐 ffmpeg 内部样本格式：
//!   8bit → u8(样本+0x80)；16bit → s16；24bit → int32<<8（= `-f s32le`）。

const std = @import("std");
const Error = @import("../../error.zig").Error;

/// 与 ffmpeg tta_decode_init 一致：channels 1..16
pub const MAX_CHANNELS: usize = 16;

/// ff_tta_shift_1：2^0..2^30、0x80000000×9、0xFFFFFFFF（C 共 41 项）；
/// 表尾补 0xFFFFFFFF 防 sh16 索引越界（无合法流能触发 C 越界）。
const shift_1 = blk: {
    var t: [48]u32 = undefined;
    for (0..31) |i| t[i] = @as(u32, 1) << @intCast(i);
    for (31..40) |i| t[i] = 0x80000000;
    for (40..48) |i| t[i] = 0xFFFFFFFF;
    break :blk t;
};
inline fn sh1(i: u32) u32 {
    return shift_1[@min(i, shift_1.len - 1)];
}
/// ff_tta_shift_16 = ff_tta_shift_1 + 4
inline fn sh16(i: u32) u32 {
    return shift_1[@min(i + 4, shift_1.len - 1)];
}

/// LSB-first 位读取（对齐 get_bits / get_unary 的 LE 语义）
pub const BitReader = struct {
    data: []const u8,
    bit_pos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn remainingBits(self: *const BitReader) usize {
        return self.data.len * 8 - self.bit_pos;
    }

    /// 读 1 位（LSB-first）。数据已尽 → Corrupt。
    pub fn readBit(self: *BitReader) Error!u1 {
        if (self.bit_pos >= self.data.len * 8) return error.Corrupt;
        const v: u1 = @intCast((self.data[self.bit_pos >> 3] >> @intCast(self.bit_pos & 7)) & 1);
        self.bit_pos += 1;
        return v;
    }

    /// 读 k 位（0..=31）LSB-first。越界 → Corrupt。
    pub fn readBits(self: *BitReader, k: u32) Error!u32 {
        if (k > 31) return error.Corrupt;
        if (self.bit_pos + k > self.data.len * 8) return error.Corrupt;
        var out: u32 = 0;
        var shift: u5 = 0;
        var need = k;
        while (need > 0) {
            const byte = self.data[self.bit_pos >> 3];
            const bit_in: u3 = @intCast(self.bit_pos & 7);
            const take: u32 = @min(need, 8 - @as(u32, bit_in));
            const chunk: u32 = (byte >> bit_in) & ((@as(u32, 1) << @intCast(take)) - 1);
            out |= chunk << shift;
            shift += @intCast(take);
            self.bit_pos += @intCast(take);
            need -= take;
        }
        return out;
    }

    /// get_unary(gb, stop=0)：数连续 1 位直到首个 0（0 被消耗）；
    /// 上限 = 调用时刻剩余位数。
    pub fn readUnary(self: *BitReader) Error!u32 {
        const max = self.remainingBits();
        var count: u32 = 0;
        while (count < max) : (count += 1) {
            if ((try self.readBit()) == 0) break;
        }
        return count;
    }
};

/// 单声道解码状态：Rice(k0/k1/sum0/sum1) + 自适应滤波器 + 一阶预测器。
pub const Channel = struct {
    predictor: i32 = 0,
    shift: i32,
    round: i32,
    err: i32 = 0,
    qm: [8]i32 = [_]i32{0} ** 8,
    dx: [8]i32 = [_]i32{0} ** 8,
    dl: [8]i32 = [_]i32{0} ** 8,
    k0: u32 = 10,
    k1: u32 = 10,
    sum0: u32,
    sum1: u32,

    pub fn init(shift: i32) Channel {
        return .{
            .shift = shift,
            .round = @bitCast(sh1(@intCast(shift - 1))),
            .sum0 = sh16(10),
            .sum1 = sh16(10),
        };
    }

    /// tta_filter_process_c：8 抽头符号 LMS；返回滤波后样本（int32 回绕域）。
    fn filterProcess(self: *Channel, inp: i32) i32 {
        if (self.err < 0) {
            for (0..8) |i| self.qm[i] = self.qm[i] -% self.dx[i];
        } else if (self.err > 0) {
            for (0..8) |i| self.qm[i] = self.qm[i] +% self.dx[i];
        }
        var acc: u32 = 0;
        for (0..8) |i| {
            const prod: u32 = @as(u32, @bitCast(self.dl[i])) *% @as(u32, @bitCast(self.qm[i]));
            acc = acc +% prod;
        }
        const roundv: u32 = @as(u32, @bitCast(self.round)) +% acc;

        self.dx[0] = self.dx[1];
        self.dx[1] = self.dx[2];
        self.dx[2] = self.dx[3];
        self.dx[3] = self.dx[4];
        self.dl[0] = self.dl[1];
        self.dl[1] = self.dl[2];
        self.dl[2] = self.dl[3];
        self.dl[3] = self.dl[4];
        self.dx[4] = (self.dl[4] >> 30) | 1;
        self.dx[5] = ((self.dl[5] >> 30) | 2) & ~@as(i32, 1);
        self.dx[6] = ((self.dl[6] >> 30) | 2) & ~@as(i32, 1);
        self.dx[7] = ((self.dl[7] >> 30) | 4) & ~@as(i32, 3);

        self.err = inp;
        const out = inp +% (@as(i32, @bitCast(roundv)) >> @intCast(self.shift));

        // dl[4..7] 重建（无符号回绕减法，复刻 C 的 unsigned 语义）
        self.dl[4] = -%self.dl[5];
        self.dl[5] = -%self.dl[6];
        self.dl[6] = out -% self.dl[7];
        self.dl[7] = out;
        self.dl[5] = self.dl[5] +% self.dl[6];
        self.dl[4] = self.dl[4] +% self.dl[5];
        return out;
    }

    /// PRED(x,k) = (int32)((((uint64)x << k) - x) >> k)
    fn pred(self: *const Channel, x: i32, k: u6) i32 {
        _ = self;
        const xs: u64 = @as(u64, @bitCast(@as(i64, x)));
        const big = (xs << k) -% xs;
        return @bitCast(@as(u32, @truncate(big >> k)));
    }

    /// 解码一个残差样本，经滤波器 + 一阶预测后返回样本值。
    pub fn decodeSample(self: *Channel, br: *BitReader, bps: u8) Error!i32 {
        var unary = try br.readUnary();
        var k: u32 = undefined;
        var depth1 = false;
        if (unary == 0) {
            k = self.k0;
        } else {
            depth1 = true;
            k = self.k1;
            unary -= 1;
        }
        if (br.remainingBits() < k) return error.Corrupt;
        var value: u32 = undefined;
        if (k != 0) {
            if (k > 31 or unary > (@as(u64, std.math.maxInt(i32)) >> @intCast(k))) return error.Corrupt;
            value = (unary << @intCast(k)) +% (try br.readBits(k));
        } else {
            value = unary;
        }
        if (depth1) {
            self.sum1 = self.sum1 +% value -% (self.sum1 >> 4);
            if (self.k1 > 0 and self.sum1 < sh16(self.k1))
                self.k1 -= 1
            else if (self.sum1 > sh16(self.k1 + 1))
                self.k1 += 1;
            value = value +% sh1(self.k0);
        }
        self.sum0 = self.sum0 +% value -% (self.sum0 >> 4);
        if (self.k0 > 0 and self.sum0 < sh16(self.k0))
            self.k0 -= 1
        else if (self.sum0 > sh16(self.k0 + 1))
            self.k0 += 1;

        // 逆 zigzag：*p = 1 + ((value>>1) ^ ((value&1)-1))（uint32 回绕域；
        // C 的 (value&1)-1 即 (value & 1) -% 1：偶 → 0xFFFFFFFF、奇 → 0）
        const t = (value >> 1) ^ ((value & 1) -% 1);
        var s: i32 = @bitCast(t +% 1);

        // 自适应滤波器
        s = self.filterProcess(s);

        // 固定一阶预测
        switch (bps) {
            1 => s = s +% self.pred(self.predictor, 4),
            2, 3 => s = s +% self.pred(self.predictor, 5),
            else => s = s +% self.predictor,
        }
        self.predictor = s;
        return s;
    }
};

/// 多声道差分去相关（tta_decode_frame 逆变换，作用于一个时间步通道值）。
/// 复刻 C：*p += *r/2；随后自末通道向首链式 *r = *(r+1) - *r（无符号回绕）。
fn decorrelate(v: []i32) void {
    const ch = v.len;
    if (ch <= 1) return;
    const last: usize = ch - 1;
    v[last] = v[last] +% @divTrunc(v[last - 1], 2);
    var i: usize = last - 1;
    while (true) {
        v[i] = @bitCast(@as(u32, @bitCast(v[i + 1])) -% @as(u32, @bitCast(v[i])));
        if (i == 0) break;
        i -= 1;
    }
}

// ---------------------------------------------------------------------------
// 帧解码（供 lib.zig 逐帧调用）
// ---------------------------------------------------------------------------

/// 输出每样本字节宽（2 = s16 / 4 = s32/24bit<<8；8bit 宽度 1 也支持）
pub const FrameDecoder = struct {
    chans: []Channel,
    allocator: std.mem.Allocator,
    step: [MAX_CHANNELS]i32 = undefined,

    pub fn init(a: std.mem.Allocator, channels: usize, bps: u8) Error!FrameDecoder {
        if (channels == 0 or channels > MAX_CHANNELS) return error.UnsupportedFormat;
        const shift: i32 = switch (bps) {
            1 => 10,
            2 => 9,
            3 => 10,
            else => return error.UnsupportedFormat,
        };
        const list = a.alloc(Channel, channels) catch return error.OutOfMemory;
        for (list) |*c| c.* = Channel.init(shift);
        return .{ .chans = list, .allocator = a };
    }

    pub fn deinit(self: *FrameDecoder) void {
        self.allocator.free(self.chans);
    }

    /// 帧解码前重置声道状态（对齐 tta_decode_frame：predictor/filter 归零、
    /// rice k0=k1=10 —— 帧间无耦合，每帧独立解码）。
    pub fn reset(self: *FrameDecoder, bps: u8) void {
        const shift: i32 = switch (bps) {
            1 => 10,
            2 => 9,
            3 => 10,
            else => return,
        };
        for (self.chans) |*c| c.* = Channel.init(shift);
    }

    /// 解码一帧的 nb 个时间步，交错写入 out（bytes = nb×channels×width）。
    /// width 依 bps：1 → u8(+0x80)、2 → s16、3 → s32<<8（对齐 ffmpeg 内部）。
    pub fn decode(self: *FrameDecoder, br: *BitReader, bps: u8, nb: usize, out: []u8) Error!void {
        self.reset(bps);
        const ch = self.chans.len;
        const width: usize = if (bps == 1) 1 else if (bps == 2) 2 else 4;
        if (out.len < nb * ch * width) return error.Corrupt;
        var t: usize = 0;
        while (t < nb) : (t += 1) {
            for (0..ch) |c| {
                self.step[c] = try self.chans[c].decodeSample(br, bps);
            }
            decorrelate(self.step[0..ch]);
            for (0..ch) |c| {
                const base = (t * ch + c) * width;
                switch (bps) {
                    1 => out[base] = @bitCast(@as(u8, @truncate(@as(u32, @bitCast(self.step[c])) +% 0x80))),
                    2 => std.mem.writeInt(i16, out[base..][0..2], @truncate(self.step[c]), .little),
                    else => std.mem.writeInt(i32, out[base..][0..4], self.step[c] *% 256, .little),
                }
            }
        }
    }
};
