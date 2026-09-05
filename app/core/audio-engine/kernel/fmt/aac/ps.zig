//! AAC PS（参数立体声）解码器（bit-exact 移植 FFmpeg n9.0.1 浮点路径）。
//!
//! 复刻对象：libavcodec/{aacps.c,aacps_common.c,aacpsdsp_template.c} +
//! aacpsdata.c 表 + aacps_tablegen.h 生成。HE-AAC v2 的立体声恢复：
//! 单声道 core + 参数化 IID/ICC/IPD/OPD → 左右声道。
//!
//! 数据流（ff_ps_apply）：混合分析(L→Lbuf 子子带) → 去相关(Lbuf→Rbuf)
//! → 立体声处理(H 矩阵混合) → 混合合成(Lbuf/Rbuf→L/R QMF 域)。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const BitReader = @import("bitreader.zig").BitReader;
const pst = @import("ps_tables.zig");
const ph = @import("ps_huff.zig");

// ---------------- 常量 ----------------

const PS_MAX_NUM_ENV = pst.PS_MAX_NUM_ENV;
const PS_MAX_NR_IIDICC = pst.PS_MAX_NR_IIDICC;
const PS_MAX_NR_IPDOPD = pst.PS_MAX_NR_IPDOPD;
const PS_MAX_SSB = pst.PS_MAX_SSB;
const PS_MAX_AP_BANDS = pst.PS_MAX_AP_BANDS;
const PS_QMF_TIME_SLOTS = pst.PS_QMF_TIME_SLOTS;
const PS_MAX_DELAY = pst.PS_MAX_DELAY;
const PS_AP_LINKS = pst.PS_AP_LINKS;
const PS_MAX_AP_DELAY = pst.PS_MAX_AP_DELAY;
const NR_PAR_BANDS = pst.NR_PAR_BANDS;
const NR_IPDOPD_BANDS = pst.NR_IPDOPD_BANDS;
const NR_BANDS = pst.NR_BANDS;
const DECAY_CUTOFF = pst.DECAY_CUTOFF;
const NR_ALLPASS_BANDS = pst.NR_ALLPASS_BANDS;
const SHORT_DELAY_BAND = pst.SHORT_DELAY_BAND;

// ---------------- 公共上下文（aacps.h PSCommonContext） ----------------

pub const PSCommonContext = struct {
    start: i32 = 0,
    enable_iid: i32 = 0,
    iid_quant: i32 = 0,
    nr_iid_par: i32 = 0,
    nr_ipdopd_par: i32 = 0,
    enable_icc: i32 = 0,
    icc_mode: i32 = 0,
    nr_icc_par: i32 = 0,
    enable_ext: i32 = 0,
    frame_class: i32 = 0,
    num_env_old: i32 = 0,
    num_env: i32 = 0,
    enable_ipdopd: i32 = 0,
    border_position: [PS_MAX_NUM_ENV + 1]i32 = [_]i32{-1} ** (PS_MAX_NUM_ENV + 1),
    iid_par: [PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]i8 = [_][PS_MAX_NR_IIDICC]i8{[_]i8{0} ** PS_MAX_NR_IIDICC} ** PS_MAX_NUM_ENV,
    icc_par: [PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]i8 = [_][PS_MAX_NR_IIDICC]i8{[_]i8{0} ** PS_MAX_NR_IIDICC} ** PS_MAX_NUM_ENV,
    ipd_par: [PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]i8 = [_][PS_MAX_NR_IIDICC]i8{[_]i8{0} ** PS_MAX_NR_IIDICC} ** PS_MAX_NUM_ENV,
    opd_par: [PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]i8 = [_][PS_MAX_NR_IIDICC]i8{[_]i8{0} ** PS_MAX_NR_IIDICC} ** PS_MAX_NUM_ENV,
    is34bands: i32 = 0,
    is34bands_old: i32 = 0,
};

// ---------------- PS 上下文（aacps.h PSContext） ----------------

pub const PSCtx = struct {
    common: PSCommonContext = .{},
    in_buf: [5][44][2]f32 = [_][44][2]f32{[_][2]f32{[_]f32{0} ** 2} ** 44} ** 5,
    delay: [PS_MAX_SSB][PS_QMF_TIME_SLOTS + PS_MAX_DELAY][2]f32 = [_][PS_QMF_TIME_SLOTS + PS_MAX_DELAY][2]f32{[_][2]f32{[_]f32{0} ** 2} ** (PS_QMF_TIME_SLOTS + PS_MAX_DELAY)} ** PS_MAX_SSB,
    ap_delay: [PS_MAX_AP_BANDS][PS_AP_LINKS][PS_QMF_TIME_SLOTS + PS_MAX_AP_DELAY][2]f32 = [_][PS_AP_LINKS][PS_QMF_TIME_SLOTS + PS_MAX_AP_DELAY][2]f32{[_][PS_QMF_TIME_SLOTS + PS_MAX_AP_DELAY][2]f32{[_][2]f32{[_]f32{0} ** 2} ** (PS_QMF_TIME_SLOTS + PS_MAX_AP_DELAY)} ** PS_AP_LINKS} ** PS_MAX_AP_BANDS,
    peak_decay_nrg: [34]f32 = [_]f32{0} ** 34,
    power_smooth: [34]f32 = [_]f32{0} ** 34,
    peak_decay_diff_smooth: [34]f32 = [_]f32{0} ** 34,
    H11: [2][PS_MAX_NUM_ENV + 1][PS_MAX_NR_IIDICC]f32 = [_][PS_MAX_NUM_ENV + 1][PS_MAX_NR_IIDICC]f32{[_][PS_MAX_NR_IIDICC]f32{[_]f32{0} ** PS_MAX_NR_IIDICC} ** (PS_MAX_NUM_ENV + 1)} ** 2,
    H12: [2][PS_MAX_NUM_ENV + 1][PS_MAX_NR_IIDICC]f32 = [_][PS_MAX_NUM_ENV + 1][PS_MAX_NR_IIDICC]f32{[_][PS_MAX_NR_IIDICC]f32{[_]f32{0} ** PS_MAX_NR_IIDICC} ** (PS_MAX_NUM_ENV + 1)} ** 2,
    H21: [2][PS_MAX_NUM_ENV + 1][PS_MAX_NR_IIDICC]f32 = [_][PS_MAX_NUM_ENV + 1][PS_MAX_NR_IIDICC]f32{[_][PS_MAX_NR_IIDICC]f32{[_]f32{0} ** PS_MAX_NR_IIDICC} ** (PS_MAX_NUM_ENV + 1)} ** 2,
    H22: [2][PS_MAX_NUM_ENV + 1][PS_MAX_NR_IIDICC]f32 = [_][PS_MAX_NUM_ENV + 1][PS_MAX_NR_IIDICC]f32{[_][PS_MAX_NR_IIDICC]f32{[_]f32{0} ** PS_MAX_NR_IIDICC} ** (PS_MAX_NUM_ENV + 1)} ** 2,
    Lbuf: [91][32][2]f32 = [_][32][2]f32{[_][2]f32{[_]f32{0} ** 2} ** 32} ** 91,
    Rbuf: [91][32][2]f32 = [_][32][2]f32{[_][2]f32{[_]f32{0} ** 2} ** 32} ** 91,
    opd_hist: [PS_MAX_NR_IIDICC]i8 = [_]i8{0} ** PS_MAX_NR_IIDICC,
    ipd_hist: [PS_MAX_NR_IIDICC]i8 = [_]i8{0} ** PS_MAX_NR_IIDICC,
};

/// 清零全部状态（对齐 FFmpeg calloc / 带宽切换复位）
fn zeroState(self: *PSCtx) void {
    const bytes: [*]u8 = @ptrCast(self);
    @memset(bytes[0..@sizeOf(PSCtx)], 0);
}

pub fn psInit(self: *PSCtx) void {
    zeroState(self);
    pst.psTableInit();
}

// ---------------- VLC 解码（规范哈夫曼，复用 sbr.zig 逻辑） ----------------

/// 解码 PS Huffman（table_idx 0..9）。返回符号（含 offset）。
fn getVlc(gb: *BitReader, table_idx: usize) Error!i32 {
    const nb = ph.ps_huff_sizes[table_idx];
    const offset = ph.ps_huff_offsets[table_idx];
    var base: usize = 0;
    for (0..table_idx) |t| base += ph.ps_huff_sizes[t];
    var acc: u32 = 0;
    const max_len: usize = if (table_idx <= 5) 20 else 5;
    var len: usize = 1;
    while (len <= max_len) : (len += 1) {
        const bit = gb.readBits(1) catch return error.Corrupt;
        acc = (acc << 1) | bit;
        var code: u64 = 0;
        var i: usize = 0;
        while (i < nb) : (i += 1) {
            const l = ph.ps_huff_lengths[base + i];
            if (l == 0) continue;
            if (l == len) {
                const c_hi = @as(u32, @intCast(code >> @intCast(32 - len)));
                if (c_hi == acc) {
                    return @as(i32, ph.ps_huff_symbols[base + i]) + offset;
                }
            }
            code += @as(u64, 1) << @intCast(32 - @as(u6, @intCast(l)));
        }
    }
    return error.Corrupt;
}

// ---------------- 语法解析（ff_ps_read_data） ----------------

const READ_PAR_DATA = struct {
    fn readParam(
        gb: *BitReader,
        ps: *PSCommonContext,
        par: *[PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]i8,
        table_idx: usize,
        e: usize,
        dt: bool,
        is_iid: bool,
        is_icc: bool,
    ) Error!bool {
        const num = ps.nr_iid_par;
        const num_icc = ps.nr_icc_par;
        const n: usize = if (is_iid) @intCast(num) else if (is_icc) @intCast(num_icc) else @intCast(ps.nr_ipdopd_par);
        if (dt) {
            const e_prev: usize = if (e > 0) e - 1 else @intCast(@max(ps.num_env_old - 1, 0));
            var b: usize = 0;
            while (b < n) : (b += 1) {
                const dv = try getVlc(gb, table_idx);
                var val: i32 = @as(i32, par[e_prev][b]) + dv;
                if (is_iid and !is_icc) {
                    if (@abs(val) > 7 + 8 * ps.iid_quant) return false;
                } else if (is_icc) {
                    if (val < 0 or val > 7) return false;
                } else {
                    val &= 0x07;
                }
                par[e][b] = @intCast(val);
            }
        } else {
            var val: i32 = 0;
            var b: usize = 0;
            while (b < n) : (b += 1) {
                val += try getVlc(gb, table_idx);
                if (is_iid and !is_icc) {
                    if (@abs(val) > 7 + 8 * ps.iid_quant) return false;
                } else if (is_icc) {
                    if (val < 0 or val > 7) return false;
                } else {
                    val &= 0x07;
                }
                par[e][b] = @intCast(val);
            }
        }
        return true;
    }
};

fn readExtensionData(gb: *BitReader, ps: *PSCommonContext, ps_extension_id: u32) Error!usize {
    if (ps_extension_id != 0) return 0;
    const start = gb.bit_pos;
    ps.enable_ipdopd = @intCast(gb.readBits(1) catch return error.Corrupt);
    if (ps.enable_ipdopd != 0) {
        var e: usize = 0;
        while (e < @as(usize, @intCast(ps.num_env))) : (e += 1) {
            const dt_ipd = gb.readBits(1) catch return error.Corrupt;
            if (!try READ_PAR_DATA.readParam(gb, ps, &ps.ipd_par, if (dt_ipd != 0) 7 else 6, e, dt_ipd != 0, false, false)) return error.Corrupt;
            const dt_opd = gb.readBits(1) catch return error.Corrupt;
            if (!try READ_PAR_DATA.readParam(gb, ps, &ps.opd_par, if (dt_opd != 0) 9 else 8, e, dt_opd != 0, false, false)) return error.Corrupt;
        }
    }
    _ = gb.readBits(1) catch return error.Corrupt; // reserved_ps
    return gb.bit_pos - start;
}

/// ff_ps_read_data：解析 PS 扩展数据，成功推进 gb；返回消费的位数。
pub fn psReadData(gb: *BitReader, ps: *PSCommonContext) Error!usize {
    const start = gb.bit_pos;
    var is34: i32 = 0;

    const header = gb.readBits(1) catch return error.Corrupt;
    if (header != 0) {
        ps.enable_iid = @intCast(gb.readBits(1) catch return error.Corrupt);
        if (ps.enable_iid != 0) {
            const iid_mode = gb.readBits(3) catch return error.Corrupt;
            if (iid_mode > 5) return error.Corrupt;
            ps.nr_iid_par = pst.nr_iidicc_par_tab[iid_mode];
            ps.iid_quant = if (iid_mode > 2) 1 else 0;
            ps.nr_ipdopd_par = pst.nr_iidopd_par_tab[iid_mode];
        }
        ps.enable_icc = @intCast(gb.readBits(1) catch return error.Corrupt);
        if (ps.enable_icc != 0) {
            const icc_mode = gb.readBits(3) catch return error.Corrupt;
            if (icc_mode > 5) return error.Corrupt;
            ps.nr_icc_par = pst.nr_iidicc_par_tab[icc_mode];
            ps.icc_mode = @intCast(icc_mode);
        }
        ps.enable_ext = @intCast(gb.readBits(1) catch return error.Corrupt);
    }

    ps.frame_class = @intCast(gb.readBits(1) catch return error.Corrupt);
    ps.num_env_old = ps.num_env;
    const env_idx = gb.readBits(2) catch return error.Corrupt;
    ps.num_env = pst.num_env_tab[@intCast(ps.frame_class)][env_idx];

    ps.border_position[0] = -1;
    if (ps.frame_class != 0) {
        var e: usize = 1;
        while (e <= @as(usize, @intCast(ps.num_env))) : (e += 1) {
            ps.border_position[e] = @intCast(gb.readBits(5) catch return error.Corrupt);
        }
        if (ps.border_position[@intCast(ps.num_env)] < 0) return error.Corrupt;
        var e2: usize = 1;
        while (e2 <= @as(usize, @intCast(ps.num_env))) : (e2 += 1) {
            if (ps.border_position[e2 - 1] > ps.border_position[e2]) return error.Corrupt;
        }
    } else {
        var e: usize = 1;
        while (e <= @as(usize, @intCast(ps.num_env))) : (e += 1) {
            ps.border_position[e] = @as(i32, @intCast((e * 32) >> @intCast(log2Tab(@intCast(ps.num_env))))) - 1;
        }
    }

    if (ps.enable_iid != 0) {
        var e: usize = 0;
        while (e < @as(usize, @intCast(ps.num_env))) : (e += 1) {
            const dt = gb.readBits(1) catch return error.Corrupt;
            const tbl: usize = pst.huff_iid[@as(usize, @intCast(2 * @as(u32, @intCast(dt)) + @as(u32, @intCast(ps.iid_quant))))];
            if (!try READ_PAR_DATA.readParam(gb, ps, &ps.iid_par, tbl, e, dt != 0, true, false)) return error.Corrupt;
        }
    } else {
        @memset(@as([*]u8, @ptrCast(&ps.iid_par))[0 .. @sizeOf(@TypeOf(ps.iid_par))], 0);
    }

    if (ps.enable_icc != 0) {
        var e: usize = 0;
        while (e < @as(usize, @intCast(ps.num_env))) : (e += 1) {
            const dt = gb.readBits(1) catch return error.Corrupt;
            const tbl: usize = if (dt != 0) 5 else 4;
            if (!try READ_PAR_DATA.readParam(gb, ps, &ps.icc_par, tbl, e, dt != 0, false, true)) return error.Corrupt;
        }
    } else {
        @memset(@as([*]u8, @ptrCast(&ps.icc_par))[0 .. @sizeOf(@TypeOf(ps.icc_par))], 0);
    }

    if (ps.enable_ext != 0) {
        var cnt: i32 = @intCast(gb.readBits(4) catch return error.Corrupt);
        if (cnt == 15) cnt += @intCast(gb.readBits(8) catch return error.Corrupt);
        cnt <<= 3;
        while (cnt > 7) {
            const ps_extension_id = gb.readBits(2) catch return error.Corrupt;
            const consumed = try readExtensionData(gb, ps, ps_extension_id);
            cnt -= 2 + @as(i32, @intCast(consumed));
        }
        if (cnt < 0) return error.Corrupt;
        if (cnt > 0) _ = gb.readBits(@intCast(cnt)) catch return error.Corrupt;
    }

    // 伪造包络（fix up envelopes）
    if (ps.num_env == 0 or ps.border_position[@intCast(ps.num_env)] < 31) {
        const source: usize = if (ps.num_env > 0) @intCast(ps.num_env - 1) else @intCast(@max(ps.num_env_old - 1, 0));
        if (source >= 0 and @as(i32, @intCast(source)) != ps.num_env) {
            if (ps.enable_iid != 0)
                @memcpy(ps.iid_par[@intCast(ps.num_env)][0..], ps.iid_par[source][0..]);
            if (ps.enable_icc != 0)
                @memcpy(ps.icc_par[@intCast(ps.num_env)][0..], ps.icc_par[source][0..]);
            if (ps.enable_ipdopd != 0) {
                @memcpy(ps.ipd_par[@intCast(ps.num_env)][0..], ps.ipd_par[source][0..]);
                @memcpy(ps.opd_par[@intCast(ps.num_env)][0..], ps.opd_par[source][0..]);
            }
        }
        if (ps.enable_iid != 0) {
            var b: usize = 0;
            while (b < @as(usize, @intCast(ps.nr_iid_par))) : (b += 1) {
                if (@abs(ps.iid_par[@intCast(ps.num_env)][b]) > 7 + 8 * ps.iid_quant) return error.Corrupt;
            }
        }
        if (ps.enable_icc != 0) {
            var b: usize = 0;
            while (b < @as(usize, @intCast(ps.nr_icc_par))) : (b += 1) {
                if (ps.icc_par[@intCast(ps.num_env)][b] < 0 or ps.icc_par[@intCast(ps.num_env)][b] > 7) return error.Corrupt;
            }
        }
        ps.num_env += 1;
        ps.border_position[@intCast(ps.num_env)] = 31;
    }

    // is34bands：由 nr_icc_par 或 nr_iid_par 决定（C 用 OR）
    is34 = @intFromBool((ps.enable_iid != 0 and ps.nr_iid_par == 34) or (ps.enable_icc != 0 and ps.nr_icc_par == 34));
    ps.is34bands_old = ps.is34bands;
    ps.is34bands = is34;
    ps.start = 1;
    return gb.bit_pos - start;
}

fn log2Tab(v: i32) u8 {
    // ff_log2_tab：2 的幂的 log2
    var r: u8 = 0;
    var x = v;
    while (x > 1) : (x >>= 1) r += 1;
    return r;
}

// ---------------- DSP：add_squares / mul_pair_single ----------------

fn psAddSquares(dst: []f32, src: *const [32][2]f32) void {
    for (src, 0..) |v, i| dst[i] += v[0] * v[0] + v[1] * v[1];
}

fn psMulPairSingle(dst: *[32][2]f32, src0: *const [32][2]f32, src1: []const f32) void {
    for (0..32) |i| {
        dst[i][0] = src0[i][0] * src1[i];
        dst[i][1] = src0[i][1] * src1[i];
    }
}

// ---------------- DSP：hybrid_analysis（13 抽头对称复滤波器） ----------------

fn psHybridAnalysis(out: []f32, in: *const [13][2]f32, filter: []const [8][2]f32, n_bands: usize) void {
    var inre0: [6]f32 = undefined;
    var inre1: [6]f32 = undefined;
    var inim0: [6]f32 = undefined;
    var inim1: [6]f32 = undefined;
    for (0..6) |j| {
        inre0[j] = in[j][0] + in[12 - j][0];
        inre1[j] = in[j][1] - in[12 - j][1];
        inim0[j] = in[j][1] + in[12 - j][1];
        inim1[j] = in[j][0] - in[12 - j][0];
    }
    for (0..n_bands) |i| {
        var sum_re: f32 = filter[i][6][0] * in[6][0];
        var sum_im: f32 = filter[i][6][0] * in[6][1];
        for (0..6) |j| {
            sum_re += filter[i][j][0] * inre0[j] - filter[i][j][1] * inre1[j];
            sum_im += filter[i][j][0] * inim0[j] + filter[i][j][1] * inim1[j];
        }
        out[2 * i] = sum_re;
        out[2 * i + 1] = sum_im;
    }
}

// ---------------- 混合分析辅助 ----------------

fn hybrid6Cx(out: *[6][32][2]f32, in: *const [13][2]f32, filter: *const [8][2]f32) void {
    var temp: [8][2]f32 = undefined;
    psHybridAnalysis(&temp, in, filter);
    out[0][0] = temp[6];
    out[1][0] = temp[7];
    out[2][0] = temp[0];
    out[3][0] = temp[1];
    out[4][0] = .{ temp[2][0] + temp[5][0], temp[2][1] + temp[5][1] };
    out[5][0] = .{ temp[3][0] + temp[4][0], temp[3][1] + temp[4][1] };
}

fn hybrid4812Cx(out: *[12][32][2]f32, in: *const [13][2]f32, filter: *const [8][2]f32, n_bands: usize) void {
    var temp: [8][2]f32 = undefined;
    psHybridAnalysis(&temp, in, filter);
    for (0..n_bands) |b| {
        out[b][0] = temp[b];
    }
}

fn hybrid2Re(out: *[2][32][2]f32, in: *const [13][2]f32, filter: [7]f32, reverse: usize) void {
    const re_in: f32 = filter[6] * in[6][0];
    const im_in: f32 = filter[6] * in[6][1];
    var re_op: f32 = 0;
    var im_op: f32 = 0;
    var j: usize = 0;
    while (j < 6) : (j += 2) {
        re_op += filter[j + 1] * (in[j + 1][0] + in[12 - j - 1][0]);
        im_op += filter[j + 1] * (in[j + 1][1] + in[12 - j - 1][1]);
    }
    out[reverse][0] = .{ re_in + re_op, im_in + im_op };
    out[1 - reverse][0] = .{ re_in - re_op, im_in - im_op };
}

fn psHybridAnalysisIleave(out: *[91][32][2]f32, L: *const [2][38][64]f32, i: usize, len: usize, base: usize) void {
    var bi: usize = i;
    while (bi < 64) : (bi += 1) {
        for (0..len) |j| {
            out[bi + base][j][0] = L[0][j][bi];
            out[bi + base][j][1] = L[1][j][bi];
        }
    }
}

// ---------------- DSP：hybrid_synthesis_deint ----------------

fn psHybridSynthesisDeint(out: *[2][38][64]f32, in: *const [91][32][2]f32, i: usize, len: usize, base: usize) void {
    var bi: usize = i;
    while (bi < 64) : (bi += 1) {
        for (0..len) |n| {
            out[0][n][bi] = in[bi + base][n][0];
            out[1][n][bi] = in[bi + base][n][1];
        }
    }
}

// ---------------- DSP：decorrelate（三级全通链） ----------------

fn psDecorrelate(
    out: *[32][2]f32,
    delay: *const [32][2]f32,
    ap_delay: *[3][37][2]f32,
    phi_fract: [2]f32,
    q_fract: *const [3][2]f32,
    transient_gain: []const f32,
    g_decay_slope: f32,
) void {
    const a = [3]f32{ 0.65143905753106, 0.56471812200776, 0.48954165955695 };
    var ag: [3]f32 = undefined;
    for (a, 0..) |av, m| ag[m] = av * g_decay_slope;
    for (delay, 0..) |dn, n| {
        var in_re: f32 = dn[0] * phi_fract[0] - dn[1] * phi_fract[1];
        var in_im: f32 = dn[0] * phi_fract[1] + dn[1] * phi_fract[0];
        for (0..3) |m| {
            const a_re: f32 = ag[m] * in_re;
            const a_im: f32 = ag[m] * in_im;
            const ld_re: f32 = ap_delay[m][n + 2 - m][0];
            const ld_im: f32 = ap_delay[m][n + 2 - m][1];
            const f_re: f32 = q_fract[m][0];
            const f_im: f32 = q_fract[m][1];
            const apd_re: f32 = in_re;
            const apd_im: f32 = in_im;
            in_re = ld_re * f_re - ld_im * f_im - a_re;
            in_im = ld_re * f_im + ld_im * f_re - a_im;
            ap_delay[m][n + 5][0] = apd_re + ag[m] * in_re;
            ap_delay[m][n + 5][1] = apd_im + ag[m] * in_im;
        }
        out[n][0] = transient_gain[n] * in_re;
        out[n][1] = transient_gain[n] * in_im;
    }
}

// ---------------- DSP：stereo_interpolate ----------------

fn psStereoInterpolate(l: *[32][2]f32, r: *[32][2]f32, h: *const [2][4]f32, h_step: *const [2][4]f32, len: usize) void {
    var h0: f32 = h[0][0];
    var h1: f32 = h[0][1];
    var h2: f32 = h[0][2];
    var h3: f32 = h[0][3];
    const hs0: f32 = h_step[0][0];
    const hs1: f32 = h_step[0][1];
    const hs2: f32 = h_step[0][2];
    const hs3: f32 = h_step[0][3];
    for (0..len) |n| {
        const l_re: f32 = l[n][0];
        const l_im: f32 = l[n][1];
        const r_re: f32 = r[n][0];
        const r_im: f32 = r[n][1];
        h0 += hs0;
        h1 += hs1;
        h2 += hs2;
        h3 += hs3;
        l[n][0] = h0 * l_re + h2 * r_re;
        l[n][1] = h0 * l_im + h2 * r_im;
        r[n][0] = h1 * l_re + h3 * r_re;
        r[n][1] = h1 * l_im + h3 * r_im;
    }
}

fn psStereoInterpolateIpdopd(l: *[32][2]f32, r: *[32][2]f32, h: *const [2][4]f32, h_step: *const [2][4]f32, len: usize) void {
    var h00: f32 = h[0][0];
    var h10: f32 = h[1][0];
    var h01: f32 = h[0][1];
    var h11: f32 = h[1][1];
    var h02: f32 = h[0][2];
    var h12: f32 = h[1][2];
    var h03: f32 = h[0][3];
    var h13: f32 = h[1][3];
    const hs00: f32 = h_step[0][0];
    const hs10: f32 = h_step[1][0];
    const hs01: f32 = h_step[0][1];
    const hs11: f32 = h_step[1][1];
    const hs02: f32 = h_step[0][2];
    const hs12: f32 = h_step[1][2];
    const hs03: f32 = h_step[0][3];
    const hs13: f32 = h_step[1][3];
    for (0..len) |n| {
        const l_re: f32 = l[n][0];
        const l_im: f32 = l[n][1];
        const r_re: f32 = r[n][0];
        const r_im: f32 = r[n][1];
        h00 += hs00;
        h01 += hs01;
        h02 += hs02;
        h03 += hs03;
        h10 += hs10;
        h11 += hs11;
        h12 += hs12;
        h13 += hs13;
        l[n][0] = h00 * l_re + h02 * r_re - h10 * l_im - h12 * r_im;
        l[n][1] = h00 * l_im + h02 * r_im + h10 * l_re + h12 * r_re;
        r[n][0] = h01 * l_re + h03 * r_re - h11 * l_im - h13 * r_im;
        r[n][1] = h01 * l_im + h03 * r_im + h11 * l_re + h13 * r_re;
    }
}

// ---------------- 重映射函数（aacps.c 200-397） ----------------

fn mapIdx10To20(par_mapped: *[34]i8, par: *const [34]i8, full: bool) void {
    var b: i32 = if (full) 9 else 4;
    if (!full) par_mapped[10] = 0;
    while (b >= 0) : (b -= 1) {
        par_mapped[2 * @as(usize, @intCast(b)) + 1] = par[@intCast(b)];
        par_mapped[2 * @as(usize, @intCast(b))] = par[@intCast(b)];
    }
}

fn mapIdx34To20(par_mapped: *[34]i8, par: *const [34]i8, full: bool) void {
    par_mapped[0] = @intCast(@divTrunc(2 * @as(i32, par[0]) + @as(i32, par[1]), 3));
    par_mapped[1] = @intCast(@divTrunc(@as(i32, par[1]) + 2 * @as(i32, par[2]), 3));
    par_mapped[2] = @intCast(@divTrunc(2 * @as(i32, par[3]) + @as(i32, par[4]), 3));
    par_mapped[3] = @intCast(@divTrunc(@as(i32, par[4]) + 2 * @as(i32, par[5]), 3));
    par_mapped[4] = @intCast(@divTrunc(@as(i32, par[6]) + @as(i32, par[7]), 2));
    par_mapped[5] = @intCast(@divTrunc(@as(i32, par[8]) + @as(i32, par[9]), 2));
    par_mapped[6] = par[10];
    par_mapped[7] = par[11];
    par_mapped[8] = @intCast(@divTrunc(@as(i32, par[12]) + @as(i32, par[13]), 2));
    par_mapped[9] = @intCast(@divTrunc(@as(i32, par[14]) + @as(i32, par[15]), 2));
    par_mapped[10] = par[16];
    if (full) {
        par_mapped[11] = par[17];
        par_mapped[12] = par[18];
        par_mapped[13] = par[19];
        par_mapped[14] = @intCast(@divTrunc(@as(i32, par[20]) + @as(i32, par[21]), 2));
        par_mapped[15] = @intCast(@divTrunc(@as(i32, par[22]) + @as(i32, par[23]), 2));
        par_mapped[16] = @intCast(@divTrunc(@as(i32, par[24]) + @as(i32, par[25]), 2));
        par_mapped[17] = @intCast(@divTrunc(@as(i32, par[26]) + @as(i32, par[27]), 2));
        par_mapped[18] = @intCast(@divTrunc(@as(i32, par[28]) + @as(i32, par[29]) + @as(i32, par[30]) + @as(i32, par[31]), 4));
        par_mapped[19] = @intCast(@divTrunc(@as(i32, par[32]) + @as(i32, par[33]), 2));
    }
}

fn mapIdx10To34(par_mapped: *[34]i8, par: *const [34]i8, full: bool) void {
    if (full) {
        par_mapped[33] = par[9];
        par_mapped[32] = par[9];
        par_mapped[31] = par[9];
        par_mapped[30] = par[9];
        par_mapped[29] = par[9];
        par_mapped[28] = par[9];
        par_mapped[27] = par[8];
        par_mapped[26] = par[8];
        par_mapped[25] = par[8];
        par_mapped[24] = par[8];
        par_mapped[23] = par[7];
        par_mapped[22] = par[7];
        par_mapped[21] = par[7];
        par_mapped[20] = par[7];
        par_mapped[19] = par[6];
        par_mapped[18] = par[6];
        par_mapped[17] = par[5];
        par_mapped[16] = par[5];
    } else {
        par_mapped[16] = 0;
    }
    par_mapped[15] = par[4];
    par_mapped[14] = par[4];
    par_mapped[13] = par[4];
    par_mapped[12] = par[4];
    par_mapped[11] = par[3];
    par_mapped[10] = par[3];
    par_mapped[9] = par[2];
    par_mapped[8] = par[2];
    par_mapped[7] = par[2];
    par_mapped[6] = par[2];
    par_mapped[5] = par[1];
    par_mapped[4] = par[1];
    par_mapped[3] = par[1];
    par_mapped[2] = par[0];
    par_mapped[1] = par[0];
    par_mapped[0] = par[0];
}

fn mapIdx20To34(par_mapped: *[34]i8, par: *const [34]i8, full: bool) void {
    if (full) {
        par_mapped[33] = par[19];
        par_mapped[32] = par[19];
        par_mapped[31] = par[18];
        par_mapped[30] = par[18];
        par_mapped[29] = par[18];
        par_mapped[28] = par[18];
        par_mapped[27] = par[17];
        par_mapped[26] = par[17];
        par_mapped[25] = par[16];
        par_mapped[24] = par[16];
        par_mapped[23] = par[15];
        par_mapped[22] = par[15];
        par_mapped[21] = par[14];
        par_mapped[20] = par[14];
        par_mapped[19] = par[13];
        par_mapped[18] = par[12];
        par_mapped[17] = par[11];
    }
    par_mapped[16] = par[10];
    par_mapped[15] = par[9];
    par_mapped[14] = par[9];
    par_mapped[13] = par[8];
    par_mapped[12] = par[8];
    par_mapped[11] = par[7];
    par_mapped[10] = par[6];
    par_mapped[9] = par[5];
    par_mapped[8] = par[5];
    par_mapped[7] = par[4];
    par_mapped[6] = par[4];
    par_mapped[5] = par[3];
    par_mapped[4] = @intCast(@divTrunc(@as(i32, par[2]) + @as(i32, par[3]), 2));
    par_mapped[3] = par[2];
    par_mapped[2] = par[1];
    par_mapped[1] = @intCast(@divTrunc(@as(i32, par[0]) + @as(i32, par[1]), 2));
    par_mapped[0] = par[0];
}

fn mapVal20To34(par: *[34]f32) void {
    // 顺序敏感：从高到低
    par[33] = par[19];
    par[32] = par[19];
    par[31] = par[18];
    par[30] = par[18];
    par[29] = par[18];
    par[28] = par[18];
    par[27] = par[17];
    par[26] = par[17];
    par[25] = par[16];
    par[24] = par[16];
    par[23] = par[15];
    par[22] = par[15];
    par[21] = par[14];
    par[20] = par[14];
    par[19] = par[13];
    par[18] = par[12];
    par[17] = par[11];
    par[16] = par[10];
    par[15] = par[9];
    par[14] = par[9];
    par[13] = par[8];
    par[12] = par[8];
    par[11] = par[7];
    par[10] = par[6];
    par[9] = par[5];
    par[8] = par[5];
    par[7] = par[4];
    par[6] = par[4];
    par[5] = par[3];
    par[4] = (par[2] + par[3]) * 0.5;
    par[3] = par[2];
    par[2] = par[1];
    par[1] = (par[0] + par[1]) * 0.5;
    par[0] = par[0];
}

fn mapVal34To20(par: *[34]f32) void {
    par[0] = (2 * par[0] + par[1]) * 0.33333333;
    par[1] = (par[1] + 2 * par[2]) * 0.33333333;
    par[2] = (2 * par[3] + par[4]) * 0.33333333;
    par[3] = (par[4] + 2 * par[5]) * 0.33333333;
    par[4] = (par[6] + par[7]) * 0.5;
    par[5] = (par[8] + par[9]) * 0.5;
    par[6] = par[10];
    par[7] = par[11];
    par[8] = (par[12] + par[13]) * 0.5;
    par[9] = (par[14] + par[15]) * 0.5;
    par[10] = par[16];
    par[11] = par[17];
    par[12] = par[18];
    par[13] = par[19];
    par[14] = (par[20] + par[21]) * 0.5;
    par[15] = (par[22] + par[23]) * 0.5;
    par[16] = (par[24] + par[25]) * 0.5;
    par[17] = (par[26] + par[27]) * 0.5;
    par[18] = (par[28] + par[29] + par[30] + par[31]) * 0.25;
    par[19] = (par[32] + par[33]) * 0.5;
}

fn ipdopdReset(ipd_hist: *[PS_MAX_NR_IIDICC]i8, opd_hist: *[PS_MAX_NR_IIDICC]i8) void {
    @memset(ipd_hist, 0);
    @memset(opd_hist, 0);
}

// ---------------- hybrid_analysis（混合分析） ----------------

fn hybridAnalysis(self: *PSCtx, L: *const [2][38][64]f32, is34: bool) void {
    const len: usize = 32;
    const in_buf = &self.in_buf;
    // 1) 前 5 个 QMF 子带填入 in_buf 时隙 6..43
    for (0..5) |i| {
        for (0..38) |j| {
            in_buf[i][j + 6][0] = L[0][j][i];
            in_buf[i][j + 6][1] = L[1][j][i];
        }
    }

    if (is34) {
        // hybrid4_8_12_cx：每个 in[i] 处理 len 个时隙
        // 由于时隙维是 32，且 hybrid 滤波器对每个时隙独立（用 in 的 13 个抽头），
        // 我们需要逐时隙处理。C 的 hybrid4_8_12_cx(dsp, in[0], out, f34_0_12, 12, len)
        // 内部对每个时隙 i 调 hybrid_analysis(temp, in+i, ...)。
        for (0..len) |n| {
            var tmp0: [12][2]f32 = undefined;
            // in[0] 在时隙 n 的 13 抽头窗口：in_buf[0][n+6 .. n+6+13] 的复共轭窗口
            var win: [13][2]f32 = undefined;
            for (0..13) |t| {
                win[t][0] = in_buf[0][n + t][0];
                win[t][1] = in_buf[0][n + t][1];
            }
            psHybridAnalysis(@as([*]f32, @ptrCast(&tmp0))[0 .. 2 * 12], &win, pst.f34_0_12[0..], 12);
            for (0..12) |b| {
                self.Lbuf[b][n][0] = tmp0[b][0];
                self.Lbuf[b][n][1] = tmp0[b][1];
            }
            // in[1]
            var tmp1: [8][2]f32 = undefined;
            for (0..13) |t| {
                win[t][0] = in_buf[1][n + t][0];
                win[t][1] = in_buf[1][n + t][1];
            }
            psHybridAnalysis(@as([*]f32, @ptrCast(&tmp1))[0 .. 2 * 8], &win, pst.f34_1_8[0..], 8);
            for (0..8) |b| {
                self.Lbuf[12 + b][n][0] = tmp1[b][0];
                self.Lbuf[12 + b][n][1] = tmp1[b][1];
            }
            // in[2..4] 用 f34_2_4
            for (0..3) |sub| {
                var tmp: [4][2]f32 = undefined;
                for (0..13) |t| {
                    win[t][0] = in_buf[sub + 2][n + t][0];
                    win[t][1] = in_buf[sub + 2][n + t][1];
                }
                psHybridAnalysis(@as([*]f32, @ptrCast(&tmp))[0 .. 2 * 4], &win, pst.f34_2_4[0..], 4);
                for (0..4) |b| {
                    self.Lbuf[20 + sub * 4 + b][n][0] = tmp[b][0];
                    self.Lbuf[20 + sub * 4 + b][n][1] = tmp[b][1];
                }
            }
        }
        // QMF 带 5..63 透传
        psHybridAnalysisIleave(&self.Lbuf, L, 5, len, 27);
    } else {
        for (0..len) |n| {
            var win: [13][2]f32 = undefined;
            for (0..13) |t| {
                win[t][0] = in_buf[0][n + t][0];
                win[t][1] = in_buf[0][n + t][1];
            }
            // hybrid6_cx：8 输出合并成 6
            var tmp: [8][2]f32 = undefined;
            psHybridAnalysis(@as([*]f32, @ptrCast(&tmp))[0 .. 2 * 8], &win, pst.f20_0_8[0..], 8);
            self.Lbuf[0][n] = tmp[6];
            self.Lbuf[1][n] = tmp[7];
            self.Lbuf[2][n] = tmp[0];
            self.Lbuf[3][n] = tmp[1];
            self.Lbuf[4][n] = .{ tmp[2][0] + tmp[5][0], tmp[2][1] + tmp[5][1] };
            self.Lbuf[5][n] = .{ tmp[3][0] + tmp[4][0], tmp[3][1] + tmp[4][1] };
            // hybrid2_re：in[1], in[2]
            for (0..13) |t| {
                win[t][0] = in_buf[1][n + t][0];
                win[t][1] = in_buf[1][n + t][1];
            }
            var out2: [2][2]f32 = undefined;
            const re_in: f32 = pst.g1_Q2[6] * win[6][0];
            const im_in: f32 = pst.g1_Q2[6] * win[6][1];
            var re_op: f32 = 0;
            var im_op: f32 = 0;
            var j: usize = 0;
            while (j < 6) : (j += 2) {
                re_op += pst.g1_Q2[j + 1] * (win[j + 1][0] + win[12 - j - 1][0]);
                im_op += pst.g1_Q2[j + 1] * (win[j + 1][1] + win[12 - j - 1][1]);
            }
            out2[1][0] = re_in + re_op;
            out2[1][1] = im_in + im_op;
            out2[0][0] = re_in - re_op;
            out2[0][1] = im_in - im_op;
            self.Lbuf[7][n] = out2[1];
            self.Lbuf[6][n] = out2[0];
            // in[2]
            for (0..13) |t| {
                win[t][0] = in_buf[2][n + t][0];
                win[t][1] = in_buf[2][n + t][1];
            }
            const re_in2: f32 = pst.g1_Q2[6] * win[6][0];
            const im_in2: f32 = pst.g1_Q2[6] * win[6][1];
            var re_op2: f32 = 0;
            var im_op2: f32 = 0;
            j = 0;
            while (j < 6) : (j += 2) {
                re_op2 += pst.g1_Q2[j + 1] * (win[j + 1][0] + win[12 - j - 1][0]);
                im_op2 += pst.g1_Q2[j + 1] * (win[j + 1][1] + win[12 - j - 1][1]);
            }
            out2[1][0] = re_in2 + re_op2;
            out2[1][1] = im_in2 + im_op2;
            out2[0][0] = re_in2 - re_op2;
            out2[0][1] = im_in2 - im_op2;
            self.Lbuf[8][n] = out2[1];
            self.Lbuf[9][n] = out2[0];
        }
        psHybridAnalysisIleave(&self.Lbuf, L, 3, len, 7);
    }
    // 2) 滑动 in_buf：时隙 32..37 → 0..5
    for (0..5) |i| {
        for (0..6) |j| {
            in_buf[i][j][0] = in_buf[i][j + 32][0];
            in_buf[i][j][1] = in_buf[i][j + 32][1];
        }
    }
}

// ---------------- decorrelation（去相关） ----------------

fn decorrelation(self: *PSCtx, is34: bool) void {
    const n0: usize = 0;
    const nL: usize = 32;
    var power: [34][32]f32 = [_][32]f32{[_]f32{0} ** 32} ** 34;
    var transient_gain: [34][32]f32 = undefined;
    const peak_decay_factor: f32 = 0.76592833836465;

    if (@as(i32, @intFromBool(is34)) != self.common.is34bands_old) {
        @memset(self.peak_decay_nrg[0..], 0);
        @memset(self.power_smooth[0..], 0);
        @memset(self.peak_decay_diff_smooth[0..], 0);
        @memset(@as([*]u8, @ptrCast(&self.delay))[0 .. @sizeOf(@TypeOf(self.delay))], 0);
        @memset(@as([*]u8, @ptrCast(&self.ap_delay))[0 .. @sizeOf(@TypeOf(self.ap_delay))], 0);
    }

    // 1) 功率累加
    const n_bands = NR_BANDS[@intFromBool(is34)];
    const k_to_i: []const i8 = if (is34) &pst.ff_k_to_i_34 else &pst.ff_k_to_i_20;
    for (0..n_bands) |k| {
        const i: usize = @intCast(k_to_i[k]);
        psAddSquares(power[i][0..32], &self.Lbuf[k]);
    }

    // 2) 瞬态检测
    const n_par = NR_PAR_BANDS[@intFromBool(is34)];
    for (0..n_par) |i| {
        for (n0..nL) |n| {
            const decayed_peak = peak_decay_factor * self.peak_decay_nrg[i];
            self.peak_decay_nrg[i] = @max(decayed_peak, power[i][n]);
            self.power_smooth[i] += 0.25 * (power[i][n] - self.power_smooth[i]);
            self.peak_decay_diff_smooth[i] += 0.25 * (self.peak_decay_nrg[i] - power[i][n] - self.peak_decay_diff_smooth[i]);
            const denom = 1.5 * self.peak_decay_diff_smooth[i];
            transient_gain[i][n] = if (denom > self.power_smooth[i]) self.power_smooth[i] / denom else 1.0;
        }
    }

    // 3) 延迟线维护 + 三个区域
    for (0..n_bands) |k| {
        // 延迟线移位
        var tmp_delay: [PS_MAX_DELAY][2]f32 = undefined;
        for (0..PS_MAX_DELAY) |m| {
            tmp_delay[m][0] = self.delay[k][m + nL][0];
            tmp_delay[m][1] = self.delay[k][m + nL][1];
        }
        for (0..PS_QMF_TIME_SLOTS) |n| {
            self.delay[k][n + PS_MAX_DELAY][0] = self.Lbuf[k][n][0];
            self.delay[k][n + PS_MAX_DELAY][1] = self.Lbuf[k][n][1];
        }
        for (0..PS_MAX_DELAY) |m| {
            self.delay[k][m][0] = tmp_delay[m][0];
            self.delay[k][m][1] = tmp_delay[m][1];
        }

        const i: usize = @intCast(k_to_i[k]);
        if (k < NR_ALLPASS_BANDS[@intFromBool(is34)]) {
            // ap_delay 移位（仅区域 A）
            for (0..PS_AP_LINKS) |m| {
                var tmp_ap: [5][2]f32 = undefined;
                for (0..5) |j| {
                    tmp_ap[j][0] = self.ap_delay[k][m][j + nL][0];
                    tmp_ap[j][1] = self.ap_delay[k][m][j + nL][1];
                }
                for (0..5) |j| {
                    self.ap_delay[k][m][j][0] = tmp_ap[j][0];
                    self.ap_delay[k][m][j][1] = tmp_ap[j][1];
                }
            }
            // 区域 A：全通
            const ki: i32 = @intCast(k);
            const cutoff: i32 = @intCast(DECAY_CUTOFF[@intFromBool(is34)]);
            const gds: f32 = std.math.clamp(1.0 - pst.DECAY_SLOPE * @as(f32, @floatFromInt(ki - cutoff)), 0.0, 1.0);
            // delay[k]+12：读 delay[12..43]
            var d12: [32][2]f32 = undefined;
            for (0..32) |n| {
                d12[n][0] = self.delay[k][n + 12][0];
                d12[n][1] = self.delay[k][n + 12][1];
            }
            psDecorrelate(&self.Rbuf[k], &d12, &self.ap_delay[k], pst.phi_fract[@intFromBool(is34)][k], &pst.Q_fract_allpass[@intFromBool(is34)][k], &transient_gain[i], gds);
        } else if (k < SHORT_DELAY_BAND[@intFromBool(is34)]) {
            // 区域 B：延迟 14
            var d0: [32][2]f32 = undefined;
            for (0..32) |n| {
                d0[n][0] = self.delay[k][n][0];
                d0[n][1] = self.delay[k][n][1];
            }
            psMulPairSingle(&self.Rbuf[k], &d0, &transient_gain[i]);
        } else {
            // 区域 C：延迟 1
            var d13: [32][2]f32 = undefined;
            for (0..32) |n| {
                d13[n][0] = self.delay[k][n + 13][0];
                d13[n][1] = self.delay[k][n + 13][1];
            }
            psMulPairSingle(&self.Rbuf[k], &d13, &transient_gain[i]);
        }
    }
}

// ---------------- stereo_processing（立体声处理） ----------------

fn stereoProcessing(self: *PSCtx, is34: bool) void {
    const ps2 = &self.common;
    const H_LUT: *const [46][8][4]f32 = if (ps2.icc_mode < 3) &pst.HA else &pst.HB;

    // 4.1 上一帧末包络拷贝到槽 0
    if (ps2.num_env_old != 0) {
        const ne: usize = @intCast(ps2.num_env_old);
        for (0..2) |layer| {
            @memcpy(self.H11[layer][0][0..34], self.H11[layer][ne][0..34]);
            @memcpy(self.H12[layer][0][0..34], self.H12[layer][ne][0..34]);
            @memcpy(self.H21[layer][0][0..34], self.H21[layer][ne][0..34]);
            @memcpy(self.H22[layer][0][0..34], self.H22[layer][ne][0..34]);
        }
    }

    // 参数带重映射
    var iid_mapped_buf: [PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]i8 = undefined;
    var icc_mapped_buf: [PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]i8 = undefined;
    var ipd_mapped_buf: [PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]i8 = undefined;
    var opd_mapped_buf: [PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]i8 = undefined;
    var iid_mapped: [*][PS_MAX_NR_IIDICC]i8 = &iid_mapped_buf;
    var icc_mapped: [*][PS_MAX_NR_IIDICC]i8 = &icc_mapped_buf;
    var ipd_mapped: [*][PS_MAX_NR_IIDICC]i8 = &ipd_mapped_buf;
    var opd_mapped: [*][PS_MAX_NR_IIDICC]i8 = &opd_mapped_buf;

    if (is34) {
        remap34(self, &iid_mapped, &ps2.iid_par, @intCast(ps2.nr_iid_par), @intCast(ps2.num_env), true);
        remap34(self, &icc_mapped, &ps2.icc_par, @intCast(ps2.nr_icc_par), @intCast(ps2.num_env), true);
        if (ps2.enable_ipdopd != 0) {
            remap34(self, &ipd_mapped, &ps2.ipd_par, @intCast(ps2.nr_ipdopd_par), @intCast(ps2.num_env), false);
            remap34(self, &opd_mapped, &ps2.opd_par, @intCast(ps2.nr_ipdopd_par), @intCast(ps2.num_env), false);
        }
        if (ps2.is34bands_old == 0) {
            for (0..2) |layer| {
                mapVal20To34(&self.H11[layer][0]);
                mapVal20To34(&self.H12[layer][0]);
                mapVal20To34(&self.H21[layer][0]);
                mapVal20To34(&self.H22[layer][0]);
            }
            ipdopdReset(&self.ipd_hist, &self.opd_hist);
        }
    } else {
        remap20(self, &iid_mapped, &ps2.iid_par, @intCast(ps2.nr_iid_par), @intCast(ps2.num_env), true);
        remap20(self, &icc_mapped, &ps2.icc_par, @intCast(ps2.nr_icc_par), @intCast(ps2.num_env), true);
        if (ps2.enable_ipdopd != 0) {
            remap20(self, &ipd_mapped, &ps2.ipd_par, @intCast(ps2.nr_ipdopd_par), @intCast(ps2.num_env), false);
            remap20(self, &opd_mapped, &ps2.opd_par, @intCast(ps2.nr_ipdopd_par), @intCast(ps2.num_env), false);
        }
        if (ps2.is34bands_old != 0) {
            for (0..2) |layer| {
                mapVal34To20(&self.H11[layer][0]);
                mapVal34To20(&self.H12[layer][0]);
                mapVal34To20(&self.H21[layer][0]);
                mapVal34To20(&self.H22[layer][0]);
            }
            ipdopdReset(&self.ipd_hist, &self.opd_hist);
        }
    }

    // 4.3 H 系数生成（外层 env 循环）
    var e: usize = 0;
    while (e < @as(usize, @intCast(ps2.num_env))) : (e += 1) {
        const n_par = NR_PAR_BANDS[@intFromBool(is34)];
        const n_ipdopd = NR_IPDOPD_BANDS[@intFromBool(is34)];
        for (0..n_par) |b| {
            var h11: f32 = undefined;
            var h12: f32 = undefined;
            var h21: f32 = undefined;
            var h22: f32 = undefined;
            const row: usize = @intCast(@as(i32, iid_mapped[e][b]) + 7 + 23 * ps2.iid_quant);
            const icc: usize = @intCast(icc_mapped[e][b]);
            h11 = H_LUT[row][icc][0];
            h12 = H_LUT[row][icc][1];
            h21 = H_LUT[row][icc][2];
            h22 = H_LUT[row][icc][3];

            if (ps2.enable_ipdopd != 0 and b < n_ipdopd) {
                var h11i: f32 = undefined;
                var h12i: f32 = undefined;
                var h21i: f32 = undefined;
                var h22i: f32 = undefined;
                var ipd_adj_re: f32 = undefined;
                var ipd_adj_im: f32 = undefined;
                const opd_idx = @as(usize, @intCast(@as(i32, self.opd_hist[b]) * 8 + opd_mapped[e][b]));
                const ipd_idx = @as(usize, @intCast(@as(i32, self.ipd_hist[b]) * 8 + ipd_mapped[e][b]));
                const opd_re = pst.pd_re_smooth[opd_idx];
                const opd_im = pst.pd_im_smooth[opd_idx];
                const ipd_re = pst.pd_re_smooth[ipd_idx];
                const ipd_im = pst.pd_im_smooth[ipd_idx];
                self.opd_hist[b] = @intCast(opd_idx & 0x3F);
                self.ipd_hist[b] = @intCast(ipd_idx & 0x3F);

                ipd_adj_re = opd_re * ipd_re + opd_im * ipd_im;
                ipd_adj_im = opd_im * ipd_re - opd_re * ipd_im;
                h11i = h11 * opd_im;
                h11 = h11 * opd_re;
                h12i = h12 * ipd_adj_im;
                h12 = h12 * ipd_adj_re;
                h21i = h21 * opd_im;
                h21 = h21 * opd_re;
                h22i = h22 * ipd_adj_im;
                h22 = h22 * ipd_adj_re;
                self.H11[1][e + 1][b] = h11i;
                self.H12[1][e + 1][b] = h12i;
                self.H21[1][e + 1][b] = h21i;
                self.H22[1][e + 1][b] = h22i;
            }
            self.H11[0][e + 1][b] = h11;
            self.H12[0][e + 1][b] = h12;
            self.H21[0][e + 1][b] = h21;
            self.H22[0][e + 1][b] = h22;
        }
    }

    // 4.4 包络间插值 + 应用
    const n_bands = NR_BANDS[@intFromBool(is34)];
    const k_to_i: []const i8 = if (is34) &pst.ff_k_to_i_34 else &pst.ff_k_to_i_20;
    e = 0;
    while (e < @as(usize, @intCast(ps2.num_env))) : (e += 1) {
        const start: i32 = ps2.border_position[e];
        const stop: i32 = ps2.border_position[e + 1];
        const width: f32 = 1.0 / @as(f32, @floatFromInt(if (stop - start != 0) stop - start else 1));
        for (0..n_bands) |k| {
            const b: usize = @intCast(k_to_i[k]);
            var h: [2][4]f32 = undefined;
            var h_step: [2][4]f32 = undefined;

            h[0][0] = self.H11[0][e][b];
            h[0][1] = self.H12[0][e][b];
            h[0][2] = self.H21[0][e][b];
            h[0][3] = self.H22[0][e][b];
            if (ps2.enable_ipdopd != 0) {
                const negate = (is34 and k >= 9 and k <= 13) or (!is34 and k <= 1);
                const sign: f32 = if (negate) -1.0 else 1.0;
                h[1][0] = sign * self.H11[1][e][b];
                h[1][1] = sign * self.H12[1][e][b];
                h[1][2] = sign * self.H21[1][e][b];
                h[1][3] = sign * self.H22[1][e][b];
            }
            h_step[0][0] = (self.H11[0][e + 1][b] - h[0][0]) * width;
            h_step[0][1] = (self.H12[0][e + 1][b] - h[0][1]) * width;
            h_step[0][2] = (self.H21[0][e + 1][b] - h[0][2]) * width;
            h_step[0][3] = (self.H22[0][e + 1][b] - h[0][3]) * width;
            if (ps2.enable_ipdopd != 0) {
                h_step[1][0] = (self.H11[1][e + 1][b] - h[1][0]) * width;
                h_step[1][1] = (self.H12[1][e + 1][b] - h[1][1]) * width;
                h_step[1][2] = (self.H21[1][e + 1][b] - h[1][2]) * width;
                h_step[1][3] = (self.H22[1][e + 1][b] - h[1][3]) * width;
            }
            const d = stop - start;
            if (d != 0) {
                const off: usize = @intCast(start + 1);
                var lseg: [32][2]f32 = undefined;
                var rseg: [32][2]f32 = undefined;
                for (0..@as(usize, @intCast(d))) |t| {
                    lseg[t][0] = self.Lbuf[k][off + t][0];
                    lseg[t][1] = self.Lbuf[k][off + t][1];
                    rseg[t][0] = self.Rbuf[k][off + t][0];
                    rseg[t][1] = self.Rbuf[k][off + t][1];
                }
                if (ps2.enable_ipdopd != 0) {
                    psStereoInterpolateIpdopd(&lseg, &rseg, &h, &h_step, @intCast(d));
                } else {
                    psStereoInterpolate(&lseg, &rseg, &h, &h_step, @intCast(d));
                }
                for (0..@as(usize, @intCast(d))) |t| {
                    self.Lbuf[k][off + t][0] = lseg[t][0];
                    self.Lbuf[k][off + t][1] = lseg[t][1];
                    self.Rbuf[k][off + t][0] = rseg[t][0];
                    self.Rbuf[k][off + t][1] = rseg[t][1];
                }
            }
        }
    }
}

fn remap34(self: *PSCtx, p_par_mapped: *[*][PS_MAX_NR_IIDICC]i8, par: *const [PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]i8, num_par: usize, num_env: usize, full: bool) void {
    _ = self;
    if (num_par == 20 or num_par == 11) {
        for (0..num_env) |e| {
            mapIdx20To34(&p_par_mapped.*[e], &par[e], full);
        }
    } else if (num_par == 10 or num_par == 5) {
        for (0..num_env) |e| {
            mapIdx10To34(&p_par_mapped.*[e], &par[e], full);
        }
    } else {
        p_par_mapped.* = @constCast(par);
    }
}

fn remap20(self: *PSCtx, p_par_mapped: *[*][PS_MAX_NR_IIDICC]i8, par: *const [PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]i8, num_par: usize, num_env: usize, full: bool) void {
    _ = self;
    if (num_par == 34 or num_par == 17) {
        for (0..num_env) |e| {
            mapIdx34To20(&p_par_mapped.*[e], &par[e], full);
        }
    } else if (num_par == 10 or num_par == 5) {
        for (0..num_env) |e| {
            mapIdx10To20(&p_par_mapped.*[e], &par[e], full);
        }
    } else {
        p_par_mapped.* = @constCast(par);
    }
}

// ---------------- hybrid_synthesis（混合合成） ----------------

fn hybridSynthesis(_: *PSCtx, out: *[2][38][64]f32, in_: *const [91][32][2]f32, is34: bool) void {
    const len: usize = 32;
    if (is34) {
        for (0..len) |n| {
            for (0..5) |i| {
                out[0][n][i] = 0;
                out[1][n][i] = 0;
            }
            for (0..12) |i| {
                out[0][n][0] += in_[i][n][0];
                out[1][n][0] += in_[i][n][1];
            }
            for (0..8) |i| {
                out[0][n][1] += in_[12 + i][n][0];
                out[1][n][1] += in_[12 + i][n][1];
            }
            for (0..4) |i| {
                out[0][n][2] += in_[20 + i][n][0];
                out[1][n][2] += in_[20 + i][n][1];
                out[0][n][3] += in_[24 + i][n][0];
                out[1][n][3] += in_[24 + i][n][1];
                out[0][n][4] += in_[28 + i][n][0];
                out[1][n][4] += in_[28 + i][n][1];
            }
        }
        psHybridSynthesisDeint(out, in_, 5, len, 27);
    } else {
        for (0..len) |n| {
            out[0][n][0] = in_[0][n][0] + in_[1][n][0] + in_[2][n][0] + in_[3][n][0] + in_[4][n][0] + in_[5][n][0];
            out[1][n][0] = in_[0][n][1] + in_[1][n][1] + in_[2][n][1] + in_[3][n][1] + in_[4][n][1] + in_[5][n][1];
            out[0][n][1] = in_[6][n][0] + in_[7][n][0];
            out[1][n][1] = in_[6][n][1] + in_[7][n][1];
            out[0][n][2] = in_[8][n][0] + in_[9][n][0];
            out[1][n][2] = in_[8][n][1] + in_[9][n][1];
        }
        psHybridSynthesisDeint(out, in_, 3, len, 7);
    }
}

// ---------------- ff_ps_apply ----------------

/// PS 应用：L（mono）→ L/R（立体声）。L/R 为 [2][38][64] QMF 域。
pub fn psApply(self: *PSCtx, L: *[2][38][64]f32, R: *[2][38][64]f32, top_in: usize) void {
    const is34 = self.common.is34bands != 0;

    const n_bands = NR_BANDS[@intFromBool(is34)];
    const top = top_in + n_bands - 64;

    // 高于 SBR 顶带的子子带清零
    for (top..n_bands) |k| {
        for (0..PS_QMF_TIME_SLOTS + PS_MAX_DELAY) |n| {
            self.delay[k][n][0] = 0;
            self.delay[k][n][1] = 0;
        }
    }
    if (top < NR_ALLPASS_BANDS[@intFromBool(is34)]) {
        for (top..NR_ALLPASS_BANDS[@intFromBool(is34)]) |k| {
            for (0..PS_AP_LINKS) |m| {
                for (0..PS_QMF_TIME_SLOTS + PS_MAX_AP_DELAY) |n| {
                    self.ap_delay[k][m][n][0] = 0;
                    self.ap_delay[k][m][n][1] = 0;
                }
            }
        }
    }

    hybridAnalysis(self, L, is34);

    decorrelation(self, is34);
    stereoProcessing(self, is34);

    hybridSynthesis(self, L, &self.Lbuf, is34);
    hybridSynthesis(self, R, &self.Rbuf, is34);
    self.common.is34bands_old = @intFromBool(is34);
}

test "ps basics" {
    var ps: PSCtx = undefined;
    psInit(&ps);
    try std.testing.expect(pst.HA[30][3][0] != 0);
    try std.testing.expect(ps.common.num_env == 0);
}

