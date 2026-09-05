//! Opus 区间解码器（docs/audio-kernel-zig.md §9.2）
//!
//! RFC 6716 §4.1 32-bit 区间解码；参考重构对照 FFmpeg `libavcodec/opus/rc.c`
//! 与 libopus `entdec.c`；参考对照非复制（§3.3）。
//!
//! 语义要点（对齐参考实现，保证 bit-exact）：
//!   - 位流经 GetBitContext 读取（MSB-first），字节取反（`get_bits(8) ^ 0xFF`，
//!     编码端补码）；帧数据须零填充（越界读按零处理，对齐 FFmpeg 填充缓存）；
//!   - `dec_init`：range=128，value=127 - 7bit，total_bits=9，随后归一化；
//!   - `dec_update`：value -= scale*(total-high)；range = low ? scale*(high-low)
//!     : range - scale*(total-high)；u32 回绕算术；
//!   - CELT rawbits 从帧尾**反向**逐字节读入（`ff_opus_rc_get_raw`）；
//!   - `tell` / `tell_frac` 供 CELT 位预算（PVQ / 带宽决策）使用。

const std = @import("std");
const Error = @import("../../error.zig").Error;

const RC_BITS = 32;
const RC_SYM = 8;
const RC_CEIL = 0xFF;
const RC_TOP: u32 = 1 << 31;
const RC_BOT: u32 = RC_TOP >> RC_SYM;
const RC_SHIFT: u32 = RC_BITS - RC_SYM - 1;

/// MSB-first 位读取（零填充越界，对齐 FFmpeg get_bits 的填充缓存语义）
pub const BitReader = struct {
    data: []const u8,
    bit_pos: usize = 0,
    /// 存储上限（bit 单位，对齐 libopus `ec_dec.storage`；越界按 0，默认 data.len*8）
    limit: usize = std.math.maxInt(usize),

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data, .limit = data.len * 8 };
    }

    /// 读 n 位（0..=32），越界位按 0 处理
    pub fn readBits(self: *BitReader, n: u6) u32 {
        var v: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            const pos = self.bit_pos + i;
            if (pos >= self.limit or pos >= self.data.len * 8) {
                v <<= 1;
                continue;
            }
            v = (v << 1) | @as(u32, @intCast((self.data[pos >> 3] >> @as(u3, @intCast(7 - (pos & 7)))) & 1));
        }
        self.bit_pos += n;
        return v;
    }
};

/// CELT rawbits 缓冲（从帧尾反向读取）
const RawBits = struct {
    /// 反向游标（index into data slice；从 data.len 递减）
    position: usize = 0,
    bytes: u32 = 0,
    cachelen: u32 = 0,
    cacheval: u32 = 0,
    data: []const u8 = &.{},
};

/// opus_ilog（av_log2(i) + !!i）
pub fn opusIlog(i: u32) u32 {
    if (i == 0) return 0;
    return @intCast(32 - @clz(i));
}

/// ff_sqrt：整数平方根（floor），逐位逼近
fn ffSqrt(a: u32) u32 {
    if (a == 0) return 0;
    var r: u64 = a;
    var b: u64 = @as(u64, 1) << 62;
    while (b > r) b >>= 2;
    var res: u64 = 0;
    while (b != 0) {
        if (r >= res + b) {
            r -= res + b;
            res = (res >> 1) + b;
        } else {
            res >>= 1;
        }
        b >>= 2;
    }
    return @intCast(res);
}

pub const Rc = struct {
    gb: BitReader,
    rb: RawBits = .{},
    range: u32 = 0,
    value: u32 = 0,
    total_bits: u32 = 0,

    /// ff_opus_rc_dec_init
    pub fn decInit(data: []const u8) Rc {
        var rc = Rc{ .gb = BitReader.init(data), .range = 128, .total_bits = 9 };
        rc.value = 127 - rc.gb.readBits(7);
        rc.decNormalize();
        return rc;
    }

    /// ff_opus_rc_dec_raw_init（rightend = 帧数据，bytes = 可读字节数）
    pub fn decRawInit(self: *Rc, data: []const u8, bytes: u32) void {
        self.rb = .{
            .position = if (bytes >= data.len) data.len else @intCast(bytes),
            .bytes = bytes,
            .cachelen = 0,
            .cacheval = 0,
            .data = data,
        };
    }

    /// opus_rc_dec_normalize
    fn decNormalize(self: *Rc) void {
        while (self.range <= RC_BOT) {
            const b = self.gb.readBits(RC_SYM) ^ RC_CEIL;
            self.value = ((self.value << RC_SYM) | b) & (RC_TOP - 1);
            self.range <<= RC_SYM;
            self.total_bits += RC_SYM;
        }
    }

    /// opus_rc_dec_update
    fn decUpdate(self: *Rc, scale: u32, low: u32, high: u32, total: u32) void {
        self.value -%= scale *% (total -% high);
        self.range = if (low != 0) scale *% (high -% low) else self.range -% scale *% (total -% high);
        self.decNormalize();
    }

    /// ff_opus_rc_dec_cdf（cdf[0] = total，其后为累计频率，末项 = total）
    pub fn decCdf(self: *Rc, cdf: []const u16) u32 {
        const total = cdf[0];
        const scale = self.range / total;
        var symbol = self.value / scale + 1;
        symbol = total - @min(symbol, total);
        var k: usize = 0;
        while (k + 1 < cdf.len and cdf[k + 1] <= symbol) k += 1;
        const high = cdf[k + 1];
        const low: u32 = if (k == 0) 0 else cdf[k];
        self.decUpdate(scale, low, high, total);
        return @intCast(k);
    }

    /// ec_dec_icdf（SILK 逆累积分布，u8 表；_ftb = 分布总位宽）
    pub fn decIcdf(self: *Rc, icdf: []const u8, ftb: u32) u32 {
        var s = self.range;
        const d = self.value;
        const r = s >> @as(u5, @intCast(ftb));
        var ret: u32 = 0;
        while (true) {
            const t = s;
            s = r *% icdf[ret];
            if (d < s) {
                ret += 1;
                continue;
            }
            self.value = d - s;
            self.range = t - s;
            self.decNormalize();
            return ret;
        }
    }

    /// ec_dec_icdf16（u16 表版本）
    pub fn decIcdf16(self: *Rc, icdf: []const u16, ftb: u32) u32 {
        var s = self.range;
        const d = self.value;
        const r = s >> @as(u5, @intCast(ftb));
        var ret: u32 = 0;
        while (true) {
            const t = s;
            s = r *% icdf[ret];
            if (d < s) {
                ret += 1;
                continue;
            }
            self.value = d - s;
            self.range = t - s;
            self.decNormalize();
            return ret;
        }
    }

    /// ff_opus_rc_dec_log（1 bit 二分）
    pub fn decLog(self: *Rc, bits: u5) u32 {
        const scale = self.range >> bits;
        var k: u32 = 0;
        if (self.value >= scale) {
            self.value -%= scale;
            self.range -%= scale;
        } else {
            self.range = scale;
            k = 1;
        }
        self.decNormalize();
        return k;
    }

    /// ff_opus_rc_get_raw：从帧尾反向读 count 位原始位
    pub fn getRaw(self: *Rc, count: u32) u32 {
        var value: u32 = 0;
        while (self.rb.bytes != 0 and self.rb.cachelen < count) {
            if (self.rb.position == 0) break;
            self.rb.position -= 1;
            self.rb.cacheval |= @as(u32, self.rb.data[self.rb.position]) << @as(u5, @intCast(self.rb.cachelen));
            self.rb.cachelen += 8;
            self.rb.bytes -= 1;
        }
        const c5: u5 = if (count >= 32) 31 else @intCast(count);
        value = if (count >= 32) self.rb.cacheval else self.rb.cacheval & ((@as(u32, 1) << c5) - 1);
        self.rb.cacheval >>= c5;
        self.rb.cachelen -%= count;
        self.total_bits +%= count;
        return value;
    }

    /// ff_opus_rc_dec_uint：均匀分布整数
    pub fn decUint(self: *Rc, size: u32) u32 {
        const bits = opusIlog(size - 1);
        const total = if (bits > 8) ((size - 1) >> @as(u5, @intCast(bits - 8))) + 1 else size;
        const scale = self.range / total;
        var k = self.value / scale + 1;
        k = total - @min(k, total);
        self.decUpdate(scale, k, k + 1, total);
        if (bits > 8) {
            k = (k << @as(u5, @intCast(bits - 8))) | self.getRaw(bits - 8);
            return @min(k, size - 1);
        }
        return k;
    }

    /// ff_opus_rc_dec_uint_step（CELT θ 量化）
    pub fn decUintStep(self: *Rc, k0: i32) u32 {
        const total: u32 = @intCast((k0 + 1) * 3 + k0);
        const scale = self.range / total;
        var symbol = self.value / scale + 1;
        symbol = total - @min(symbol, total);
        const k: u32 = if (symbol < @as(u32, @intCast(k0 + 1)) * 3)
            symbol / 3
        else
            symbol - @as(u32, @intCast(k0 + 1)) * 2;
        const k0u: u32 = @intCast(k0);
        const low: u32 = if (k <= k0u) 3 * k else (k - 1 - k0u) + 3 * @as(u32, @intCast(k0 + 1));
        const high: u32 = if (k <= k0u) 3 * (k + 1) else (k - k0u) + 3 * @as(u32, @intCast(k0 + 1));
        self.decUpdate(scale, low, high, total);
        return k;
    }

    /// ff_opus_rc_dec_uint_tri（CELT 三角分布整数）
    pub fn decUintTri(self: *Rc, qn: i32) u32 {
        const qnu: u32 = @intCast(qn);
        const half = (qnu >> 1) + 1;
        const total: u32 = half * half;
        const scale = self.range / total;
        var center = self.value / scale + 1;
        center = total - @min(center, total);
        var k: u32 = 0;
        var low: u32 = 0;
        var symbol: u32 = 0;
        if (center < total >> 1) {
            k = (ffSqrt(8 * center + 1) - 1) >> 1;
            low = k * (k + 1) >> 1;
            symbol = k + 1;
        } else {
            k = (2 * (qnu + 1) - ffSqrt(8 * (total - center - 1) + 1)) >> 1;
            low = total - ((qnu + 1 - k) * (qnu + 2 - k) >> 1);
            symbol = qnu + 1 - k;
        }
        self.decUpdate(scale, low, low + symbol, total);
        return k;
    }

    /// ec_laplace_decode（CELT 粗能量拉普拉斯解码，基于 ec_decode_bin + ec_dec_update）
    pub fn decLaplace(self: *Rc, symbol0: u32, decay: u32) i32 {
        const lap_minp: u32 = 1;
        var value: i32 = 0;
        var fl: u32 = 0;
        var fs: u32 = symbol0;
        const ext = self.range >> 15;
        const s = self.value / ext;
        const fm: u32 = (1 << 15) - @min(s + 1, 1 << 15);
        if (fm >= symbol0) {
            value += 1;
            fl = symbol0;
            fs = ecLaplaceGetFreq1(symbol0, decay) + lap_minp;
            while (fs > lap_minp and fm >= fl + 2 * fs) {
                fs *= 2;
                fl += fs;
                fs = ((fs - 2 * lap_minp) * decay) >> 15;
                fs += lap_minp;
                value += 1;
            }
            if (fs <= lap_minp) {
                const di: u32 = (fm - fl) >> (lap_minp_log + 1);
                value += @intCast(di);
                fl += 2 * di * lap_minp;
            }
            if (fm < fl + fs) {
                value = -value;
            } else {
                fl += fs;
            }
        }
        self.decUpdate(ext, fl, @min(fl + fs, 32768), 32768);
        return value;
    }

    const lap_minp_log: u5 = 0;

    fn ecLaplaceGetFreq1(fs0: u32, decay: u32) u32 {
        const ft = 32768 - 2 * @as(u32, 16) - fs0;
        return ft * (16384 - decay) >> 15;
    }

    /// opus_rc_tell（整数位精度）
    pub fn tell(self: *const Rc) u32 {
        return self.total_bits -% (@as(u32, 31 - @clz(self.range)) + 1);
    }

    /// opus_rc_tell_frac（1/8 位精度）
    pub fn tellFrac(self: *const Rc) u32 {
        const total_bits = self.total_bits << 3;
        var rcbuffer: u32 = @as(u32, 31 - @clz(self.range)) + 1;
        var range = self.range >> @as(u5, @intCast(rcbuffer - 16));
        for (0..3) |_| {
            range = range * range >> 15;
            const bit = range >> 16;
            rcbuffer = rcbuffer << 1 | bit;
            range >>= @as(u5, @intCast(bit));
        }
        return total_bits - rcbuffer;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "opus rc: 原始位反向读取" {
    var rc = Rc{ .gb = undefined, .range = 128, .total_bits = 9 };
    // 数据 0x12 0x34 0x56：反向读 = 先 0x56
    const data = [_]u8{ 0x12, 0x34, 0x56 };
    rc.decRawInit(&data, 3);
    try testing.expectEqual(@as(u32, 0x56), rc.getRaw(8));
    try testing.expectEqual(@as(u32, 0x34), rc.getRaw(8));
    try testing.expectEqual(@as(u32, 0x12), rc.getRaw(8));
    try testing.expectEqual(@as(u32, 0), rc.getRaw(8)); // 耗尽
}

test "opus rc: ff_sqrt 整数平方根" {
    try testing.expectEqual(@as(u32, 0), ffSqrt(0));
    try testing.expectEqual(@as(u32, 1), ffSqrt(1));
    try testing.expectEqual(@as(u32, 2), ffSqrt(4));
    try testing.expectEqual(@as(u32, 2), ffSqrt(5));
    try testing.expectEqual(@as(u32, 3), ffSqrt(9));
    try testing.expectEqual(@as(u32, 3), ffSqrt(15));
    try testing.expectEqual(@as(u32, 46340), ffSqrt(0x7FFFFFFF)); // floor(sqrt(2^31-1))
}

test "opus rc: opus_ilog" {
    try testing.expectEqual(@as(u32, 0), opusIlog(0));
    try testing.expectEqual(@as(u32, 1), opusIlog(1));
    try testing.expectEqual(@as(u32, 2), opusIlog(2));
    try testing.expectEqual(@as(u32, 3), opusIlog(4));
}

test "opus rc: tell / tell_frac 单调性" {
    const data = [_]u8{0} ** 16;
    var rc = Rc.decInit(&data); // 归一化后 range > BOT，tell_frac 安全
    const t0 = rc.tell();
    const tf0 = rc.tellFrac();
    // 模拟若干解码后位预算增长
    rc.total_bits = 100;
    rc.range = 0x40000000;
    try testing.expect(rc.tell() > t0);
    try testing.expect(rc.tellFrac() > tf0);
}

test "opus rc: dec_log 二分读取一致性" {
    // 手工构造 8 字节零流（编码端补码 → 全 0xFF 位流）
    const data = [_]u8{0x00} ** 8;
    var rc = Rc.decInit(&data);
    // 8 次 decLog(1)：每读 1 位，应能稳定推进不崩溃且位预算增长
    const before = rc.tell();
    for (0..8) |_| {
        _ = rc.decLog(1);
    }
    try testing.expect(rc.tell() >= before);
}
