//! APE 区间解码器 + 版本化熵解码（docs/audio-kernel-zig.md §9.10）
//!
//! 参考重构对照 FFmpeg libavcodec/apedec.c：APERangecoder（§"range decoding
//! functions"）、update_rice / get_rice_ook / ape_decode_value_3860 / _3900 /
//! _3990 / decode_array_0000 与各版本 entropy_decode_mono/stereo 编排；
//! 逐位复刻以保证 bit-exact；许可登记见 audio-engine/THIRD-PARTY-LICENSES.md。
//!
//! 版本分派（对齐 ape_decode_init）：
//!   < 3860  → decode_array_0000（GetBitContext 位流）
//!   3860-3889 → ape_decode_value_3860
//!   3900-3929 → ape_decode_value_3900（stereo 含 range 回退重开：先整行 ch0，
//!               normalize + ptr-1 回退 + 重开区间，再整行 ch1）
//!   3930-3989 → mono 用 3900，stereo 用 3900（逐样本交错，无回退）
//!   >= 3990 → ape_decode_value_3990（pivot 自适应 base 编码）
//!
//! 健壮性（§13.3）：所有读取先校验边界，越界/除零 → error.Corrupt，
//! 不产生越界读与除零崩溃；区间归一化在数据耗尽时按零填充推进并置 error
//! 标志（对齐 FFmpeg `ptr >= data_end` 分支），帧末统一检查。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const BitReader = @import("bitreader.zig").BitReader;

/// EXTRA_BITS = ((32-2) % 8 + 1) = 7
pub const EXTRA_BITS: u32 = 7;
/// BOTTOM_VALUE = TOP_VALUE >> 8 = (1<<31) >> 8 = 0x00800000
pub const BOTTOM_VALUE: u32 = 0x0080_0000;
pub const MODEL_ELEMENTS: usize = 64;
/// FFmpeg MIN_CACHE_BITS（get_bits.h）；rice.k 上限由调用处保证 <= 24
pub const MIN_CACHE_BITS: u32 = 25;

/// counts_3970：Monkey's Audio 3.97 固定概率起点（22 项）
const counts_3970 = [22]u16{
    0, 14824, 28224, 39348, 47855, 53994, 58171, 60926,
    62682, 63786, 64463, 64878, 65126, 65276, 65365, 65419,
    65450, 65469, 65480, 65487, 65491, 65493,
};

/// counts_diff_3970：3.97 固定概率宽度（21 项）
const counts_diff_3970 = [21]u16{
    14824, 13400, 11124, 8507, 6139, 4177, 2755, 1756,
    1104, 677, 415, 248, 150, 89, 54, 31,
    19, 11, 7, 4, 2,
};

/// counts_3980：Monkey's Audio 3.98 固定概率起点（22 项）
const counts_3980 = [22]u16{
    0, 19578, 36160, 48417, 56323, 60899, 63265, 64435,
    64971, 65232, 65351, 65416, 65447, 65466, 65476, 65482,
    65485, 65488, 65490, 65491, 65492, 65493,
};

/// counts_diff_3980：3.98 固定概率宽度（21 项）
const counts_diff_3980 = [21]u16{
    19578, 16582, 12257, 7906, 4576, 2366, 1170, 536,
    261, 119, 65, 31, 19, 10, 6, 3,
    3, 2, 1, 1, 1,
};

/// Rice 编码参数（k / ksum 自适应）
pub const Rice = struct {
    k: u32 = 10,
    ksum: u32 = (1 << 10) * 16,
};

/// zigzag 符号解码：((x >> 1) ^ ((x & 1) - 1)) + 1
pub fn zigzag(x: u32) i32 {
    return @as(i32, @bitCast((x >> 1) ^ ((x & 1) -% 1))) +% 1;
}

/// update_rice（对齐 FFmpeg：k 上限 24，ksum u32 回绕）
pub fn updateRice(rice: *Rice, x: u32) void {
    const lim: u32 = if (rice.k != 0) @as(u32, 1) << @intCast(rice.k + 4) else 0;
    rice.ksum +%= ((x + 1) / 2) -% ((rice.ksum + 16) >> 5);
    if (rice.ksum < lim) {
        rice.k -%= 1;
    } else if (rice.ksum >= (@as(u32, 1) << @intCast(rice.k + 5)) and rice.k < 24) {
        rice.k +%= 1;
    }
}

/// get_k（av_log2(ksum) + !!ksum）
pub fn getK(ksum: u32) u32 {
    if (ksum == 0) return 0;
    return @intCast(32 - @clz(ksum));
}

/// get_rice_ook：unary 前缀 + k 位后缀（GetBitContext 位流）
fn getRiceOok(gb: *BitReader, k: u32) Error!u32 {
    var x: u32 = @intCast(gb.unaryStop(1, gb.remainingBits()));
    if (k != 0) x = (x << @intCast(k)) | try gb.readBits(@intCast(k));
    return x;
}

/// 熵解码上下文（区间 + 位流 + rice 状态，数据为帧级 bswapped 缓冲）
pub const Ctx = struct {
    /// 完整 bswapped 帧缓冲（含 nblocks/offset 头，零填充到 buf_size）
    data: []const u8,
    /// 字节游标（区间解码 / bytestream 读取共用）
    ptr: usize = 0,
    fileversion: u32,
    /// 区间归一化越过数据尾时置位（FFmpeg ctx->error 语义），帧末检查
    err: bool = false,

    low: u32 = 0,
    range: u32 = 0,
    help: u32 = 0,
    buffer: u32 = 0,

    /// < 3900 的位流（覆盖 data[8..data_end]）
    gb: BitReader = undefined,
    gb_active: bool = false,

    riceX: Rice = .{},
    riceY: Rice = .{},

    pub fn init(data: []const u8, fileversion: u32) Ctx {
        return .{ .data = data, .fileversion = fileversion };
    }

    /// bytestream 读字节（rangeStart 用；越界 → Corrupt）
    pub fn readByte(self: *Ctx) Error!u8 {
        if (self.ptr >= self.data.len) return error.Corrupt;
        const b = self.data[self.ptr];
        self.ptr += 1;
        return b;
    }

    /// bytestream 读 BE32（CRC / frameflags / nblocks / offset）
    pub fn readBe32(self: *Ctx) Error!u32 {
        if (self.ptr + 4 > self.data.len) return error.Corrupt;
        const v = std.mem.readInt(u32, self.data[self.ptr..][0..4], .big);
        self.ptr += 4;
        return v;
    }

    /// range_start_decoding
    pub fn rangeStart(self: *Ctx) Error!void {
        self.buffer = try self.readByte();
        self.low = self.buffer >> @intCast(8 - EXTRA_BITS);
        self.range = @as(u32, 1) << @intCast(EXTRA_BITS);
    }

    /// range_dec_normalize（数据耗尽 → 零填充推进并置 error）
    pub fn rangeNormalize(self: *Ctx) void {
        while (self.range <= BOTTOM_VALUE) {
            self.buffer <<= 8;
            if (self.ptr < self.data.len) {
                self.buffer += self.data[self.ptr];
                self.ptr += 1;
            } else {
                self.err = true;
            }
            self.low = (self.low << 8) | ((self.buffer >> 1) & 0xFF);
            self.range <<= 8;
        }
    }

    /// range_decode_culfreq（help=0 → 置 error 并返回 0，防除零）
    pub fn culFreq(self: *Ctx, tot_f: u32) Error!u32 {
        self.rangeNormalize();
        self.help = self.range / tot_f;
        if (self.help == 0) {
            self.err = true;
            return 0;
        }
        return self.low / self.help;
    }

    /// range_decode_culshift
    pub fn culShift(self: *Ctx, shift: u5) Error!u32 {
        self.rangeNormalize();
        self.help = self.range >> shift;
        if (self.help == 0) {
            self.err = true;
            return 0;
        }
        return self.low / self.help;
    }

    /// range_decode_update
    pub fn update(self: *Ctx, sy_f: u32, lt_f: u32) void {
        self.low -%= self.help *% lt_f;
        self.range = self.help *% sy_f;
    }

    /// range_decode_bits（n 位无建模解码）
    pub fn decodeBits(self: *Ctx, n: u5) Error!u32 {
        const sym = try self.culShift(n);
        self.update(1, sym);
        return sym;
    }

    /// range_get_symbol（counts 线性搜索，非二分——逐位对齐参考实现）
    pub fn getSymbol(self: *Ctx, counts: *const [22]u16, counts_diff: *const [21]u16) Error!u32 {
        const cf = try self.culShift(16);
        if (cf > 65492) {
            // C 语义：symbol = cf - 65535 + 63（int 算术，cf ∈ 65493..65535）
            const symbol: u32 = @intCast(@as(i32, @intCast(cf)) - 65535 + 63);
            self.update(1, cf);
            if (cf > 65535) self.err = true;
            return symbol;
        }
        var symbol: usize = 0;
        while (symbol < 21 and counts[symbol + 1] <= cf) symbol += 1;
        self.update(counts_diff[symbol], counts[symbol]);
        return @intCast(symbol);
    }

    /// ape_decode_value_3860（GetBitContext 位流）
    pub fn decodeValue3860(self: *Ctx, rice: *Rice) Error!i32 {
        var overflow: u32 = @intCast(self.gb.unaryStop(1, self.gb.remainingBits()));
        if (self.fileversion > 3880) {
            while (overflow >= 16) {
                overflow -= 16;
                rice.k +%= 4;
            }
        }
        var x: u32 = 0;
        if (rice.k == 0) {
            x = overflow;
        } else if (rice.k <= MIN_CACHE_BITS) {
            x = (overflow << @intCast(rice.k)) | try self.gb.readBits(@intCast(rice.k));
        } else {
            return error.Corrupt;
        }
        rice.ksum +%= x -% ((rice.ksum + 8) >> 4);
        if (rice.ksum < (if (rice.k != 0) @as(u32, 1) << @intCast(rice.k + 4) else 0)) {
            rice.k -%= 1;
        } else if (rice.ksum >= (@as(u32, 1) << @intCast(rice.k + 5)) and rice.k < 24) {
            rice.k +%= 1;
        }
        return zigzag(x);
    }

    /// ape_decode_value_3900（区间编码，3.97 概率表）
    pub fn decodeValue3900(self: *Ctx, rice: *Rice) Error!i32 {
        var overflow = try self.getSymbol(&counts_3970, &counts_diff_3970);
        var tmpk: u32 = 0;
        if (overflow == MODEL_ELEMENTS - 1) {
            tmpk = try self.decodeBits(5);
            overflow = 0;
        } else {
            tmpk = if (rice.k < 1) 0 else rice.k - 1;
        }
        var x: u32 = 0;
        if (tmpk <= 16 or self.fileversion < 3910) {
            if (tmpk > 23) return error.Corrupt;
            x = try self.decodeBits(@intCast(tmpk));
        } else if (tmpk <= 31) {
            x = try self.decodeBits(16);
            x |= (try self.decodeBits(@intCast(tmpk - 16))) << 16;
        } else {
            return error.Corrupt;
        }
        x +%= overflow << @intCast(tmpk);
        updateRice(rice, x);
        return zigzag(x);
    }

    /// ape_decode_value_3990（区间编码，3.98 概率表 + pivot 自适应 base）
    pub fn decodeValue3990(self: *Ctx, rice: *Rice) Error!i32 {
        const pivot: u32 = @max(rice.ksum >> 5, 1);
        var overflow = try self.getSymbol(&counts_3980, &counts_diff_3980);
        if (overflow == MODEL_ELEMENTS - 1) {
            overflow = (try self.decodeBits(16)) << 16;
            overflow |= try self.decodeBits(16);
        }
        var base: u32 = 0;
        if (pivot < 0x10000) {
            base = try self.culFreq(pivot);
            self.update(1, base);
        } else {
            var base_hi: u32 = pivot;
            var bbits: u5 = 0;
            while (base_hi & ~@as(u32, 0xFFFF) != 0) {
                base_hi >>= 1;
                bbits += 1;
            }
            base_hi = try self.culFreq(base_hi + 1);
            self.update(1, base_hi);
            const base_lo = try self.culFreq(@as(u32, 1) << @intCast(bbits));
            self.update(1, base_lo);
            base = (base_hi << @intCast(bbits)) + base_lo;
        }
        const x = base +% overflow *% pivot;
        updateRice(rice, x);
        return zigzag(x);
    }

    /// decode_array_0000（< 3860；GetBitContext 位流 + 分阶段 Rice 自适应）
    pub fn decodeArray0000(self: *Ctx, rice: *Rice, out: []i32, blockstodecode: usize) Error!void {
        var i: usize = 0;
        rice.ksum = 0;
        var n: usize = @min(blockstodecode, 5);
        while (i < n) : (i += 1) {
            const v = try getRiceOok(&self.gb, 10);
            out[i] = @bitCast(v);
            rice.ksum +%= v;
        }
        if (blockstodecode <= 5) {
            finishZigzag(out, blockstodecode);
            return;
        }
        rice.k = getK(rice.ksum / 10);
        if (rice.k >= 24) return;
        n = @min(blockstodecode, 64);
        while (i < n) : (i += 1) {
            const v = try getRiceOok(&self.gb, @intCast(rice.k));
            out[i] = @bitCast(v);
            rice.ksum +%= v;
            rice.k = getK(rice.ksum / @as(u32, @intCast((i + 1) * 2)));
            if (rice.k >= 24) return;
        }
        if (blockstodecode <= 64) {
            finishZigzag(out, blockstodecode);
            return;
        }
        rice.k = getK(rice.ksum >> 7);
        var ksummax: u32 = @as(u32, 1) << @intCast(rice.k + 7);
        var ksummin: u32 = if (rice.k != 0) @as(u32, 1) << @intCast(rice.k + 6) else 0;
        while (i < blockstodecode) : (i += 1) {
            if (self.gb.remainingBits() < 1) return error.Corrupt;
            const v = try getRiceOok(&self.gb, @intCast(rice.k));
            out[i] = @bitCast(v);
            rice.ksum +%= v -% @as(u32, @bitCast(out[i - 64]));
            while (rice.ksum < ksummin) {
                rice.k -%= 1;
                ksummin = if (rice.k != 0) ksummin >> 1 else 0;
                ksummax >>= 1;
            }
            while (rice.ksum >= ksummax) {
                rice.k +%= 1;
                if (rice.k > 24) return;
                ksummax <<= 1;
                ksummin = if (ksummin != 0) ksummin << 1 else 128;
            }
        }
        finishZigzag(out, blockstodecode);
    }

    /// 熵解码单声道块（按版本分派，逐样本写入 decoded[0]）
    pub fn entropyMono(self: *Ctx, decoded0: []i32, count: usize) Error!void {
        if (self.fileversion < 3860) {
            try self.decodeArray0000(&self.riceY, decoded0, count);
            return;
        }
        if (self.fileversion < 3900) {
            for (0..count) |i| decoded0[i] = try self.decodeValue3860(&self.riceY);
        } else if (self.fileversion < 3990) {
            for (0..count) |i| decoded0[i] = try self.decodeValue3900(&self.riceY);
        } else {
            for (0..count) |i| decoded0[i] = try self.decodeValue3990(&self.riceY);
        }
    }

    /// 熵解码立体声块（按版本分派；3900-3929 走整行 + 区间回退重开）
    pub fn entropyStereo(self: *Ctx, decoded0: []i32, decoded1: []i32, count: usize) Error!void {
        if (self.fileversion < 3860) {
            try self.decodeArray0000(&self.riceY, decoded0, count);
            try self.decodeArray0000(&self.riceX, decoded1, count);
            return;
        }
        if (self.fileversion < 3900) {
            for (0..count) |i| decoded0[i] = try self.decodeValue3860(&self.riceY);
            for (0..count) |i| decoded1[i] = try self.decodeValue3860(&self.riceX);
            return;
        }
        if (self.fileversion < 3930) {
            for (0..count) |i| decoded0[i] = try self.decodeValue3900(&self.riceY);
            // 实现怪癖对齐（ape_decode_stereo_3900）：normalize + ptr-1 回退 +
            // 区间重开，再整行解码 ch1
            self.rangeNormalize();
            if (self.ptr > 0) self.ptr -= 1;
            try self.rangeStart();
            for (0..count) |i| decoded1[i] = try self.decodeValue3900(&self.riceX);
            return;
        }
        if (self.fileversion < 3990) {
            for (0..count) |i| {
                decoded0[i] = try self.decodeValue3900(&self.riceY);
                decoded1[i] = try self.decodeValue3900(&self.riceX);
            }
            return;
        }
        for (0..count) |i| {
            decoded0[i] = try self.decodeValue3990(&self.riceY);
            decoded1[i] = try self.decodeValue3990(&self.riceX);
        }
    }
};

/// end 标签：全部 out[0..n] 转符号（zigzag）
fn finishZigzag(out: []i32, n: usize) void {
    for (0..n) |i| out[i] = zigzag(@bitCast(out[i]));
}
