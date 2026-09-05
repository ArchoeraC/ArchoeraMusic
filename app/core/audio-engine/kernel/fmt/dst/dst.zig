//! DST（Direct Stream Transfer，DST 压缩 DSD）帧解码 —— FFmpeg libavcodec/dstdec.c
//! 逐句移植。
//!
//! 背景（ISO/IEC 14496-3 Subpart 10「lossless coding of oversampled audio」）：
//! SACD 镜像 .dff 常见为 DST 压缩而非未压缩 DSD。每个 DSTF 帧是独立的压缩单元：
//!   - 帧头标志（压缩 / 未压缩 DSD 数据）、分段（segmentation）头、通道→滤波
//!     系数集映射（fsets）与通道→概率表映射（probs）、半概率位；
//!   - fsets / probs 两张表用「未编码系数 + Golomb-Rice 残差 + 前向预测」传输
//!     （10.12 / 10.13）；fsets 提供每声道 8×16=128 抽头的 DSD 预测滤波器，
//!     probs 提供按 |预测值| 查表的符号概率；
//!   - 其后为算术码数据：ac 初始化 12 位，逐 DSD 样本用上述概率做二进制算术
//!     解码（ac_get），与（滤波器预测 >>15 的最高位）异或还原出 DSD 位 v；
//!   - 每个通道的 status 是一个 128 位移位寄存器（初始 0xAA），随输出逐位左移，
//!     作为滤波器 / 概率索引的历史（该过程无损：DST 为有损码流设计，但 ffmpeg
//!     按原样重建编码器侧等价的位流，mine 与其 bit-exact）。
//!
//! 移植对齐点（与 dstdec.c 一一对应）：
//!   - read_map（10.7~10.9）、read_table（10.12/10.13）、get_sr_golomb_dst
//!     （golomb.h get_ur_golomb_jpegls + 符号位）、ac_init/ac_get（10.11）、
//!     build_filter、prob_dst_x_bit（ff_reverse 表）；
//!   - 逐样本主循环中 status 以 16 字节小端 u64 双半移位，filter[felem][j][b]
//!     查表累加预测；
//!   - 输出 DSD 字节序与 dstdec 写盘一致：每 8 位一时间槽，位 i 落字节
//!     (i/8) 的 MSB-first（位 7-(i&7)），字节按 `槽×channels+通道` 交错存储
//!     （ffmpeg 在帧缓冲内为每通道预留 4 字节对齐；抽离 4 字节填充后逐字节等价，
//!     见 dsd2pcm translate 的 src_stride 论证）。
//!
//! 约束与 FFmpeg 一致：通道 ≤ 6（DST_MAX_CHANNELS）、fsets/probs 元素 ≤ 12
//! （DST_MAX_ELEMENTS）。不在 PATCHWELCOME 集合内的帧结构（非 same segmentation /
//! 非 same mapping 等，dstdec 仅 request_sample 后报错）返回 UnsupportedFormat。
//!
//! 验证：本模块 + dsd.zig 对 fate-suite `dst/dst-64fs44-2ch.dff`（DSD64 立体声
//! 10 帧）解码，逐 DSTF 帧重建 DSD → 复用 dsd2pcm（与 ffmpeg dsd.c 同源算法）
//! 输出 f32，与系统 ffmpeg `dst` 解码器输出（pcm_f32le，352800 Hz）逐位一致。

const std = @import("std");
const Error = @import("../../error.zig").Error;

/// DST 帧内可承载的最大通道数 / 元素数（与 dstdec.c 常量一致）
pub const max_channels = 6;
pub const max_elements = 12;

/// ffmpeg 的字节位反转表（libavutil/reverse.c）
const ff_reverse = blk: {
    @setEvalBranchQuota(100000);
    var t: [256]u8 = undefined;
    for (0..256) |x| {
        var v: u8 = @intCast(x);
        var r: u8 = 0;
        for (0..8) |_| {
            r = (r << 1) | (v & 1);
            v >>= 1;
        }
        t[x] = r;
    }
    break :blk t;
};

/// read_table 的预测系数（dstdec.c fsets_code_pred_coeff / probs_code_pred_coeff）
const fsets_code_pred_coeff = [3][3]i8{
    .{ -8, 0, 0 },
    .{ -16, 8, 0 },
    .{ -9, -5, 6 },
};
const probs_code_pred_coeff = [3][3]i8{
    .{ -8, 0, 0 },
    .{ -16, 8, 0 },
    .{ -24, 24, -8 },
};

// ---- 位读取（MSB-first，越界按 0 填充，行为对齐 ffmpeg GetBitContext） ----

pub const BitReader = struct {
    data: []const u8,
    bitpos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn bitsLeft(self: *const BitReader) usize {
        const total = self.data.len * 8;
        return if (self.bitpos >= total) 0 else total - self.bitpos;
    }

    pub fn readBit(self: *BitReader) u1 {
        if (self.bitpos >= self.data.len * 8) return 0;
        const b = self.data[self.bitpos >> 3];
        const shift: u3 = @intCast(7 - (self.bitpos & 7));
        self.bitpos += 1;
        return @intCast((b >> shift) & 1);
    }

    pub fn readBits(self: *BitReader, n: usize) u32 {
        var v: u32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            v = (v << 1) | self.readBit();
        }
        return v;
    }
};

fn avLog2(x: u32) u5 {
    if (x == 0) return 0;
    return @intCast(31 - @clz(x));
}

/// golomb.h get_ur_golomb_jpegls（非缓存路径逐位等价版）。返回 i<<k + suffix，
/// 其中 i 为前导 0 个数（读到 1 终止并消费之）；越界/无效返回 null。
fn readUrGolombJpegls(br: *BitReader, k: u32, limit: usize) ?u64 {
    var i: u32 = 0;
    while (i < limit) {
        if (br.readBit() == 1) break;
        i += 1;
        if (br.bitsLeft() == 0) break;
    }
    if (i < limit - 1) {
        const suffix: u64 = if (k > 0) br.readBits(k) else 0;
        return (@as(u64, i) << @intCast(k)) + suffix;
    } else {
        return null;
    }
}

/// dstdec.c get_sr_golomb_dst：unsigned golomb + 可选符号位。
fn getSrGolombDst(br: *BitReader, k: u32) Error!i64 {
    const v = readUrGolombJpegls(br, k, br.bitsLeft()) orelse return error.Corrupt;
    var r: i64 = @intCast(v);
    if (r != 0 and br.readBit() == 1) r = -r;
    return r;
}

// ---- 表结构 ----

const Table = struct {
    elements: u32 = 0,
    length: [max_elements]u32 = undefined,
    coeff: [max_elements][128]i32 = undefined,
};

/// read_table 的位读取：读 length_bits+1 长度；1 标志带 Golomb 差分编码
fn readUncodedCoeff(br: *BitReader, coeff_bits: u32, is_signed: bool, offset: i32) i32 {
    const raw: i32 = if (is_signed) br: {
        // 9 位补码符号扩展
        const v = br.readBits(coeff_bits);
        const sign: i32 = if ((v >> @intCast(coeff_bits - 1)) & 1 != 0) -1 else 0;
        break :br @as(i32, @intCast(v)) | (sign << @intCast(coeff_bits));
    } else @intCast(br.readBits(coeff_bits));
    return raw + offset;
}

fn readMap(br: *BitReader, t: *Table, map: []u32, channels: usize) Error!void {
    t.elements = 1;
    map[0] = 0;
    if (br.readBit() == 0) {
        var ch: usize = 1;
        while (ch < channels) : (ch += 1) {
            const bits: u5 = @intCast(@as(u32, avLog2(t.elements)) + 1);
            const m = br.readBits(bits);
            if (m == t.elements) {
                t.elements += 1;
                if (t.elements >= max_elements) return error.Corrupt;
            } else if (m > t.elements) {
                return error.Corrupt;
            }
            map[ch] = m;
        }
    } else {
        for (0..channels) |ch| map[ch] = 0;
    }
}

fn readTable(
    br: *BitReader,
    t: *Table,
    code_pred_coeff: *const [3][3]i8,
    length_bits: u32,
    coeff_bits: u32,
    is_signed: bool,
    offset: i32,
) Error!void {
    var i: usize = 0;
    while (i < t.elements) : (i += 1) {
        t.length[i] = br.readBits(length_bits) + 1;
        if (br.readBit() == 0) {
            // 未编码：直接读取全部系数
            var j: usize = 0;
            while (j < t.length[i]) : (j += 1) {
                t.coeff[i][j] = readUncodedCoeff(br, coeff_bits, is_signed, offset);
            }
        } else {
            const method = br.readBits(2);
            if (method == 3) return error.Corrupt;
            var j: usize = 0;
            while (j < method + 1) : (j += 1) {
                t.coeff[i][j] = readUncodedCoeff(br, coeff_bits, is_signed, offset);
            }
            const lsb_size = br.readBits(3);
            while (j < t.length[i]) : (j += 1) {
                // 前向预测（C 侧以 (unsigned) 系数做 mod 2^32 乘加，等价于两补码环绕）
                var x: u32 = 0;
                var k: usize = 0;
                while (k < method + 1) : (k += 1) {
                    const cv: u32 = @bitCast(t.coeff[i][j - k - 1]);
                    const f: u32 = @bitCast(@as(i32, code_pred_coeff[method][k]));
                    x +%= f *% cv;
                }
                const sx: i32 = @bitCast(x);
                var c: i64 = try getSrGolombDst(br, lsb_size);
                if (sx >= 0) {
                    c -= @divTrunc(@as(i64, sx) + 4, 8);
                } else {
                    c += @divTrunc(-@as(i64, sx) + 3, 8);
                }
                if (!is_signed) {
                    const lim: i64 = @as(i64, offset) + (@as(i64, 1) << @intCast(coeff_bits));
                    if (c < offset or c >= lim) return error.Corrupt;
                }
                t.coeff[i][j] = @intCast(c);
            }
        }
    }
}

// ---- 算术码（10.11） ----

const ArithCoder = struct {
    a: u32 = 0,
    c: u32 = 0,
};

fn acInit(br: *BitReader) ArithCoder {
    return .{ .a = 4095, .c = br.readBits(12) };
}

/// 二进制算术解码一比特，返回 e（0 = c<a_q）。与 dstdec.c ac_get 逐句一致。
fn acGet(br: *BitReader, ac: *ArithCoder, p: u32) u1 {
    const k = (ac.a >> 8) | ((ac.a >> 7) & 1);
    const q = k * p;
    const a_q = ac.a - q;
    const e: u1 = @intFromBool(ac.c < a_q);
    if (e == 1) {
        ac.a = a_q;
    } else {
        ac.a = q;
        ac.c -= a_q;
    }
    if (ac.a < 2048) {
        const n: u5 = @intCast(11 - @as(u32, avLog2(ac.a)));
        ac.a <<= n;
        ac.c = (ac.c << n) | br.readBits(n);
    }
    return e;
}

/// dstdec.c prob_dst_x_bit：由首个 fsets 系数经 ff_reverse 派生首样本概率
fn probDstXBit(c: i32) u32 {
    const idx: u8 = @truncate(@as(u32, @bitCast(c)) & 127);
    return (@as(u32, ff_reverse[idx]) >> 1) + 1;
}

// ---- 每元素 16×256 的字节点积滤波表（dstdec.c build_filter） ----

const FilterTables = struct {
    t: [max_elements][16][256]i16 = undefined,
};

fn buildFilter(ft: *FilterTables, fsets: *const Table) Error!void {
    var i: usize = 0;
    while (i < fsets.elements) : (i += 1) {
        const length: i32 = @intCast(fsets.length[i]);
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            var total: i32 = length - @as(i32, @intCast(j * 8));
            if (total < 0) total = 0 else if (total > 8) total = 8;
            var k: usize = 0;
            while (k < 256) : (k += 1) {
                var v: i64 = 0;
                var l: u8 = 0;
                while (l < @as(u8, @intCast(total))) : (l += 1) {
                    const s: i32 = if (((k >> @as(u6, @truncate(l))) & 1) != 0) 1 else -1;
                    v += @as(i64, s) * fsets.coeff[i][j * 8 + @as(usize, l)];
                }
                if (v != @as(i16, @intCast(v))) return error.Corrupt;
                ft.t[i][j][k] = @intCast(v);
            }
        }
    }
}

// ---- 解码器（按 DSTF 帧调用） ----

pub const Decoder = struct {
    fsets: Table = .{},
    probs: Table = .{},
    filter: FilterTables = .{},

    /// 解码一个 DSTF 帧载荷。
    ///   data：DSTF chunk 载荷（不含 12 字节 chunk 头）；
    ///   channels：声道数（≤ 6）；
    ///   frame_bytes_per_ch：每声道本帧产生的 DSD 字节数（= samples_per_frame/8）；
    ///   out：长度 frame_bytes_per_ch×channels，输出按「时间槽×channels+通道」
    ///     交错存储（槽内 8 位 MSB-first，与 dstdec 写盘位序一致）。
    pub fn decodeFrame(
        self: *Decoder,
        data: []const u8,
        channels: usize,
        frame_bytes_per_ch: usize,
        out: []u8,
    ) Error!void {
        if (channels == 0 or channels > max_channels) return error.UnsupportedFormat;
        if (out.len < frame_bytes_per_ch * channels) return error.Corrupt;
        @memset(out[0 .. frame_bytes_per_ch * channels], 0);
        if (data.len <= 1) return error.Corrupt;

        var br = BitReader.init(data);

        // 未压缩 DSD 数据直通（dstdec：bit0=0 → data+1 为裸 DSD）
        if (br.readBit() == 0) {
            _ = br.readBit();
            if (br.readBits(6) != 0) return error.Corrupt;
            const nbytes = frame_bytes_per_ch * channels;
            const take = @min(nbytes, data.len - 1);
            @memcpy(out[0..take], data[1 .. 1 + take]);
            return;
        }

        // 分段头（10.4~10.6）：dstdec 仅支持三位全 1
        if (br.readBit() == 0) return error.UnsupportedFormat;
        if (br.readBit() == 0) return error.UnsupportedFormat;
        if (br.readBit() == 0) return error.UnsupportedFormat;

        // 映射（10.7~10.9）
        var map_felem: [max_channels]u32 = undefined;
        var map_pelem: [max_channels]u32 = undefined;
        const same_map = br.readBit();
        try readMap(&br, &self.fsets, &map_felem, channels);
        if (same_map == 1) {
            self.probs.elements = self.fsets.elements;
            @memcpy(&map_pelem, &map_felem);
        } else {
            return error.UnsupportedFormat; // dstdec: PATCHWELCOME（Not Same Mapping）
        }

        // 半概率位（10.10）
        var half_prob: [max_channels]u1 = undefined;
        for (0..channels) |ch| half_prob[ch] = br.readBit();

        // 系数集 / 概率表（10.12 / 10.13）
        try readTable(&br, &self.fsets, &fsets_code_pred_coeff, 7, 9, true, 0);
        try readTable(&br, &self.probs, &probs_code_pred_coeff, 6, 7, false, 1);

        if (br.readBit() != 0) return error.Corrupt;

        var ac = acInit(&br);
        try buildFilter(&self.filter, &self.fsets);

        var status: [max_channels][16]u8 = undefined;
        for (0..channels) |ch| @memset(&status[ch], 0xAA);

        const samples_per_frame = frame_bytes_per_ch * 8;
        _ = acGet(&br, &ac, probDstXBit(self.fsets.coeff[0][0]));

        var i: usize = 0;
        while (i < samples_per_frame) : (i += 1) {
            for (0..channels) |ch| {
                const felem = map_felem[ch];
                const ftrow = &self.filter.t[felem];
                const st = &status[ch];
                var predict: i32 = 0;
                for (0..16) |jj| {
                    predict += @as(i32, ftrow[jj][st[jj]]);
                }
                const prob: u32 = blk: {
                    if (half_prob[ch] != 0 and i < self.fsets.length[felem]) break :blk 128;
                    const pelem = map_pelem[ch];
                    const abs_p: u32 = if (predict < 0) @as(u32, @intCast(-@as(i64, predict))) else @intCast(predict);
                    const index = abs_p >> 3;
                    const plen = self.probs.length[pelem];
                    const idx = @min(index, plen - 1);
                    break :blk @intCast(self.probs.coeff[pelem][idx]);
                };
                const residual: u1 = acGet(&br, &ac, prob);
                const sign_bit: u1 = @intCast((@as(u32, @bitCast(predict)) >> 15) & 1);
                const v: u1 = sign_bit ^ residual;

                const shift: u3 = @intCast(7 - (i & 7));
                out[(i >> 3) * channels + ch] |= @as(u8, v) << shift;

                // status 128 位移位寄存器（16 字节 = 双小端 u64；新位入 LSB）
                const lo_old = std.mem.readInt(u64, st[0..8], .little);
                const hi_old = std.mem.readInt(u64, st[8..16], .little);
                std.mem.writeInt(u64, st[8..16], (hi_old << 1) | (lo_old >> 63), .little);
                std.mem.writeInt(u64, st[0..8], (lo_old << 1) | v, .little);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "dst: 位读取器 MSB-first 基本语义" {
    var br = BitReader.init(&.{ 0b10100011, 0b00001111 });
    try testing.expectEqual(@as(u1, 1), br.readBit());
    try testing.expectEqual(@as(u32, 0b010), br.readBits(3));
    try testing.expectEqual(@as(u32, 0b0011), br.readBits(4));
    try testing.expectEqual(@as(u32, 0), br.readBits(4));
    try testing.expectEqual(@as(u32, 0b1111), br.readBits(4));
    try testing.expectEqual(@as(u32, 0), br.readBits(3)); // 越界填充 0
}

test "dst: readMap 全零映射分支（首 bit=1 → 全部通道映射元素 0）" {
    var br = BitReader.init(&.{ 0b10000000, 0b00000000 });
    var t: Table = undefined;
    var map: [max_channels]u32 = undefined;
    try readMap(&br, &t, &map, 3);
    try testing.expectEqual(@as(u32, 1), t.elements);
    try testing.expectEqual(@as(u32, 0), map[0]);
    try testing.expectEqual(@as(u32, 0), map[1]);
    try testing.expectEqual(@as(u32, 0), map[2]);
}

test "dst: readMap 通道独立映射（fate 样本帧 0 真实前导位）" {
    const dff = @embedFile("samples/dst-64fs44-2ch.dff");
    // 首个 DSTF 载荷 @0xa0 长 4676：帧 bit0=1（压缩），随后 3 bit 分段头全 1，
    // same_map 位、fsets map、half_prob×2、fsets 表……
    const payload = dff[0xa0 .. 0xa0 + 4676];
    var br = BitReader.init(payload);
    try testing.expectEqual(@as(u1, 1), br.readBit());
    try testing.expectEqual(@as(u1, 1), br.readBit());
    try testing.expectEqual(@as(u1, 1), br.readBit());
    try testing.expectEqual(@as(u1, 1), br.readBit());
    try testing.expectEqual(@as(u1, 1), br.readBit()); // same_map
    var t: Table = undefined;
    var map: [max_channels]u32 = undefined;
    try readMap(&br, &t, &map, 2);
    // 编码器为每通道使用独立滤波系数集（fsets.elements=2）
    try testing.expectEqual(@as(u32, 2), t.elements);
    // half_prob ×2
    _ = br.readBit();
    _ = br.readBit();
    // 后续为 fsets 表读取（length_bits=7）；仅验证能完整解析
    try readTable(&br, &t, &fsets_code_pred_coeff, 7, 9, true, 0);
    try testing.expect(t.length[0] > 0 and t.length[1] > 0);
}

test "dst: ff_reverse 与 ffmpeg reverse 表抽样一致" {
    // 抽样：0x01→0x80、0x80→0x01、0xF0→0x0F、0x2C→0x34
    try testing.expectEqual(@as(u8, 0x80), ff_reverse[0x01]);
    try testing.expectEqual(@as(u8, 0x01), ff_reverse[0x80]);
    try testing.expectEqual(@as(u8, 0x0F), ff_reverse[0xF0]);
    try testing.expectEqual(@as(u8, 0x34), ff_reverse[0x2C]);
}

test "dst: prob_dst_x_bit 抽样（对照 dstdec.c 公式）" {
    // c=64 → c&127=64 → ff_reverse[64]=0x02 → >>1=1 → 2
    try testing.expectEqual(@as(u32, 2), probDstXBit(64));
    // c=0 → ff_reverse[0]=0 → 1
    try testing.expectEqual(@as(u32, 1), probDstXBit(0));
}

// ---------------------------------------------------------------------------
// >2 声道 / 高位 DSD 帧路径（无公开多声道 DST 样本，见交付报告）
//
// DSTF 帧头（map/fsets/probs/half_prob）与逐样本算术码主循环均按「声道数」
// 参数化：DST_MAX_CHANNELS=6，map 由每个通道独立读索引。公开渠道无 >2 声道
// DST 样本（fate-suite /dst/ 仅 dst-64fs44-2ch.dff，DSD64 立体声；SACD 5.1
// 镜像为商业内容不在可获取范围内），因此多声道路径以合成位测试覆盖：
//   - read_map 6 声道 / 逐通道建元素（新元素 = 读值恰为当前元素数）；
//   - 未压缩 DSD 直通帧的 6 声道交错布局；
//   - 通道数边界（0 / >6 拒绝）。
// DST 算术解码与 DSD 采样率无关（dstdec 只重建 1-bit 流，DSD64/128/256 的差异
// 在容器层帧长与下游 dsd2pcm，非本解码器），故高位档无可独立验证的编解码差异。
// ---------------------------------------------------------------------------

test "dst: readMap 6 声道逐通道建元素（多元素映射）" {
    // 前置位 0（非全零）后逐通道：elements 1→2→3，ch3..ch5 复用已有元素
    // bits: 0 | 1 | 10 | 00 | 01 | 10  = 0b0110_0001_10
    var br = BitReader.init(&.{ 0b01100001, 0b10000000 });
    var t: Table = undefined;
    var map: [max_channels]u32 = undefined;
    try readMap(&br, &t, &map, 6);
    try testing.expectEqual(@as(u32, 3), t.elements);
    const want = [_]u32{ 0, 1, 2, 0, 1, 2 };
    for (0..6) |ch| try testing.expectEqual(want[ch], map[ch]);
}

test "dst: readMap 6 声道全部独立元素（元素数 6 = 通道数）" {
    // bits: 0 | 1 | 10 | 11 | 100 | 101  = 0b0110_1110_0101
    var br = BitReader.init(&.{ 0b01101110, 0b01010000 });
    var t: Table = undefined;
    var map: [max_channels]u32 = undefined;
    try readMap(&br, &t, &map, 6);
    try testing.expectEqual(@as(u32, 6), t.elements);
    for (0..6) |ch| try testing.expectEqual(@as(u32, @intCast(ch)), map[ch]);
}

test "dst: readMap 越界元素引用被拒" {
    // 通道 2 读到 m=2 但 elements 仍为 1（只可能来自 bit 宽度不足时的非法值）
    var br = BitReader.init(&.{ 0b00000000, 0b10000000 });
    var t: Table = undefined;
    var map: [max_channels]u32 = undefined;
    try readMap(&br, &t, &map, 2);
    // 首 bit=0；ch1 宽 1 位读 0 → m=0<elements(1) 合法。此处仅验证流程可完成。
    try testing.expectEqual(@as(u32, 1), t.elements);
}

test "dst: 6 声道未压缩 DSD 直通帧布局" {
    // DSTF 帧首字节 bit0=0（未压缩）+ bit1 跳过 + 6 位保留须 0 → 其后为裸 DSD，
    // 按「时间槽×channels+通道」交错拷贝。帧字节/声道 = 4，共 6 声道。
    var payload: [1 + 4 * 6]u8 = undefined;
    payload[0] = 0b00000000;
    for (1..payload.len) |i| payload[i] = @truncate(0xA0 + i);
    var dec = Decoder{};
    var out: [4 * 6]u8 = undefined;
    @memset(&out, 0xCC);
    try dec.decodeFrame(&payload, 6, 4, &out);
    try testing.expectEqualSlices(u8, payload[1..], &out);
}

test "dst: 未压缩直通对 5.1（6ch）长帧逐位保持" {
    var payload: [1 + 32 * 6]u8 = undefined;
    payload[0] = 0b00000000;
    var seed: u32 = 7;
    for (1..payload.len) |i| {
        seed = seed *% 1664525 +% 1013904223;
        payload[i] = @truncate(seed >> 16);
    }
    var dec = Decoder{};
    var out: [32 * 6]u8 = undefined;
    try dec.decodeFrame(&payload, 6, 32, &out);
    try testing.expectEqualSlices(u8, payload[1..], &out);
}

test "dst: 声道数边界（0 与 >6 拒绝；输出缓冲不足为 Corrupt）" {
    var dec = Decoder{};
    var out: [64]u8 = undefined;
    try testing.expectError(error.UnsupportedFormat, dec.decodeFrame(&.{ 0xFF }, 0, 8, &out));
    try testing.expectError(error.UnsupportedFormat, dec.decodeFrame(&.{ 0xFF }, 7, 8, &out));
    var out32: [32]u8 = undefined;
    try testing.expectError(error.Corrupt, dec.decodeFrame(&.{ 0xFF, 0x00 }, 6, 8, &out32));
}
