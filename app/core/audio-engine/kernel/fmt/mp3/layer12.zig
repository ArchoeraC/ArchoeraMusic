//! Layer I/II 解码（对标 minimp3 标量路径，CC0）。

const std = @import("std");
const br = @import("bitreader.zig");
const hdr = @import("header.zig");
const synth = @import("synth.zig");

pub const ScaleInfo = struct {
    scf: [3 * 64]f32 = .{0} ** (3 * 64),
    total_bands: u8 = 0,
    stereo_bands: u8 = 0,
    bitalloc: [64]u8 = .{0} ** 64,
    scfcod: [64]u8 = .{0} ** 64,
};

const SubbandAlloc = struct {
    tab_offset: u8,
    code_tab_width: u8,
    band_count: u8,
};

const g_deq_L12 = [18 * 3]f32{
    @as(f32, 9.53674316e-07) / 3, @as(f32, 7.56931807e-07) / 3, @as(f32, 6.00777173e-07) / 3,
    @as(f32, 9.53674316e-07) / 7, @as(f32, 7.56931807e-07) / 7, @as(f32, 6.00777173e-07) / 7,
    @as(f32, 9.53674316e-07) / 15, @as(f32, 7.56931807e-07) / 15, @as(f32, 6.00777173e-07) / 15,
    @as(f32, 9.53674316e-07) / 31, @as(f32, 7.56931807e-07) / 31, @as(f32, 6.00777173e-07) / 31,
    @as(f32, 9.53674316e-07) / 63, @as(f32, 7.56931807e-07) / 63, @as(f32, 6.00777173e-07) / 63,
    @as(f32, 9.53674316e-07) / 127, @as(f32, 7.56931807e-07) / 127, @as(f32, 6.00777173e-07) / 127,
    @as(f32, 9.53674316e-07) / 255, @as(f32, 7.56931807e-07) / 255, @as(f32, 6.00777173e-07) / 255,
    @as(f32, 9.53674316e-07) / 511, @as(f32, 7.56931807e-07) / 511, @as(f32, 6.00777173e-07) / 511,
    @as(f32, 9.53674316e-07) / 1023, @as(f32, 7.56931807e-07) / 1023, @as(f32, 6.00777173e-07) / 1023,
    @as(f32, 9.53674316e-07) / 2047, @as(f32, 7.56931807e-07) / 2047, @as(f32, 6.00777173e-07) / 2047,
    @as(f32, 9.53674316e-07) / 4095, @as(f32, 7.56931807e-07) / 4095, @as(f32, 6.00777173e-07) / 4095,
    @as(f32, 9.53674316e-07) / 8191, @as(f32, 7.56931807e-07) / 8191, @as(f32, 6.00777173e-07) / 8191,
    @as(f32, 9.53674316e-07) / 16383, @as(f32, 7.56931807e-07) / 16383, @as(f32, 6.00777173e-07) / 16383,
    @as(f32, 9.53674316e-07) / 32767, @as(f32, 7.56931807e-07) / 32767, @as(f32, 6.00777173e-07) / 32767,
    @as(f32, 9.53674316e-07) / 65535, @as(f32, 7.56931807e-07) / 65535, @as(f32, 6.00777173e-07) / 65535,
    @as(f32, 9.53674316e-07) / 3, @as(f32, 7.56931807e-07) / 3, @as(f32, 6.00777173e-07) / 3,
    @as(f32, 9.53674316e-07) / 5, @as(f32, 7.56931807e-07) / 5, @as(f32, 6.00777173e-07) / 5,
    @as(f32, 9.53674316e-07) / 9, @as(f32, 7.56931807e-07) / 9, @as(f32, 6.00777173e-07) / 9,
};

const g_bitalloc_code_tab = [92]u8{
    0, 17, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    0, 17, 18, 3, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
    0, 17, 18, 3, 19, 4, 5, 16,
    0, 17, 18, 16,
    0, 17, 18, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    0, 17, 18, 3, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
};

const g_alloc_L1 = [_]SubbandAlloc{.{ .tab_offset = 76, .code_tab_width = 4, .band_count = 32 }};
const g_alloc_L2M2 = [_]SubbandAlloc{
    .{ .tab_offset = 60, .code_tab_width = 4, .band_count = 4 },
    .{ .tab_offset = 44, .code_tab_width = 3, .band_count = 7 },
    .{ .tab_offset = 44, .code_tab_width = 2, .band_count = 19 },
};
const g_alloc_L2M1 = [_]SubbandAlloc{
    .{ .tab_offset = 0, .code_tab_width = 4, .band_count = 3 },
    .{ .tab_offset = 16, .code_tab_width = 4, .band_count = 8 },
    .{ .tab_offset = 32, .code_tab_width = 3, .band_count = 12 },
    .{ .tab_offset = 40, .code_tab_width = 2, .band_count = 7 },
};
const g_alloc_L2M1_lowrate = [_]SubbandAlloc{
    .{ .tab_offset = 44, .code_tab_width = 4, .band_count = 2 },
    .{ .tab_offset = 44, .code_tab_width = 3, .band_count = 10 },
};

fn subbandAllocTable(h: []const u8, sci: *ScaleInfo) []const SubbandAlloc {
    const mode = hdr.hdrGetStereoMode(h);
    const stereo_bands: i32 = if (mode == 3)
        0
    else if (mode == 1)
        @as(i32, hdr.hdrGetStereoModeExt(h)) * 4 + 4
    else
        32;

    var nbands: i32 = undefined;
    var alloc: []const SubbandAlloc = undefined;

    if (hdr.hdrIsLayer1(h)) {
        alloc = &g_alloc_L1;
        nbands = 32;
    } else if (!hdr.hdrTestMPEG1(h)) {
        alloc = &g_alloc_L2M2;
        nbands = 30;
    } else {
        const sample_rate_idx = hdr.hdrGetSampleRate(h);
        var kbps: u32 = @as(u32, @intCast(hdr.hdrBitrateKbps(h))) >> @intFromBool(mode != 3);
        if (kbps == 0) kbps = 192; // free-format

        alloc = &g_alloc_L2M1;
        nbands = 27;
        if (kbps < 56) {
            alloc = &g_alloc_L2M1_lowrate;
            nbands = if (sample_rate_idx == 2) 12 else 8;
        } else if (kbps >= 96 and sample_rate_idx != 1) {
            nbands = 30;
        }
    }

    sci.total_bands = @intCast(nbands);
    sci.stereo_bands = @intCast(@min(stereo_bands, nbands));
    return alloc;
}

fn readScalefactors(bs: *br.BitReader, pba: []const u8, scfcod: []const u8, bands: usize, scf: []f32) void {
    var i: usize = 0;
    var scf_idx: usize = 0;
    while (i < bands) : (i += 1) {
        var s: f32 = 0;
        const ba: u8 = pba[i];
        const mask: u8 = if (ba != 0) 4 + ((@as(u8, 19) >> @as(u3, @intCast(scfcod[i]))) & 3) else 0;
        var m: u8 = 4;
        while (m != 0) {
            if (mask & m != 0) {
                const b: i32 = @intCast(bs.getBits(6));
                const idx: usize = @intCast(@as(i32, ba) * 3 - 6 + @rem(b, 3));
                const shift: u5 = @intCast(@divFloor(b, 3));
                s = g_deq_L12[idx] * @as(f32, @floatFromInt(@as(i32, 1) << 21 >> shift));
            }
            scf[scf_idx] = s;
            scf_idx += 1;
            m >>= 1;
        }
    }
}

fn readScaleInfo(h: []const u8, bs: *br.BitReader, sci: *ScaleInfo) void {
    const subband_alloc = subbandAllocTable(h, sci);

    var ai: usize = 0;
    var k: usize = 0;
    var ba_bits: usize = 0;
    var ba_code_tab: []const u8 = g_bitalloc_code_tab[0..];

    var i: usize = 0;
    while (i < sci.total_bands) : (i += 1) {
        var ba: u8 = undefined;
        if (i == k) {
            k += subband_alloc[ai].band_count;
            ba_bits = subband_alloc[ai].code_tab_width;
            ba_code_tab = g_bitalloc_code_tab[subband_alloc[ai].tab_offset..];
            ai += 1;
        }
        ba = ba_code_tab[@intCast(bs.getBits(@intCast(ba_bits)))];
        sci.bitalloc[2 * i] = ba;
        if (i < sci.stereo_bands) {
            ba = ba_code_tab[@intCast(bs.getBits(@intCast(ba_bits)))];
        }
        sci.bitalloc[2 * i + 1] = if (sci.stereo_bands != 0) ba else 0;
    }

    i = 0;
    while (i < 2 * sci.total_bands) : (i += 1) {
        sci.scfcod[i] = if (sci.bitalloc[i] != 0) (if (hdr.hdrIsLayer1(h)) 2 else @intCast(bs.getBits(2))) else 6;
    }

    readScalefactors(bs, sci.bitalloc[0..], sci.scfcod[0..], sci.total_bands * 2, sci.scf[0..]);

    i = sci.stereo_bands;
    while (i < sci.total_bands) : (i += 1) {
        sci.bitalloc[2 * i + 1] = 0;
    }
}

fn dequantizeGranule(grbuf: []f32, start: usize, bs: *br.BitReader, sci: *const ScaleInfo, group_size: usize) usize {
    var j: usize = 0;
    var choff: i32 = 576;
    while (j < 4) : (j += 1) {
        var dst: i32 = @intCast(start + group_size * j);
        var i: usize = 0;
        while (i < 2 * sci.total_bands) : (i += 1) {
            const ba: u8 = sci.bitalloc[i];
            if (ba != 0) {
                if (ba < 17) {
                    const half: i32 = (@as(i32, 1) << @intCast(ba - 1)) - 1;
                    var k: usize = 0;
                    while (k < group_size) : (k += 1) {
                        grbuf[@intCast(dst + @as(i32, @intCast(k)))] = @floatFromInt(@as(i32, @intCast(bs.getBits(ba))) - half);
                    }
                } else {
                    const mod: u32 = (@as(u32, 2) << @intCast(ba - 17)) + 1; // 3, 5, 9
                    var code: u32 = @intCast(bs.getBits(mod + 2 - (mod >> 3))); // 5, 7, 10
                    var k: usize = 0;
                    while (k < group_size) : (k += 1) {
                        grbuf[@intCast(dst + @as(i32, @intCast(k)))] = @floatFromInt(@as(i32, @intCast(code % mod)) - @as(i32, @intCast(mod / 2)));
                        code /= mod;
                    }
                }
            }
            dst += choff;
            choff = 18 - choff;
        }
    }
    return group_size * 4;
}

fn applyScf384(sci: *const ScaleInfo, scf: []const f32, dst: []f32) void {
    const stereo: usize = sci.stereo_bands;
    const total: usize = sci.total_bands;
    @memcpy(dst[576 + stereo * 18 .. 576 + total * 18], dst[stereo * 18 .. total * 18]);
    var i: usize = 0;
    var scf_off: usize = 0;
    var d = dst;
    while (i < total) : (i += 1) {
        var k: usize = 0;
        while (k < 12) : (k += 1) {
            d[k] *= scf[scf_off + 0];
            d[k + 576] *= scf[scf_off + 3];
        }
        d = d[18..];
        scf_off += 6;
    }
}

/// Layer I/II 帧解码。返回样本数（L1=384, L2=1152），失败返回 0。
/// qmf_state 为跨帧状态，grbuf 临时缓冲区（1152*2），pcm 输出。
pub fn decode12(qmf_state: []f32, h: []const u8, bs: *br.BitReader, nch: usize, pcm: []f32, grbuf: []f32, syn: []f32) usize {
    var sci: ScaleInfo = .{};
    readScaleInfo(h, bs, &sci);

    @memset(grbuf[0 .. 576 * 2], 0);
    var i: usize = 0;
    var igr: usize = 0;
    var pcm_off: usize = 0;
    while (igr < 3) : (igr += 1) {
        const group_size: usize = (4 - @as(usize, hdr.hdrGetLayer(h))) | 1;
        i += dequantizeGranule(grbuf, i, bs, &sci, group_size);
        if (12 == i) {
            i = 0;
            applyScf384(&sci, sci.scf[igr..], grbuf);
            const grbuf_all: []f32 = @as([*]f32, @ptrCast(&grbuf[0]))[0 .. 576 * 2];
            const lins_all: []f32 = @as([*]f32, @ptrCast(&syn[0]))[0 .. 33 * 64];
            synth.synthGranule(qmf_state, grbuf_all, 12, nch, pcm[pcm_off .. pcm_off + 384 * nch], lins_all);
            pcm_off += 384 * nch;
            @memset(grbuf[0 .. 576 * 2], 0);
        }
        if (bs.pos > bs.limit) {
            return 0;
        }
    }
    return if (hdr.hdrIsLayer1(h)) 384 else 1152;
}
