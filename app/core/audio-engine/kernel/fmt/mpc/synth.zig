//! Musepack 合成核心 —— FFmpeg n9.0.1 定点路径逐句复刻（mpc.c + mpegaudiodsp 固定点）。
//!
//! 覆盖：
//!   - dct32 定点（dct32_template.c，DCT32_FLOAT=0）
//!   - apply_window 定点（mpegaudiodsp_template.c，USE_FLOATS=0）+ round_sample
//!   - ff_mpa_synth_filter_fixed 调度（offset 回绕 512）
//!   - ff_mpc_dequantize_and_synth（mpc.c：CC×SCF 浮点乘→int32 截断、M/S 折回）
//!   - 合成窗 ff_mpa_synth_window_fixed 生成（mpa_synth_init）
//!   - AVLFG（av_lfg_init(0xDEADBEEF)+av_lfg_get，libavutil/lfg.{h,c}）
//!
//! 位型/运算顺序与 C 完全一致：32-bit 用 i32 回绕乘法与算术右移；乘加以 i64 保持；
//! dct 中间量按 unsigned 32-bit 模算术（FFmpeg SUINT），复刻其回绕行为。
//! 验证目标：与 `ffmpeg -i x.mpc -f s16le` 逐样本位一致。

const std = @import("std");
const tables = @import("tables.zig");

pub const SBLIMIT = 32;
pub const SAMPLES_PER_BAND = 36;
pub const MPC_FRAME_SIZE = SBLIMIT * SAMPLES_PER_BAND;
pub const MPA_MAX_CHANNELS = 2;
/// FFmpeg 的 FRAC_BITS=23 / WFRAC_BITS=16，合成输出移位 = 16+23-15
const OUT_SHIFT: u6 = 24;

// ---------------------------------------------------------------------------
// AVLFG（libavutil/lfg.h av_lfg_get + lfg.c av_lfg_init）
// ---------------------------------------------------------------------------

pub const Lfg = struct {
    state: [64]u32 = [_]u32{0} ** 64,
    index: u32 = 0,

    pub fn init(self: *Lfg, seed: u32) void {
        var tmp: [16]u8 = [_]u8{0} ** 16;
        var i: usize = 8;
        while (i < 64) : (i += 4) {
            std.mem.writeInt(u32, tmp[0..4], seed, .little);
            tmp[4] = @intCast(i);
            var md5: [16]u8 = undefined;
            std.crypto.hash.Md5.hash(&tmp, &md5, .{});
            self.state[i] = std.mem.readInt(u32, md5[0..4], .little);
            self.state[i + 1] = std.mem.readInt(u32, md5[4..8], .little);
            self.state[i + 2] = std.mem.readInt(u32, md5[8..12], .little);
            self.state[i + 3] = std.mem.readInt(u32, md5[12..16], .little);
        }
        self.index = 0;
    }

    pub fn next(self: *Lfg) u32 {
        const idx = self.index & 63;
        const a = self.state[(self.index -% 24) & 63] +% self.state[(self.index -% 55) & 63];
        self.state[idx] = a;
        self.index +%= 1;
        return a;
    }
};

// ---------------------------------------------------------------------------
// 32-band 合成窗生成（mpa_synth_init，fixed）
// ---------------------------------------------------------------------------

/// [512+256]；本实现（C 标量路径）只用前 512。含延伸段以对齐 FFmpeg 布局。
pub var synth_window: [512 + 256]i32 = undefined;
var window_ready = false;

fn mpa_synth_init() void {
    var i: usize = 0;
    while (i < 257) : (i += 1) {
        var v: i32 = tables.enwindow[i];
        synth_window[i] = v;
        if ((i & 63) != 0) v = -v;
        if (i != 0) synth_window[512 - i] = v;
    }
    i = 0;
    while (i < 8) : (i += 1) {
        var j: usize = 0;
        while (j < 16) : (j += 1) synth_window[512 + 16 * i + j] = synth_window[64 * i + 32 - j];
    }
    i = 0;
    while (i < 8) : (i += 1) {
        var j: usize = 0;
        while (j < 16) : (j += 1) synth_window[512 + 128 + 16 * i + j] = synth_window[64 * i + 48 - j];
    }
    window_ready = true;
}

/// 线程安全初始化（模拟 ff_mpa_synth_init_fixed 的 once）
pub fn synthWindow() *const [512 + 256]i32 {
    if (!window_ready) mpa_synth_init();
    return &synth_window;
}

// ---------------------------------------------------------------------------
// 定点 dct32（dct32_template.c；DCT32_FLOAT=0）
// ---------------------------------------------------------------------------

// FIXHR(x) = (int)(x * (1<<32) + 0.5)（double → int 截断）
inline fn fixhr(x: f64) i32 {
    return @intFromFloat(x * 4294967296.0 + 0.5);
}

// MULH(a, b)：a 为 u32（模算术结果，按 int32 位型解释后符号扩展），
// b 为 i32 常量；结果 (int64) * (int64) >> 32（算术右移）。
inline fn mulh(a: u32, b: i32) i32 {
    const sa: i64 = @as(i32, @bitCast(a));
    return @intCast((sa * @as(i64, b)) >> 32);
}

/// dct32_fixed 输出 out[32]，输入 tab 视为 u32 模算术（SUINT），
/// val 均按 u32 维护、位宽回绕；写回 out 时以 i32 位模式解释。
pub fn dct32Fixed(out: *[SBLIMIT]i32, tab_in: *const [SBLIMIT]i32) void {
    var val = [_]u32{0} ** 32;
    for (0..SBLIMIT) |i| val[i] = @bitCast(tab_in[i]);

    // BF0(a,b,c,s): tmp0=tab[a]+tab[b]; tmp1=tab[a]-tab[b]; val[a]=tmp0; val[b]=MULH((1<<s)*tmp1, c)
    // BF(a,b,c,s): 同但基于 val
    const BF0 = struct {
        fn apply(v: *[32]u32, a: usize, b: usize, c: i32, s: u6) void {
            const t0 = v[a] +% v[b];
            const t1 = v[a] -% v[b];
            v[a] = t0;
            const m = (@as(u32, 1) << @intCast(s)) *% t1;
            v[b] = @bitCast(mulh(m, c));
        }
    };
    const BF = struct {
        fn apply(v: *[32]u32, a: usize, b: usize, c: i32, s: u6) void {
            const t0 = v[a] +% v[b];
            const t1 = v[a] -% v[b];
            v[a] = t0;
            const m = (@as(u32, 1) << @intCast(s)) *% t1;
            v[b] = @bitCast(mulh(m, c));
        }
    };

    // 常量（FIXHR）
    const COS0_0: i32 = fixhr(@as(f64, 0.50060299823519630134) / 2.0);
    const COS0_1: i32 = fixhr(@as(f64, 0.50547095989754365998) / 2.0);
    const COS0_2: i32 = fixhr(@as(f64, 0.51544730992262454697) / 2.0);
    const COS0_3: i32 = fixhr(@as(f64, 0.53104259108978417447) / 2.0);
    const COS0_4: i32 = fixhr(@as(f64, 0.55310389603444452782) / 2.0);
    const COS0_5: i32 = fixhr(@as(f64, 0.58293496820613387367) / 2.0);
    const COS0_6: i32 = fixhr(@as(f64, 0.62250412303566481615) / 2.0);
    const COS0_7: i32 = fixhr(@as(f64, 0.67480834145500574602) / 2.0);
    const COS0_8: i32 = fixhr(@as(f64, 0.74453627100229844977) / 2.0);
    const COS0_9: i32 = fixhr(@as(f64, 0.83934964541552703873) / 2.0);
    const COS0_10: i32 = fixhr(@as(f64, 0.97256823786196069369) / 2.0);
    const COS0_11: i32 = fixhr(@as(f64, 1.16943993343288495515) / 4.0);
    const COS0_12: i32 = fixhr(@as(f64, 1.48416461631416627724) / 4.0);
    const COS0_13: i32 = fixhr(@as(f64, 2.05778100995341155085) / 8.0);
    const COS0_14: i32 = fixhr(@as(f64, 3.40760841846871878570) / 8.0);
    const COS0_15: i32 = fixhr(@as(f64, 10.19000812354805681150) / 32.0);

    const COS1_0: i32 = fixhr(@as(f64, 0.50241928618815570551) / 2.0);
    const COS1_1: i32 = fixhr(@as(f64, 0.52249861493968888062) / 2.0);
    const COS1_2: i32 = fixhr(@as(f64, 0.56694403481635770368) / 2.0);
    const COS1_3: i32 = fixhr(@as(f64, 0.64682178335999012954) / 2.0);
    const COS1_4: i32 = fixhr(@as(f64, 0.78815462345125022473) / 2.0);
    const COS1_5: i32 = fixhr(@as(f64, 1.06067768599034747134) / 4.0);
    const COS1_6: i32 = fixhr(@as(f64, 1.72244709823833392782) / 4.0);
    const COS1_7: i32 = fixhr(@as(f64, 5.10114861868916385802) / 16.0);

    const COS2_0: i32 = fixhr(@as(f64, 0.50979557910415916894) / 2.0);
    const COS2_1: i32 = fixhr(@as(f64, 0.60134488693504528054) / 2.0);
    const COS2_2: i32 = fixhr(@as(f64, 0.89997622313641570463) / 2.0);
    const COS2_3: i32 = fixhr(@as(f64, 2.56291544774150617881) / 8.0);

    const COS3_0: i32 = fixhr(@as(f64, 0.54119610014619698439) / 2.0);
    const COS3_1: i32 = fixhr(@as(f64, 1.30656296487637652785) / 4.0);

    const COS4_0: i32 = fixhr(@as(f64, 0.70710678118654752440) / 2.0);

    // pass 1/2 sequences（顺序必须与 C 完全一致）
    BF0.apply(&val, 0, 31, COS0_0, 1);
    BF0.apply(&val, 15, 16, COS0_15, 5);
    BF.apply(&val, 0, 15, COS1_0, 1);
    BF.apply(&val, 16, 31, -COS1_0, 1);

    BF0.apply(&val, 7, 24, COS0_7, 1);
    BF0.apply(&val, 8, 23, COS0_8, 1);
    BF.apply(&val, 7, 8, COS1_7, 4);
    BF.apply(&val, 23, 24, -COS1_7, 4);
    BF.apply(&val, 0, 7, COS2_0, 1);
    BF.apply(&val, 8, 15, -COS2_0, 1);
    BF.apply(&val, 16, 23, COS2_0, 1);
    BF.apply(&val, 24, 31, -COS2_0, 1);

    BF0.apply(&val, 3, 28, COS0_3, 1);
    BF0.apply(&val, 12, 19, COS0_12, 2);
    BF.apply(&val, 3, 12, COS1_3, 1);
    BF.apply(&val, 19, 28, -COS1_3, 1);
    BF0.apply(&val, 4, 27, COS0_4, 1);
    BF0.apply(&val, 11, 20, COS0_11, 2);
    BF.apply(&val, 4, 11, COS1_4, 1);
    BF.apply(&val, 20, 27, -COS1_4, 1);
    BF.apply(&val, 3, 4, COS2_3, 3);
    BF.apply(&val, 11, 12, -COS2_3, 3);
    BF.apply(&val, 19, 20, COS2_3, 3);
    BF.apply(&val, 27, 28, -COS2_3, 3);
    BF.apply(&val, 0, 3, COS3_0, 1);
    BF.apply(&val, 4, 7, -COS3_0, 1);
    BF.apply(&val, 8, 11, COS3_0, 1);
    BF.apply(&val, 12, 15, -COS3_0, 1);
    BF.apply(&val, 16, 19, COS3_0, 1);
    BF.apply(&val, 20, 23, -COS3_0, 1);
    BF.apply(&val, 24, 27, COS3_0, 1);
    BF.apply(&val, 28, 31, -COS3_0, 1);

    BF0.apply(&val, 1, 30, COS0_1, 1);
    BF0.apply(&val, 14, 17, COS0_14, 3);
    BF.apply(&val, 1, 14, COS1_1, 1);
    BF.apply(&val, 17, 30, -COS1_1, 1);
    BF0.apply(&val, 6, 25, COS0_6, 1);
    BF0.apply(&val, 9, 22, COS0_9, 1);
    BF.apply(&val, 6, 9, COS1_6, 2);
    BF.apply(&val, 22, 25, -COS1_6, 2);
    BF.apply(&val, 1, 6, COS2_1, 1);
    BF.apply(&val, 9, 14, -COS2_1, 1);
    BF.apply(&val, 17, 22, COS2_1, 1);
    BF.apply(&val, 25, 30, -COS2_1, 1);

    BF0.apply(&val, 2, 29, COS0_2, 1);
    BF0.apply(&val, 13, 18, COS0_13, 3);
    BF.apply(&val, 2, 13, COS1_2, 1);
    BF.apply(&val, 18, 29, -COS1_2, 1);
    BF0.apply(&val, 5, 26, COS0_5, 1);
    BF0.apply(&val, 10, 21, COS0_10, 1);
    BF.apply(&val, 5, 10, COS1_5, 2);
    BF.apply(&val, 21, 26, -COS1_5, 2);
    BF.apply(&val, 2, 5, COS2_2, 1);
    BF.apply(&val, 10, 13, -COS2_2, 1);
    BF.apply(&val, 18, 21, COS2_2, 1);
    BF.apply(&val, 26, 29, -COS2_2, 1);
    BF.apply(&val, 1, 2, COS3_1, 2);
    BF.apply(&val, 5, 6, -COS3_1, 2);
    BF.apply(&val, 9, 10, COS3_1, 2);
    BF.apply(&val, 13, 14, -COS3_1, 2);
    BF.apply(&val, 17, 18, COS3_1, 2);
    BF.apply(&val, 21, 22, -COS3_1, 2);
    BF.apply(&val, 25, 26, COS3_1, 2);
    BF.apply(&val, 29, 30, -COS3_1, 2);

    // pass 5：BF1/BF2 宏
    // BF1(a,b,c,d): BF(a,b,COS4_0,1); BF(c,d,-COS4_0,1); val[c]+=val[d]
    // BF2(a,b,c,d): ... val[a]+=val[c]; val[c]+=val[b]; val[b]+=val[d]
    {
        bf1(&val, 0, 1, 2, 3, COS4_0);
        bf2(&val, 4, 5, 6, 7, COS4_0);
        bf1(&val, 8, 9, 10, 11, COS4_0);
        bf2(&val, 12, 13, 14, 15, COS4_0);
        bf1(&val, 16, 17, 18, 19, COS4_0);
        bf2(&val, 20, 21, 22, 23, COS4_0);
        bf1(&val, 24, 25, 26, 27, COS4_0);
        bf2(&val, 28, 29, 30, 31, COS4_0);
    }

    // pass 6
    add(&val, 8, 12);
    add(&val, 12, 10);
    add(&val, 10, 14);
    add(&val, 14, 9);
    add(&val, 9, 13);
    add(&val, 13, 11);
    add(&val, 11, 15);

    out[0] = @bitCast(val[0]);
    out[16] = @bitCast(val[1]);
    out[8] = @bitCast(val[2]);
    out[24] = @bitCast(val[3]);
    out[4] = @bitCast(val[4]);
    out[20] = @bitCast(val[5]);
    out[12] = @bitCast(val[6]);
    out[28] = @bitCast(val[7]);
    out[2] = @bitCast(val[8]);
    out[18] = @bitCast(val[9]);
    out[10] = @bitCast(val[10]);
    out[26] = @bitCast(val[11]);
    out[6] = @bitCast(val[12]);
    out[22] = @bitCast(val[13]);
    out[14] = @bitCast(val[14]);
    out[30] = @bitCast(val[15]);

    add(&val, 24, 28);
    add(&val, 28, 26);
    add(&val, 26, 30);
    add(&val, 30, 25);
    add(&val, 25, 29);
    add(&val, 29, 27);
    add(&val, 27, 31);

    out[1] = @bitCast(val[16] +% val[24]);
    out[17] = @bitCast(val[17] +% val[25]);
    out[9] = @bitCast(val[18] +% val[26]);
    out[25] = @bitCast(val[19] +% val[27]);
    out[5] = @bitCast(val[20] +% val[28]);
    out[21] = @bitCast(val[21] +% val[29]);
    out[13] = @bitCast(val[22] +% val[30]);
    out[29] = @bitCast(val[23] +% val[31]);
    out[3] = @bitCast(val[24] +% val[20]);
    out[19] = @bitCast(val[25] +% val[21]);
    out[11] = @bitCast(val[26] +% val[22]);
    out[27] = @bitCast(val[27] +% val[23]);
    out[7] = @bitCast(val[28] +% val[18]);
    out[23] = @bitCast(val[29] +% val[19]);
    out[15] = @bitCast(val[30] +% val[17]);
    out[31] = @bitCast(val[31]);
}

fn bf1(val: *[32]u32, a: usize, b: usize, c: usize, d: usize, cos4: i32) void {
    bfBody(val, a, b, cos4, 1);
    bfBody(val, c, d, -cos4, 1);
    val[c] +%= val[d];
}

fn bf2(val: *[32]u32, a: usize, b: usize, c: usize, d: usize, cos4: i32) void {
    bfBody(val, a, b, cos4, 1);
    bfBody(val, c, d, -cos4, 1);
    val[c] +%= val[d];
    val[a] +%= val[c];
    val[c] +%= val[b];
    val[b] +%= val[d];
}

fn bfBody(val: *[32]u32, a: usize, b: usize, c: i32, s: u6) void {
    const t0 = val[a] +% val[b];
    const t1 = val[a] -% val[b];
    val[a] = t0;
    const m = (@as(u32, 1) << @intCast(s)) *% t1;
    val[b] = @bitCast(mulh(m, c));
}

fn add(val: *[32]u32, a: usize, b: usize) void {
    val[a] +%= val[b];
}

// ---------------------------------------------------------------------------
// apply_window 定点（mpegaudiodsp_template.c）+ round_sample
// ---------------------------------------------------------------------------

inline fn roundSample(sum: *i64) i16 {
    const shifted = (sum.* >> OUT_SHIFT);
    const sum1: i32 = @truncate(shifted);
    sum.* &= (@as(i64, 1) << OUT_SHIFT) - 1;
    return clipInt16(sum1);
}

inline fn clipInt16(a: i32) i16 {
    return @intCast(std.math.clamp(a, -32768, 32767));
}

/// synth_buf 为各通道 1024 长缓冲的“视图起点”；调用前由 synthFilter 切好。
fn applyWindowFixed(synth_buf_ptr: []i32, window: *const [512 + 256]i32, dither_state: *i32, samples: *[32]i16) void {
    const sb = synth_buf_ptr;
    // memcpy(synth_buf + 512, synth_buf, 32*4)
    @memcpy(sb[512..][0..32], sb[0..32]);

    var sum: i64 = dither_state.*;
    const w = window;

    // p = synth_buf + 16；SUM8(MACS)： sum += w[k64]*p[k64]
    {
        const p = sb[16..];
        sum += @as(i64, w[0 * 64]) * p[0 * 64];
        sum += @as(i64, w[1 * 64]) * p[1 * 64];
        sum += @as(i64, w[2 * 64]) * p[2 * 64];
        sum += @as(i64, w[3 * 64]) * p[3 * 64];
        sum += @as(i64, w[4 * 64]) * p[4 * 64];
        sum += @as(i64, w[5 * 64]) * p[5 * 64];
        sum += @as(i64, w[6 * 64]) * p[6 * 64];
        sum += @as(i64, w[7 * 64]) * p[7 * 64];
    }
    // p = synth_buf + 48；SUM8(MLSS)
    {
        const p = sb[48..];
        sum -= @as(i64, w[32]) * p[0];
        sum -= @as(i64, w[32 + 64]) * p[64];
        sum -= @as(i64, w[32 + 128]) * p[128];
        sum -= @as(i64, w[32 + 192]) * p[192];
        sum -= @as(i64, w[32 + 256]) * p[256];
        sum -= @as(i64, w[32 + 320]) * p[320];
        sum -= @as(i64, w[32 + 384]) * p[384];
        sum -= @as(i64, w[32 + 448]) * p[448];
    }
    samples[0] = roundSample(&sum);

    var j: usize = 1;
    while (j < 16) : (j += 1) {
        var sum2: i64 = 0;
        const w1 = w[j..];
        const w2 = w[32 - j ..];
        // SUM8P2(sum, MACS, sum2, MLSS, w+j, w2, p=synth_buf+16+j)
        {
            const p = sb[16 + j ..];
            sum += @as(i64, w1[0 * 64]) * p[0 * 64];
            sum2 -= @as(i64, w2[0 * 64]) * p[0 * 64];
            sum += @as(i64, w1[1 * 64]) * p[1 * 64];
            sum2 -= @as(i64, w2[1 * 64]) * p[1 * 64];
            sum += @as(i64, w1[2 * 64]) * p[2 * 64];
            sum2 -= @as(i64, w2[2 * 64]) * p[2 * 64];
            sum += @as(i64, w1[3 * 64]) * p[3 * 64];
            sum2 -= @as(i64, w2[3 * 64]) * p[3 * 64];
            sum += @as(i64, w1[4 * 64]) * p[4 * 64];
            sum2 -= @as(i64, w2[4 * 64]) * p[4 * 64];
            sum += @as(i64, w1[5 * 64]) * p[5 * 64];
            sum2 -= @as(i64, w2[5 * 64]) * p[5 * 64];
            sum += @as(i64, w1[6 * 64]) * p[6 * 64];
            sum2 -= @as(i64, w2[6 * 64]) * p[6 * 64];
            sum += @as(i64, w1[7 * 64]) * p[7 * 64];
            sum2 -= @as(i64, w2[7 * 64]) * p[7 * 64];
        }
        // SUM8P2(sum, MLSS, sum2, MLSS, w+32+j, w2+32, p=synth_buf+48-j)
        {
            const p = sb[48 - j ..];
            const wa = w[32 + j ..];
            const wb = w[32 + 32 - j ..];
            sum -= @as(i64, wa[0 * 64]) * p[0 * 64];
            sum2 -= @as(i64, wb[0 * 64]) * p[0 * 64];
            sum -= @as(i64, wa[1 * 64]) * p[1 * 64];
            sum2 -= @as(i64, wb[1 * 64]) * p[1 * 64];
            sum -= @as(i64, wa[2 * 64]) * p[2 * 64];
            sum2 -= @as(i64, wb[2 * 64]) * p[2 * 64];
            sum -= @as(i64, wa[3 * 64]) * p[3 * 64];
            sum2 -= @as(i64, wb[3 * 64]) * p[3 * 64];
            sum -= @as(i64, wa[4 * 64]) * p[4 * 64];
            sum2 -= @as(i64, wb[4 * 64]) * p[4 * 64];
            sum -= @as(i64, wa[5 * 64]) * p[5 * 64];
            sum2 -= @as(i64, wb[5 * 64]) * p[5 * 64];
            sum -= @as(i64, wa[6 * 64]) * p[6 * 64];
            sum2 -= @as(i64, wb[6 * 64]) * p[6 * 64];
            sum -= @as(i64, wa[7 * 64]) * p[7 * 64];
            sum2 -= @as(i64, wb[7 * 64]) * p[7 * 64];
        }

        samples[j] = roundSample(&sum);
        sum += sum2;
        samples[32 - j] = roundSample(&sum);
    }

    // p = synth_buf + 32; SUM8(MLSS, sum, w+32, p)
    // C 中 w 在 j 循环里已递增 16 次（w == window+16），故此处实为 window+48。
    {
        const p = sb[32..];
        sum -= @as(i64, w[48]) * p[0];
        sum -= @as(i64, w[48 + 64]) * p[64];
        sum -= @as(i64, w[48 + 128]) * p[128];
        sum -= @as(i64, w[48 + 192]) * p[192];
        sum -= @as(i64, w[48 + 256]) * p[256];
        sum -= @as(i64, w[48 + 320]) * p[320];
        sum -= @as(i64, w[48 + 384]) * p[384];
        sum -= @as(i64, w[48 + 448]) * p[448];
    }
    samples[16] = roundSample(&sum);
    dither_state.* = @intCast(sum); // round_sample 已将 sum 掩为低 24 位（进位状态）
}

// ---------------------------------------------------------------------------
// 32 sub band 合成过滤入口（ff_mpa_synth_filter_fixed 的标量路径）
// ---------------------------------------------------------------------------

/// synth_buf 指向该通道 1024 缓冲（含 offset 前移），sb_samples 为 32 子带输入，
/// 输出 32 个 s16 到 samples。
pub fn mpaSynthFilterFixed(
    synth_buf_all: *[MPA_MAX_CHANNELS][1024]i32,
    synth_buf_offset: *[MPA_MAX_CHANNELS]usize,
    ch: usize,
    window: *const [512 + 256]i32,
    dither_state: *i32,
    samples: *[32]i16,
    sb_samples: *const [SBLIMIT]i32,
) void {
    const offset: usize = synth_buf_offset[ch];
    const sbuf = synth_buf_all[ch][offset..];
    var dct_out: [SBLIMIT]i32 = undefined;
    dct32Fixed(&dct_out, sb_samples);
    @memcpy(sbuf[0..SBLIMIT], &dct_out);
    applyWindowFixed(synth_buf_all[ch][offset..], window, dither_state, samples);
    synth_buf_offset[ch] = (offset -% 32) & 511;
}

// ---------------------------------------------------------------------------
// 子带参数与去量化（mpc.c / mpc.h）
// ---------------------------------------------------------------------------

pub const Band = struct {
    msf: bool = false,
    res: [2]i32 = .{ 0, 0 },
    scfi: [2]i32 = .{ 0, 0 },
    scf_idx: [2][3]i32 = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 } },
};

pub const MpcCore = struct {
    /// oldDSCF[ch][band]（帧间持久）
    oldDSCF: [2][32]i32 = [_][32]i32{[_]i32{0} ** 32} ** 2,
    bands: [32]Band = [_]Band{.{}} ** 32,
    /// Q[ch][0..1152]
    Q: [2][MPC_FRAME_SIZE]i32 = [_][MPC_FRAME_SIZE]i32{[_]i32{0} ** MPC_FRAME_SIZE} ** 2,
    /// 去量化后的 子带样本 [ch][36][32]
    sb_samples: [2][36][32]i32 = undefined,
    /// 合成滤波器状态
    synth_buf: [2][1024]i32 = [_][1024]i32{[_]i32{0} ** 1024} ** 2,
    synth_buf_offset: [2]usize = .{ 0, 0 },
    rnd: Lfg = .{},

    pub fn init(self: *MpcCore) void {
        self.oldDSCF = [_][32]i32{[_]i32{0} ** 32} ** 2;
        self.synth_buf = [_][1024]i32{[_]i32{0} ** 1024} ** 2;
        self.synth_buf_offset = .{ 0, 0 };
        self.rnd.init(0xDEADBEEF);
    }
};

/// FFmpeg 的 av_clipf(a, INT32_MIN, INT32_MAX) —— float 域裁剪后转 int32。
/// 注意 C 语义：INT32_MAX 以 float 形参传入时舍入为 2147483648.0f（2^31，
/// f32 不可精确表示 2147483647），故上界实为 2^31；x86 cvttss2si 对越界值
/// 产生"整数不定值" 0x80000000 = INT32_MIN（含恰好 2^31 与 NaN 情形），
/// 此处复刻该位型（Zig @intFromFloat 对 2^31 直接 panic，需显式分流）。
inline fn clipfToI32(a: f32) i32 {
    const lo: f32 = @floatFromInt(std.math.minInt(i32)); // 精确
    const hi: f32 = @floatFromInt(std.math.maxInt(i32)); // → 2^31
    const v = @min(@max(a, lo), hi);
    return if (v == hi) std.math.minInt(i32) else @intFromFloat(v);
}

/// ff_mpc_dequantize_and_synth(c, maxband, out, channels)（mpc.c）
/// maxband 为“最高有效子带号”（调用处传 frame 的 maxband-1）。out 为各通道 1152 输出。
pub fn dequantizeAndSynth(
    c: *MpcCore,
    maxband: i32,
    out: *[MPA_MAX_CHANNELS][MPC_FRAME_SIZE]i16,
    channels: usize,
) void {
    const window = synthWindow();
    // 清 sb_samples
    {
        var ch: usize = 0;
        while (ch < 2) : (ch += 1) {
            var i: usize = 0;
            while (i < 36) : (i += 1) {
                for (0..32) |b| c.sb_samples[ch][i][b] = 0;
            }
        }
    }

    var off: i32 = 0;
    var i: i32 = 0;
    while (i <= maxband) : (i += 1) {
        const bi: usize = @intCast(i);
        for (0..2) |ch| {
            const res = c.bands[bi].res[ch];
            if (res != 0) {
                var j: usize = 0;
                var mul: f32 = tables.mpc_CC[@intCast(res + 1)] * tables.mpc_SCF[@as(u8, @truncate(@as(u32, @bitCast(c.bands[bi].scf_idx[ch][0]))))];
                while (j < 12) : (j += 1) {
                    c.sb_samples[ch][j][bi] = clipfToI32(mul * @as(f32, @floatFromInt(c.Q[ch][j + @as(usize, @intCast(off))])));
                }
                mul = tables.mpc_CC[@intCast(res + 1)] * tables.mpc_SCF[@as(u8, @truncate(@as(u32, @bitCast(c.bands[bi].scf_idx[ch][1]))))];
                while (j < 24) : (j += 1) {
                    c.sb_samples[ch][j][bi] = clipfToI32(mul * @as(f32, @floatFromInt(c.Q[ch][j + @as(usize, @intCast(off))])));
                }
                mul = tables.mpc_CC[@intCast(res + 1)] * tables.mpc_SCF[@as(u8, @truncate(@as(u32, @bitCast(c.bands[bi].scf_idx[ch][2]))))];
                while (j < 36) : (j += 1) {
                    c.sb_samples[ch][j][bi] = clipfToI32(mul * @as(f32, @floatFromInt(c.Q[ch][j + @as(usize, @intCast(off))])));
                }
            }
        }
        if (c.bands[bi].msf) {
            var j: usize = 0;
            while (j < 36) : (j += 1) {
                const t1: u32 = @bitCast(c.sb_samples[0][j][bi]);
                const t2: u32 = @bitCast(c.sb_samples[1][j][bi]);
                c.sb_samples[0][j][bi] = @bitCast(t1 +% t2);
                c.sb_samples[1][j][bi] = @bitCast(t1 -% t2);
            }
        }
        off += 36;
    }

    mpcSynth(c, out, channels, window);
}

fn mpcSynth(
    c: *MpcCore,
    out: *[MPA_MAX_CHANNELS][MPC_FRAME_SIZE]i16,
    channels: usize,
    window: *const [512 + 256]i32,
) void {
    var dither_state: i32 = 0;
    var ch: usize = 0;
    while (ch < channels) : (ch += 1) {
        var i: usize = 0;
        while (i < SAMPLES_PER_BAND) : (i += 1) {
            var row: [32]i32 = undefined;
            for (0..32) |b| row[b] = c.sb_samples[ch][i][b];
            var smp: [32]i16 = undefined;
            mpaSynthFilterFixed(&c.synth_buf, &c.synth_buf_offset, ch, window, &dither_state, &smp, &row);
            const dst = out[ch][32 * i ..][0..32];
            @memcpy(dst, &smp);
        }
    }
}
