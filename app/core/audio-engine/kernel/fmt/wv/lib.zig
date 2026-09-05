//! WavPack 解码器（docs/audio-kernel-zig.md §9.9）
//!
//! 参考重构对照 wavpack.c / wavpack.h / wavpackdata.c；参考对照非复制（§3.3）。
//!
//! 容器：wvpk 32 字节块头 + 块内 metadata 序列。文件为连续块流：
//!   一个"包"由 INITIAL_BLOCK 起到 FINAL_BLOCK 止的 1..N 个块组成，
//!   多声道文件每块携带 1（mono）或 2（stereo）个声道，块间共用同一样本区间。
//!
//! 解码流程（对齐 FFmpeg wavpack_decode_frame/block 语义）：
//!   1. 包内逐块读入内存（块总大小 = ckSize + 8）；
//!   2. 解析 metadata：DECTERMS（去相关项）→ DECWEIGHTS（权重）→ DECSAMPLES（初始样本）
//!      → ENTROPY（median 初值）→ HYBRID / INT32INFO / FLOATINFO → DATA（主位流）
//!      → EXTRABITS（低位补全位流，首 32 位为 CRC）；
//!   3. 熵解码（LSB-first）：零块压缩 → unary 区间 → median 自适应 → 符号位；
//!   4. 去相关 terms 级联（t>8 二阶预测 / t≤8 环形缓冲 / t=-1 自预测 / t=-3 交叉）；
//!   5. joint 反变换 → CRC 校验 → 按输出契约打包。
//!
//! 输出契约（对齐 FFmpeg wavpack 默认输出，保证 bit-exact 对照可逐字节比对）：
//!   - flags&3 ≤ 1 → 16-bit（post_shift 对齐满幅）；≥ 2 → 32-bit 顶对齐；
//!   - WV_FLOAT_DATA → 32-bit IEEE float；
//!   - 交错小端 PCM，`Info.bits_per_sample` = 16 / 32，`is_float` 标记 float。
//!
//! 范围与容错（§9.9 / §13.3）：
//!   - 混合 .wvc 修正、DSD 调制不在本期范围：DSD 在 open 判定 → UnsupportedFormat
//!     （引擎回退 FFmpeg 主后端，§8.3）；流中段出现 → Corrupt；
//!   - 块内位流越界、CRC 不匹配、包内块数失控 → Corrupt；
//!   - seek 走块头扫描（block_index 定位包），目标超出文件尾 → 置 EOF。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const bitreader = @import("bitreader.zig");

const BitReader = bitreader.BitReader;
const VTable = decoder.Decoder.VTable;

// ---------------------------------------------------------------------------
// 常量（对齐 WavPack 规范 / FFmpeg wavpack.h 取值）
// ---------------------------------------------------------------------------

const MAX_TERMS = 16;
const MAX_TERM = 8;
const header_size = 32;
const WV_MAX_SAMPLES = 150000;
/// 单块内存上限（DATA 最大 ≈ samples×4×2 声道，16MB 为恶意 ckSize 兜底）
const block_cap = 16 * 1024 * 1024;
/// 单包最多块数（声道上限兜底；实际 ≤ 8）
const max_blocks_per_packet = 64;

// 块标志
const F_MONO = 0x00000004;
const F_JOINT_STEREO = 0x00000010;
const F_CROSS_DECORR = 0x00000020;
const F_FLOAT_DATA = 0x00000080;
const F_INT32_DATA = 0x00000100;
const F_FALSE_STEREO = 0x40000000;
const F_DSD_DATA = 0x80000000;
const F_HYBRID_MODE = 0x00000008;
const F_HYBRID_BITRATE = 0x00000200;
const F_HYBRID_BALANCE = 0x00000400;
const F_INITIAL_BLOCK = 0x00000800;
const F_FINAL_BLOCK = 0x00001000;

// metadata ID 标志
const IDF_MASK: u8 = 0x3F;
const IDF_ODD: u8 = 0x40;
const IDF_LONG: u8 = 0x80;

// WP_ID
const ID_DECTERMS = 2;
const ID_DECWEIGHTS = 3;
const ID_DECSAMPLES = 4;
const ID_ENTROPY = 5;
const ID_HYBRID = 6;
const ID_FLOATINFO = 8;
const ID_INT32INFO = 9;
const ID_DATA = 10;
const ID_EXTRABITS = 12;
const ID_CHANINFO = 13;
const ID_SAMPLE_RATE = 0x27;

// float 标志（WV_FLT_*）
const FFLT_SHIFT_ONES = 0x01;
const FFLT_SHIFT_SAME = 0x02;
const FFLT_SHIFT_SENT = 0x04;
const FFLT_ZERO_SENT = 0x08;
const FFLT_ZERO_SIGN = 0x10;

/// 采样率表（wv_rates[16]，索引 = flags>>23 & 0xf；0xf = 自定义走 SAMPLE_RATE）
const rate_table = [16]u32{
    6000,  8000,  9600,  11025, 12000, 16000, 22050,  24000,
    32000, 44100, 48000, 64000, 88200, 96000, 192000, 0,
};

/// 指数表（17 位定点 2^(i/256) 的低字节；与参考实现一致的数据表）
const exp2_table = [256]u8{
    0x00, 0x01, 0x01, 0x02, 0x03, 0x03, 0x04, 0x05, 0x06, 0x06, 0x07, 0x08, 0x08, 0x09, 0x0a, 0x0b,
    0x0b, 0x0c, 0x0d, 0x0e, 0x0e, 0x0f, 0x10, 0x10, 0x11, 0x12, 0x13, 0x13, 0x14, 0x15, 0x16, 0x16,
    0x17, 0x18, 0x19, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1d, 0x1e, 0x1f, 0x20, 0x20, 0x21, 0x22, 0x23,
    0x24, 0x24, 0x25, 0x26, 0x27, 0x28, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2c, 0x2d, 0x2e, 0x2f, 0x30,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3a, 0x3b, 0x3c, 0x3d,
    0x3e, 0x3f, 0x40, 0x41, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x48, 0x49, 0x4a, 0x4b,
    0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a,
    0x5b, 0x5c, 0x5d, 0x5e, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
    0x7a, 0x7b, 0x7c, 0x7d, 0x7e, 0x7f, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x87, 0x88, 0x89, 0x8a,
    0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0x90, 0x91, 0x92, 0x93, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b,
    0x9c, 0x9d, 0x9f, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad,
    0xaf, 0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbc, 0xbd, 0xbe, 0xbf, 0xc0,
    0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc8, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf, 0xd0, 0xd2, 0xd3, 0xd4,
    0xd6, 0xd7, 0xd8, 0xd9, 0xdb, 0xdc, 0xdd, 0xde, 0xe0, 0xe1, 0xe2, 0xe4, 0xe5, 0xe6, 0xe8, 0xe9,
    0xea, 0xec, 0xed, 0xee, 0xf0, 0xf1, 0xf2, 0xf4, 0xf5, 0xf6, 0xf8, 0xf9, 0xfa, 0xfc, 0xfd, 0xff,
};

/// 对数表（log2_table，17 位定点小数低字节）
const log2_table = [256]u8{
    0x00, 0x01, 0x03, 0x04, 0x06, 0x07, 0x09, 0x0a, 0x0b, 0x0d, 0x0e, 0x10, 0x11, 0x12, 0x14, 0x15,
    0x16, 0x18, 0x19, 0x1a, 0x1c, 0x1d, 0x1e, 0x20, 0x21, 0x22, 0x24, 0x25, 0x26, 0x28, 0x29, 0x2a,
    0x2c, 0x2d, 0x2e, 0x2f, 0x31, 0x32, 0x33, 0x34, 0x36, 0x37, 0x38, 0x39, 0x3b, 0x3c, 0x3d, 0x3e,
    0x3f, 0x41, 0x42, 0x43, 0x44, 0x45, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4d, 0x4e, 0x4f, 0x50, 0x51,
    0x52, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x5c, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63,
    0x64, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73, 0x74,
    0x76, 0x77, 0x78, 0x79, 0x7a, 0x7b, 0x7c, 0x7d, 0x7e, 0x7f, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85,
    0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0x90, 0x91, 0x92, 0x93, 0x94, 0x95,
    0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4,
    0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb0, 0xb1, 0xb2, 0xb2,
    0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xc0, 0xc0,
    0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xcb, 0xcb, 0xcc, 0xcd, 0xce,
    0xcf, 0xd0, 0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd8, 0xd9, 0xda, 0xdb,
    0xdc, 0xdc, 0xdd, 0xde, 0xdf, 0xe0, 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe4, 0xe5, 0xe6, 0xe7, 0xe7,
    0xe8, 0xe9, 0xea, 0xea, 0xeb, 0xec, 0xed, 0xee, 0xee, 0xef, 0xf0, 0xf1, 0xf1, 0xf2, 0xf3, 0xf4,
    0xf4, 0xf5, 0xf6, 0xf7, 0xf7, 0xf8, 0xf9, 0xf9, 0xfa, 0xfb, 0xfc, 0xfc, 0xfd, 0xfe, 0xff, 0xff,
};

// ---------------------------------------------------------------------------
// 数学原语（17 位定点对数/指数域）
// ---------------------------------------------------------------------------

/// 2^(val/256)（17 位定点）。整数部分 > 31 → 溢出哨兵（真实数据不会出现）。
fn wpExp2(val: i16) i32 {
    var v: i32 = val;
    var neg = false;
    if (v < 0) {
        v = -v;
        neg = true;
    }
    var res: i32 = @as(i32, exp2_table[@as(u8, @truncate(@as(u32, @bitCast(v))))]) | 0x100;
    const shift: i32 = v >> 8;
    if (shift > 31) return std.math.minInt(i32);
    res = if (shift > 9) res << @intCast(shift - 9) else res >> @intCast(9 - shift);
    return if (neg) -res else res;
}

/// 最高位索引（floor(log2(x))，x > 0）
fn log2Floor(x: u32) u6 {
    return @intCast(31 - @clz(x));
}

/// 256·log2(val)（17 位定点）
fn wpLog2(val: u32) i32 {
    if (val == 0) return 0;
    if (val == 1) return 256;
    const v = val +% (val >> 9);
    const bits: i32 = @intCast(@as(u32, log2Floor(v)) + 1);
    const frac: u32 = if (bits < 9)
        (v << @intCast(9 - bits)) & 0xFF
    else
        (v >> @intCast(bits - 9)) & 0xFF;
    return (bits << 8) + @as(i32, log2_table[frac]);
}

/// 慢电平衰减（17 位定点，算术右移 = floor）
inline fn levelDecay(a: i32) i32 {
    return (a + 0x80) >> 8;
}

// ---------------------------------------------------------------------------
// 数据结构
// ---------------------------------------------------------------------------

/// 去相关项（自适应预测器状态）
const Decorr = struct {
    delta: i32 = 0,
    value: i32 = 0,
    weightA: i32 = 0,
    weightB: i32 = 0,
    samplesA: [MAX_TERM]i32 = [_]i32{0} ** MAX_TERM,
    samplesB: [MAX_TERM]i32 = [_]i32{0} ** MAX_TERM,
};

/// 声道熵解码状态
const WvChannel = struct {
    median: [3]i32 = [_]i32{0} ** 3,
    slow_level: i32 = 0,
    error_limit: i32 = 0,
    bitrate_acc: u32 = 0,
    bitrate_delta: u32 = 0,
};

/// 输出格式（对齐 FFmpeg 三种输出）
const OutFmt = enum { s16, s32, float };

/// 单块解码上下文（解析 + 熵解码 + 去相关共用）
const BlockCtx = struct {
    crc: u32 = 0,
    crc_extra_bits: u32 = 0,
    samples: u32 = 0,
    frame_flags: u32 = 0,
    sample_rate: u32 = 0,
    terms: usize = 0,
    decorr: [MAX_TERMS]Decorr = [_]Decorr{.{}} ** MAX_TERMS,
    ch: [2]WvChannel = [_]WvChannel{.{}} ** 2,
    zero: bool = false,
    one: bool = false,
    zeroes: u32 = 0,
    extra_bits: u32 = 0,
    and_: i32 = 0,
    or_: i32 = 0,
    shift: u5 = 0,
    post_shift: u5 = 0,
    hybrid: bool = false,
    hybrid_bitrate: bool = false,
    hybrid_maxclip: i32 = 0,
    hybrid_minclip: i32 = 0,
    float_flag: u8 = 0,
    float_shift: u5 = 0,
    float_max_exp: i32 = 0,
    stereo: bool = false,
    stereo_in: bool = false,
    joint: bool = false,
    got_extra_bits: bool = false,
    out_fmt: OutFmt = .s16,
    data_br: BitReader = undefined,
    extra_bits_br: BitReader = undefined,
};

// ---------------------------------------------------------------------------
// 熵解码
// ---------------------------------------------------------------------------

/// 区间尾部：k 个符号的 zigzag 编码（LSB-first 位流）
fn getTail(br: *BitReader, k: u32) Error!u32 {
    if (k < 1) return 0;
    const p = log2Floor(k);
    const e: u32 = (@as(u32, 1) << @intCast(p + 1)) -% k -% 1;
    var res = try br.readBits(@intCast(p));
    if (res >= e) {
        res = res *% 2 -% e +% @as(u32, try br.readBit());
    }
    return res;
}

/// GET_MED(n)：median[n]>>4 + 1（≥ 1）
inline fn getMed(c: *const WvChannel, n: u3) i32 {
    return (c.median[n] >> 4) + 1;
}

/// DEC_MED(n)：以 2 的幂收敛（C 语义：u32 回绕 + 截断除法）
fn decMed(c: *WvChannel, n: u3) void {
    const div: i32 = @as(i32, 128) >> @intCast(n);
    const acc: u32 = @as(u32, @bitCast(c.median[n])) +% (@as(u32, @intCast(div)) -% 2);
    const quot = @divTrunc(@as(i32, @bitCast(acc)), div);
    c.median[n] = @bitCast(@as(u32, @bitCast(c.median[n])) -% (@as(u32, @bitCast(quot)) *% 2));
}

/// INC_MED(n)：以 5 的幂放大
fn incMed(c: *WvChannel, n: u3) void {
    const div: i32 = @as(i32, 128) >> @intCast(n);
    const acc: u32 = @as(u32, @bitCast(c.median[n])) +% @as(u32, @intCast(div));
    const quot = @divTrunc(@as(i32, @bitCast(acc)), div);
    c.median[n] = @bitCast(@as(u32, @bitCast(c.median[n])) +% (@as(u32, @bitCast(quot)) *% 5));
}

/// 混合模式错误上限更新（仅声道 0 触发，见 getValue）
fn updateErrorLimit(b: *BlockCtx) Error!void {
    var brv: [2]i32 = undefined;
    var sl: [2]i32 = undefined;
    var i: usize = 0;
    while (i <= @intFromBool(b.stereo_in)) : (i += 1) {
        if (b.ch[i].bitrate_acc > std.math.maxInt(u32) - b.ch[i].bitrate_delta) return error.Corrupt;
        b.ch[i].bitrate_acc +%= b.ch[i].bitrate_delta;
        brv[i] = @intCast(b.ch[i].bitrate_acc >> 16);
        sl[i] = levelDecay(b.ch[i].slow_level);
    }
    if (b.stereo_in and b.hybrid_bitrate) {
        const balance: i32 = (sl[1] - sl[0] + brv[1] + 1) >> 1;
        if (balance > brv[0]) {
            brv[1] = brv[0] * 2;
            brv[0] = 0;
        } else if (-balance > brv[0]) {
            brv[0] *= 2;
            brv[1] = 0;
        } else {
            brv[1] = brv[0] + balance;
            brv[0] -= balance;
        }
    }
    i = 0;
    while (i <= @intFromBool(b.stereo_in)) : (i += 1) {
        b.ch[i].error_limit = if (b.hybrid_bitrate)
            (if (sl[i] - brv[i] > -0x100) wpExp2(@bitCast(@as(u16, @truncate(@as(u32, @bitCast(sl[i] - brv[i] + 0x100)))))) else 0)
        else
            wpExp2(@bitCast(@as(u16, @truncate(@as(u32, @bitCast(brv[i]))))));
    }
}

/// 熵解码一个样本（未去相关）。位流不足 → Corrupt。
fn getValue(b: *BlockCtx, br: *BitReader, channel: usize) Error!i32 {
    const c = &b.ch[channel];
    var t: i32 = 0;

    // 零块压缩：两声道 median[0] 均 < 2 且无挂起位时，游程编码
    if (b.ch[0].median[0] < 2 and b.ch[1].median[0] < 2 and !b.zero and !b.one) {
        if (b.zeroes != 0) {
            b.zeroes -= 1;
            if (b.zeroes != 0) {
                c.slow_level -= levelDecay(c.slow_level);
                return 0;
            }
        } else {
            var z: u32 = try br.readUnary0(33);
            if (z >= 2) {
                if (z >= 32) return error.Corrupt;
                z = (try br.readBits(@intCast(z - 1))) | (@as(u32, 1) << @intCast(z - 1));
            }
            b.zeroes = z;
            if (b.zeroes != 0) {
                b.ch[0].median = [_]i32{ 0, 0, 0 };
                b.ch[1].median = [_]i32{ 0, 0, 0 };
                c.slow_level -= levelDecay(c.slow_level);
                return 0;
            }
        }
    }

    // 主 unary 前缀（含 16 → 32 位扩展的逃逸路径）
    if (b.zero) {
        t = 0;
        b.zero = false;
    } else {
        t = @intCast(try br.readUnary0(33));
        if (t == 16) {
            const t2: u32 = try br.readUnary0(33);
            if (t2 < 2) {
                t += @intCast(t2);
            } else {
                if (t2 >= 32) return error.Corrupt;
                const ext: u32 = (try br.readBits(@intCast(t2 - 1))) | (@as(u32, 1) << @intCast(t2 - 1));
                t +%= @as(i32, @bitCast(ext));
            }
        }
        if (b.one) {
            b.one = (t & 1) != 0;
            t = (t >> 1) + 1;
        } else {
            b.one = (t & 1) != 0;
            t >>= 1;
        }
        b.zero = !b.one;
    }

    // 混合模式：每对样本（声道 0）更新错误上限
    if (b.hybrid and channel == 0) {
        try updateErrorLimit(b);
    }

    // median 区间 → base/add
    var base: i32 = 0;
    var add: i32 = 0;
    if (t == 0) {
        add = getMed(c, 0) - 1;
        decMed(c, 0);
    } else if (t == 1) {
        base = getMed(c, 0);
        add = getMed(c, 1) - 1;
        incMed(c, 0);
        decMed(c, 1);
    } else if (t == 2) {
        base = getMed(c, 0) + getMed(c, 1);
        add = getMed(c, 2) - 1;
        incMed(c, 0);
        incMed(c, 1);
        decMed(c, 2);
    } else {
        const t_u: u32 = @bitCast(t);
        base = @bitCast(@as(u32, @bitCast(getMed(c, 0))) +% @as(u32, @bitCast(getMed(c, 1))) +%
            @as(u32, @bitCast(getMed(c, 2))) *% (t_u -% 2));
        add = getMed(c, 2) - 1;
        incMed(c, 0);
        incMed(c, 1);
        incMed(c, 2);
    }

    // 误差限路径：error_limit==0 走区间尾部，否则逐位二分逼近
    var ret: i32 = 0;
    if (c.error_limit == 0) {
        ret = @bitCast(@as(u32, @bitCast(base)) +% (try getTail(br, @intCast(add))));
    } else {
        var mid: i32 = @bitCast((@as(u32, @bitCast(base)) *% 2 +% @as(u32, @bitCast(add)) +% 1) >> 1);
        while (add > c.error_limit) {
            if (try br.readBit() == 1) {
                add = @bitCast(@as(u32, @bitCast(add)) -% (@as(u32, @bitCast(mid)) -% @as(u32, @bitCast(base))));
                base = mid;
            } else {
                add = @bitCast(@as(u32, @bitCast(mid)) -% @as(u32, @bitCast(base)) -% 1);
            }
            mid = @bitCast((@as(u32, @bitCast(base)) *% 2 +% @as(u32, @bitCast(add)) +% 1) >> 1);
        }
        ret = mid;
    }

    // 符号位 + 混合码率慢电平跟踪
    const sign = try br.readBit();
    if (b.hybrid_bitrate) {
        c.slow_level +%= wpLog2(@bitCast(ret)) - levelDecay(c.slow_level);
    }
    return if (sign != 0) ~ret else ret;
}

/// 整数样本成形：extrabits 补全 → 符号/位深调整 → 混合限幅 → post_shift 顶对齐
fn valueToInteger(b: *BlockCtx, crc: *u32, s_in: i32) Error!i32 {
    var s: u32 = @bitCast(s_in);
    if (b.extra_bits != 0) {
        s *%= @as(u32, 1) << @intCast(b.extra_bits);
        if (b.got_extra_bits and b.extra_bits_br.remainingBits() >= b.extra_bits) {
            s |= try b.extra_bits_br.readBits(@intCast(b.extra_bits));
            crc.* = crc.* *% 9 +% (s & 0xffff) *% 3 +% (s >> 16);
        }
    }
    var bit: u32 = (s & @as(u32, @bitCast(b.and_))) | @as(u32, @bitCast(b.or_));
    bit = ((s +% bit) << @intCast(b.shift)) -% bit;
    if (b.hybrid) {
        bit = @bitCast(std.math.clamp(@as(i32, @bitCast(bit)), b.hybrid_minclip, b.hybrid_maxclip));
    }
    return @bitCast(bit << @intCast(b.post_shift));
}

/// float 样本重建：尾数移位 + 指数恢复（含 extrabits 尾数补充路径）
fn valueToFloat(b: *BlockCtx, crc: *u32, s_in: i32) f32 {
    var s: i32 = s_in;
    var sign: u1 = 0;
    var exp: i32 = b.float_max_exp;

    if (s != 0) {
        s = @bitCast(@as(u32, @bitCast(s)) *% (@as(u32, 1) << @intCast(b.float_shift)));
        sign = if (s < 0) 1 else 0;
        if (sign == 1) s = @bitCast(-%@as(u32, @bitCast(s)));
        if (s >= 0x1000000) {
            if (b.got_extra_bits and (b.extra_bits_br.readBit() catch 0) != 0) {
                s = @bitCast(b.extra_bits_br.readBits(23) catch 0);
            } else {
                s = 0;
            }
            exp = 255;
        } else if (exp != 0) {
            var shift: i32 = 23 - @as(i32, log2Floor(@intCast(s)));
            exp = b.float_max_exp;
            if (exp <= shift) {
                exp -= 1;
                shift = exp;
            }
            exp -= shift;
            if (shift != 0) {
                s <<= @intCast(shift);
                if ((b.float_flag & FFLT_SHIFT_ONES) != 0 or
                    (b.got_extra_bits and (b.float_flag & FFLT_SHIFT_SAME) != 0 and (b.extra_bits_br.readBit() catch 0) != 0))
                {
                    s |= (@as(i32, 1) << @intCast(shift)) - 1;
                } else if (b.got_extra_bits and (b.float_flag & FFLT_SHIFT_SENT) != 0) {
                    s |= @bitCast(b.extra_bits_br.readBits(@intCast(shift)) catch 0);
                }
            }
        } else {
            exp = b.float_max_exp;
        }
        s &= 0x7fffff;
    } else {
        sign = 0;
        exp = 0; // 对齐参考：S==0 时 exp 归零（首样本静音 → 0.0）
        if (b.got_extra_bits and (b.float_flag & FFLT_ZERO_SENT) != 0) {
            if ((b.extra_bits_br.readBit() catch 0) != 0) {
                s = @bitCast(b.extra_bits_br.readBits(23) catch 0);
                if (b.float_max_exp >= 25) exp = @bitCast(b.extra_bits_br.readBits(8) catch 0);
                sign = b.extra_bits_br.readBit() catch 0;
            } else if ((b.float_flag & FFLT_ZERO_SIGN) != 0) {
                sign = b.extra_bits_br.readBit() catch 0;
            }
        }
    }

    crc.* = crc.* *% 27 +% @as(u32, @intCast(s)) *% 9 +% @as(u32, @intCast(exp)) *% 3 +% sign;
    const u: u32 = (@as(u32, sign) << 31) | (@as(u32, @intCast(exp)) << 23) | @as(u32, @intCast(s));
    return @bitCast(u);
}

// ---------------------------------------------------------------------------
// 去相关权重
// ---------------------------------------------------------------------------

/// s16 快速路径：u32 模乘 + 512，int 算术右移 10（对齐参考实现的乘法技巧）
inline fn applyWeightS16(weight: i32, sample: i32) i32 {
    const acc: u32 = @as(u32, @bitCast(weight *% sample)) +% 512;
    return @as(i32, @bitCast(acc)) >> 10;
}

/// s32/float 精确路径：i64 乘 + 512 >> 10
inline fn applyWeightWide(weight: i32, sample: i32) i32 {
    const prod: i64 = @as(i64, weight) * sample + 512;
    return @as(i32, @intCast(prod >> 10));
}

/// 自适应权重更新（±delta，钳位 ±1024）
inline fn updateWeightClip(w: *i32, delta: i32) void {
    const clip: i32 = 1024;
    w.* += delta;
    if (w.* > clip) {
        w.* = clip;
    } else if (w.* < -clip) {
        w.* = -clip;
    }
}

/// UPDATE_WEIGHT_CLIP 语义：samples 与 input 异号 → -delta，同号 → +delta，钳位 ±1024
inline fn updateWeightClipSigned(w: *i32, delta: i32, samples: i32, input: i32) void {
    if (samples != 0 and input != 0) {
        if ((samples ^ input) < 0) {
            w.* -= delta;
            if (w.* < -1024) w.* = -1024;
        } else {
            w.* += delta;
            if (w.* > 1024) w.* = 1024;
        }
    }
}

// ---------------------------------------------------------------------------
// 样本解包（熵解码 + 去相关 + joint + CRC）
// ---------------------------------------------------------------------------

/// stereo 解包。planes 已按 packet_samples 分块（plane_l/plane_r 各一独立块）。
/// 输出前对去相关原始值做 CRC 累计（crc 为块头校验值，crc_extra 为 extrabits 流）。
fn unpackStereo(
    b: *BlockCtx,
    br: *BitReader,
    plane_l: []i32,
    plane_r: []i32,
    fmt: OutFmt,
) Error!void {
    var pos: usize = 0;
    var crc: u32 = 0xFFFFFFFF;
    var crc_extra: u32 = 0xFFFFFFFF;
    var count: usize = 0;
    b.zero = false;
    b.one = false;
    b.zeroes = 0;
    while (count < b.samples) {
        var l_val: i32 = try getValue(b, br, 0);
        var r_val: i32 = try getValue(b, br, 1);
        for (0..b.terms) |i| {
            const d = &b.decorr[i];
            const t = d.value;
            if (t > 0) {
                var a: i32 = 0;
                var bv: i32 = 0;
                var j: usize = 0;
                if (t > 8) {
                    if (t & 1 != 0) {
                        a = @bitCast(@as(u32, @bitCast(d.samplesA[0])) *% 2 -% @as(u32, @bitCast(d.samplesA[1])));
                        bv = @bitCast(@as(u32, @bitCast(d.samplesB[0])) *% 2 -% @as(u32, @bitCast(d.samplesB[1])));
                    } else {
                        a = @as(i32, @bitCast(@as(u32, @bitCast(d.samplesA[0])) *% 3 -% @as(u32, @bitCast(d.samplesA[1])))) >> 1;
                        bv = @as(i32, @bitCast(@as(u32, @bitCast(d.samplesB[0])) *% 3 -% @as(u32, @bitCast(d.samplesB[1])))) >> 1;
                    }
                    d.samplesA[1] = d.samplesA[0];
                    d.samplesB[1] = d.samplesB[0];
                    j = 0;
                } else {
                    a = d.samplesA[pos];
                    bv = d.samplesB[pos];
                    j = (pos + @as(usize, @intCast(t))) & 7;
                }
                const l2 = l_val + (if (fmt == .s16) applyWeightS16(d.weightA, a) else applyWeightWide(d.weightA, a));
                const r2 = r_val + (if (fmt == .s16) applyWeightS16(d.weightB, bv) else applyWeightWide(d.weightB, bv));
                if (a != 0 and l_val != 0)
                    d.weightA -= ((@as(i32, (l_val ^ a) >> 30) & 2) - 1) * d.delta;
                if (bv != 0 and r_val != 0)
                    d.weightB -= ((@as(i32, (r_val ^ bv) >> 30) & 2) - 1) * d.delta;
                d.samplesA[j] = l2;
                d.samplesB[j] = r2;
                l_val = l2;
                r_val = r2;
            } else if (t == -1) {
                // 自预测：L 用 samplesA[0]；R 用更新后的 L2；samplesA[0] = R
                const l2 = l_val + (if (fmt == .s16) applyWeightS16(d.weightA, d.samplesA[0]) else applyWeightWide(d.weightA, d.samplesA[0]));
                updateWeightClipSigned(&d.weightA, d.delta, d.samplesA[0], l_val);
                const r2 = r_val + (if (fmt == .s16) applyWeightS16(d.weightB, l2) else applyWeightWide(d.weightB, l2));
                updateWeightClipSigned(&d.weightB, d.delta, l2, r_val);
                d.samplesA[0] = r2;
                l_val = l2;
                r_val = r2;
            } else {
                // t = -2/-3：R 用 samplesB[0]；L 用更新后的 R2（t=-3 时用旧 samplesA[0]）；samplesB[0] = L
                const r2 = r_val + (if (fmt == .s16) applyWeightS16(d.weightB, d.samplesB[0]) else applyWeightWide(d.weightB, d.samplesB[0]));
                updateWeightClipSigned(&d.weightB, d.delta, d.samplesB[0], r_val);
                var pred_a = r2;
                if (t == -3) {
                    pred_a = d.samplesA[0];
                    d.samplesA[0] = r2;
                }
                const l2 = l_val + (if (fmt == .s16) applyWeightS16(d.weightA, pred_a) else applyWeightWide(d.weightA, pred_a));
                updateWeightClipSigned(&d.weightA, d.delta, pred_a, l_val);
                d.samplesB[0] = l2;
                l_val = l2;
                r_val = r2;
            }
        }
        // s16 大样本越界防护（对齐参考：decorr 之后、joint 之前）
        if (fmt == .s16) {
            const big: i64 = @as(i64, @abs(l_val)) + @as(i64, @abs(r_val));
            if (big > (1 << 19)) return error.Corrupt;
        }
        pos = (pos + 1) & 7;

        // joint 反变换（对齐参考：L += (R -= L>>1)，算术右移）
        if (b.joint) {
            r_val = r_val - (l_val >> 1);
            l_val = l_val + r_val;
        }

        crc = crc *% 3 +% @as(u32, @bitCast(l_val));
        crc = crc *% 3 +% @as(u32, @bitCast(r_val));

        plane_l[count] = switch (fmt) {
            .s16, .s32 => try valueToInteger(b, &crc_extra, l_val),
            .float => @bitCast(valueToFloat(b, &crc_extra, l_val)),
        };
        plane_r[count] = switch (fmt) {
            .s16, .s32 => try valueToInteger(b, &crc_extra, r_val),
            .float => @bitCast(valueToFloat(b, &crc_extra, r_val)),
        };
        count += 1;
    }
    try checkCrc(b, crc, crc_extra);
}

/// mono 解包（单平面）
fn unpackMono(b: *BlockCtx, br: *BitReader, plane: []i32, fmt: OutFmt) Error!void {
    var pos: usize = 0;
    var crc: u32 = 0xFFFFFFFF;
    var crc_extra: u32 = 0xFFFFFFFF;
    var count: usize = 0;
    b.zero = false;
    b.one = false;
    b.zeroes = 0;
    while (count < b.samples) {
        var t_val: i32 = try getValue(b, br, 0);
        var s_val: i32 = 0;
        for (0..b.terms) |i| {
            const d = &b.decorr[i];
            const t = d.value;
            var a_val: i32 = 0;
            var j: usize = 0;
            if (t > 8) {
                if (t & 1 != 0) {
                    a_val = @bitCast(@as(u32, @bitCast(d.samplesA[0])) *% 2 -% @as(u32, @bitCast(d.samplesA[1])));
                } else {
                    a_val = @as(i32, @bitCast(@as(u32, @bitCast(d.samplesA[0])) *% 3 -% @as(u32, @bitCast(d.samplesA[1])))) >> 1;
                }
                d.samplesA[1] = d.samplesA[0];
                j = 0;
            } else {
                a_val = d.samplesA[pos];
                j = (pos + @as(usize, @intCast(t))) & 7;
            }
            s_val = t_val + (if (fmt == .s16) applyWeightS16(d.weightA, a_val) else applyWeightWide(d.weightA, a_val));
            if (a_val != 0 and t_val != 0)
                d.weightA -= ((@as(i32, (t_val ^ a_val) >> 30) & 2) - 1) * d.delta;
            t_val = s_val;
            d.samplesA[j] = t_val;
        }
        pos = (pos + 1) & 7;
        crc = crc *% 3 +% @as(u32, @bitCast(s_val));
        plane[count] = switch (fmt) {
            .s16, .s32 => try valueToInteger(b, &crc_extra, s_val),
            .float => @bitCast(valueToFloat(b, &crc_extra, s_val)),
        };
        count += 1;
    }
    try checkCrc(b, crc, crc_extra);
}

/// CRC 校验（数据流 + extrabits 流）
fn checkCrc(b: *BlockCtx, crc: u32, crc_extra: u32) Error!void {
    if (crc != b.crc) return error.Corrupt;
    if (b.got_extra_bits and crc_extra != b.crc_extra_bits) return error.Corrupt;
}

// ---------------------------------------------------------------------------
// 容器：块解析
// ---------------------------------------------------------------------------

/// 解析单个 wvpk 块（buf = 完整块，≥ 32 字节）。
/// 填充 BlockCtx：块头派生 + metadata（terms/weights/samples/entropy/…）+ 主位流。
fn parseBlock(b: *BlockCtx, buf: []const u8) Error!void {
    b.samples = std.mem.readInt(u32, buf[20..24], .little);
    b.frame_flags = std.mem.readInt(u32, buf[24..28], .little);
    b.crc = std.mem.readInt(u32, buf[28..32], .little);
    const flags = b.frame_flags;

    b.stereo = (flags & F_MONO) == 0;
    b.stereo_in = b.stereo;
    b.joint = (flags & F_JOINT_STEREO) != 0;
    b.hybrid = (flags & F_HYBRID_MODE) != 0;
    b.hybrid_bitrate = (flags & F_HYBRID_BITRATE) != 0;

    // 输出格式与位深派生（flags&3：0=8bit 1=16bit 2=24bit 3=32bit）
    const is_float = (flags & F_FLOAT_DATA) != 0;
    const is_s16 = !is_float and (flags & 0x03) <= 1;
    b.out_fmt = if (is_float) .float else if (is_s16) .s16 else .s32;
    const bpp: i32 = if (b.out_fmt == .s16) 2 else 4;
    const orig_bpp: i32 = @as(i32, @intCast((flags & 0x03) + 1)) << 3;
    const post_shift_i: i32 = bpp * 8 - orig_bpp + @as(i32, @intCast((flags >> 13) & 0x1f));
    if (post_shift_i < 0 or post_shift_i > 31) return error.Corrupt;
    b.post_shift = @intCast(post_shift_i);

    if (b.hybrid) {
        b.hybrid_maxclip = (@as(i32, 1) << @intCast(orig_bpp - 1)) - 1;
        b.hybrid_minclip = @bitCast(@as(u32, 0xFFFFFFFF) << @intCast(orig_bpp - 1));
    }

    const sr: u32 = (flags >> 23) & 0xf;
    b.sample_rate = rate_table[sr];

    // ---- metadata 遍历（字节消耗对齐参考实现）----
    var got_terms = false;
    var got_weights = false;
    var got_samples = false;
    var got_entropy = false;
    var got_hybrid = false;
    var got_float = false;
    var got_pcm = false;
    var pos: usize = header_size;
    while (pos + 2 <= buf.len) {
        const id = buf[pos];
        pos += 1;
        var size: usize = buf[pos];
        pos += 1;
        if ((id & IDF_LONG) != 0) {
            if (pos + 2 > buf.len) break;
            size |= @as(usize, std.mem.readInt(u16, buf[pos..][0..2], .little)) << 8;
            pos += 2;
        }
        size <<= 1; // 字节数 = 字数 × 2
        const ssize = size;
        if ((id & IDF_ODD) != 0) size -%= 1;
        if (size > buf.len - pos) break; // 越界（含 ODD 下溢为巨大值）→ 终止解析

        switch (id & IDF_MASK) {
            ID_DECTERMS => {
                if (size > MAX_TERMS) {
                    pos += ssize;
                    continue;
                }
                b.terms = size;
                for (0..size) |i| {
                    const val = buf[pos + i];
                    const d = &b.decorr[size - i - 1];
                    d.delta = @as(i32, val) >> 5;
                    d.value = @as(i32, val & 0x1F) - 5;
                }
                pos += size;
                got_terms = true;
            },
            ID_DECWEIGHTS => {
                if (!got_terms) {
                    pos += ssize; // 参考实现无消耗 continue（潜在死循环），此处跳过防挂死
                    continue;
                }
                const weights = size >> @intFromBool(b.stereo_in);
                if (weights > MAX_TERMS or weights > b.terms) {
                    pos += ssize;
                    continue;
                }
                var wi: usize = 0;
                while (wi < weights) : (wi += 1) {
                    const d = &b.decorr[b.terms - wi - 1];
                    var t: i32 = @as(i32, @as(i8, @bitCast(buf[pos]))) * 8;
                    pos += 1;
                    if (t > 0) t +%= (t + 64) >> 7;
                    d.weightA = t;
                    if (b.stereo_in) {
                        t = @as(i32, @as(i8, @bitCast(buf[pos]))) * 8;
                        pos += 1;
                        if (t > 0) t +%= (t + 64) >> 7;
                        d.weightB = t;
                    }
                }
                got_weights = true;
            },
            ID_DECSAMPLES => {
                if (!got_terms) {
                    pos += ssize;
                    continue;
                }
                const limit = (size - 2) >> @intFromBool(b.stereo_in);
                var t: i32 = 0;
                var i: usize = b.terms;
                while (i > 0) {
                    i -= 1;
                    if (t >= limit) break;
                    const d = &b.decorr[i];
                    if (d.value > 8) {
                        d.samplesA[0] = wpExp2(@bitCast(std.mem.readInt(u16, buf[pos..][0..2], .little)));
                        pos += 2;
                        d.samplesA[1] = wpExp2(@bitCast(std.mem.readInt(u16, buf[pos..][0..2], .little)));
                        pos += 2;
                        t += 4;
                        if (b.stereo_in) {
                            d.samplesB[0] = wpExp2(@bitCast(std.mem.readInt(u16, buf[pos..][0..2], .little)));
                            pos += 2;
                            d.samplesB[1] = wpExp2(@bitCast(std.mem.readInt(u16, buf[pos..][0..2], .little)));
                            pos += 2;
                            t += 4;
                        }
                    } else if (d.value < 0) {
                        d.samplesA[0] = wpExp2(@bitCast(std.mem.readInt(u16, buf[pos..][0..2], .little)));
                        pos += 2;
                        d.samplesB[0] = wpExp2(@bitCast(std.mem.readInt(u16, buf[pos..][0..2], .little)));
                        pos += 2;
                        t += 4;
                    } else if (d.value != 0) {
                        for (0..@intCast(d.value)) |j| {
                            d.samplesA[j] = wpExp2(@bitCast(std.mem.readInt(u16, buf[pos..][0..2], .little)));
                            pos += 2;
                            if (b.stereo_in) {
                                d.samplesB[j] = wpExp2(@bitCast(std.mem.readInt(u16, buf[pos..][0..2], .little)));
                                pos += 2;
                            }
                        }
                        t += d.value * 2 * (1 + @as(i32, @intFromBool(b.stereo_in)));
                    } else break;
                }
                got_samples = true;
            },
            ID_ENTROPY => {
                if (size != 6 * (1 + @as(usize, @intFromBool(b.stereo_in)))) {
                    pos += ssize;
                    continue;
                }
                for (0..1 + @as(usize, @intFromBool(b.stereo_in))) |j| {
                    for (0..3) |m| {
                        b.ch[j].median[m] = wpExp2(@bitCast(std.mem.readInt(u16, buf[pos..][0..2], .little)));
                        pos += 2;
                    }
                }
                got_entropy = true;
            },
            ID_HYBRID => {
                var hsize: i32 = @intCast(size);
                if (b.hybrid_bitrate) {
                    for (0..1 + @as(usize, @intFromBool(b.stereo_in))) |i| {
                        b.ch[i].slow_level = wpExp2(@bitCast(std.mem.readInt(u16, buf[pos..][0..2], .little)));
                        pos += 2;
                        hsize -= 2;
                    }
                }
                for (0..1 + @as(usize, @intFromBool(b.stereo_in))) |i| {
                    b.ch[i].bitrate_acc = @as(u32, std.mem.readInt(u16, buf[pos..][0..2], .little)) << 16;
                    pos += 2;
                    hsize -= 2;
                }
                if (hsize > 0) {
                    for (0..1 + @as(usize, @intFromBool(b.stereo_in))) |i| {
                        b.ch[i].bitrate_delta = @bitCast(wpExp2(@bitCast(std.mem.readInt(u16, buf[pos..][0..2], .little))));
                        pos += 2;
                    }
                } else {
                    for (0..1 + @as(usize, @intFromBool(b.stereo_in))) |i|
                        b.ch[i].bitrate_delta = 0;
                }
                got_hybrid = true;
            },
            ID_INT32INFO => {
                if (size != 4) {
                    if (ssize >= 4) {
                        pos += ssize - 4;
                    } else {
                        pos = buf.len;
                    }
                    continue;
                }
                const v0 = buf[pos];
                const v1 = buf[pos + 1];
                const v2 = buf[pos + 2];
                const v3 = buf[pos + 3];
                pos += 4;
                if (v0 > 30) {
                    pos += ssize; // 参考实现无消耗 continue；此处跳过防挂死
                    continue;
                }
                b.extra_bits = v0;
                if (v1 != 0) b.shift = @intCast(v1);
                if (v2 != 0) {
                    b.and_ = 1;
                    b.or_ = 1;
                    b.shift = @intCast(v2);
                }
                if (v3 != 0) {
                    b.and_ = 1;
                    b.shift = @intCast(v3);
                }
                if (b.shift > 31) {
                    b.and_ = 0;
                    b.or_ = 0;
                    b.shift = 0;
                    pos += ssize;
                    continue;
                }
                // 32-bit 有损按 24-bit 限幅（对齐参考实现的特殊处理）
                if (b.hybrid and bpp == 4 and b.post_shift < 8 and b.shift > 8) {
                    b.post_shift += 8;
                    b.shift -= 8;
                    b.hybrid_maxclip >>= 8;
                    b.hybrid_minclip >>= 8;
                }
            },
            ID_FLOATINFO => {
                if (size != 4) {
                    pos += ssize;
                    continue;
                }
                b.float_flag = buf[pos];
                b.float_shift = @intCast(buf[pos + 1]);
                b.float_max_exp = buf[pos + 2];
                pos += 4;
                if (b.float_shift > 31) {
                    b.float_shift = 0;
                    pos += ssize;
                    continue;
                }
                got_float = true;
            },
            ID_DATA => {
                b.data_br = BitReader.init(buf[pos..][0..size]);
                pos += size;
                got_pcm = true;
            },
            ID_EXTRABITS => {
                if (size <= 4) {
                    pos += size;
                    continue;
                }
                b.extra_bits_br = BitReader.init(buf[pos..][0..size]);
                b.crc_extra_bits = b.extra_bits_br.readBits(32) catch 0;
                pos += size;
                b.got_extra_bits = true;
            },
            ID_CHANINFO => {
                if (size <= 1) return error.Corrupt;
                pos += 1; // chan
                switch (size - 2) {
                    0 => pos += 1,
                    1 => pos += 2,
                    2 => pos += 3,
                    3 => pos += 4,
                    4 => pos += 6, // 1 保留 + 1 chan_hi + 3 chmask
                    5 => pos += 7, // 1 保留 + 1 chan_hi + 4 chmask
                    else => {},
                }
            },
            ID_SAMPLE_RATE => {
                if (size != 3) return error.Corrupt;
                b.sample_rate = @as(u32, buf[pos]) | (@as(u32, buf[pos + 1]) << 8) | (@as(u32, buf[pos + 2]) << 16);
                pos += 3;
            },
            else => {
                pos += size;
            },
        }
        if ((id & IDF_ODD) != 0) pos += 1;
    }

    // 主位流必需元数据完备性（对齐参考实现）
    if (got_pcm) {
        if (!got_terms or !got_weights or !got_samples or !got_entropy) return error.Corrupt;
        if (b.hybrid and !got_hybrid) return error.Corrupt;
        if (!got_float and b.out_fmt == .float) return error.Corrupt;
    } else {
        return error.Corrupt;
    }

    // extrabits 流样本数一致性（非 float 文件，位流长度须 ≥ samples·extra_bits·声道数）
    if (b.got_extra_bits and b.out_fmt != .float) {
        const wanted = b.samples *% b.extra_bits << @intFromBool(b.stereo_in);
        if (b.extra_bits_br.remainingBits() < wanted) b.got_extra_bits = false;
    }
}

// ---------------------------------------------------------------------------
// 解码会话：包（packet）驱动
// ---------------------------------------------------------------------------

const MAX_CHANNELS = 8;

const BlockHeader = struct {
    block_index: u64,
    block_samples: u32,
    flags: u32,
    total: usize,
};

const WvCtx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,
    sample_rate: u32,
    channels: u8,
    total_samples: u64,
    out_bps: u8,
    is_float: bool,
    block_buf: []u8,
    planes: []i32,
    pkt: []u8,
    pkt_samples: usize,
    pkt_block_index: u64,
    cursor: usize,
    samples_done: u64,
};

const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

/// 读一个完整块到 block_buf；文件尾 / 魔数不符 → null；块大小越界 → Corrupt
fn readBlock(ctx: *WvCtx) Error!?BlockHeader {
    var head: [header_size]u8 = undefined;
    const n = try ctx.reader.peek(&head);
    if (n < header_size) return null;
    if (!std.mem.eql(u8, head[0..4], "wvpk")) return null;
    const ck_size: u32 = std.mem.readInt(u32, head[4..8], .little);
    const total: u64 = @as(u64, ck_size) + 8;
    if (total < header_size or total > block_cap) return error.Corrupt;
    const t: usize = @intCast(total);
    if (ctx.block_buf.len < t) ctx.block_buf = try ctx.allocator.realloc(ctx.block_buf, t);
    const got = try ctx.reader.read(ctx.block_buf[0..t]);
    if (got < t) return error.Corrupt;
    return .{
        .block_index = std.mem.readInt(u32, head[16..20], .little),
        .block_samples = std.mem.readInt(u32, head[20..24], .little),
        .flags = std.mem.readInt(u32, head[24..28], .little),
        .total = t,
    };
}

/// 解码一个完整包（INITIAL..FINAL 块序列）到 planes 并交错进 pkt。
/// false = 文件尾（无更多包）。返回后 reader 位于下一包起点。
fn decodePacket(ctx: *WvCtx) Error!bool {
    const first = (try readBlock(ctx)) orelse return false;
    const packet_samples: usize = first.block_samples;
    if (packet_samples == 0 or packet_samples > WV_MAX_SAMPLES) return error.Corrupt;
    const pkt_float = (first.flags & F_FLOAT_DATA) != 0;
    const pkt_s16 = !pkt_float and (first.flags & 0x03) <= 1;
    const pkt_fmt: OutFmt = if (pkt_float) .float else if (pkt_s16) .s16 else .s32;
    const bpp: usize = if (pkt_fmt == .s16) 2 else 4;

    var ch_offset: usize = 0;
    var block_no: usize = 0;
    var bh = first;
    while (true) {
        if (bh.block_samples != packet_samples) return error.Corrupt;
        var b = std.mem.zeroes(BlockCtx);
        try parseBlock(&b, ctx.block_buf[0..bh.total]);
        const blk_float = (b.frame_flags & F_FLOAT_DATA) != 0;
        const blk_s16 = !blk_float and (b.frame_flags & 0x03) <= 1;
        const blk_fmt: OutFmt = if (blk_float) .float else if (blk_s16) .s16 else .s32;
        if (block_no > 0 and blk_fmt != pkt_fmt) return error.Corrupt;

        const planes_need = packet_samples * (ch_offset + @as(usize, @intFromBool(b.stereo)) + 1);
        if (ctx.planes.len < planes_need) ctx.planes = try ctx.allocator.realloc(ctx.planes, planes_need);
        const base = ch_offset * packet_samples;
        if (b.stereo_in) {
            try unpackStereo(
                &b,
                &b.data_br,
                ctx.planes[base..][0..packet_samples],
                ctx.planes[base + packet_samples ..][0..packet_samples],
                blk_fmt,
            );
        } else {
            try unpackMono(&b, &b.data_br, ctx.planes[base..][0..packet_samples], blk_fmt);
            if (b.stereo) // 伪立体声：单声道样本复制到第二平面
                @memcpy(ctx.planes[base + packet_samples ..][0..packet_samples], ctx.planes[base..][0..packet_samples]);
        }
        ch_offset += 1 + @as(usize, @intFromBool(b.stereo));
        if (ch_offset > MAX_CHANNELS) return error.Corrupt;

        if (ctx.sample_rate == 0) ctx.sample_rate = b.sample_rate;
        if (block_no == 0) {
            ctx.is_float = blk_float;
            ctx.out_bps = if (pkt_fmt == .s16) 16 else 32;
        }
        if ((bh.flags & F_FINAL_BLOCK) != 0) break;
        block_no += 1;
        if (block_no >= max_blocks_per_packet) return error.Corrupt;
        bh = (try readBlock(ctx)) orelse return error.Corrupt;
    }
    if (ch_offset == 0 or ctx.sample_rate == 0) return error.Corrupt;
    if (ctx.channels == 0) {
        ctx.channels = @intCast(ch_offset);
    } else if (ctx.channels != ch_offset) {
        return error.Corrupt;
    }

    const pkt_bytes = packet_samples * ch_offset * bpp;
    if (ctx.pkt.len < pkt_bytes) ctx.pkt = try ctx.allocator.realloc(ctx.pkt, pkt_bytes);
    interleavePkt(ctx, packet_samples, ch_offset, pkt_fmt);
    ctx.pkt_samples = packet_samples;
    ctx.pkt_block_index = first.block_index;
    ctx.cursor = 0;
    return true;
}

/// 平面 → 交错原生 PCM（小端；float 为 IEEE 位模式）
fn interleavePkt(ctx: *WvCtx, samples: usize, channels: usize, fmt: OutFmt) void {
    const bpp: usize = if (fmt == .s16) 2 else 4;
    const stride = samples;
    const frame = channels * bpp;
    for (0..samples) |i| {
        for (0..channels) |c| {
            const v: i32 = ctx.planes[c * stride + i];
            const off = i * frame + c * bpp;
            switch (fmt) {
                .s16 => std.mem.writeInt(i16, ctx.pkt[off..][0..2], @truncate(v), .little),
                .s32 => std.mem.writeInt(i32, ctx.pkt[off..][0..4], v, .little),
                .float => std.mem.writeInt(u32, ctx.pkt[off..][0..4], @bitCast(v), .little),
            }
        }
    }
}

/// 块头扫描定位目标样本所在包（含缓冲包内命中优化）
fn seekToSample(f: *WvCtx, target: u64) Error!void {
    if (f.pkt_samples > 0 and target >= f.pkt_block_index and target < f.pkt_block_index + f.pkt_samples) {
        f.cursor = @intCast(target - f.pkt_block_index);
        f.samples_done = target;
        return;
    }
    try f.reader.seek(0, .start);
    var pos: u64 = 0;
    while (true) {
        var head: [header_size]u8 = undefined;
        const n = try f.reader.peek(&head);
        if (n < header_size or !std.mem.eql(u8, head[0..4], "wvpk")) {
            // 扫描至文件尾：目标超出 → 置 EOF
            f.pkt_samples = 0;
            f.cursor = 0;
            f.samples_done = f.total_samples;
            return;
        }
        const ck: u32 = std.mem.readInt(u32, head[4..8], .little);
        const total: u64 = @as(u64, ck) + 8;
        if (total < header_size or total > block_cap) return error.Corrupt;
        const block_index: u64 = std.mem.readInt(u32, head[16..20], .little);
        const block_samples: u64 = std.mem.readInt(u32, head[20..24], .little);
        const fl: u32 = std.mem.readInt(u32, head[24..28], .little);
        if ((fl & F_INITIAL_BLOCK) != 0 and target >= block_index and target < block_index + block_samples) {
            try f.reader.seek(@intCast(pos), .start);
            if (!try decodePacket(f)) return error.Corrupt;
            f.cursor = @intCast(target - f.pkt_block_index);
            f.samples_done = target;
            return;
        }
        pos += total;
        try f.reader.seek(@intCast(pos), .start);
    }
}

// ---------------------------------------------------------------------------
// VTable + 入口
// ---------------------------------------------------------------------------

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *WvCtx = @ptrCast(@alignCast(ctx));
    out_channels.* = f.channels;
    if (f.channels == 0 or max_samples == 0 or out.len == 0) return 0;
    const frame_bytes = @as(usize, f.channels) * (f.out_bps / 8);
    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        if (f.cursor < f.pkt_samples) {
            const avail = f.pkt_samples - f.cursor;
            const take = @min(avail, cap - produced);
            const bytes = take * frame_bytes;
            @memcpy(out[produced * frame_bytes ..][0..bytes], f.pkt[f.cursor * frame_bytes ..][0..bytes]);
            f.cursor += take;
            f.samples_done += take;
            produced += take;
        } else if (!try decodePacket(f)) {
            break; // EOF
        }
    }
    return produced;
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    const f: *WvCtx = @ptrCast(@alignCast(ctx));
    var target: u64 = if (ms <= 0)
        0
    else
        @intCast((@as(u128, @intCast(ms)) * f.sample_rate) / 1000);
    if (f.total_samples > 0 and target > f.total_samples) target = f.total_samples;
    try seekToSample(f, target);
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *WvCtx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate == 0) return 0;
    return @intCast((f.samples_done * 1000) / f.sample_rate);
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *WvCtx = @ptrCast(@alignCast(ctx));
    if (f.block_buf.len > 0) f.allocator.free(f.block_buf);
    if (f.planes.len > 0) f.allocator.free(f.planes);
    if (f.pkt.len > 0) f.allocator.free(f.pkt);
    f.reader.deinit();
    f.allocator.destroy(f);
}

fn buildInfo(ctx: *WvCtx) decoder.Info {
    var duration_us: i64 = 0;
    var known: decoder.DurationKnown = .unknown;
    if (ctx.total_samples > 0 and ctx.sample_rate > 0) {
        duration_us = @intCast((@as(u128, ctx.total_samples) * 1_000_000) / ctx.sample_rate);
        known = .exact;
    }
    return .{
        .sample_rate = ctx.sample_rate,
        .channels = ctx.channels,
        .bits_per_sample = ctx.out_bps,
        .is_float = ctx.is_float,
        .duration_us = duration_us,
        .duration_known = known,
        .codec_name = "wavpack",
        .format_name = "wv",
        .metadata = .{},
    };
}

/// 打开 WavPack：校验首块头（魔数/版本/DSD）→ 解码首包确定声道/采样率/位深。
/// 成功时 Decoder 接管 `reader` 所有权（deinit 关闭）。DSD / 版本不符 → UnsupportedFormat。
pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    var head: [header_size]u8 = undefined;
    const n = try reader.peek(&head);
    if (n < header_size) return error.Corrupt;
    if (!std.mem.eql(u8, head[0..4], "wvpk")) return error.UnsupportedFormat;
    const version: u16 = std.mem.readInt(u16, head[8..10], .little);
    if (version < 0x402 or version > 0x410) return error.UnsupportedFormat;
    const flags: u32 = std.mem.readInt(u32, head[24..28], .little);
    if ((flags & F_DSD_DATA) != 0) return error.UnsupportedFormat;
    const total_samples: u32 = std.mem.readInt(u32, head[12..16], .little);

    const ctx = try allocator.create(WvCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .reader = reader.*,
        .sample_rate = 0,
        .channels = 0,
        .total_samples = if (total_samples == 0xFFFFFFFF) 0 else total_samples,
        .out_bps = 16,
        .is_float = false,
        .block_buf = &.{},
        .planes = &.{},
        .pkt = &.{},
        .pkt_samples = 0,
        .pkt_block_index = 0,
        .cursor = 0,
        .samples_done = 0,
    };
    errdefer deinitCtxBuffers(ctx);
    if (!try decodePacket(ctx)) return error.Corrupt;
    if (ctx.channels == 0 or ctx.sample_rate == 0) return error.Corrupt;
    info.* = buildInfo(ctx);
    return .{ .vtable = &vtable, .ctx = @ptrCast(ctx) };
}

/// 释放 ctx 缓冲（open 错误路径与 deinit 共用）
fn deinitCtxBuffers(ctx: *WvCtx) void {
    if (ctx.block_buf.len > 0) ctx.allocator.free(ctx.block_buf);
    if (ctx.planes.len > 0) ctx.allocator.free(ctx.planes);
    if (ctx.pkt.len > 0) ctx.allocator.free(ctx.pkt);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "wpExp2 定点指数" {
    // 参考实现语义：res = table|0x100，再 >>(9-int)（int = val>>8）
    try std.testing.expectEqual(@as(i32, 0), wpExp2(0));
    try std.testing.expectEqual(@as(i32, 1), wpExp2(256));
    try std.testing.expectEqual(@as(i32, 2), wpExp2(512));
    try std.testing.expectEqual(@as(i32, -1), wpExp2(-256));
    try std.testing.expectEqual(@as(i32, -2), wpExp2(-512));
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), wpExp2(32000));
}

test "wpLog2 定点对数" {
    try std.testing.expectEqual(@as(i32, 0), wpLog2(0));
    try std.testing.expectEqual(@as(i32, 256), wpLog2(1));
    try std.testing.expectEqual(@as(i32, 768), wpLog2(4)); // log2(4)=2 → 512 + 小数
    try std.testing.expectEqual(@as(i32, 2816), wpLog2(1024)); // log2(1024)=10 → 2560 + 小数
}

test "median 自适应收敛" {
    var c = WvChannel{};
    c.median[0] = 0x100;
    const m0 = getMed(&c, 0);
    decMed(&c, 0);
    try std.testing.expect(getMed(&c, 0) < m0);
    incMed(&c, 0);
    incMed(&c, 0);
    try std.testing.expect(getMed(&c, 0) > m0);
}

test "getTail zigzag 区间" {
    // k=4：p=2, e=3。数据 0x05（LSB 位序 1,0,1）：读 2 位 = 0b01 = 1 < 3 → res = 1
    const data = [_]u8{0x05};
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 1), try getTail(&br, 4));
    // k=1：p=0, e=0：读 0 位，res=0 >= 0 → 再读 1 位（当前 bit2=1）→ 1
    try std.testing.expectEqual(@as(u32, 1), try getTail(&br, 1));
}
