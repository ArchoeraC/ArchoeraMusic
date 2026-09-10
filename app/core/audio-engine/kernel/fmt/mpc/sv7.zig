// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! Musepack SV7 解码 —— FFmpeg n9.0.1 libavcodec/mpc7.c + libavformat/mpc.c
//! （SV7 分支）逐句移植。
//!
//! 容器：`MP+\x07/\x17` 打包帧流。头部 8 字节（魔数+版本 / fcount LE u32）后跟
//! 16 字节 extradata；帧表由 mpc_read_packet 的逐帧链式推导重建（20-bit 帧长
//! 场 + 32-bit 字内位偏移 curbits 链），与 FFmpeg 解封装逐字节一致。
//!
//! 解码（mpc7_decode_frame）：
//!   - 包前 4 字节为 [skip, last_frame, 0, 0]；载荷按 32-bit 字 bswap（LE 存储
//!     → MSB-first 位流），skip_bits_long(skip) 后进入位流；
//!   - 逐子带 res（首带 4-bit 原码，其后 hdr_vlc 差分）、MSS 强度标志、
//!     scfi_vlc / dscf_vlc 标度索引差分链、idx_to_quant 量化样本；
//!   - 尾部复用 synth.zig 的 ff_mpc_dequantize_and_synth（CC×SCF 浮点去量化 +
//!     MPEG 定点合成滤波），帧间状态（oldDSCF/合成窗/LFG 噪声）跨帧持续。
//!
//! last_frame/lastframelen（mpc7.c 的末帧截断）：demux 侧 data[1] =
//! (curframe > fcount) && fcount 在 fcount>0 时恒为 0（curframe 自增后至多等于
//! fcount），故 FFmpeg 实际解码路径永远输出整帧 1152 样本 —— 本实现保持一致，
//! 仅保留字段以对齐结构。
//!
//! 验证目标：与 `ffmpeg n9.0.1 -i x.mpc -f s16le` 逐位一致
//! （FATE inside-mp7.mpc 全流 456 帧已对齐）。

const std = @import("std");
const synth = @import("synth.zig");
const vlc = @import("vlc.zig");
const tables = @import("tables.zig");

pub const Error = error{ Corrupt, OutOfMemory };

const SBLIMIT = synth.SBLIMIT;
const SAMPLES_PER_BAND = synth.SAMPLES_PER_BAND;
const MPC_FRAME_SIZE = synth.MPC_FRAME_SIZE;
const BANDS = 32;

/// FFmpeg mpc demuxer：DELAY_FRAMES（seek 预热丢弃帧数）
pub const DELAY_FRAMES = 32;
/// mpc_rate[extradata[2] & 3]（libavformat/mpc.c）
const mpc_rate = [4]u32{ 44100, 48000, 37800, 32000 };

/// 头部/extradata 解析出的解码器配置（mpc7_decode_init）
pub const Cfg = struct {
    sample_rate: u32,
    /// IS 标志（mpc7.c 读取但不参与解码路径）
    is: bool,
    mss: bool,
    maxbands: i32,
    gapless: bool,
    lastframelen: u32,
    /// 容器声明的帧总数（fcount；0 = 未声明）
    fcount: u32,
};

/// 一帧的封装参数（mpc_read_packet 推导；pos 指向文件内载荷起点）
pub const Frame = struct {
    pos: usize,
    /// 载荷字节数（4 的倍数；含帧尾填充到 32-bit 字边界）
    size: usize,
    /// 帧起始位偏移（pkt->data[0]：含 20-bit 帧长场，解码器先 skip 的位数）
    skip: u32,
    /// data[1] 语义（见模块注释：实际恒为 false）
    last: bool,
};

pub const Parsed = struct {
    cfg: Cfg,
    frames: []Frame,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Parsed) void {
        self.allocator.free(self.frames);
    }
};

/// 逐句复刻 mpc_read_header（extradata 位域）+ mpc_read_packet（帧链推导）。
/// data 生命周期须覆盖解码。fcount==0 时按 FFmpeg 行为读到数据耗尽为止。
pub fn parse(data: []const u8, allocator: std.mem.Allocator) Error!Parsed {
    if (data.len < 24) return error.Corrupt;
    if (!std.mem.eql(u8, data[0..3], "MP+")) return error.Corrupt;
    const ver = data[3];
    if (ver != 7 and ver != 0x17) return error.Corrupt; // 仅 SV7
    const fcount = std.mem.readInt(u32, data[4..8], .little);
    // FFmpeg：fcount * sizeof(MPCFrame) >= UINT_MAX → AVERROR_INVALIDDATA
    if (@as(u64, fcount) * @sizeOf(Frame) >= std.math.maxInt(u32)) return error.Corrupt;

    // ---- mpc7_decode_init：extradata 16 字节 bswap 后读位域 ----
    const extradata = data[8..24];
    var hdr: [16]u8 = undefined;
    @memcpy(&hdr, extradata);
    bswapBuf(&hdr);
    var gb = vlc.BitReader{ .data = &hdr };
    var cfg: Cfg = .{
        .sample_rate = mpc_rate[extradata[2] & 3],
        .is = gb.bit() != 0,
        .mss = gb.bit() != 0,
        .maxbands = @intCast(gb.bits(6)),
        .gapless = undefined,
        .lastframelen = undefined,
        .fcount = fcount,
    };
    if (cfg.maxbands >= BANDS) return error.Corrupt;
    gb.pos += 88; // skip_bits_long(&gb, 88)
    cfg.gapless = gb.bit() != 0;
    cfg.lastframelen = gb.bits(11);

    // ---- mpc_read_packet：帧链推导 ----
    var frames = std.ArrayList(Frame).empty;
    errdefer frames.deinit(allocator);
    var curbits: u32 = 8;
    var pos: usize = 24;
    var cur: u32 = 0;
    while (true) {
        // `if (c->curframe >= c->fcount && c->fcount) return AVERROR_EOF;`
        if (fcount != 0 and cur >= fcount) break;
        // 需要读 1–2 个 LE u32 推导帧长；位置越过文件尾 → avio 语义失败，停止
        const need: usize = if (curbits <= 12) 4 else 8;
        if (pos + need > data.len) break;
        const tmp = std.mem.readInt(u32, data[pos..][0..4], .little);
        var size2: u32 = undefined;
        if (curbits <= 12) {
            size2 = (tmp >> @intCast(12 - curbits)) & 0xFFFFF;
        } else {
            const tmp2 = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
            size2 = ((tmp << @intCast(curbits - 12)) | (tmp2 >> @intCast(44 - curbits))) & 0xFFFFF;
        }
        curbits += 20;
        const size = ((size2 + curbits + 31) & ~@as(u32, 31)) >> 3;
        const pkt_last = fcount != 0 and (cur + 1) > fcount;
        // avio_read 不足 size 字节（文件截断）→ AVERROR_INVALIDDATA，该包丢弃
        if (pos + size > data.len) break;
        // 退化防护：合法帧至少含 res/scf/量化位流，4 字节装不下；
        // 防止 size<=4 且 curbits!=0 时 pos 不前进的死循环（FFmpeg 无此防护）
        if (size <= 4) break;
        // pkt->data[0] = curbits（局部变量，+= 20 之后的值）：解码器跳过
        // 20-bit 帧长场，从帧数据起点开始；（curbits-20 只存 seek 表，不进包）
        try frames.append(allocator, .{
            .pos = pos,
            .size = size,
            .skip = curbits,
            .last = pkt_last,
        });
        cur += 1;
        const new_curbits = (curbits + size2) & 0x1F;
        pos += size;
        if (new_curbits != 0) pos -= 4; // `if (c->curbits) avio_seek(-4)`
        curbits = new_curbits;
    }

    const fl = try frames.toOwnedSlice(allocator);
    return .{ .cfg = cfg, .frames = fl, .allocator = allocator };
}

/// bdsp.bswap_buf：按 32-bit 字字节反转（LE 存储位流 → MSB-first 读取序）
fn bswapBuf(buf: []u8) void {
    var off: usize = 0;
    while (off + 4 <= buf.len) : (off += 4) {
        const t = buf[off];
        buf[off] = buf[off + 3];
        buf[off + 3] = t;
        const u = buf[off + 1];
        buf[off + 1] = buf[off + 2];
        buf[off + 2] = u;
    }
}

// ---------------------------------------------------------------------------
// 解码器实例（mpc7_decode_frame 状态；跨帧持续）
// ---------------------------------------------------------------------------

pub const Decoder7 = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    parsed: Parsed,
    core: synth.MpcCore = .{},
    scfi_vlc: vlc.Vlc = vlc.Vlc.init(),
    dscf_vlc: vlc.Vlc = vlc.Vlc.init(),
    hdr_vlc: vlc.Vlc = vlc.Vlc.init(),
    quant_vlc: [7][2]vlc.Vlc = .{ .{ vlc.Vlc.init(), vlc.Vlc.init() }, .{ vlc.Vlc.init(), vlc.Vlc.init() }, .{ vlc.Vlc.init(), vlc.Vlc.init() }, .{ vlc.Vlc.init(), vlc.Vlc.init() }, .{ vlc.Vlc.init(), vlc.Vlc.init() }, .{ vlc.Vlc.init(), vlc.Vlc.init() }, .{ vlc.Vlc.init(), vlc.Vlc.init() } },
    /// bswap 载荷暂存（init 时按最大帧分配）
    scratch: []u8 = &.{},

    cur_frame: usize = 0,
    eof: bool = false,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Error!Decoder7 {
        var d: Decoder7 = .{ .allocator = allocator, .data = data, .parsed = undefined };
        d.parsed = try parse(data, allocator);
        errdefer d.parsed.deinit();
        // mpc7_decode_init：oldDSCF 清零、LFG 种子 0xDEADBEEF、合成状态清零
        d.core.init();
        d.buildVlcs();
        var max_size: usize = 0;
        for (d.parsed.frames) |f| max_size = @max(max_size, f.size);
        if (max_size > 0) d.scratch = try allocator.alloc(u8, max_size);
        return d;
    }

    pub fn deinit(self: *Decoder7) void {
        self.parsed.deinit();
        if (self.scratch.len > 0) self.allocator.free(self.scratch);
        self.scratch = &.{};
    }

    /// 重置到指定帧起点（seek 预热入口）：状态清零并跳过前 frame 帧。
    /// 等价 FFmpeg 语义：avcodec_flush_buffers（oldDSCF 清零）+ demuxer
    /// 跳转到 frames[frame] 包起点；LFG 重新播种（与"全新解码会话后立即
    /// seek"的 FFmpeg 路径一致；会话中途 seek 的 rnd 连续性见 lib.zig 说明）。
    pub fn resetTo(self: *Decoder7, frame: usize) void {
        self.core.init();
        self.cur_frame = frame;
        self.eof = frame >= self.parsed.frames.len;
    }

    fn buildVlcs(self: *Decoder7) void {
        // VLC_INIT_STATIC_TABLE_FROM_LENGTHS：偶数字节为符号、奇数字节为码长
        //（ff_vlc_init_from_lengths 按输入顺序增量分配码字），offset 加在符号上。
        const t = &tables;
        self.scfi_vlc.build(4, &t.mpc7_scfi_lens, &vlc.symsU16(&t.mpc7_scfi_codes), 0);
        self.dscf_vlc.build(16, &t.mpc7_dscf_lens, &vlc.symsU16(&t.mpc7_dscf_codes), -7);
        self.hdr_vlc.build(10, &t.mpc7_hdr_lens, &vlc.symsU16(&t.mpc7_hdr_codes), -5);
        inline for (0..7) |i| {
            inline for (0..2) |j| {
                const pair = comptime switch (i * 2 + j) {
                    0 => .{ &t.mpc7_quant_0_0_codes, &t.mpc7_quant_0_0_lens },
                    1 => .{ &t.mpc7_quant_0_1_codes, &t.mpc7_quant_0_1_lens },
                    2 => .{ &t.mpc7_quant_1_0_codes, &t.mpc7_quant_1_0_lens },
                    3 => .{ &t.mpc7_quant_1_1_codes, &t.mpc7_quant_1_1_lens },
                    4 => .{ &t.mpc7_quant_2_0_codes, &t.mpc7_quant_2_0_lens },
                    5 => .{ &t.mpc7_quant_2_1_codes, &t.mpc7_quant_2_1_lens },
                    6 => .{ &t.mpc7_quant_3_0_codes, &t.mpc7_quant_3_0_lens },
                    7 => .{ &t.mpc7_quant_3_1_codes, &t.mpc7_quant_3_1_lens },
                    8 => .{ &t.mpc7_quant_4_0_codes, &t.mpc7_quant_4_0_lens },
                    9 => .{ &t.mpc7_quant_4_1_codes, &t.mpc7_quant_4_1_lens },
                    10 => .{ &t.mpc7_quant_5_0_codes, &t.mpc7_quant_5_0_lens },
                    11 => .{ &t.mpc7_quant_5_1_codes, &t.mpc7_quant_5_1_lens },
                    12 => .{ &t.mpc7_quant_6_0_codes, &t.mpc7_quant_6_0_lens },
                    13 => .{ &t.mpc7_quant_6_1_codes, &t.mpc7_quant_6_1_lens },
                    else => unreachable,
                };
                const syms = comptime vlc.symsU16(pair[0]);
                self.quant_vlc[i][j].build(t.mpc7_quant_vlc_sizes[i], pair[1], &syms, t.mpc7_quant_vlc_off[i]);
            }
        }
    }

    /// 解码下一帧到 out_planar（[2][1152]）；返回 false = EOF。
    /// 帧解码失败时跳过该帧输出继续（FFmpeg 丢包继续解封装语义）。
    pub fn next(self: *Decoder7, out_planar: *[2][MPC_FRAME_SIZE]i16) bool {
        while (true) {
            if (self.eof or self.cur_frame >= self.parsed.frames.len) {
                self.eof = true;
                return false;
            }
            const f = self.parsed.frames[self.cur_frame];
            self.cur_frame += 1;
            if (self.decodeFrame(f, out_planar)) |_| {
                return true;
            } else |_| {
                // FFmpeg：decode_frame 出错 → 本包无输出，状态保持，继续下一包
                continue;
            }
        }
    }

    /// mpc7_decode_frame 主体
    fn decodeFrame(self: *Decoder7, f: Frame, out_planar: *[2][MPC_FRAME_SIZE]i16) Error!void {
        const c = &self.core;
        const cfg = &self.parsed.cfg;
        const payload = self.data[f.pos .. f.pos + f.size];
        // buf_size = avpkt->size & ~3 - 4：size 恒为 4 的倍数（demuxer 对齐）
        const buf_size = f.size;

        // bswap_buf → MSB-first 位流
        const scratch = self.scratch[0..buf_size];
        @memcpy(scratch, payload);
        bswapBuf(scratch);
        var br = vlc.BitReader{ .data = scratch };
        br.pos = f.skip; // skip_bits_long(&gb, skip)

        // 本帧 bands[0..=maxbands] 清零（FFmpeg memset sizeof(*bands)*(maxbands+1)）
        for (0..@as(usize, @intCast(cfg.maxbands)) + 1) |i| {
            c.bands[i] = .{};
        }

        // 读子带量化指数（res）
        var mb: i32 = -1;
        var i: usize = 0;
        while (i <= @as(usize, @intCast(cfg.maxbands))) : (i += 1) {
            for (0..2) |ch| {
                const t: i32 = if (i != 0) self.hdr_vlc.get(&br) else 4;
                var res: i32 = undefined;
                if (t == 4) {
                    res = @intCast(br.bits(4));
                } else {
                    res = c.bands[i - 1].res[ch] + t;
                }
                if (res < -1 or res > 17) return error.Corrupt;
                c.bands[i].res[ch] = res;
            }
            if (c.bands[i].res[0] != 0 or c.bands[i].res[1] != 0) {
                mb = @intCast(i);
                if (cfg.mss) c.bands[i].msf = br.bit() != 0;
            }
        }

        // 标度因子编码方式（scfi）；mb 可为 -1（全静音帧，两段循环均不执行）
        var ii: i32 = 0;
        while (ii <= mb) : (ii += 1) {
            const bi: usize = @intCast(ii);
            for (0..2) |ch| {
                if (c.bands[bi].res[ch] != 0) {
                    c.bands[bi].scfi[ch] = self.scfi_vlc.get(&br);
                }
            }
        }

        // 标度因子索引（差分链 + oldDSCF）
        ii = 0;
        while (ii <= mb) : (ii += 1) {
            const bi: usize = @intCast(ii);
            for (0..2) |ch| {
                if (c.bands[bi].res[ch] != 0) {
                    var idx3: [3]i32 = undefined;
                    idx3[2] = c.oldDSCF[ch][bi];
                    idx3[0] = getScaleIdx(self, &br, idx3[2]);
                    switch (c.bands[bi].scfi[ch]) {
                        0 => {
                            idx3[1] = getScaleIdx(self, &br, idx3[0]);
                            idx3[2] = getScaleIdx(self, &br, idx3[1]);
                        },
                        1 => {
                            idx3[1] = getScaleIdx(self, &br, idx3[0]);
                            idx3[2] = idx3[1];
                        },
                        2 => {
                            idx3[1] = idx3[0];
                            idx3[2] = getScaleIdx(self, &br, idx3[1]);
                        },
                        3 => {
                            idx3[2] = idx3[0];
                            idx3[1] = idx3[0];
                        },
                        else => return error.Corrupt,
                    }
                    c.bands[bi].scf_idx[ch] = idx3;
                    c.oldDSCF[ch][bi] = idx3[2];
                }
            }
        }

        // 量化样本（Q 每帧清零；全 32 子带按 res 填充）
        for (0..2) |ch| @memset(&c.Q[ch], 0);
        var off: usize = 0;
        i = 0;
        while (i < BANDS) : (i += 1) {
            for (0..2) |ch| {
                try idxToQuant(self, &br, c.bands[i].res[ch], c.Q[ch][off .. off + SAMPLES_PER_BAND]);
            }
            off += SAMPLES_PER_BAND;
        }

        // 去量化 + 合成（mpc.c 共用路径；mb 可为 -1 = 全静音帧）
        synth.dequantizeAndSynth(c, mb, out_planar, 2);

        // 位使用量校验（FFmpeg：超出或剩余 ≥32 位 → 帧错误；last_frame 豁免，
        // 见模块注释——data[1] 恒 0，故校验恒生效）
        const bits_used: i64 = @intCast(br.pos);
        const bits_avail: i64 = @intCast(buf_size * 8);
        if (!f.last and (bits_avail < bits_used or bits_used + 32 <= bits_avail)) {
            return error.Corrupt;
        }
    }
};

/// get_scale_idx（mpc7.c）：dscf_vlc 差分；t==8（原码 15）→ 6-bit 绝对值
inline fn getScaleIdx(d: *Decoder7, br: *vlc.BitReader, ref: i32) i32 {
    const t = d.dscf_vlc.get(br);
    if (t == 8) return @intCast(br.bits(6));
    return ref + t;
}

/// idx_to_quant（mpc7.c）：按 res 填充一个子带 36 个量化样本
fn idxToQuant(d: *Decoder7, br: *vlc.BitReader, idx: i32, dst: []i32) Error!void {
    switch (idx) {
        -1 => {
            // PNS：LFG 伪随机（帧间状态持续）
            for (0..SAMPLES_PER_BAND) |j| {
                dst[j] = @as(i32, @intCast(d.core.rnd.next() & 0x3FC)) - 510;
            }
        },
        1 => {
            const sel = br.bit();
            var j: usize = 0;
            while (j < SAMPLES_PER_BAND / 3) : (j += 1) {
                const t = d.quant_vlc[0][sel].get(br);
                dst[j * 3] = tables.mpc7_idx30[@intCast(t)];
                dst[j * 3 + 1] = tables.mpc7_idx31[@intCast(t)];
                dst[j * 3 + 2] = tables.mpc7_idx32[@intCast(t)];
            }
        },
        2 => {
            const sel = br.bit();
            var j: usize = 0;
            while (j < SAMPLES_PER_BAND / 2) : (j += 1) {
                const t = d.quant_vlc[1][sel].get(br);
                dst[j * 2] = tables.mpc7_idx50[@intCast(t)];
                dst[j * 2 + 1] = tables.mpc7_idx51[@intCast(t)];
            }
        },
        3, 4, 5, 6, 7 => {
            const sel = br.bit();
            const ti: usize = @intCast(idx - 1);
            for (0..SAMPLES_PER_BAND) |j| {
                dst[j] = d.quant_vlc[ti][sel].get(br);
            }
        },
        8...17 => {
            const t: i32 = (@as(i32, 1) << @intCast(idx - 2)) - 1;
            for (0..SAMPLES_PER_BAND) |j| {
                dst[j] = @as(i32, @intCast(br.bits(@intCast(idx - 1)))) - t;
            }
        },
        else => {
            // case 0 与 -2..-17：Q 保持清零
        },
    }
}

// ---------------------------------------------------------------------------
// 单测
// ---------------------------------------------------------------------------

const testing = std.testing;

test "sv7: parse 头部与帧链（FATE inside-mp7）" {
    const data = @embedFile("samples/inside-mp7.mpc");
    var parsed = try parse(data, testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 44100), parsed.cfg.sample_rate);
    try testing.expectEqual(true, parsed.cfg.mss);
    try testing.expectEqual(false, parsed.cfg.is);
    try testing.expectEqual(@as(i32, 28), parsed.cfg.maxbands);
    try testing.expectEqual(true, parsed.cfg.gapless);
    try testing.expectEqual(@as(u32, 117), parsed.cfg.lastframelen);
    // ffprobe 实测 456 包，载荷字节数逐帧一致（见 lib.zig 对拍说明）
    try testing.expectEqual(@as(u32, 456), parsed.cfg.fcount);
    try testing.expectEqual(@as(usize, 456), parsed.frames.len);
    // 首帧：pos=24 size=12 skip=28（8 位链偏移 + 20 位帧长场；FFmpeg demux 推导值）
    try testing.expectEqual(@as(usize, 24), parsed.frames[0].pos);
    try testing.expectEqual(@as(usize, 12), parsed.frames[0].size);
    try testing.expectEqual(@as(u32, 28), parsed.frames[0].skip);
    // 末帧为整帧输出（data[1] 恒 0）
    try testing.expectEqual(false, parsed.frames[455].last);
}

test "sv7: 全流解码帧数与位校验" {
    const alloc = testing.allocator;
    const data = @embedFile("samples/inside-mp7.mpc");
    var d = try Decoder7.init(alloc, data);
    defer d.deinit();
    var planar: [2][MPC_FRAME_SIZE]i16 = undefined;
    var frames: usize = 0;
    while (d.next(&planar)) frames += 1;
    try testing.expectEqual(@as(usize, 456), frames);
}
