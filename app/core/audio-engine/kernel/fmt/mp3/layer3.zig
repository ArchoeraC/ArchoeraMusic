//! Layer III 解码（对标 minimp3 标量路径，CC0）。
//! 含 side info、scalefactor、huffman、requant、stereo、reorder、antialias、IMDCT。

const std = @import("std");
const hdr = @import("header.zig");
const br = @import("bitreader.zig");
const ht = @import("huffman_tables.zig");
const t = @import("layer3_tables.zig");

pub const SHORT_BLOCK_TYPE: u8 = 2;
pub const STOP_BLOCK_TYPE: u8 = 3;
pub const BITS_DEQUANTIZER_OUT: i32 = -1;
pub const MAX_SCF: i32 = 255 + BITS_DEQUANTIZER_OUT * 4 - 210;
pub const MAX_SCFI: i32 = (MAX_SCF + 3) & ~@as(i32, 3);

pub const MAX_BITRESERVOIR_BYTES: usize = 511;
pub const MAX_L3_FRAME_PAYLOAD_BYTES: usize = 2304;

pub const GrInfo = struct {
    sfbtab: [40]u8 = undefined,
    part_23_length: u16 = 0,
    big_values: u16 = 0,
    scalefac_compress: u16 = 0,
    global_gain: u8 = 0,
    block_type: u8 = 0,
    mixed_block_flag: u8 = 0,
    n_long_sfb: u8 = 0,
    n_short_sfb: u8 = 0,
    table_select: [3]u8 = .{ 0, 0, 0 },
    region_count: [3]u8 = .{ 0, 0, 0 },
    subblock_gain: [3]u8 = .{ 0, 0, 0 },
    preflag: u8 = 0,
    scalefac_scale: u8 = 0,
    count1_table: u8 = 0,
    scfsi: u8 = 0,
};

pub const DecoderState = struct {
    mdct_overlap: [2][9 * 32]f32 = .{ .{0} ** (9 * 32) } ** 2,
    qmf_state: [15 * 2 * 32]f32 = .{0} ** (15 * 2 * 32),
    reserv: i32 = 0,
    free_format_bytes: i32 = 0,
    header: [4]u8 = .{ 0, 0, 0, 0 },
    reserv_buf: [511]u8 = .{0} ** 511,
};

const Scratch = struct {
    bs: br.BitReader = undefined,
    maindata: [MAX_BITRESERVOIR_BYTES + MAX_L3_FRAME_PAYLOAD_BYTES]u8 = undefined,
    gr_info: [4]GrInfo = undefined,
    grbuf: [2][576]f32 = undefined,
    scf: [40]f32 = undefined,
    syn: [18 + 15][2 * 32]f32 = undefined,
    ist_pos: [2][39]u8 = undefined,
};

fn hdrIsCrc(h: []const u8) bool {
    return (h[1] & 1) == 0;
}

// ---------------------------------------------------------------------------
// side info
// ---------------------------------------------------------------------------

fn readSideInfo(bs: *br.BitReader, gr: []GrInfo, h: []const u8) i32 {
    var scfsi: u32 = 0;
    var part_23_sum: i32 = 0;
    var sr_idx: i32 = @intCast(hdr.hdrGetMySampleRate(h));
    sr_idx -= @intFromBool(sr_idx != 0);
    var gr_count: i32 = if (hdr.hdrIsMono(h)) 1 else 2;
    var main_data_begin: i32 = 0;

    if (hdr.hdrTestMPEG1(h)) {
        gr_count *= 2;
        main_data_begin = @intCast(bs.getBits(9));
        scfsi = bs.getBits(7 + @as(u32, @intCast(gr_count)));
    } else {
        main_data_begin = @intCast(@as(i32, @intCast(bs.getBits(8 + @as(u32, @intCast(gr_count))))) >> @intCast(gr_count));
    }

    var gi: usize = 0;
    while (gr_count > 0) : (gr_count -= 1) {
        const g = &gr[gi];
        gi += 1;
        if (hdr.hdrIsMono(h)) scfsi <<= 4;
        g.part_23_length = @intCast(bs.getBits(12));
        part_23_sum += @as(i32, g.part_23_length);
        g.big_values = @intCast(bs.getBits(9));
        if (g.big_values > 288) return -1;
        g.global_gain = @intCast(bs.getBits(8));
        g.scalefac_compress = @intCast(bs.getBits(if (hdr.hdrTestMPEG1(h)) 4 else 9));
        @memset(g.sfbtab[0..40], 0);
        @memcpy(g.sfbtab[0..23], &t.scf_long[@intCast(sr_idx)]);
        g.n_long_sfb = 22;
        g.n_short_sfb = 0;
        if (bs.getBits(1) != 0) {
            g.block_type = @intCast(bs.getBits(2));
            if (g.block_type == 0) return -1;
            g.mixed_block_flag = @intCast(bs.getBits(1));
            g.region_count[0] = 7;
            g.region_count[1] = 255;
            if (g.block_type == SHORT_BLOCK_TYPE) {
                scfsi &= 0x0F0F;
                if (g.mixed_block_flag == 0) {
                    g.region_count[0] = 8;
                    @memcpy(g.sfbtab[0..40], &t.scf_short[@intCast(sr_idx)]);
                    g.n_long_sfb = 0;
                    g.n_short_sfb = 39;
                } else {
                    @memcpy(g.sfbtab[0..40], &t.scf_mixed[@intCast(sr_idx)]);
                    g.n_long_sfb = if (hdr.hdrTestMPEG1(h)) 8 else 6;
                    g.n_short_sfb = 30;
                }
            }
            var tables: u32 = bs.getBits(10);
            tables <<= 5;
            g.subblock_gain[0] = @intCast(bs.getBits(3));
            g.subblock_gain[1] = @intCast(bs.getBits(3));
            g.subblock_gain[2] = @intCast(bs.getBits(3));
            g.table_select[0] = @intCast((tables >> 10) & 31);
            g.table_select[1] = @intCast((tables >> 5) & 31);
            g.table_select[2] = @intCast(tables & 31);
            g.preflag = if (hdr.hdrTestMPEG1(h)) @intCast(bs.getBits(1)) else @intFromBool(g.scalefac_compress >= 500);
            g.scalefac_scale = @intCast(bs.getBits(1));
            g.count1_table = @intCast(bs.getBits(1));
        } else {
            g.block_type = 0;
            g.mixed_block_flag = 0;
            const tables: u32 = bs.getBits(15);
            g.region_count[0] = @intCast(bs.getBits(4));
            g.region_count[1] = @intCast(bs.getBits(3));
            g.region_count[2] = 255;
            g.table_select[0] = @intCast((tables >> 10) & 31);
            g.table_select[1] = @intCast((tables >> 5) & 31);
            g.table_select[2] = @intCast(tables & 31);
            g.preflag = if (hdr.hdrTestMPEG1(h)) @intCast(bs.getBits(1)) else @intFromBool(g.scalefac_compress >= 500);
            g.scalefac_scale = @intCast(bs.getBits(1));
            g.count1_table = @intCast(bs.getBits(1));
        }
        g.scfsi = @intCast((scfsi >> 12) & 15);
        scfsi <<= 4;
    }

    if (part_23_sum + @as(i32, @intCast(bs.pos)) > @as(i32, @intCast(bs.limit)) + main_data_begin * 8) {
        return -1;
    }
    return main_data_begin;
}

// ---------------------------------------------------------------------------
// scalefactors
// ---------------------------------------------------------------------------

fn ldexpQ2(y: f32, exp_q2_in: i32) f32 {
    var y0 = y;
    var exp_q2 = exp_q2_in;
    while (true) {
        const e = @min(30 * 4, exp_q2);
        y0 *= t.expfrac[@as(usize, @intCast(e & 3))] * @as(f32, @floatFromInt(@as(i32, 1) << @intCast(30 - (e >> 2))));
        exp_q2 -= e;
        if (exp_q2 <= 0) break;
    }
    return y0;
}

fn readScalefactors(scf: []u8, ist_pos: []u8, scf_size: []const u8, scf_count: []const u8, bitbuf: *br.BitReader, scfsi_in: i32) void {
    var scfsi = scfsi_in;
    var si: usize = 0;
    var sc: usize = 0;
    var i: usize = 0;
    while (i < 4 and scf_count[i] != 0) : (i += 1) {
        const cnt: usize = scf_count[i];
        if ((scfsi & 8) != 0) {
            @memcpy(scf[sc .. sc + cnt], ist_pos[si .. si + cnt]);
        } else {
            const bits: u32 = scf_size[i];
            if (bits == 0) {
                @memset(scf[sc .. sc + cnt], 0);
                @memset(ist_pos[si .. si + cnt], 0);
            } else {
                const max_scf: i32 = if (scfsi < 0) (@as(i32, 1) << @as(u5, @intCast(bits))) - 1 else -1;
                var kk: usize = 0;
                while (kk < cnt) : (kk += 1) {
                    const s: i32 = @intCast(bitbuf.getBits(bits));
                    ist_pos[si + kk] = if (s == max_scf) 0xff else @intCast(s);
                    scf[sc + kk] = @intCast(s);
                }
            }
        }
        si += cnt;
        sc += cnt;
        scfsi *= 2;
    }
    scf[sc] = 0;
    scf[sc + 1] = 0;
    scf[sc + 2] = 0;
}

fn decodeScalefactors(h: []const u8, ist_pos: []u8, bs: *br.BitReader, gr: *const GrInfo, scf: []f32, ch: u32) void {
    var scf_size: [4]u8 = undefined;
    var iscf: [40]u8 = undefined;
    const scf_shift: i32 = @as(i32, gr.scalefac_scale) + 1;
    var scfsi: i32 = gr.scfsi;
    var gain_exp: i32 = 0;
    var scf_partition: []const u8 = undefined;

    const sel: usize = @as(usize, @intFromBool(gr.n_short_sfb != 0)) + @as(usize, @intFromBool(gr.n_long_sfb == 0));
    scf_partition = t.scf_partitions[sel][0..];

    if (hdr.hdrTestMPEG1(h)) {
        const part: i32 = @as(i32, t.scfc_decode[gr.scalefac_compress]);
        scf_size[0] = @intCast(part >> 2);
        scf_size[1] = @intCast(part >> 2);
        scf_size[2] = @intCast(part & 3);
        scf_size[3] = @intCast(part & 3);
    } else {
        var k: usize = 0;
        var modprod: i32 = 0;
        var sfc: i32 = gr.scalefac_compress;
        const ist: usize = @intFromBool(hdr.hdrIsIStereo(h) and ch != 0);
        sfc >>= @intCast(ist);
        k = ist * 3 * 4;
        while (sfc >= 0) {
            modprod = 1;
            var i: i32 = 3;
            while (i >= 0) : (i -= 1) {
                const m: i32 = @as(i32, t.modtab[k + @as(usize, @intCast(i))]);
                scf_size[@intCast(i)] = @intCast(@mod(@divFloor(sfc, modprod), m));
                modprod *= m;
            }
            if (modprod == 0) break;
            sfc -= modprod;
            k += 4;
        }
        scf_partition = scf_partition[k..];
        scfsi = -16;
    }

    var ist_scf: [40]u8 = undefined;
    readScalefactors(ist_scf[0..], ist_pos[0..39], scf_size[0..], scf_partition, bs, scfsi);
    @memcpy(iscf[0..40], ist_scf[0..40]);

    var i: usize = 0;
    if (gr.n_short_sfb != 0) {
        const sh: u5 = @intCast(3 - scf_shift);
        i = 0;
        while (i < gr.n_short_sfb) : (i += 3) {
            iscf[gr.n_long_sfb + i + 0] = @intCast((@as(u32, ist_scf[gr.n_long_sfb + i + 0]) + (@as(u32, gr.subblock_gain[0]) << sh)) & 0xff);
            iscf[gr.n_long_sfb + i + 1] = @intCast((@as(u32, ist_scf[gr.n_long_sfb + i + 1]) + (@as(u32, gr.subblock_gain[1]) << sh)) & 0xff);
            iscf[gr.n_long_sfb + i + 2] = @intCast((@as(u32, ist_scf[gr.n_long_sfb + i + 2]) + (@as(u32, gr.subblock_gain[2]) << sh)) & 0xff);
        }
    } else if (gr.preflag != 0) {
        i = 0;
        while (i < 10) : (i += 1) {
            iscf[11 + i] = @intCast((@as(u32, ist_scf[11 + i]) + @as(u32, t.preamp[i])) & 0xff);
        }
    }

    gain_exp = @as(i32, gr.global_gain) + BITS_DEQUANTIZER_OUT * 4 - 210 - 2 * @as(i32, @intFromBool(hdr.hdrIsMsStereo(h)));
    const gain = ldexpQ2(@as(f32, @floatFromInt(@as(i32, 1) << @intCast(MAX_SCFI / 4))), MAX_SCFI - gain_exp);
    const n_sfb = @as(usize, gr.n_long_sfb) + gr.n_short_sfb;
    i = 0;
    while (i < n_sfb) : (i += 1) {
        scf[i] = ldexpQ2(gain, @as(i32, iscf[i]) << @intCast(scf_shift));
    }

}

// ---------------------------------------------------------------------------
// requant
// ---------------------------------------------------------------------------

fn pow43(x_in: i32) f32 {
    var x = x_in;
    var mult: i32 = 256;
    if (x < 129) return t.pow43[16 + @as(usize, @intCast(x))];
    if (x < 1024) {
        mult = 16;
        x <<= 3;
    }
    const sign: i32 = 2 * x & 64;
    const frac: f32 = @as(f32, @floatFromInt((x & 63) - sign)) / @as(f32, @floatFromInt((x & ~@as(i32, 63)) + sign));
    return t.pow43[16 + @as(usize, @intCast((x + sign) >> 6))] * (1 + frac * (@as(f32, 4) / 3 + frac * (@as(f32, 2) / 9))) * @as(f32, @floatFromInt(mult));
}

// ---------------------------------------------------------------------------
// huffman
// ---------------------------------------------------------------------------

const HufState = struct {
    bs_next: [*]const u8,
    bs_cache: u32,
    bs_sh: i32,
    buf: []const u8,
    pos: usize,
};

inline fn hufPeek(state: *HufState, n: u32) u32 {
    return state.bs_cache >> @as(u5, @intCast(32 - n));
}
inline fn hufFlush(state: *HufState, n: u32) void {
    state.bs_cache <<= @as(u5, @intCast(n));
    state.bs_sh += @as(i32, @intCast(n));
}
inline fn hufCheck(state: *HufState) void {
    while (state.bs_sh >= 0) {
        state.bs_cache |= @as(u32, state.bs_next[0]) << @as(u5, @intCast(state.bs_sh));
        state.bs_next += 1;
        state.bs_sh -= 8;
    }
}
inline fn hufBspos(state: *HufState, bs: *const br.BitReader) i32 {
    return @as(i32, @intCast(state.bs_next - bs.buf.ptr)) * 8 - 24 + state.bs_sh;
}

fn huffman(dst: []f32, bs: *br.BitReader, gr_info: *const GrInfo, scf: []const f32, layer3gr_limit: i32) void {
    var ireg: usize = 0;
    var big_val_cnt: i32 = gr_info.big_values;
    var sfb: usize = 0;
    var one: f32 = 0.0;

    const pos: usize = bs.pos / 8;
    const bsptr = bs.buf.ptr + pos;
    var state = HufState{
        .bs_next = bsptr + 4,
        .bs_cache = (((@as(u32, bsptr[0]) * 256 + bsptr[1]) * 256 + bsptr[2]) * 256 + bsptr[3]) << @as(u5, @intCast(bs.pos & 7)),
        .bs_sh = @as(i32, @intCast(bs.pos & 7)) - 8,
        .buf = bs.buf,
        .pos = bs.pos,
    };

    var dpos: usize = 0;
    while (big_val_cnt > 0) {
        const tab_num: usize = gr_info.table_select[ireg];
        var sfb_cnt: i32 = gr_info.region_count[ireg];
        ireg += 1;
        const codebook: []const i16 = ht.tabs[@as(usize, @intCast(ht.tabindex[tab_num]))..];
        const linbits: u32 = ht.g_linbits[tab_num];
        if (linbits != 0) {
            while (true) {
                const np: i32 = gr_info.sfbtab[sfb] / 2;
                sfb += 1;
                var pairs_to_decode = @min(big_val_cnt, np);
                one = scf[if (sfb - 1 < scf.len) sfb - 1 else 0];
                while (true) {
                    var w: i32 = 5;
                    var leaf: i32 = codebook[hufPeek(&state, @intCast(w))];
                    while (leaf < 0) {
                        hufFlush(&state, @intCast(w));
                        w = leaf & 7;
                        leaf = codebook[@as(usize, @intCast(hufPeek(&state, @intCast(w)) -% @as(u32, @bitCast(leaf >> 3))))];
                    }
                    hufFlush(&state, @intCast(leaf >> 8));

                    var j: usize = 0;
                    while (j < 2) : (j += 1) {
                        var lsb: i32 = leaf & 0x0F;
                        if (lsb == 15) {
                            lsb += @intCast(hufPeek(&state, linbits));
                            hufFlush(&state, linbits);
                            hufCheck(&state);
                            const sign: f32 = if (@as(i32, @bitCast(state.bs_cache)) < 0) -1 else 1;
                            dst[dpos] = one * pow43(lsb) * sign;
                        } else {
                            const sign: u32 = state.bs_cache >> 31;
                            const idx: u32 = @as(u32, @intCast(lsb)) -% sign * 16 +% 16;
                            dst[dpos] = t.pow43[@as(usize, @intCast(idx))] * one;
                        }
                        hufFlush(&state, @intFromBool(lsb != 0));
                        leaf >>= 4;
                        dpos += 1;
                    }
                    hufCheck(&state);
                    pairs_to_decode -= 1;
                    if (pairs_to_decode <= 0) break;
                }
                big_val_cnt -= np;
                sfb_cnt -= 1;
                if (!(big_val_cnt > 0 and sfb_cnt >= 0)) break;
            }
        } else {
            while (true) {
                const np: i32 = gr_info.sfbtab[sfb] / 2;
                sfb += 1;
                var pairs_to_decode = @min(big_val_cnt, np);
                one = scf[if (sfb - 1 < scf.len) sfb - 1 else 0];
                while (true) {
                    var w: i32 = 5;
                    var leaf: i32 = codebook[hufPeek(&state, @intCast(w))];
                    while (leaf < 0) {
                        hufFlush(&state, @intCast(w));
                        w = leaf & 7;
                        leaf = codebook[@as(usize, @intCast(hufPeek(&state, @intCast(w)) -% @as(u32, @bitCast(leaf >> 3))))];
                    }
                    hufFlush(&state, @intCast(leaf >> 8));

                    var j: usize = 0;
                    while (j < 2) : (j += 1) {
                        const lsb: i32 = leaf & 0x0F;
                        const sign: u32 = state.bs_cache >> 31;
                        const idx: u32 = @as(u32, @intCast(lsb)) -% sign * 16 +% 16;
                        dst[dpos] = t.pow43[@as(usize, @intCast(idx))] * one;
                        hufFlush(&state, @intFromBool(lsb != 0));
                        leaf >>= 4;
                        dpos += 1;
                    }
                    hufCheck(&state);
                    pairs_to_decode -= 1;
                    if (pairs_to_decode <= 0) break;
                }
                big_val_cnt -= np;
                sfb_cnt -= 1;
                if (!(big_val_cnt > 0 and sfb_cnt >= 0)) break;
            }
        }
    }

    var np: i32 = 1 - big_val_cnt;
    while (true) : (dpos += 4) {
        const codebook_count1: []const u8 = if (gr_info.count1_table != 0) &ht.tab33 else &ht.tab32;
        var leaf: i32 = codebook_count1[hufPeek(&state, 4)];
        if ((leaf & 8) == 0) {
            leaf = codebook_count1[@as(usize, @intCast(leaf >> 3)) + @as(usize, @intCast(state.bs_cache << 4 >> @as(u5, @intCast(32 - (leaf & 3)))))];
        }
        hufFlush(&state, @intCast(leaf & 7));
        if (hufBspos(&state, bs) > layer3gr_limit) break;

        np -= 1;
        if (np == 0) {
            np = gr_info.sfbtab[sfb] / 2;
            sfb += 1;
            if (np == 0) break;
            one = scf[if (sfb - 1 < scf.len) sfb - 1 else 0];
        }
        if ((leaf & 128) != 0) {
            dst[dpos + 0] = if (@as(i32, @bitCast(state.bs_cache)) < 0) -one else one;
            hufFlush(&state, 1);
        }
        if ((leaf & 64) != 0) {
            dst[dpos + 1] = if (@as(i32, @bitCast(state.bs_cache)) < 0) -one else one;
            hufFlush(&state, 1);
        }
        np -= 1;
        if (np == 0) {
            np = gr_info.sfbtab[sfb] / 2;
            sfb += 1;
            if (np == 0) break;
            one = scf[if (sfb - 1 < scf.len) sfb - 1 else 0];
        }
        if ((leaf & 32) != 0) {
            dst[dpos + 2] = if (@as(i32, @bitCast(state.bs_cache)) < 0) -one else one;
            hufFlush(&state, 1);
        }
        if ((leaf & 16) != 0) {
            dst[dpos + 3] = if (@as(i32, @bitCast(state.bs_cache)) < 0) -one else one;
            hufFlush(&state, 1);
        }
        hufCheck(&state);
    }

    bs.pos = @intCast(layer3gr_limit);
}

// ---------------------------------------------------------------------------
// stereo
// ---------------------------------------------------------------------------

fn midsideStereo(left: []f32, n: usize) void {
    const right = left[576..];
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a = left[i];
        const b = right[i];
        left[i] = a + b;
        right[i] = a - b;
    }
}

fn intensityStereoBand(left: []f32, n: usize, kl: f32, kr: f32) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        left[i + 576] = left[i] * kr;
        left[i] = left[i] * kl;
    }
}

fn stereoTopBand(right: []const f32, sfb: []const u8, nbands: usize, max_band: *[3]i32) void {
    max_band[0] = -1;
    max_band[1] = -1;
    max_band[2] = -1;
    var off: usize = 0;
    var i: usize = 0;
    while (i < nbands) : (i += 1) {
        var k: usize = 0;
        while (k < sfb[i]) : (k += 2) {
            if (right[off + k] != 0 or right[off + k + 1] != 0) {
                max_band[i % 3] = @intCast(i);
                break;
            }
        }
        off += sfb[i];
    }
}

const g_pan = [14]f32{ 0, 1, 0.21132487, 0.78867513, 0.36602540, 0.63397460, 0.5, 0.5, 0.63397460, 0.36602540, 0.78867513, 0.21132487, 1, 0 };

fn stereoProcess(left: []f32, ist_pos: []const u8, sfb: []const u8, h: []const u8, max_band: *const [3]i32, mpeg2_sh: u32) void {
    const max_pos: u32 = if (hdr.hdrTestMPEG1(h)) 7 else 64;
    var off: usize = 0;
    var i: usize = 0;
    while (sfb[i] != 0) : (i += 1) {
        const ipos: u32 = ist_pos[i];
        if (@as(i32, @intCast(i)) > max_band[i % 3] and ipos < max_pos) {
            const s: f32 = if (hdr.hdrIsMsStereo(h)) 1.41421356 else 1;
            var kl: f32 = 1;
            var kr: f32 = 1;
            if (hdr.hdrTestMPEG1(h)) {
                kl = g_pan[2 * ipos];
                kr = g_pan[2 * ipos + 1];
            } else {
                kr = ldexpQ2(1, (@as(i32, @intCast(ipos + 1)) >> 1) << @intCast(mpeg2_sh));
                if (ipos & 1 != 0) {
                    kl = kr;
                    kr = 1;
                }
            }
            intensityStereoBand(left[off..], sfb[i], kl * s, kr * s);
        } else if (hdr.hdrIsMsStereo(h)) {
            midsideStereo(left[off..], sfb[i]);
        }
        off += sfb[i];
    }
}

fn intensityStereo(left: []f32, ist_pos: []u8, gr: *const GrInfo, h: []const u8) void {
    const n_sfb = @as(usize, gr.n_long_sfb) + gr.n_short_sfb;
    var max_band: [3]i32 = .{ 0, 0, 0 };
    const max_blocks: usize = if (gr.n_short_sfb != 0) 3 else 1;

    stereoTopBand(left[576..], gr.sfbtab[0..], n_sfb, &max_band);
    if (gr.n_long_sfb != 0) {
        const m = @max(@max(max_band[0], max_band[1]), max_band[2]);
        max_band[0] = m;
        max_band[1] = m;
        max_band[2] = m;
    }
    var i: usize = 0;
    while (i < max_blocks) : (i += 1) {
        const default_pos: i32 = if (hdr.hdrTestMPEG1(h)) 3 else 0;
        const itop: i32 = @as(i32, @intCast(n_sfb - max_blocks + i));
        const prev: i32 = itop - @as(i32, @intCast(max_blocks));
        ist_pos[@intCast(itop)] = if (max_band[i] >= prev) @intCast(default_pos) else ist_pos[@intCast(prev)];
    }
    stereoProcess(left, ist_pos[0..], gr.sfbtab[0..], h, &max_band, gr.scalefac_compress & 1);
}

// ---------------------------------------------------------------------------
// reorder / antialias
// ---------------------------------------------------------------------------

fn reorder(grbuf: []f32, scratch: []f32, sfb: []const u8) void {
    var src: usize = 0;
    var dst: usize = 0;
    var off: usize = 0;
    while (true) {
        const len: usize = sfb[off];
        if (len == 0) break;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            scratch[dst] = grbuf[src + 0 * len];
            scratch[dst + 1] = grbuf[src + 1 * len];
            scratch[dst + 2] = grbuf[src + 2 * len];
            dst += 3;
            src += 1;
        }
        off += 3;
        src += 2 * len;
    }
    @memcpy(grbuf[0..dst], scratch[0..dst]);
}

const g_aa = [2][8]f32{
    .{ 0.85749293, 0.88174200, 0.94962865, 0.98331459, 0.99551782, 0.99916056, 0.99989920, 0.99999316 },
    .{ 0.51449576, 0.47173197, 0.31337745, 0.18191320, 0.09457419, 0.04096558, 0.01419856, 0.00369997 },
};

fn antialias(grbuf_in: []f32, nbands: i32) void {
    var grbuf = grbuf_in;
    var b: i32 = 0;
    while (b < nbands) : (b += 1) {
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const u = grbuf[18 + i];
            const d = grbuf[17 - i];
            grbuf[18 + i] = u * g_aa[0][i] - d * g_aa[1][i];
            grbuf[17 - i] = u * g_aa[1][i] + d * g_aa[0][i];
        }
        grbuf = grbuf[18..];
    }
}

// ---------------------------------------------------------------------------
// IMDCT
// ---------------------------------------------------------------------------

fn dct3_9(y: []f32) void {
    var s0 = y[0];
    const s2 = y[2];
    var s4 = y[4];
    var s6 = y[6];
    const s8 = y[8];
    const t0 = s0 + s6 * 0.5;
    s0 -= s6;
    const t4 = (s4 + s2) * 0.93969262;
    const t2 = (s8 + s2) * 0.76604444;
    s6 = (s4 - s8) * 0.17364818;
    s4 += s8 - s2;

    const s0b = s0 - s4 * 0.5;
    y[4] = s4 + s0;
    const s8b = t0 - t2 + s6;
    const s0c = t0 - t4 + t2;
    const s4b = t0 + t4 - s6;

    var s1 = y[1];
    var s3 = y[3];
    const s5 = y[5];
    const s7 = y[7];

    s3 *= 0.86602540;
    const tb0 = (s5 + s1) * 0.98480775;
    const tb4 = (s5 - s7) * 0.34202014;
    const tb2 = (s1 + s7) * 0.64278761;
    s1 = (s1 - s5 - s7) * 0.86602540;

    const s5b = tb0 - s3 - tb2;
    const s7b = tb4 - s3 - tb0;
    const s3b = tb4 + s3 - tb2;

    y[0] = s4b - s7b;
    y[1] = s0b + s1;
    y[2] = s0c - s3b;
    y[3] = s8b + s5b;
    y[5] = s8b - s5b;
    y[6] = s0c + s3b;
    y[7] = s0b - s1;
    y[8] = s4b + s7b;
}

const g_twid9 = [18]f32{
    0.73727734, 0.79335334, 0.84339145, 0.88701083, 0.92387953, 0.95371695, 0.97629601, 0.99144486, 0.99904822, 0.67559021, 0.60876143, 0.53729961, 0.46174861, 0.38268343, 0.30070580, 0.21643961, 0.13052619, 0.04361938,
};

fn imdct36(grbuf_in: []f32, overlap_in: []f32, window: []const f32, nbands: usize) void {
    var grbuf = grbuf_in;
    var overlap = overlap_in;
    var j: usize = 0;
    while (j < nbands) : (j += 1) {
        var co: [9]f32 = undefined;
        var si: [9]f32 = undefined;
        co[0] = -grbuf[0];
        si[0] = grbuf[17];
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            si[8 - 2 * i] = grbuf[4 * i + 1] - grbuf[4 * i + 2];
            co[1 + 2 * i] = grbuf[4 * i + 1] + grbuf[4 * i + 2];
            si[7 - 2 * i] = grbuf[4 * i + 4] - grbuf[4 * i + 3];
            co[2 + 2 * i] = -(grbuf[4 * i + 3] + grbuf[4 * i + 4]);
        }
        dct3_9(&co);
        dct3_9(&si);
        si[1] = -si[1];
        si[3] = -si[3];
        si[5] = -si[5];
        si[7] = -si[7];

        i = 0;
        while (i < 9) : (i += 1) {
            const ovl = overlap[i];
            const sum = co[i] * g_twid9[9 + i] + si[i] * g_twid9[0 + i];
            overlap[i] = co[i] * g_twid9[0 + i] - si[i] * g_twid9[9 + i];
            grbuf[i] = ovl * window[0 + i] - sum * window[9 + i];
            grbuf[17 - i] = ovl * window[9 + i] + sum * window[0 + i];
        }
        grbuf = grbuf[18..];
        overlap = overlap[9..];
    }
}

fn idct3(x0: f32, x1: f32, x2: f32, dst: *[3]f32) void {
    const m1 = x1 * 0.86602540;
    const a1 = x0 - x2 * 0.5;
    dst[1] = x0 + x2;
    dst[0] = a1 + m1;
    dst[2] = a1 - m1;
}

const g_twid3 = [6]f32{ 0.79335334, 0.92387953, 0.99144486, 0.60876143, 0.38268343, 0.13052619 };

fn imdct12(x: []const f32, dst: []f32, overlap: []f32) void {
    var co: [3]f32 = undefined;
    var si: [3]f32 = undefined;
    idct3(-x[0], x[6] + x[3], x[12] + x[9], &co);
    idct3(x[15], x[12] - x[9], x[6] - x[3], &si);
    si[1] = -si[1];
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const ovl = overlap[i];
        const sum = co[i] * g_twid3[3 + i] + si[i] * g_twid3[0 + i];
        overlap[i] = co[i] * g_twid3[0 + i] - si[i] * g_twid3[3 + i];
        dst[i] = ovl * g_twid3[2 - i] - sum * g_twid3[5 - i];
        dst[5 - i] = ovl * g_twid3[5 - i] + sum * g_twid3[2 - i];
    }
}

fn imdctShort(grbuf_in: []f32, overlap_in: []f32, nbands: usize) void {
    var grbuf = grbuf_in;
    var overlap = overlap_in;
    var b: usize = 0;
    while (b < nbands) : (b += 1) {
        var tmp: [18]f32 = undefined;
        @memcpy(tmp[0..18], grbuf[0..18]);
        @memcpy(grbuf[0..6], overlap[0..6]);
        imdct12(tmp[0..], grbuf[6..], overlap[6..]);
        imdct12(tmp[1..], grbuf[12..], overlap[6..]);
        imdct12(tmp[2..], overlap[0..], overlap[6..]);
        overlap = overlap[9..];
        grbuf = grbuf[18..];
    }
}

fn changeSign(grbuf: []f32) void {
    var b: usize = 0;
    var off: usize = 18;
    while (b < 32) : (b += 2) {
        var i: usize = 1;
        while (i < 18) : (i += 2) grbuf[off + i] = -grbuf[off + i];
        off += 36;
    }
}

const g_mdct_window = [2][18]f32{
    .{ 0.99904822, 0.99144486, 0.97629601, 0.95371695, 0.92387953, 0.88701083, 0.84339145, 0.79335334, 0.73727734, 0.04361938, 0.13052619, 0.21643961, 0.30070580, 0.38268343, 0.46174861, 0.53729961, 0.60876143, 0.67559021 },
    .{ 1, 1, 1, 1, 1, 1, 0.99144486, 0.92387953, 0.79335334, 0, 0, 0, 0, 0, 0, 0.13052619, 0.38268343, 0.60876143 },
};

fn imdctGr(grbuf_in: []f32, overlap_in: []f32, block_type: u8, n_long_bands: usize) void {
    var grbuf = grbuf_in;
    var overlap = overlap_in;
    if (n_long_bands != 0) {
        imdct36(grbuf, overlap, &g_mdct_window[0], n_long_bands);
        grbuf = grbuf[18 * n_long_bands ..];
        overlap = overlap[9 * n_long_bands ..];
    }
    if (block_type == SHORT_BLOCK_TYPE)
        imdctShort(grbuf, overlap, 32 - n_long_bands)
    else
        imdct36(grbuf, overlap, &g_mdct_window[@intFromBool(block_type == STOP_BLOCK_TYPE)], 32 - n_long_bands);
}

// ---------------------------------------------------------------------------
// reservoir
// ---------------------------------------------------------------------------

fn saveReservoir(dec: *DecoderState, s: *Scratch) void {
    if (s.bs.pos > s.bs.limit) {
        dec.reserv = 0;
        return;
    }
    const pos: usize = (s.bs.pos + 7) / 8;
    var remains: usize = s.bs.limit / 8 - pos;
    var pos_adj = pos;
    if (remains > MAX_BITRESERVOIR_BYTES) {
        pos_adj += remains - MAX_BITRESERVOIR_BYTES;
        remains = MAX_BITRESERVOIR_BYTES;
    }
    if (remains > 0) {
        @memcpy(dec.reserv_buf[0..remains], s.maindata[pos_adj .. pos_adj + remains]);
    }
    dec.reserv = @intCast(remains);
}

fn restoreReservoir(dec: *DecoderState, bs: *br.BitReader, s: *Scratch, main_data_begin: usize) bool {
    const frame_bytes: usize = (bs.limit - bs.pos) / 8;
    const bytes_have = @min(@as(usize, @intCast(dec.reserv)), main_data_begin);
    const start = if (dec.reserv > @as(i32, @intCast(main_data_begin))) @as(usize, @intCast(dec.reserv)) - main_data_begin else 0;
    @memcpy(s.maindata[0..bytes_have], dec.reserv_buf[start .. start + bytes_have]);
    @memcpy(s.maindata[bytes_have .. bytes_have + frame_bytes], bs.buf[bs.pos / 8 .. bs.pos / 8 + frame_bytes]);
    s.bs = br.BitReader.init(s.maindata[0 .. bytes_have + frame_bytes]);
    return dec.reserv >= @as(i32, @intCast(main_data_begin));
}

// ---------------------------------------------------------------------------
// L3_decode
// ---------------------------------------------------------------------------

fn decode(dec: *DecoderState, s: *Scratch, gr_info: []GrInfo, nch: usize) void {
    var ch: usize = 0;
    while (ch < nch) : (ch += 1) {
        const layer3gr_limit: i32 = @as(i32, @intCast(s.bs.pos)) + gr_info[ch].part_23_length;
        decodeScalefactors(dec.header[0..], s.ist_pos[ch][0..], &s.bs, &gr_info[ch], s.scf[0..], @intCast(ch));
        huffman(s.grbuf[ch][0..], &s.bs, &gr_info[ch], s.scf[0..], layer3gr_limit);
    }

    if (hdr.hdrIsIStereo(dec.header[0..])) {
        intensityStereo(@as([*]f32, @ptrCast(&s.grbuf[0]))[0..1152], s.ist_pos[1][0..], &gr_info[0], dec.header[0..]);
    } else if (hdr.hdrIsMS_Stereo(dec.header[0..])) {
        midsideStereo(@as([*]f32, @ptrCast(&s.grbuf[0]))[0..1152], 576);
    }

    var gidx: usize = 0;
    while (gidx < nch) : (gidx += 1) {
        const gr = &gr_info[gidx];
        var aa_bands: i32 = 31;
        const n_long_bands: usize = (@as(usize, @intFromBool(gr.mixed_block_flag != 0)) << @intFromBool(hdr.hdrGetMySampleRate(dec.header[0..]) == 2)) << 1;

        if (gr.n_short_sfb != 0) {
            aa_bands = @as(i32, @intCast(n_long_bands)) - 1;
            reorder(s.grbuf[gidx][n_long_bands * 18 ..], @as([*]f32, @ptrCast(&s.syn[0]))[0..576], gr.sfbtab[gr.n_long_sfb..]);
        }
        antialias(s.grbuf[gidx][0..], aa_bands);
        imdctGr(s.grbuf[gidx][0..], dec.mdct_overlap[gidx][0..], gr.block_type, n_long_bands);
        changeSign(s.grbuf[gidx][0..]);
    }
}

const synth = @import("synth.zig");
const layer12 = @import("layer12.zig");

fn findFrame(mp3: []const u8, mp3_bytes: usize, free_format_bytes: *i32, ptr_frame_bytes: *usize) usize {
    var i: usize = 0;
    while (i < mp3_bytes - 4) : (i += 1) {
        const h = mp3[i .. i + 4];
        if (hdr.hdrValid(h)) {
            var frame_bytes: usize = hdr.hdrFrameBytes(h, @intCast(free_format_bytes.*));
            var frame_and_padding = frame_bytes + hdr.hdrPadding(h);
            var k: usize = 4;
            if (frame_bytes == 0) {
                while (k < 2304 and i + 2 * k < mp3_bytes - 4) : (k += 1) {
                    if (hdr.hdrCompare(h, mp3[i + k .. i + k + 4])) {
                        const fb: i32 = @intCast(k - hdr.hdrPadding(h));
                        const nextfb: i32 = fb + @as(i32, @intCast(hdr.hdrPadding(mp3[i + k .. i + k + 4])));
                        if (i + @as(usize, @intCast(nextfb)) + k + 4 > mp3_bytes or !hdr.hdrCompare(h, mp3[i + k + @as(usize, @intCast(nextfb)) .. i + k + @as(usize, @intCast(nextfb)) + 4])) continue;
                        frame_and_padding = k;
                        frame_bytes = @as(usize, @intCast(fb));
                        free_format_bytes.* = fb;
                    }
                }
            }
            if ((frame_bytes != 0 and i + frame_and_padding <= mp3_bytes and
                matchFrame(h, mp3[i..], frame_bytes)) or
                (i == 0 and frame_and_padding == mp3_bytes))
            {
                ptr_frame_bytes.* = frame_and_padding;
                return i;
            }
            free_format_bytes.* = 0;
        }
    }
    ptr_frame_bytes.* = 0;
    return mp3_bytes;
}

fn matchFrame(h4: []const u8, mp3: []const u8, frame_bytes: usize) bool {
    var i: usize = 0;
    var nmatch: i32 = 0;
    while (nmatch < 10) : (nmatch += 1) {
        const cur = mp3[i..];
        i += hdr.hdrFrameBytes(cur[0..4], frame_bytes) + hdr.hdrPadding(cur[0..4]);
        if (i + 4 > mp3.len) return nmatch > 0;
        if (!hdr.hdrCompare(h4, mp3[i .. i + 4])) return false;
    }
    return true;
}

pub const FrameInfo = struct {
    frame_bytes: usize = 0,
    frame_offset: usize = 0,
    channels: usize = 0,
    hz: usize = 0,
    layer: usize = 0,
    bitrate_kbps: usize = 0,
};

pub fn decodeFrame(dec: *DecoderState, mp3: []const u8, pcm: []f32, info: *FrameInfo) usize {
    const mp3_bytes = mp3.len;
    var i: usize = 0;
    var igr: usize = 0;
    var frame_size: usize = 0;
    var success: bool = true;
    var scratch: Scratch = .{};

    if (mp3_bytes > 4 and dec.header[0] == 0xff and hdr.hdrCompare(&dec.header, mp3[0..4])) {
        frame_size = hdr.hdrFrameBytes(mp3, @intCast(dec.free_format_bytes)) + hdr.hdrPadding(mp3);
        if (frame_size != mp3_bytes and (frame_size + 4 > mp3_bytes or !hdr.hdrCompare(mp3[0..4], mp3[frame_size .. frame_size + 4]))) {
            frame_size = 0;
        }
    }
    if (frame_size == 0) {
        dec.* = .{};
        i = findFrame(mp3, mp3_bytes, &dec.free_format_bytes, &frame_size);
        if (frame_size == 0 or i + frame_size > mp3_bytes) {
            info.frame_bytes = i;
            return 0;
        }
    }

    const h = mp3[i .. i + 4];
    @memcpy(&dec.header, h);
    info.frame_bytes = i + frame_size;
    info.frame_offset = i;
    info.channels = if (hdr.hdrIsMono(h)) 1 else 2;
    info.hz = hdr.hdrSampleRateHz(h);
    info.layer = 4 - @as(usize, hdr.hdrGetLayer(h));
    info.bitrate_kbps = hdr.hdrBitrateKbps(h);

    if (info.layer == 3) {
        var bs_frame = br.BitReader.init(mp3[i + 4 .. i + frame_size]);
        if (hdrIsCrc(h)) _ = bs_frame.getBits(16);

        const main_data_begin = readSideInfo(&bs_frame, scratch.gr_info[0..], h);
        if (main_data_begin < 0 or bs_frame.pos > bs_frame.limit) {
            dec.* = .{};
            return 0;
        }
        success = restoreReservoir(dec, &bs_frame, &scratch, @intCast(main_data_begin));
        if (success) {
            const gr_count: usize = if (hdr.hdrTestMPEG1(h)) 2 else 1;
            igr = 0;
            while (igr < gr_count) : (igr += 1) {
                @memset(scratch.grbuf[0][0..576], 0);
                @memset(scratch.grbuf[1][0..576], 0);
                decode(dec, &scratch, scratch.gr_info[igr * info.channels ..][0..info.channels], info.channels);
                const grbuf_all: []f32 = @as([*]f32, @ptrCast(&scratch.grbuf[0]))[0 .. 576 * 2];
                const lins_all: []f32 = @as([*]f32, @ptrCast(&scratch.syn[0]))[0 .. 33 * 64];
                synth.synthGranule(&dec.qmf_state, grbuf_all, 18, info.channels, pcm[igr * 576 * info.channels ..][0 .. 576 * info.channels], lins_all);
            }
        }
        saveReservoir(dec, &scratch);
    } else {
        var bs_frame = br.BitReader.init(mp3[i + 4 .. i + frame_size]);
        if (hdrIsCrc(h)) _ = bs_frame.getBits(16);
        const grbuf_all: []f32 = @as([*]f32, @ptrCast(&scratch.grbuf[0]))[0 .. 576 * 2];
        const lins_all: []f32 = @as([*]f32, @ptrCast(&scratch.syn[0]))[0 .. 33 * 64];
        success = layer12.decode12(&dec.qmf_state, h, &bs_frame, info.channels, pcm[0 .. 1152 * info.channels], grbuf_all, lins_all) != 0;
    }
    return @as(usize, @intFromBool(success)) * hdr.hdrFrameSamples(h);
}
