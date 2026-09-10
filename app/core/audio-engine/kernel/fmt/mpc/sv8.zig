// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! Musepack SV8 解码 —— FFmpeg n9.0.1 libavcodec/mpc8.c 逐句移植。
//!
//! 含容器（MPCK chunk：SH/AP…）与逐帧解码。帧间状态（Q/oldDSCF/合成滤波/噪声
//! RNG）跨 chunk 持续，`cur_frame` 以 SH 头 `frames`（1<<(3bit*2)）为模 ——
//! 与 FFmpeg 解码器在连续 AVPacket 流中的行为一致（每帧一解、wrap 即 keyframe）。
//!
//! 帧长固定 1152 样本/声道，S16。

const std = @import("std");
const synth = @import("synth.zig");
const vlc = @import("vlc.zig");
const tables = @import("tables.zig");

const SBLIMIT = synth.SBLIMIT;
const SAMPLES_PER_BAND = synth.SAMPLES_PER_BAND;
const MPC_FRAME_SIZE = synth.MPC_FRAME_SIZE;

pub const Error = error{ Corrupt, Truncated };

/// SH 头解析出的解码器配置（mpc8_decode_init）
pub const Cfg = struct {
    sample_rate: u32,
    maxbands: i32,
    channels: u8,
    mss: bool,
    frames: u16,
    /// SH 声明的样本总数（时长用）
    total_samples: i64,
};

pub const APChunk = struct {
    /// chunk 载荷范围（音频比特流）
    off: usize,
    len: usize,
};

/// 解析整个文件（内存缓冲）→ 返回配置与 AP 载荷表。data 生命周期须覆盖解码。
pub const Parsed = struct {
    cfg: Cfg,
    aps: []APChunk,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Parsed) void {
        self.allocator.free(self.aps);
    }
};

fn readVarlen(d: []const u8, p: *usize) i64 {
    var v: i64 = 0;
    var br: usize = 0;
    while (true) {
        if (p.* >= d.len) return -1;
        const c = d[p.*];
        p.* += 1;
        v = (v << 7) | (c & 0x7F);
        br += 1;
        if (br > 10) return -1;
        if ((c & 0x80) == 0) return v; // ffio_read_varlen 语义：不减编码字节数
    }
}

pub fn parse(data: []const u8, allocator: std.mem.Allocator) !Parsed {
    if (data.len < 4 or !std.mem.eql(u8, data[0..4], "MPCK")) return error.Corrupt;
    var ap_list = std.ArrayList(APChunk).empty;
    errdefer ap_list.deinit(allocator);

    var cfg: Cfg = undefined;
    var have_sh = false;

    var pos: usize = 4;
    while (pos + 2 <= data.len) {
        const tag = data[pos .. pos + 2];
        var q = pos + 2;
        const raw = readVarlen(data, &q);
        if (raw < 0) break;
        const payload_len: u64 = @intCast(raw - @as(i64, @intCast(q - pos)));
        const start = q;
        const end = start + payload_len;
        if (end > data.len) break;
        if (std.mem.eql(u8, tag, "SH")) {
            const sh = data[start..end];
            if (sh.len < 7) return error.Corrupt;
            if (sh[4] != 8) return error.Corrupt; // 仅 SV8
            var sp: usize = 5;
            const samples = readVarlen(sh, &sp);
            if (samples < 0) return error.Corrupt;
            _ = readVarlen(sh, &sp); // silence samples
            if (sp + 2 > sh.len) return error.Corrupt;
            const ex = sh[sp .. sp + 2];
            var gb = vlc.BitReader{ .data = ex };
            const sr_idx = gb.bits(3);
            const srates = [4]u32{ 44100, 48000, 37800, 32000 };
            if (sr_idx >= 4) return error.Corrupt;
            cfg.sample_rate = srates[sr_idx];
            const maxbands: i32 = @intCast(gb.bits(5) + 1);
            if (maxbands >= SBLIMIT) return error.Corrupt;
            cfg.maxbands = maxbands;
            const channels: u8 = @intCast(gb.bits(4) + 1);
            if (channels > 2) return error.Corrupt;
            cfg.channels = channels;
            cfg.mss = gb.bit() != 0;
            cfg.frames = @as(u16, 1) << @intCast(gb.bits(3) * 2);
            cfg.total_samples = samples;
            have_sh = true;
        } else if (std.mem.eql(u8, tag, "AP")) {
            try ap_list.append(allocator, .{ .off = start, .len = payload_len });
        } else if (std.mem.eql(u8, tag, "SE")) {
            break;
        }
        pos = end;
    }
    if (!have_sh) return error.Corrupt;
    const aps = try ap_list.toOwnedSlice(allocator);
    return .{ .cfg = cfg, .aps = aps, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// SV8 帧解码状态（解码器实例；跨帧/跨 AP 持续）
// ---------------------------------------------------------------------------

pub const Decoder8 = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    parsed: Parsed,
    core: synth.MpcCore = .{},
    /// 内部 VLC 表
    band_vlc: vlc.Vlc = vlc.Vlc.init(),
    scfi_vlc: [2]vlc.Vlc = .{ vlc.Vlc.init(), vlc.Vlc.init() },
    dscf_vlc: [2]vlc.Vlc = .{ vlc.Vlc.init(), vlc.Vlc.init() },
    res_vlc: [2]vlc.Vlc = .{ vlc.Vlc.init(), vlc.Vlc.init() },
    q1_vlc: vlc.Vlc = vlc.Vlc.init(),
    q9up_vlc: vlc.Vlc = vlc.Vlc.init(),
    q2_vlc: [2]vlc.Vlc = .{ vlc.Vlc.init(), vlc.Vlc.init() },
    q3_vlc: [2]vlc.Vlc = .{ vlc.Vlc.init(), vlc.Vlc.init() },
    quant_vlc: [4][2]vlc.Vlc = .{ .{ vlc.Vlc.init(), vlc.Vlc.init() }, .{ vlc.Vlc.init(), vlc.Vlc.init() }, .{ vlc.Vlc.init(), vlc.Vlc.init() }, .{ vlc.Vlc.init(), vlc.Vlc.init() } },

    cur_chunk: usize = 0,
    /// 相对当前 AP chunk 载荷的位偏移
    bitpos: u64 = 0,
    /// 当前 chunk 内帧计数（与 FFmpeg mpc8 一致：跨 chunk 持续，
    /// 达 cfg.frames 回绕即 keyframe —— 标准编码的 AP chunk 恰含 frames 帧，
    /// 故 wrap 位置 == chunk 边界）
    cur_frame: u16 = 0,
    last_max_band: i32 = 0,
    /// 当前 chunk 的总位数
    chunk_total_bits: u64 = 0,
    eof: bool = false,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Decoder8 {
        var d: Decoder8 = .{ .allocator = allocator, .data = data, .parsed = undefined };
        d.parsed = try parse(data, allocator);
        d.core.init();
        d.buildVlcs();
        if (d.parsed.aps.len > 0) {
            d.chunk_total_bits = d.parsed.aps[0].len * 8;
        } else {
            d.eof = true;
        }
        return d;
    }

    pub fn deinit(self: *Decoder8) void {
        self.parsed.deinit();
    }

    fn buildVlcs(self: *Decoder8) void {
        const t = &tables;
        self.band_vlc.build(33, &vlc.lensFromCounts(t.mpc8_bands_len_counts, 33), &vlc.symsU16(&t.mpc8_bands_syms), 0);
        self.q1_vlc.build(19, &vlc.lensFromCounts(t.mpc8_q1_len_counts, 19), &vlc.symsU16(&t.q1_syms), 0);
        self.q9up_vlc.build(256, &vlc.lensFromCounts(t.mpc8_q9up_len_counts, 256), &vlc.symsU16(&t.q9up_syms), 0);
        self.scfi_vlc[0].build(4, &vlc.lensFromCounts(t.mpc8_scfi_len_counts[0], 4), &vlc.symsU16(&t.mpc8_scfi0_syms), 0);
        self.scfi_vlc[1].build(16, &vlc.lensFromCounts(t.mpc8_scfi_len_counts[1], 16), &vlc.symsU16(&t.mpc8_scfi1_syms), 0);
        self.dscf_vlc[0].build(64, &vlc.lensFromCounts(t.mpc8_dscf_len_counts[0], 64), &vlc.symsU16(&t.mpc8_dscf0_syms), 0);
        self.dscf_vlc[1].build(65, &vlc.lensFromCounts(t.mpc8_dscf_len_counts[1], 65), &vlc.symsU16(&t.mpc8_dscf1_syms), 0);
        self.res_vlc[0].build(17, &vlc.lensFromCounts(t.mpc8_res_len_counts[0], 17), &vlc.symsU16(&t.mpc8_res0_syms), 0);
        self.res_vlc[1].build(17, &vlc.lensFromCounts(t.mpc8_res_len_counts[1], 17), &vlc.symsU16(&t.mpc8_res1_syms), 0);
        self.q2_vlc[0].build(125, &vlc.lensFromCounts(t.mpc8_q2_len_counts[0], 125), &vlc.symsU16(&t.q2_0_syms), 0);
        self.q2_vlc[1].build(125, &vlc.lensFromCounts(t.mpc8_q2_len_counts[1], 125), &vlc.symsU16(&t.q2_1_syms), 0);
        self.q3_vlc[0].build(49, &vlc.lensFromCounts(t.mpc8_q34_len_counts[0], 49), &vlc.symsU16(&t.q3_0_syms), -48);
        self.q3_vlc[1].build(81, &vlc.lensFromCounts(t.mpc8_q34_len_counts[1], 81), &vlc.symsU16(&t.q4_syms), -64);
        const q5sizes = [4]usize{ 15, 31, 63, 127 };
        const q5off = [4]i32{ -7, -15, -31, -63 };
        inline for (0..4) |j| {
            inline for (0..2) |i| {
                const syms_u8 = comptime switch (@as(usize, j) * 2 + i) {
                    0 => &t.q5_0_syms,
                    1 => &t.q5_1_syms,
                    2 => &t.q6_0_syms,
                    3 => &t.q6_1_syms,
                    4 => &t.q7_0_syms,
                    5 => &t.q7_1_syms,
                    6 => &t.q8_0_syms,
                    7 => &t.q8_1_syms,
                    else => unreachable,
                };
                const syms = comptime vlc.symsU16(syms_u8);
                const counts = comptime t.mpc8_q5_8_len_counts[i][j];
                const lens = comptime vlc.lensFromCounts(counts, q5sizes[j]);
                self.quant_vlc[j][i].build(q5sizes[j], &lens, &syms, q5off[j]);
            }
        }
    }

    /// 生成下一帧 1152×ch 样本到 out_planar；返回 false = EOF。
    /// out 布局 [ch][1152]（对应 FFmpeg planar S16）。
    pub fn next(self: *Decoder8, out_planar: *[2][MPC_FRAME_SIZE]i16) bool {
        if (self.eof) return false;
        while (true) {
            if (self.cur_chunk >= self.parsed.aps.len) {
                self.eof = true;
                return false;
            }
            const chunk = self.parsed.aps[self.cur_chunk];
            const payload = self.data[chunk.off .. chunk.off + chunk.len];
            const total_bits = @as(u64, chunk.len) * 8;
            if (self.bitpos + 8 > total_bits) {
                // 本 chunk 已无足够位（FFmpeg overread 语义：整包吞掉，帧计数不回绕）
                self.cur_chunk += 1;
                self.bitpos = 0;
                continue;
            }
            const keyframe = self.cur_frame == 0;
            var br = vlc.BitReader{ .data = payload };
            br.pos = self.bitpos;
            if (self.decodeFrame(&br, keyframe, out_planar)) |_| {} else |_| {
                // 帧截断：FFmpeg 置 got_frame=0 并吞掉该 chunk 剩余字节（帧计数不回绕）
                self.cur_chunk += 1;
                self.bitpos = 0;
                continue;
            }
            self.bitpos = br.pos;
            // 帧计数推进；达 frames 回绕 → 下一帧即 keyframe，chunk 同步结束
            // （FFmpeg：cur_frame==0 时返回整包，丢弃其后 >8 位的填充）
            var wrapped = false;
            self.cur_frame += 1;
            if (self.cur_frame >= self.parsed.cfg.frames) {
                self.cur_frame = 0;
                wrapped = true;
            }
            if (wrapped or self.bitpos + 8 > total_bits) {
                self.cur_chunk += 1;
                self.bitpos = 0;
            }
            return true;
        }
    }

    fn decodeFrame(self: *Decoder8, br: *vlc.BitReader, keyframe: bool, out_planar: *[2][MPC_FRAME_SIZE]i16) !void {
        const c = &self.core;
        const cfg = &self.parsed.cfg;
        var maxband: i32 = 0;

        if (keyframe) {
            c.Q = [_][MPC_FRAME_SIZE]i32{[_]i32{0} ** MPC_FRAME_SIZE} ** 2;
        }

        if (keyframe) {
            maxband = @intCast(vlc.getModGolomb(br, @as(usize, @intCast(cfg.maxbands + 1))));
        } else {
            const delta = self.band_vlc.get(br);
            maxband = self.last_max_band + delta;
            if (maxband > 32) maxband -= 33;
        }

        if (br.left() < 0) return error.Truncated;
        if (maxband > cfg.maxbands + 1) return error.Corrupt;
        self.last_max_band = maxband;

        // 子带索引（降序）
        if (maxband > 0) {
            var last: [2]i32 = .{ 0, 0 };
            var i: i32 = maxband - 1;
            while (i >= 0) : (i -= 1) {
                const bi: usize = @intCast(i);
                var ch: usize = 0;
                while (ch < 2) : (ch += 1) {
                    const rv = self.res_vlc[if (last[ch] > 2) @as(usize, 1) else 0].get(br);
                    last[ch] = rv + last[ch];
                    if (last[ch] > 15) last[ch] -= 17;
                    c.bands[bi].res[ch] = last[ch];
                }
            }
            if (cfg.mss) {
                var cnt: usize = 0;
                var k: usize = 0;
                while (k < maxband) : (k += 1) {
                    if (c.bands[k].res[0] != 0 or c.bands[k].res[1] != 0) cnt += 1;
                }
                const t = vlc.getModGolomb(br, cnt);
                var mask = vlc.getMask(br, cnt, @intCast(t));
                var ii: i32 = maxband - 1;
                while (ii >= 0) : (ii -= 1) {
                    const bi: usize = @intCast(ii);
                    if (c.bands[bi].res[0] != 0 or c.bands[bi].res[1] != 0) {
                        c.bands[bi].msf = (mask & 1) != 0;
                        mask >>= 1;
                    }
                }
            }
        }
        var i: i32 = maxband;
        while (i < cfg.maxbands) : (i += 1) {
            c.bands[@intCast(i)].res = .{ 0, 0 };
        }

        if (keyframe) {
            for (0..32) |k| {
                c.oldDSCF[0][k] = 1;
                c.oldDSCF[1][k] = 1;
            }
        }

        // SCFI
        var kk: usize = 0;
        while (kk < @as(usize, @intCast(maxband))) : (kk += 1) {
            if (c.bands[kk].res[0] != 0 or c.bands[kk].res[1] != 0) {
                const cnt: i32 = @as(i32, @intFromBool(c.bands[kk].res[0] != 0)) + @as(i32, @intFromBool(c.bands[kk].res[1] != 0)) - 1;
                if (cnt >= 0) {
                    const t = self.scfi_vlc[@intCast(cnt)].get(br);
                    if (c.bands[kk].res[0] != 0) c.bands[kk].scfi[0] = t >> @intCast(2 * cnt);
                    if (c.bands[kk].res[1] != 0) c.bands[kk].scfi[1] = t & 3;
                }
            }
        }

        // SCF 索引
        kk = 0;
        while (kk < @as(usize, @intCast(maxband))) : (kk += 1) {
            var ch: usize = 0;
            while (ch < 2) : (ch += 1) {
                if (c.bands[kk].res[ch] == 0) continue;
                var t: i32 = undefined;
                if (c.oldDSCF[ch][kk] != 0) {
                    c.bands[kk].scf_idx[ch][0] = @as(i32, @intCast(br.bits(7))) - 6;
                    c.oldDSCF[ch][kk] = 0;
                } else {
                    t = self.dscf_vlc[1].get(br);
                    if (t == 64) t += @as(i32, @intCast(br.bits(6)));
                    c.bands[kk].scf_idx[ch][0] = ((c.bands[kk].scf_idx[ch][2] + t - 25) & 0x7F) - 6;
                }
                var j: usize = 0;
                while (j < 2) : (j += 1) {
                    if ((c.bands[kk].scfi[ch] << @intCast(j)) & 2 != 0) {
                        c.bands[kk].scf_idx[ch][j + 1] = c.bands[kk].scf_idx[ch][j];
                    } else {
                        t = self.dscf_vlc[0].get(br);
                        if (t == 31) t = 64 + @as(i32, @intCast(br.bits(6)));
                        c.bands[kk].scf_idx[ch][j + 1] = ((c.bands[kk].scf_idx[ch][j] + t - 25) & 0x7F) - 6;
                    }
                }
            }
        }

        // 量化样本
        var off: usize = 0;
        i = 0;
        while (i < maxband) : (i += 1) {
            const bi: usize = @intCast(i);
            var ch: usize = 0;
            while (ch < 2) : (ch += 1) {
                const res = c.bands[bi].res[ch];
                const qch = &c.Q[ch];
                switch (res) {
                    -1 => {
                        var j: usize = 0;
                        while (j < SAMPLES_PER_BAND) : (j += 1) {
                            qch[off + j] = @as(i32, @intCast(c.rnd.next() & 0x3FC)) - 510;
                        }
                    },
                    0 => {},
                    1 => {
                        var j: usize = 0;
                        while (j < SAMPLES_PER_BAND) : (j += 18) {
                            const cnt = self.q1_vlc.get(br);
                            const t = vlc.getMask(br, 18, @intCast(cnt));
                            var k: usize = 0;
                            while (k < 18) : (k += 1) {
                                qch[off + j + k] = if (t & (@as(u32, 1) << @intCast(17 - k)) != 0)
                                    (@as(i32, @intCast(br.bit())) << 1) - 1
                                else
                                    0;
                            }
                        }
                    },
                    2 => {
                        var cnt: i32 = 6;
                        var j: usize = 0;
                        while (j < SAMPLES_PER_BAND) : (j += 3) {
                            const t = self.q2_vlc[if (cnt > 3) @as(usize, 1) else 0].get(br);
                            qch[off + j + 0] = tables.mpc8_idx50[@intCast(t)];
                            qch[off + j + 1] = tables.mpc8_idx51[@intCast(t)];
                            qch[off + j + 2] = tables.mpc8_idx52[@intCast(t)];
                            cnt = (cnt >> 1) + tables.mpc8_huffq2[@intCast(t)];
                        }
                    },
                    3, 4 => {
                        var j: usize = 0;
                        while (j < SAMPLES_PER_BAND) : (j += 2) {
                            const t = self.q3_vlc[@intCast(res - 3)].get(br);
                            qch[off + j + 1] = t >> 4;
                            qch[off + j + 0] = signExtend(t, 4);
                        }
                    },
                    5...8 => {
                        const th: i32 = @intCast(tables.mpc8_thres[@intCast(res)]);
                        var cnt: i32 = 2 * th;
                        var j: usize = 0;
                        while (j < SAMPLES_PER_BAND) : (j += 1) {
                            const qv = self.quant_vlc[@intCast(res - 5)][if (cnt > th) @as(usize, 1) else 0].get(br);
                            qch[off + j] = qv;
                            const aq: i32 = if (qv < 0) -qv else qv;
                            cnt = (cnt >> 1) + aq;
                        }
                    },
                    else => {
                        // res >= 9
                        var j: usize = 0;
                        while (j < SAMPLES_PER_BAND) : (j += 1) {
                            var t: i32 = self.q9up_vlc.get(br);
                            if (res != 9) {
                                t <<= @intCast(res - 9);
                                t |= @as(i32, @intCast(br.bits(@intCast(res - 9))));
                            }
                            qch[off + j] = t - ((@as(i32, 1) << @intCast(res - 2)) - 1);
                        }
                    },
                }
            }
            off += SAMPLES_PER_BAND;
        }

        // 去量化 + 合成（每帧输出 planar 1152）
        synth.dequantizeAndSynth(c, maxband - 1, out_planar, cfg.channels);
    }
};

inline fn signExtend(val: i32, bits: u32) i32 {
    const sh: u5 = @intCast(32 - bits);
    return (val << sh) >> sh;
}
