//! DTS core 定点合成 DSP（阶段二，对照 FFmpeg dcamath.h / dcadct.c / dcadsp.c
//! / dcaadpcm.c / synth_filter.c 的 fixed（整数）路径）
//!
//! 全部为整数运算，运算顺序逐句对齐 FFmpeg C（含每个舍入点），保证
//! 与 `ffmpeg -flags +bitexact`（定点模式，S32 24bit<<8 输出）逐位一致。

const std = @import("std");

pub const DCA_SUBBANDS: usize = 32;
pub const DCA_SUBBAND_SAMPLES: usize = 8;
pub const DCA_PCMBLOCK_SAMPLES: usize = 32;
pub const DCA_ADPCM_COEFFS: usize = 4;

// ---------------------------------------------------------------------------
// 定点基础（dcamath.h）
// ---------------------------------------------------------------------------

/// (a + (1 << (bits-1))) >> bits（算术右移）；bits<=0 直接截断。
pub inline fn norm__(a: i64, bits: i32) i32 {
    if (bits > 0) {
        return @intCast((a + (@as(i64, 1) << @intCast(bits - 1))) >> @intCast(bits));
    }
    return @intCast(a);
}

pub inline fn mul__(a: i32, b: i32, bits: i32) i32 {
    return norm__(@as(i64, a) * b, bits);
}

pub inline fn mul15(a: i32, b: i32) i32 {
    return mul__(a, b, 15);
}
pub inline fn mul16(a: i32, b: i32) i32 {
    return mul__(a, b, 16);
}
pub inline fn mul17(a: i32, b: i32) i32 {
    return mul__(a, b, 17);
}
pub inline fn mul22(a: i32, b: i32) i32 {
    return mul__(a, b, 22);
}
pub inline fn mul23(a: i32, b: i32) i32 {
    return mul__(a, b, 23);
}
pub inline fn mul31(a: i32, b: i32) i32 {
    return mul__(a, b, 31);
}

pub inline fn norm13(a: i64) i32 {
    return norm__(a, 13);
}
pub inline fn norm16(a: i64) i32 {
    return norm__(a, 16);
}
pub inline fn norm20(a: i64) i32 {
    return norm__(a, 20);
}
pub inline fn norm21(a: i64) i32 {
    return norm__(a, 21);
}
pub inline fn norm23(a: i64) i32 {
    return norm__(a, 23);
}

/// av_clip_intp2(a, 23)
pub inline fn clip23(a: i32) i32 {
    return std.math.clamp(a, -(1 << 23), (1 << 23) - 1);
}

// ---------------------------------------------------------------------------
// dcadct.c —— 32/64 点"半 IMDCT"（定点）
// ---------------------------------------------------------------------------

fn sum_a(input: []const i32, output: []i32, len: usize) void {
    for (0..len) |i| output[i] = input[2 * i] + input[2 * i + 1];
}

fn sum_b(input: []const i32, output: []i32, len: usize) void {
    output[0] = input[0];
    for (1..len) |i| output[i] = input[2 * i] + input[2 * i - 1];
}

fn sum_c(input: []const i32, output: []i32, len: usize) void {
    for (0..len) |i| output[i] = input[2 * i];
}

fn sum_d(input: []const i32, output: []i32, len: usize) void {
    output[0] = input[1];
    for (1..len) |i| output[i] = input[2 * i - 1] + input[2 * i + 1];
}

const cos_a = [8][8]i32{
    .{ 8348215, 8027397, 7398092, 6484482, 5321677, 3954362, 2435084, 822227 },
    .{ 8027397, 5321677, 822227, -3954362, -7398092, -8348215, -6484482, -2435084 },
    .{ 7398092, 822227, -6484482, -8027397, -2435084, 5321677, 8348215, 3954362 },
    .{ 6484482, -3954362, -8027397, 822227, 8348215, 2435084, -7398092, -5321677 },
    .{ 5321677, -7398092, -2435084, 8348215, -822227, -8027397, 3954362, 6484482 },
    .{ 3954362, -8348215, 5321677, 2435084, -8027397, 6484482, 822227, -7398092 },
    .{ 2435084, -6484482, 8348215, -7398092, 3954362, 822227, -5321677, 8027397 },
    .{ 822227, -2435084, 3954362, -5321677, 6484482, -7398092, 8027397, -8348215 },
};

const cos_b = [8][7]i32{
    .{ 8227423, 7750063, 6974873, 5931642, 4660461, 3210181, 1636536 },
    .{ 6974873, 3210181, -1636536, -5931642, -8227423, -7750063, -4660461 },
    .{ 4660461, -3210181, -8227423, -5931642, 1636536, 7750063, 6974873 },
    .{ 1636536, -7750063, -4660461, 5931642, 6974873, -3210181, -8227423 },
    .{ -1636536, -7750063, 4660461, 5931642, -6974873, -3210181, 8227423 },
    .{ -4660461, -3210181, 8227423, -5931642, -1636536, 7750063, -6974873 },
    .{ -6974873, 3210181, 1636536, -5931642, 8227423, -7750063, 4660461 },
    .{ -8227423, 7750063, -6974873, 5931642, -4660461, 3210181, -1636536 },
};

const cos_c = [16]i32{
    4199362,   4240198,   4323885,   4454708,
    4639772,   4890013,   5221943,   5660703,
    -6245623,  -7040975,  -8158494,  -9809974,
    -12450076, -17261920, -28585092, -85479984,
};

const cos_d = [8]i32{
    4214598, 4383036, 4755871,  5425934,
    6611520, 8897610, 14448934, 42791536,
};

const cos_e = [32]i32{
    1048892,  1051425,  1056522,   1064244,
    1074689,  1087987,  1104313,   1123884,
    1146975,  1173922,  1205139,   1241133,
    1282529,  1330095,  1384791,   1447815,
    -1520688, -1605358, -1704360,  -1821051,
    -1959964, -2127368, -2332183,  -2587535,
    -2913561, -3342802, -3931480,  -4785806,
    -6133390, -8566050, -14253820, -42727120,
};

fn dct_a(input: []const i32, output: []i32) void {
    for (0..8) |i| {
        var res: i64 = 0;
        for (0..8) |j| res += @as(i64, cos_a[i][j]) * input[j];
        output[i] = norm23(res);
    }
}

fn dct_b(input: []const i32, output: []i32) void {
    for (0..8) |i| {
        var res: i64 = @as(i64, input[0]) * (@as(i64, 1) << 23);
        for (0..7) |j| res += @as(i64, cos_b[i][j]) * input[1 + j];
        output[i] = norm23(res);
    }
}

fn mod_a(input: []const i32, output: []i32) void {
    for (0..8) |i| output[i] = mul23(cos_c[i], input[i] + input[8 + i]);
    for (8..16) |i| {
        const k = 15 - i;
        output[i] = mul23(cos_c[i], input[k] - input[8 + k]);
    }
}

fn mod_b(input: []i32, output: []i32) void {
    for (0..8) |i| input[8 + i] = mul23(cos_d[i], input[8 + i]);
    for (0..8) |i| output[i] = input[i] + input[8 + i];
    for (8..16) |i| {
        const k = 15 - i;
        output[i] = input[k] - input[8 + k];
    }
}

fn mod_c(input: []const i32, output: []i32) void {
    for (0..16) |i| output[i] = mul23(cos_e[i], input[i] + input[16 + i]);
    for (16..32) |i| {
        const k = 31 - i;
        output[i] = mul23(cos_e[i], input[k] - input[16 + k]);
    }
}

fn clp_v(input: []i32) void {
    for (input) |*v| v.* = clip23(v.*);
}

/// imdct_half_32（dcadct.c）输出 32 个定点样本。
pub fn imdctHalf32(output: *[32]i32, input: *const [32]i32) void {
    var buf_a: [32]i32 = undefined;
    var buf_b: [32]i32 = undefined;
    var mag: i32 = 0;
    for (input) |v| mag += if (v < 0) -v else v;
    const shift: u5 = if (mag > 0x400000) 2 else 0;
    const round: i32 = if (shift > 0) @as(i32, 1) << (shift - 1) else 0;

    for (input, 0..) |v, ii| buf_a[ii] = (v + round) >> shift;

    sum_a(&buf_a, buf_b[0..16], 16);
    sum_b(&buf_a, buf_b[16..32], 16);
    clp_v(&buf_b);

    sum_a(buf_b[0..16], buf_a[0..8], 8);
    sum_b(buf_b[0..16], buf_a[8..16], 8);
    sum_c(buf_b[16..32], buf_a[16..24], 8);
    sum_d(buf_b[16..32], buf_a[24..32], 8);
    clp_v(&buf_a);

    dct_a(buf_a[0..8], buf_b[0..8]);
    dct_b(buf_a[8..16], buf_b[8..16]);
    dct_b(buf_a[16..24], buf_b[16..24]);
    dct_b(buf_a[24..32], buf_b[24..32]);
    clp_v(&buf_b);

    mod_a(buf_b[0..16], buf_a[0..16]);
    mod_b(buf_b[16..32], buf_a[16..32]);
    clp_v(&buf_a);

    mod_c(&buf_a, &buf_b);

    for (buf_b, 0..) |v, ii| buf_b[ii] = clip23(v * (@as(i32, 1) << @intCast(shift)));

    for (0..16) |ii| {
        const kk = 31 - ii;
        output[ii] = clip23(buf_b[ii] - buf_b[kk]);
        output[16 + ii] = clip23(buf_b[ii] + buf_b[kk]);
    }
}

const mod64_a_cos = [32]i32{
    4195568,   4205700,   4226086,   4256977,
    4298755,   4351949,   4417251,   4495537,
    4587901,   4695690,   4820557,   4964534,
    5130115,   5320382,   5539164,   5791261,
    -6082752, -6421430, -6817439, -7284203,
    -7839855, -8509474, -9328732, -10350140,
    -11654242, -13371208, -15725922, -19143224,
    -24533560, -34264200, -57015280, -170908480,
};

const mod64_b_cos = [16]i32{
    4199362,  4240198,  4323885,  4454708,
    4639772,  4890013,  5221943,  5660703,
    6245623,  7040975,  8158494,  9809974,
    12450076, 17261920, 28585092, 85479984,
};

const mod64_c_cos = [64]i32{
    741511,   741958,   742853,   744199,
    746001,   748262,   750992,   754197,
    757888,   762077,   766777,   772003,
    777772,   784105,   791021,   798546,
    806707,   815532,   825054,   835311,
    846342,   858193,   870912,   884554,
    899181,   914860,   931667,   949686,
    969011,   989747,   1012012,  1035941,
    -1061684, -1089412, -1119320, -1151629,
    -1186595, -1224511, -1265719, -1310613,
    -1359657, -1413400, -1472490, -1537703,
    -1609974, -1690442, -1780506, -1881904,
    -1996824, -2128058, -2279225, -2455101,
    -2662128, -2909200, -3208956, -3579983,
    -4050785, -4667404, -5509372, -6726913,
    -8641940, -12091426, -20144284, -60420720,
};

fn mod64_a(input: []const i32, output: []i32) void {
    for (0..16) |i| output[i] = mul23(mod64_a_cos[i], input[i] + input[16 + i]);
    for (16..32) |i| {
        const k = 31 - i;
        output[i] = mul23(mod64_a_cos[i], input[k] - input[16 + k]);
    }
}

fn mod64_b(input: []i32, output: []i32) void {
    for (0..16) |i| input[16 + i] = mul23(mod64_b_cos[i], input[16 + i]);
    for (0..16) |i| output[i] = input[i] + input[16 + i];
    for (16..32) |i| {
        const k = 31 - i;
        output[i] = input[k] - input[16 + k];
    }
}

fn mod64_c(input: []const i32, output: []i32) void {
    for (0..32) |i| output[i] = mul23(mod64_c_cos[i], input[i] + input[32 + i]);
    for (32..64) |i| {
        const k = 63 - i;
        output[i] = mul23(mod64_c_cos[i], input[k] - input[32 + k]);
    }
}

/// imdct_half_64（dcadct.c）输出 64 个定点样本（X96 96k/192k 合成）。
pub fn imdctHalf64(output: *[64]i32, input: *const [64]i32) void {
    var buf_a: [64]i32 = undefined;
    var buf_b: [64]i32 = undefined;
    var mag: i32 = 0;
    for (input) |v| mag += if (v < 0) -v else v;
    const shift: u5 = if (mag > 0x400000) 2 else 0;
    const round: i32 = if (shift > 0) @as(i32, 1) << (shift - 1) else 0;

    for (input, 0..) |v, ii| buf_a[ii] = (v + round) >> shift;

    sum_a(&buf_a, buf_b[0..32], 32);
    sum_b(&buf_a, buf_b[32..64], 32);
    clp_v(&buf_b);

    sum_a(buf_b[0..32], buf_a[0..16], 16);
    sum_b(buf_b[0..32], buf_a[16..32], 16);
    sum_c(buf_b[32..64], buf_a[32..48], 16);
    sum_d(buf_b[32..64], buf_a[48..64], 16);
    clp_v(&buf_a);

    sum_a(buf_a[0..16], buf_b[0..8], 8);
    sum_b(buf_a[0..16], buf_b[8..16], 8);
    sum_c(buf_a[16..32], buf_b[16..24], 8);
    sum_d(buf_a[16..32], buf_b[24..32], 8);
    sum_c(buf_a[32..48], buf_b[32..40], 8);
    sum_d(buf_a[32..48], buf_b[40..48], 8);
    sum_c(buf_a[48..64], buf_b[48..56], 8);
    sum_d(buf_a[48..64], buf_b[56..64], 8);
    clp_v(&buf_b);

    dct_a(buf_b[0..8], buf_a[0..8]);
    dct_b(buf_b[8..16], buf_a[8..16]);
    dct_b(buf_b[16..24], buf_a[16..24]);
    dct_b(buf_b[24..32], buf_a[24..32]);
    dct_b(buf_b[32..40], buf_a[32..40]);
    dct_b(buf_b[40..48], buf_a[40..48]);
    dct_b(buf_b[48..56], buf_a[48..56]);
    dct_b(buf_b[56..64], buf_a[56..64]);
    clp_v(&buf_a);

    mod_a(buf_a[0..16], buf_b[0..16]);
    mod_b(buf_a[16..32], buf_b[16..32]);
    mod_b(buf_a[32..48], buf_b[32..48]);
    mod_b(buf_a[48..64], buf_b[48..64]);
    clp_v(&buf_b);

    mod64_a(buf_b[0..32], buf_a[0..32]);
    mod64_b(buf_b[32..64], buf_a[32..64]);
    clp_v(&buf_a);

    mod64_c(&buf_a, &buf_b);

    for (buf_b, 0..) |v, ii| buf_b[ii] = clip23(v * (@as(i32, 1) << @intCast(shift)));

    for (0..32) |ii| {
        const kk = 63 - ii;
        output[ii] = clip23(buf_b[ii] - buf_b[kk]);
        output[32 + ii] = clip23(buf_b[ii] + buf_b[kk]);
    }
}

// ---------------------------------------------------------------------------
// synth_filter.c —— synth_filter_fixed（32 子带窗口 FIR）
// ---------------------------------------------------------------------------

inline fn ringAt(h: *const [1024]i32, base: usize, idx: isize) i32 {
    const p: isize = @as(isize, @intCast(base)) + idx + 2048;
    return h[@intCast(@mod(p, 1024))];
}

/// 一次子带样本 → 32 个时域样本。hist1 为 1024 环形缓冲（offset 0..511），
/// 每步先由 imdct_half_32 写入 hist1[offset..offset+32)，再对窗口 512 抽头求和。
pub fn synthFilterFixed(
    hist1: *[1024]i32,
    offset: *u9,
    hist2: *[32]i32,
    window: *const [512]i32,
    out: *[32]i32,
    in: *const [32]i32,
) void {
    const off: usize = offset.*;

    var tmp: [32]i32 = undefined;
    imdctHalf32(&tmp, in);
    for (tmp, 0..) |v, j| hist1[(off + j) & 1023] = v;

    for (0..16) |i| {
        var a: i64 = @as(i64, hist2[i]) * (@as(i64, 1) << 21);
        var b: i64 = @as(i64, hist2[i + 16]) * (@as(i64, 1) << 21);
        var c: i64 = 0;
        var d: i64 = 0;

        var j: usize = 0;
        while (j < 512 - off) : (j += 64) {
            const ji: isize = @intCast(j);
            a += @as(i64, window[i + j]) * ringAt(hist1, off, @as(isize, @intCast(i)) + ji);
            b += @as(i64, window[i + j + 16]) * ringAt(hist1, off, @as(isize, @intCast(15)) - @as(isize, @intCast(i)) + ji);
            c += @as(i64, window[i + j + 32]) * ringAt(hist1, off, @as(isize, @intCast(16)) + @as(isize, @intCast(i)) + ji);
            d += @as(i64, window[i + j + 48]) * ringAt(hist1, off, @as(isize, @intCast(31)) - @as(isize, @intCast(i)) + ji);
        }
        while (j < 512) : (j += 64) {
            const ji: isize = @intCast(j);
            a += @as(i64, window[i + j]) * ringAt(hist1, off, @as(isize, @intCast(i)) + ji - 512);
            b += @as(i64, window[i + j + 16]) * ringAt(hist1, off, @as(isize, @intCast(15)) - @as(isize, @intCast(i)) + ji - 512);
            c += @as(i64, window[i + j + 32]) * ringAt(hist1, off, @as(isize, @intCast(16)) + @as(isize, @intCast(i)) + ji - 512);
            d += @as(i64, window[i + j + 48]) * ringAt(hist1, off, @as(isize, @intCast(31)) - @as(isize, @intCast(i)) + ji - 512);
        }

        out[i] = clip23(norm21(a));
        out[i + 16] = clip23(norm21(b));
        hist2[i] = norm21(c);
        hist2[i + 16] = norm21(d);
    }

    offset.* = @intCast((@as(u16, @intCast(off)) -% 32) & 511);
}

inline fn ringAt1024(h: *const [1024]i32, base: usize, idx: isize) i32 {
    const p: isize = @as(isize, @intCast(base)) + idx;
    return h[@intCast(@mod(p, 1024))];
}

/// 64 子带合成（synth_filter_fixed_64，X96 96k/192k）。hist1 环形 1024，
/// offset 0..1023（每次 -64 & 1023）。一次 64 个时域样本。
pub fn synthFilterFixed64(
    hist1: *[1024]i32,
    offset: *u10,
    hist2: *[64]i32,
    window: *const [1024]i32,
    out: *[64]i32,
    in: *const [64]i32,
) void {
    const off: usize = offset.*;
    var tmp: [64]i32 = undefined;
    imdctHalf64(&tmp, in);
    for (tmp, 0..) |v, j| hist1[(off + j) & 1023] = v;

    for (0..32) |i| {
        var a: i64 = @as(i64, hist2[i]) * (@as(i64, 1) << 20);
        var b: i64 = @as(i64, hist2[i + 32]) * (@as(i64, 1) << 20);
        var c: i64 = 0;
        var d: i64 = 0;
        var j: usize = 0;
        while (j < 1024) : (j += 128) {
            const ji: isize = @intCast(j);
            a += @as(i64, window[i + j]) * ringAt1024(hist1, off, @as(isize, @intCast(i)) + ji);
            b += @as(i64, window[i + j + 32]) * ringAt1024(hist1, off, @as(isize, @intCast(31)) - @as(isize, @intCast(i)) + ji);
            c += @as(i64, window[i + j + 64]) * ringAt1024(hist1, off, @as(isize, @intCast(32)) + @as(isize, @intCast(i)) + ji);
            d += @as(i64, window[i + j + 96]) * ringAt1024(hist1, off, @as(isize, @intCast(63)) - @as(isize, @intCast(i)) + ji);
        }
        out[i] = clip23(norm20(a));
        out[i + 32] = clip23(norm20(b));
        hist2[i] = norm20(c);
        hist2[i + 32] = norm20(d);
    }
    offset.* = @intCast((@as(u16, @intCast(off)) -% 64) & 1023);
}

/// LFE 插值（lfe_fir_fixed_c）：npcmblocks/2 个 LFE 样本 → npcmblocks*32 个输出。
/// lfe_buf 传入 [8 + npcmblocks/2] 缓冲，其中 [0..8) 为上一帧历史，[8..) 为本帧数据；
/// 内部按 FFmpeg 语义（指针 = 数据起点 + i，负下标取历史）访问。
pub fn lfeFirFixed(pcm: []i32, lfe_buf: []const i32, filter_coeff: *const [256]i32, npcmblocks: usize) void {
    const n = npcmblocks >> 1;
    for (0..n) |i| {
        for (0..32) |j| {
            var a: i64 = 0;
            var b: i64 = 0;
            for (0..8) |k| {
                const v: i64 = lfe_buf[i + 8 - k];
                a += @as(i64, filter_coeff[j * 8 + k]) * v;
                b += @as(i64, filter_coeff[255 - j * 8 - k]) * v;
            }
            pcm[i * 64 + j] = clip23(norm23(a));
            pcm[i * 64 + 32 + j] = clip23(norm23(b));
        }
    }
}

/// LFE 96k 二次插值（lfe_x96_fixed_c）：src 为 48k 抽取后的 LFE PCM，
/// 输出 2× 样本数（hist 为上一帧末样本）。
pub fn lfeX96Fixed(dst: []i32, src: []const i32, hist: *i32, len: usize) void {
    var prev = hist.*;
    for (0..len) |i| {
        const a: i64 = 2097471 * @as(i64, src[i]) + 6291137 * @as(i64, prev);
        const b: i64 = 6291137 * @as(i64, src[i]) + 2097471 * @as(i64, prev);
        prev = src[i];
        dst[2 * i] = clip23(norm23(a));
        dst[2 * i + 1] = clip23(norm23(b));
    }
    hist.* = prev;
}

test "dsp: imdctHalf32 输出有界" {
    var in: [32]i32 = [_]i32{1000} ** 32;
    var out: [32]i32 = undefined;
    imdctHalf32(&out, &in);
    for (out) |v| try std.testing.expect(v >= -(1 << 23) and v <= (1 << 23) - 1);
}
