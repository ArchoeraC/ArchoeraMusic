// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! DTS core 流帧扫描/统计（阶段一）
//!
//! 在整段缓冲上以 sync 定位 + 帧头 frame_size 前进的方式遍历 core 帧：
//!   - 相邻纯 core 流（裸 .dts / .dca，如 ffmpeg dca 编码器输出）逐帧无缝；
//!   - DTS-HD（core + EXSS/XLL 交错，如 fate-suite dtshd）core 帧之间存在
//!     EXSS 子流 → 帧间差额计入 skipped（core 帧本身仍可按 header 前进）；
//!   - 帧尾不足 / 悬挂 sync 视为尾部残留（residual）。
//!
//! 校验口径（供与 ffprobe/ffmpeg 对照）：core 帧数 = 解码 PCM 帧数，
//! total_samples = Σ npcmblocks×32，纯 core 文件 residual 应为 0。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const hdr = @import("header.zig");
const t = @import("tables.zig");

pub const Header = hdr.Header;
pub const ParseError = hdr.ParseError;
pub const ByteOrder = hdr.ByteOrder;
pub const parse = hdr.parse;
pub const detectOrder = hdr.detectOrder;
pub const frameSamples = hdr.frameSamples;

// ---- 阶段二：core → PCM 解码（dca_core / fixed 路径）----
pub const core = @import("core.zig");
pub const DcaDecoder = core.DcaDecoder;
pub const DecodedFrame = core.DecodedFrame;

// ---- 阶段三：DTS-HD 扩展（EXSS 描述 / XLL 无损解码 / LBR DTS Express）----
pub const exss = @import("exss.zig");
pub const xll = @import("xll.zig");
pub const lbr = @import("lbr.zig");

/// 定位下一处 core sync（16-bit BE/LE 形态之一）。返回偏移；无 → null。
pub fn findSync(buf: []const u8, from: usize, order: ByteOrder) ?usize {
    const be: []const u8 = &.{ 0x7F, 0xFE, 0x80, 0x01 };
    const le: []const u8 = &.{ 0xFE, 0x7F, 0x01, 0x80 };
    const pat = if (order == .le16) le else be;
    if (buf.len < 4 or from >= buf.len) return null;
    var i = from;
    while (i + 4 <= buf.len) : (i += 1) {
        if (std.mem.eql(u8, buf[i .. i + 4], pat)) return i;
    }
    return null;
}

/// 一帧：文件偏移 + 帧头
pub const Frame = struct {
    offset: usize,
    header: Header,
};

/// 全流统计（迭代到 EOF 时填充）
pub const Stats = struct {
    order: ByteOrder = .be16,
    /// 成功解析的 core 帧数
    frames: u64 = 0,
    /// core 帧字节合计（Σ frame_size，含 sync）
    core_bytes: u64 = 0,
    /// 帧间差额合计（EXSS / 填充等非 core 字节）
    skipped_bytes: u64 = 0,
    /// 尾部残留（最后一帧结束后的字节）
    residual_bytes: u64 = 0,
    /// 最后一帧跨过 EOF（文件截断/不完整）
    truncated: bool = false,
    /// Σ npcmblocks×32（core PCM 样本/声道）
    total_samples: u64 = 0,
    /// 首个帧的采样率（帧间一致的判据）
    sample_rate: u32 = 0,
    sample_rates_differ: bool = false,
    /// 首帧每帧样本数
    frame_samples_first: u32 = 0,
    errors: u64 = 0,

    /// 流时长（秒，按 total_samples / sample_rate）
    pub fn durationSec(self: *const Stats) f64 {
        if (self.sample_rate == 0) return 0;
        return @as(f64, @floatFromInt(self.total_samples)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// core 帧迭代器。next() 从文件起始按 sync 扫描；
/// 命中合法帧后按 frame_size 前进，帧间差额在下次定位时累计入 skipped。
pub const Iterator = struct {
    buf: []const u8,
    order: ByteOrder,
    pos: usize = 0,
    /// 上一帧结束位置（用于差额/残留）
    frame_end: usize = 0,
    has_frame: bool = false,
    stats: Stats = .{},

    pub fn init(buf: []const u8, order: ByteOrder) Iterator {
        return .{ .buf = buf, .order = order, .stats = .{ .order = order } };
    }

    /// 解析失败 → error（调用方自行选择 resync/终止）
    pub fn next(self: *Iterator) ?Frame {
        while (true) {
            const off = findSync(self.buf, self.pos, self.order) orelse {
                self.stats.residual_bytes = if (self.has_frame)
                    self.buf.len - @min(self.frame_end, self.buf.len)
                else
                    self.buf.len;
                return null;
            };

            const header = blk: {
                if (off + hdr.header_window > self.buf.len) {
                    // 帧头不足（截断）：跳过，避免死循环
                    self.stats.errors += 1;
                    self.pos = off + 1;
                    continue;
                }
                break :blk hdr.parse(self.buf[off .. off + hdr.header_window], self.order) catch {
                    // 伪 sync：前进 1 字节重新扫描
                    self.stats.errors += 1;
                    self.pos = off + 1;
                    continue;
                };
            };

            const end = off + header.frame_size;
            if (end > self.buf.len) {
                // 帧跨过 EOF（文件截断）：不计数该残帧，标记后停止
                self.stats.truncated = true;
                self.pos = self.buf.len;
                self.frame_end = self.buf.len;
                self.has_frame = true;
                return Frame{ .offset = off, .header = header };
            }

            if (self.has_frame and off > self.frame_end)
                self.stats.skipped_bytes += off - self.frame_end;

            self.stats.frames += 1;
            self.stats.core_bytes += header.frame_size;
            self.stats.total_samples += hdr.frameSamples(&header);
            if (self.stats.sample_rate == 0) {
                self.stats.sample_rate = header.sample_rate;
                self.stats.frame_samples_first = hdr.frameSamples(&header);
            } else if (self.stats.sample_rate != header.sample_rate) {
                self.stats.sample_rates_differ = true;
            }

            const f = Frame{ .offset = off, .header = header };
            self.pos = end;
            self.frame_end = end;
            self.has_frame = true;
            return f;
        }
    }

    /// 消费到 EOF，返回统计
    pub fn scan(self: *Iterator) Stats {
        while (self.next()) |_| {}
        return self.stats;
    }
};

/// core 声道/扩展判定（阶段一展示用；与 FFmpeg 输出声道数一致的简化模型）：
///   channels = popcount(ch_mask)；ch_mask = amode 表掩码 + LFE + XCH(Cs)。
/// X96 不增声道（提高采样率 2×）；XXCH 需读 XXCH 头才能定声道（阶段一仅标记）。
pub const ChannelInfo = struct {
    channels: u8,
    ch_mask: u32,
    base_channels: u8,
    lfe_present: bool,
    xch: bool,
    x96: bool,
    xxch: bool,
    es_format: bool,
};

pub fn channelConfig(h: *const Header) ChannelInfo {
    var mask: u32 = t.amode_ch_mask[h.audio_mode];
    const lfe = h.lfe_present != 0;
    if (lfe) mask |= t.speaker_lfe1;

    const ext = h.ext_audio_present;
    const xch = ext and h.ext_audio_type == t.ext_xch;
    const x96 = ext and h.ext_audio_type == t.ext_x96;
    const xxch = ext and h.ext_audio_type == t.ext_xxch;
    if (xch) mask |= t.speaker_cs;

    return .{
        .channels = t.countChannelsForMask(mask),
        .ch_mask = mask,
        .base_channels = t.channels_by_amode[h.audio_mode],
        .lfe_present = lfe,
        .xch = xch,
        .x96 = x96,
        .xxch = xxch,
        .es_format = h.es_format,
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
// 样本头部（真实 ffmpeg dca 编码器 / fate-suite dts_es 首帧前 64 字节）
const head_48s = @embedFile("test_head_48s.bin"); // 48k 立体声 512kbps
const head_48x = @embedFile("test_head_48x.bin"); // 48k 5.1(side)+LFE 1536kbps
const head_8m = @embedFile("test_head_8m.bin"); // 8k mono 512kbps
const head_es = @embedFile("test_head_es.bin"); // DTS-ES (XCH, 24bit)

const testing = std.testing;

test "dts: detectOrder 四种 sync 形态" {
    var be = [_]u8{ 0x7F, 0xFE, 0x80, 0x01 };
    try testing.expectEqual(ByteOrder.be16, detectOrder(&be).?);
    var le = [_]u8{ 0xFE, 0x7F, 0x01, 0x80 };
    try testing.expectEqual(ByteOrder.le16, detectOrder(&le).?);
    var b14b = [_]u8{ 0x1F, 0xFF, 0xE8, 0x00 };
    try testing.expectEqual(ByteOrder.b14_be, detectOrder(&b14b).?);
    var b14l = [_]u8{ 0xFF, 0x1F, 0x00, 0xE8 };
    try testing.expectEqual(ByteOrder.b14_le, detectOrder(&b14l).?);
    try testing.expectEqual(@as(?ByteOrder, null), detectOrder("ABCD"));
    try testing.expectEqual(@as(?ByteOrder, null), detectOrder("AB"));
}

fn padFrame(head: []const u8, frame_size: usize, count: usize, out: []u8) usize {
    @memset(out[0 .. frame_size * count], 0);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        @memcpy(out[i * frame_size ..][0..head.len], head);
    }
    return frame_size * count;
}

test "dts: 48k 立体声帧头字段（ffmpeg dca 编码器）" {
    const h = try parse(head_48s, .be16);
    try testing.expect(h.normal_frame);
    try testing.expectEqual(@as(u8, 32), h.deficit_samples);
    try testing.expect(!h.crc_present);
    try testing.expectEqual(@as(u8, 16), h.npcmblocks);
    try testing.expectEqual(@as(u16, 684), h.frame_size);
    try testing.expectEqual(@as(u8, 2), h.audio_mode); // stereo
    try testing.expectEqual(@as(u8, 13), h.sr_code); // 48000
    try testing.expectEqual(@as(u32, 48000), h.sample_rate);
    try testing.expectEqual(@as(u8, 12), h.br_code);
    try testing.expectEqual(@as(u32, 512000), h.bit_rate);
    try testing.expectEqual(@as(u8, 0), h.lfe_present);
    try testing.expectEqual(@as(u8, 16), h.source_pcm_res);
    try testing.expectEqual(@as(u8, 1), h.nsubframes);
    try testing.expectEqual(@as(u8, 2), h.nchannels);
    try testing.expect(!h.nchannels_mismatch);
    try testing.expectEqual(@as(usize, 104), h.consumed_bits);
    try testing.expectEqual(@as(u32, 512), frameSamples(&h));
}

test "dts: 5.1 帧头（LFE 64x）与 8k mono 帧头" {
    const h5 = try parse(head_48x, .be16);
    try testing.expectEqual(@as(u8, 9), h5.audio_mode); // 3/2
    try testing.expectEqual(@as(u8, 2), h5.lfe_present); // 64x
    try testing.expectEqual(@as(u16, 2048), h5.frame_size);
    try testing.expectEqual(@as(u32, 1536000), h5.bit_rate);
    const cc = channelConfig(&h5);
    try testing.expectEqual(@as(u8, 6), cc.channels);
    try testing.expectEqual(@as(u32, 0x3F), cc.ch_mask);
    try testing.expect(cc.lfe_present and !cc.xch);

    const hm = try parse(head_8m, .be16);
    try testing.expectEqual(@as(u8, 0), hm.audio_mode); // mono
    try testing.expectEqual(@as(u8, 1), hm.sr_code); // 8000
    try testing.expectEqual(@as(u32, 8000), hm.sample_rate);
    try testing.expectEqual(@as(u16, 4096), hm.frame_size);
    const cm = channelConfig(&hm);
    try testing.expectEqual(@as(u8, 1), cm.channels);
}

test "dts: DTS-ES 帧头（ext_audio XCH + 24bit）" {
    const h = try parse(head_es, .be16);
    try testing.expectEqual(@as(u8, 9), h.audio_mode);
    try testing.expectEqual(@as(u8, 2), h.lfe_present);
    try testing.expect(h.ext_audio_present);
    try testing.expectEqual(@as(u8, 0), h.ext_audio_type); // XCH
    try testing.expectEqual(@as(u8, 24), h.source_pcm_res);
    try testing.expect(h.es_format);
    const cc = channelConfig(&h);
    try testing.expectEqual(@as(u8, 7), cc.channels); // 5.1 + Cs = 6.1
    try testing.expect(cc.xch);
}

test "dts: LE（16-bit 字交换）帧头与 BE 等价" {
    var swapped: [hdr.header_window]u8 = undefined;
    var i: usize = 0;
    while (i + 1 < hdr.header_window) : (i += 2) {
        swapped[i] = head_48s[i + 1];
        swapped[i + 1] = head_48s[i];
    }
    const h = try parse(&swapped, .le16);
    try testing.expectEqual(@as(u32, 48000), h.sample_rate);
    try testing.expectEqual(@as(u16, 684), h.frame_size);
    try testing.expectEqual(@as(u8, 2), h.audio_mode);
}

test "dts: 帧头负例" {
    // 伪 sync（≥18 字节，通过窗口检查）
    try testing.expectError(error.Sync, parse("NOTASYNCWORD-0123456789abcdef", .be16));
    // 14-bit 打包不支持
    var b14: [hdr.header_window]u8 = [_]u8{0} ** hdr.header_window;
    b14[0] = 0x1F;
    b14[1] = 0xFF;
    b14[2] = 0xE8;
    try testing.expectError(error.Unsupported14Bit, parse(&b14, .b14_be));
    // 截断窗口
    try testing.expectError(error.Corrupt, parse("ABC", .be16));
}

test "dts: Iterator 逐帧前进（合成 3 帧，无残留）" {
    const fs: usize = 684;
    var buf: [fs * 3]u8 = undefined;
    const n = padFrame(head_48s, fs, 3, &buf);
    try testing.expectEqual(@as(usize, fs * 3), n);

    var it = Iterator.init(buf[0..n], .be16);
    var got: usize = 0;
    var last: Frame = undefined;
    while (it.next()) |f| {
        got += 1;
        last = f;
        // 逐帧偏移须等于 帧号 × frame_size
        try testing.expectEqual(@as(usize, (got - 1) * fs), f.offset);
    }
    try testing.expectEqual(@as(usize, 3), got);
    const st = it.stats;
    try testing.expectEqual(@as(u64, 3), st.frames);
    try testing.expectEqual(@as(u64, fs * 3), st.core_bytes);
    try testing.expectEqual(@as(u64, 0), st.skipped_bytes);
    try testing.expectEqual(@as(u64, 0), st.residual_bytes);
    try testing.expectEqual(@as(u32, 48000), st.sample_rate);
    try testing.expectEqual(@as(u32, 512), st.frame_samples_first);
    try testing.expectEqual(@as(u64, 1536), st.total_samples);
}

test "dts: Iterator 尾部残留计数（截断）" {
    const fs: usize = 684;
    var buf: [fs + 5]u8 = undefined;
    _ = padFrame(head_48s, fs, 1, &buf);
    buf[fs] = 0x7F;
    buf[fs + 1] = 0xFE; // 悬挂 sync 残缺
    buf[fs + 2] = 0x80;
    buf[fs + 3] = 0x01;
    buf[fs + 4] = 0x00;

    var it = Iterator.init(buf[0..], .be16);
    var frames: usize = 0;
    while (it.next()) |_| frames += 1;
    try testing.expectEqual(@as(usize, 1), frames);
    try testing.expectEqual(@as(u64, 5), it.stats.residual_bytes);
    try testing.expectEqual(@as(u64, 0), it.stats.skipped_bytes);
}

test "dts: Iterator 帧间差额（DTS-HD 形态：core + 外部扩展字节）" {
    const fs: usize = 684;
    var buf: [fs * 2 + 12]u8 = undefined;
    _ = padFrame(head_48s, fs, 1, &buf);
    // 帧间插入 12 字节非 core（EXSS 模拟）
    @memset(buf[fs .. fs + 12], 0xAB);
    @memcpy(buf[fs + 12 ..][0..head_48s.len], head_48s);

    var it = Iterator.init(buf[0 .. fs + 12 + fs], .be16);
    var frames: usize = 0;
    while (it.next()) |_| frames += 1;
    try testing.expectEqual(@as(usize, 2), frames);
    try testing.expectEqual(@as(u64, 12), it.stats.skipped_bytes);
    try testing.expectEqual(@as(u64, fs * 2), it.stats.core_bytes);
}

// ---- 阶段二接入：Decoder VTable（整读 → 逐帧 core decode → 交错 s16）----
const stdio = @import("std");
const io2 = @import("../../io.zig");
const decoder2 = @import("../../decoder.zig");

const DtsCtx = struct {
    allocator: stdio.mem.Allocator,
    data: []u8,
    pcm: []i16,
    sample_rate: u32,
    channels: u8,
    total_samples: usize, // 每声道
    cursor: usize = 0,

    fn read(self: *DtsCtx, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
        out_channels.* = self.channels;
        const n = @min(max_samples, self.total_samples - self.cursor);
        if (n == 0) return 0;
        const bytes = n * @as(usize, self.channels) * 2;
        if (out.len < bytes) return error.Corrupt;
        stdio.mem.copyForwards(u8, out[0..bytes], stdio.mem.sliceAsBytes(self.pcm[self.cursor * self.channels ..][0 .. n * self.channels]));
        self.cursor += n;
        return n;
    }
};

fn toS16(v: i32) i16 {
    return @intCast(stdio.math.clamp(v >> 8, -32768, 32767));
}

const dts_vtable = decoder2.Decoder.VTable{
    .read = dtsRead,
    .seek_ms = dtsSeek,
    .position_ms = dtsPos,
    .deinit = dtsDeinit,
};

fn dtsRead(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const self: *DtsCtx = @ptrCast(@alignCast(ctx));
    return self.read(out, max_samples, out_channels);
}
fn dtsSeek(ctx: *anyopaque, ms: i64) Error!void {
    const self: *DtsCtx = @ptrCast(@alignCast(ctx));
    if (ms <= 0) {
        self.cursor = 0;
        return;
    }
    const target = @as(u64, @intCast(ms)) * self.sample_rate / 1000;
    self.cursor = @min(@as(usize, @intCast(target)), self.total_samples);
}
fn dtsPos(ctx: *anyopaque) i64 {
    const self: *DtsCtx = @ptrCast(@alignCast(ctx));
    return @intCast(@divTrunc(@as(i128, @intCast(self.cursor)) * 1000, @as(i128, self.sample_rate)));
}
fn dtsDeinit(ctx: *anyopaque) void {
    const self: *DtsCtx = @ptrCast(@alignCast(ctx));
    const a = self.allocator;
    a.free(self.data);
    a.free(self.pcm);
    a.destroy(self);
}

/// 打开 .dts/.dtshd 整文件解码；成功接管 `reader` 所有权。
///
/// .dtshd 容器路径（DTSHDHDR → STRMDATA 载荷）对每个访问单元执行
/// core +（EXSS 中存在的）XLL 解码：XLL 可用时输出全声道无损上混结果，
/// 否则回落 core 子流。与既有 .dts 裸流 core 定点路径共用输出语义（s16）。
pub fn open(allocator: stdio.mem.Allocator, reader: *io2.Reader, info: *decoder2.Info) Error!decoder2.Decoder {
    const sz = reader.size() catch return error.Corrupt;
    if (sz <= 0 or sz > 512 * 1024 * 1024) return error.UnsupportedFormat;
    const data = try allocator.alloc(u8, @intCast(sz));
    errdefer allocator.free(data);
    var got: usize = 0;
    while (got < data.len) {
        const n = try reader.read(data[got..]);
        if (n == 0) break;
        got += n;
    }
    const buf: []const u8 = data[0..got];

    const is_container = buf.len >= 8 and stdio.mem.eql(u8, buf[0..8], "DTSHDHDR");
    const payload: []const u8 = if (is_container)
        extractStreamPayload(buf) catch return error.UnsupportedFormat
    else
        buf;

    var pcm_list = stdio.ArrayList(i16).empty;
    defer pcm_list.deinit(allocator);

    var sr: u32 = 0;
    var ch: u8 = 0;
    var nsamples_total: usize = 0;
    var container_dur_us: ?i64 = null;
    var xll_used = false;
    var stream_has_exss = false;
    var lbr_flag = false;
    var xll_x_flag: u8 = 0;

    const ord = detectOrder(payload);
    if (ord == null) {
        // 无 core sync：纯 EXSS（LBR / DTS Express）流（逐 EXSS 子流解码）
        if (payload.len < 4 or !stdio.mem.eql(u8, payload[0..4], &exss_sync_be))
            return error.UnsupportedFormat;
        const dec = try decodePayloadToS16(allocator, payload, false, 0);
        defer allocator.free(dec.pcm);
        sr = dec.sample_rate;
        ch = dec.channels;
        nsamples_total = dec.nsamples;
        xll_used = dec.xll_used;
        stream_has_exss = dec.has_exss;
        lbr_flag = dec.lbr_used;
        xll_x_flag = dec.xll_x_profile;
        try pcm_list.appendSlice(allocator, dec.pcm);
    } else if (is_container) {
        // .dtshd 容器：先解出 STRMDATA 载荷，再按访问单元（core + EXSS）解码。
        // 容器开头的初始填充单元（AUPR-HDR initial_padding，样本集 = 2 个 core
        // 帧）只用于填充解码状态、不产生输出（与 ffmpeg dtshd 解封装/dca 解析
        // 丢弃 start_skip_samples 及 dtshd_dump 工具 -skip 2 行为一致）。
        const skip = auprInitialPaddingUnits(buf);
        const dec = try decodePayloadToS16(allocator, payload, false, skip);
        defer allocator.free(dec.pcm);
        sr = dec.sample_rate;
        ch = dec.channels;
        nsamples_total = dec.nsamples;
        container_dur_us = auprDurationUs(buf, sr);
        xll_used = dec.xll_used;
        stream_has_exss = dec.has_exss;
        lbr_flag = dec.lbr_used;
        xll_x_flag = dec.xll_x_profile;
        try pcm_list.appendSlice(allocator, dec.pcm);
    } else {
        const swap_words = ord.? == .le16;
        // 裸 .dts/.dca core 流：逐帧 core 定点解码（既有路径，零回归）。
        var dec = core.DcaDecoder.init(allocator);
        defer dec.deinit();

        var it = Iterator.init(payload, ord.?);
        var frame: core.DecodedFrame = undefined;
        while (it.next()) |f| {
            const frame_size = f.header.frame_size;
            var frame_buf = payload[f.offset .. f.offset + frame_size];
            var swp: []u8 = &.{};
            if (swap_words) {
                swp = try allocator.alloc(u8, frame_size);
                var i: usize = 0;
                while (i + 1 < frame_size) : (i += 2) {
                    swp[i] = frame_buf[i + 1];
                    swp[i + 1] = frame_buf[i];
                }
                frame_buf = swp;
            }
            defer if (swap_words) allocator.free(swp);
            dec.decode(frame_buf, &frame) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Corrupt,
            };
            if (sr == 0) {
                sr = frame.sample_rate;
                ch = @intCast(frame.nch);
            }
            for (0..frame.nsamples) |nn| {
                for (0..frame.nch) |c| {
                    try pcm_list.append(allocator, toS16(frame.planes[c][nn]));
                }
            }
            nsamples_total += frame.nsamples;
        }
    }
    if (sr == 0 or ch == 0 or nsamples_total == 0) return error.Corrupt;

    const ctx = try allocator.create(DtsCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .data = data,
        .pcm = try pcm_list.toOwnedSlice(allocator),
        .sample_rate = sr,
        .channels = ch,
        .total_samples = nsamples_total,
    };

    info.* = .{
        .sample_rate = sr,
        .channels = ch,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = @intCast(container_dur_us orelse
            @as(i128, @intCast(@divTrunc(@as(i128, @intCast(nsamples_total)) * 1_000_000, @as(i128, sr))))),
        // 裸流：整文件预解码，nsamples_total 即实际可播样本总数（ffprobe 对
        // 裸流仅码率估算，无法对齐）；容器：AUPR-HDR 帧数×帧样本（= ffprobe）。
        // 两者均为确切值。
        .duration_known = .exact,
        .codec_name = "dts",
        .format_name = if (is_container) "dtshd" else "dts",
        .profile = dtsProfile2(xll_used, stream_has_exss, xll_x_flag, lbr_flag, sr),
        .metadata = .{},
    };
    return .{ .vtable = &dts_vtable, .ctx = ctx };
}

/// DTS 编码 profile 名（对齐 ffmpeg ffprobe：core→DTS / X96 96k core→DTS 96/24 /
/// EXSS 扩展（HRA，无 XLL）→DTS-HD HRA / XLL 上混→DTS-HD MA）
fn dtsProfile2(xll_used: bool, has_exss: bool, xll_x_profile: u8, lbr_used: bool, sample_rate: u32) ?[:0]const u8 {
    // ffmpeg dcadec：LBR 输出优先（DCA_PACKET_LBR）→ AV_PROFILE_DTS_EXPRESS
    if (lbr_used) return "DTS Express";
    if (xll_used) {
        // ffmpeg profiles.c：DTS:X / IMAX 由 XLL 帧尾扩展 sync 判定
        if (xll_x_profile == 2) return "DTS-HD MA + DTS:X IMAX";
        if (xll_x_profile == 1) return "DTS-HD MA + DTS:X";
        return "DTS-HD MA";
    }
    if (has_exss) return "DTS-HD HRA";
    if (sample_rate == 96000) return "DTS 96/24";
    return "DTS";
}

// ---------------------------------------------------------------------------
// 生产 .dtshd 访问单元解码：core + XLL → 交错 s16
// ---------------------------------------------------------------------------

/// .dtshd 容器初始填充单元数（AUPR-HDR initial_padding / samples_per_frame）；
/// 无 AUPR-HDR 时 0（与 ffmpeg dtshd demux 缺省一致）。
fn auprInitialPaddingUnits(buf: []const u8) usize {
    if (buf.len < 8 or !stdio.mem.eql(u8, buf[0..8], "DTSHDHDR")) return 0;
    var off: usize = 0; // 平铺 chunk 表（首 chunk tag = "DTSHDHDR"）
    while (off + 16 <= buf.len) {
        const tag = buf[off .. off + 8];
        const size = stdio.mem.readInt(u64, buf[off + 8 ..][0..8], .big);
        if (size < 4 or size > buf.len) return 0;
        if (stdio.mem.eql(u8, tag, "AUPR-HDR")) {
            const p = buf[off + 16 .. off + 16 + @as(usize, @intCast(size))];
            if (p.len >= 21) {
                const spf = stdio.mem.readInt(u16, p[10..12], .big);
                const pad = stdio.mem.readInt(u16, p[19..21], .big);
                if (spf != 0) return @intCast(@divTrunc(@as(u32, pad), @as(u32, spf)));
            }
            return 0;
        }
        off += 16 + @as(usize, @intCast(size));
    }
    return 0;
}

/// .dtshd 容器时长（AUPR-HDR num_frames × samples_per_frame / 采样率，
/// 与 ffprobe format duration 同源；含 initial/trailing padding，容器语义）。
/// 无 AUPR-HDR / 字段非法 → null（调用方回落预解码样本总数）。
fn auprDurationUs(buf: []const u8, sample_rate: u32) ?i64 {
    if (sample_rate == 0) return null;
    var off: usize = 0; // 平铺 chunk 表
    while (off + 16 <= buf.len) {
        const tag = buf[off .. off + 8];
        const size = stdio.mem.readInt(u64, buf[off + 8 ..][0..8], .big);
        if (size < 4 or size > buf.len) return null;
        if (stdio.mem.eql(u8, tag, "AUPR-HDR")) {
            const p = buf[off + 16 .. off + 16 + @as(usize, @intCast(size))];
            if (p.len >= 12) {
                const num_frames = stdio.mem.readInt(u32, p[6..10], .big);
                const spf = stdio.mem.readInt(u16, p[10..12], .big);
                if (num_frames > 0 and spf > 0)
                    return @intCast(@as(u128, num_frames) * spf * 1_000_000 / sample_rate);
            }
            return null;
        }
        off += 16 + @as(usize, @intCast(size));
    }
    return null;
}

/// 已解码 PCM 汇总（decodePayloadToS16 输出）
const PcmS16 = struct {
    pcm: []i16,
    sample_rate: u32,
    channels: u8,
    nsamples: usize,
    /// 输出是否来自 XLL 上混（false = core 子流回落）
    xll_used: bool,
    /// 是否存在 EXSS 扩展分量（非 XLL 的 EXSS → DTS-HD HRA profile）
    has_exss: bool,
    /// XLL 帧尾 DTS:X 扩展（0 无 / 1 DTS:X / 2 DTS:X IMAX；对象渲染不支持，仅上报）
    xll_x_profile: u8 = 0,
    /// 输出是否来自 LBR（DTS Express）解码
    lbr_used: bool = false,
};

/// 一个访问单元：core 帧范围 + 本单元 EXSS 子流位置。
/// EXSS-only 单元（纯 LBR 流）：core_len=0，exss_off 起 exss_size 字节。
const Unit = struct {
    off: usize,
    core_len: usize,
    exss_off: ?usize,
    end: usize,
    /// EXSS-only 单元的子流尺寸（0 = core 单元）
    exss_size: usize = 0,
};

const core_sync_be = [4]u8{ 0x7F, 0xFE, 0x80, 0x01 };
const exss_sync_be = [4]u8{ 0x64, 0x58, 0x20, 0x25 };

fn coreFrameSize(payload: []const u8, off: usize) usize {
    var v: u64 = 0;
    for (0..8) |i| v = (v << 8) | payload[off + 4 + i];
    return @as(usize, @intCast((v >> 36) & 0x3fff)) + 1;
}

/// 收集载荷内全部访问单元。两种形态：
///   1) 含 core 帧：自 core sync 起，单元内 EXSS 在 core 帧尾与下一 core sync
///      之间向后定位（DTS-HD 形态）；
///   2) 纯 EXSS（LBR/DTS Express）流：无 core sync，逐 EXSS 子流（exss_size）
///      为一个访问单元。
fn collectUnits(a: stdio.mem.Allocator, payload: []const u8) Error![]Unit {
    var starts = stdio.ArrayList(struct { off: usize, core_len: usize }).empty;
    defer starts.deinit(a);
    var i: usize = 0;
    while (i + 4 <= payload.len) : (i += 1) {
        if (stdio.mem.eql(u8, payload[i .. i + 4], &core_sync_be)) {
            try starts.append(a, .{ .off = i, .core_len = coreFrameSize(payload, i) });
            i += 4;
        }
    }

    var out = stdio.ArrayList(Unit).empty;
    errdefer out.deinit(a);

    if (starts.items.len == 0) {
        // 纯 EXSS 流：每个 EXSS 子流一个单元
        var j: usize = 0;
        while (j + 4 <= payload.len) {
            if (!stdio.mem.eql(u8, payload[j .. j + 4], &exss_sync_be)) {
                j += 1;
                continue;
            }
            const esz = exssSubstreamSize(payload[j..]) orelse return error.Corrupt;
            if (j + esz > payload.len) return error.Corrupt;
            try out.append(a, .{
                .off = j,
                .core_len = 0,
                .exss_off = j,
                .end = j + esz,
                .exss_size = esz,
            });
            j += esz;
        }
        return out.toOwnedSlice(a);
    }

    for (starts.items, 0..) |s, k| {
        const next_off = if (k + 1 < starts.items.len) starts.items[k + 1].off else payload.len;
        var exss_off: ?usize = null;
        const core_end = s.off + s.core_len;
        var j = core_end;
        while (j + 4 <= next_off) : (j += 1) {
            if (stdio.mem.eql(u8, payload[j .. j + 4], &exss_sync_be)) {
                exss_off = j;
                break;
            }
        }
        try out.append(a, .{
            .off = s.off,
            .core_len = s.core_len,
            .exss_off = exss_off,
            .end = if (exss_off != null) next_off else core_end,
        });
    }
    return out.toOwnedSlice(a);
}

/// 读 EXSS 头的 exss_size（wide_hdr 时 20 位，否则 16 位；+1 偏置）
fn exssSubstreamSize(buf: []const u8) ?usize {
    // 头：32 sync + 8 user + 2 index + 1 wide + (8|12) header_size + (16|20) size
    if (buf.len < 10) return null;
    const wide = buf[5] & 1 != 0;
    const size_nbits: usize = if (wide) 20 else 16;
    const bit_base: usize = (32 + 8 + 2 + 1 + (if (wide) @as(usize, 12) else 8));
    const total_bits = bit_base + size_nbits;
    if (total_bits > buf.len * 8) return null;
    var v: u32 = 0;
    for (0..size_nbits) |b| {
        const bit_idx = bit_base + b;
        const bit = (buf[bit_idx >> 3] >> @intCast(7 - (bit_idx & 7))) & 1;
        v = (v << 1) | bit;
    }
    return @as(usize, v) + 1;
}

/// 把 .dtshd STRMDATA 载荷（或裸 core 流）逐访问单元解码为交错 s16。
/// `skip_units` 个起始单元参与解码（维护 core/XLL 历史）但不输出。
/// 返回已 owned PCM（调用方 free）。
///
/// 输出语义：core 平面与 XLL 24bit 平面均为定点 clip23 值，右移 8 得到 s16
/// （即 ffmpeg `-f s32le` 24bit<<8 输出再经 s32→s16 转换 v>>16 的等价结果）；
/// XLL storage16 平面即为 s16 值，直接输出。声道序 = ffmpeg 默认 remap 序。
fn decodePayloadToS16(
    a: stdio.mem.Allocator,
    payload: []const u8,
    swap_words: bool,
    skip_units: usize,
) Error!PcmS16 {
    const units = try collectUnits(a, payload);
    defer a.free(units);

    var core_dec = core.DcaDecoder.init(a);
    defer core_dec.deinit();
    var xll_dec = xll.XllDecoder.init(a);
    defer xll_dec.deinit();
    var lbr_dec = lbr.LbrDecoder.init(a);
    defer lbr_dec.deinit();

    var list = stdio.ArrayList(i16).empty;
    errdefer list.deinit(a);

    var sr: u32 = 0;
    var ch: u8 = 0;
    var xll_used = false;
    var has_exss = false;
    var xll_x_profile: u8 = 0; // DTS:X 标志（0 无 / 1 DTS:X / 2 IMAX；对象渲染不支持，仅上报）
    var lbr_used = false;

    var ui: usize = 0;
    for (units) |u| {
        // ---- 纯 EXSS 单元（LBR / DTS Express 流）：无 core 帧 ----
        if (u.core_len == 0 and u.exss_off != null) {
            const exss_buf = payload[u.exss_off.? .. u.end];
            var asset: exss.Asset = .{};
            var lbr_ok = false;
            if (exss.parse(exss_buf, &asset)) |_| {
                has_exss = true;
                if (asset.extension_mask & exss.ext_lbr != 0 and asset.lbr_size != 0 and
                    asset.lbr_offset + asset.lbr_size <= exss_buf.len)
                {
                    if (lbr_dec.parse(exss_buf[asset.lbr_offset .. asset.lbr_offset + asset.lbr_size])) |_| {
                        if (lbr_dec.filterFrame()) |_| {
                            lbr_ok = true;
                        } else |_| {}
                    } else |_| {}
                }
            } else |_| {}

            if (lbr_ok and ui >= skip_units) {
                const nch = lbr_dec.outputNchannels();
                const n = lbr_dec.outputNsamples();
                if (sr == 0) {
                    sr = lbr_dec.outputSampleRate();
                    ch = nch;
                    lbr_used = true;
                }
                for (0..n) |nn| {
                    var c: usize = 0;
                    while (c < nch) : (c += 1) {
                        const pl = lbr_dec.plane(c) orelse return error.Corrupt;
                        try list.append(a, lbrF32ToS16(pl[nn]));
                    }
                }
            }
            ui += 1;
            continue;
        }

        var frame_buf = payload[u.off .. u.off + u.core_len];
        var swp: []u8 = &.{};
        if (swap_words) {
            swp = try a.alloc(u8, u.core_len);
            var k: usize = 0;
            while (k + 1 < u.core_len) : (k += 2) {
                swp[k] = frame_buf[k + 1];
                swp[k + 1] = frame_buf[k];
            }
            frame_buf = swp;
        }
        defer if (swap_words) a.free(swp);

        var frame: core.DecodedFrame = undefined;

        // 1) 解析 core 子帧（含 CSS X96/XCH/XXCH sync 定位）
        core_dec.parseCore(frame_buf) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Corrupt,
        };

        // 2) 定位本单元 EXSS asset（先解析 XLL 帧头以决定 core 是否需 X96 合成）
        var xll_parse_ok = false;
        var xll_xdata: []const u8 = &.{};
        var o2o = false;
        var exss_buf: []const u8 = &.{};
        var em: u16 = 0;
        var xbr_off: usize = 0;
        var xbr_sz: usize = 0;
        var xxch_off: usize = 0;
        var xxch_sz: usize = 0;
        var x96_off: usize = 0;
        var x96_sz: usize = 0;
        if (u.exss_off) |eo| {
            exss_buf = payload[eo..u.end];
            var asset: exss.Asset = .{};
            var aok = true;
            exss.parse(exss_buf, &asset) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => aok = false,
            };
            if (aok) {
                em = asset.extension_mask;
                if (em != 0) has_exss = true;
                xbr_off = asset.xbr_offset;
                xbr_sz = asset.xbr_size;
                xxch_off = asset.xxch_offset;
                xxch_sz = asset.xxch_size;
                x96_off = asset.x96_offset;
                x96_sz = asset.x96_size;
                if (em & exss.ext_xll != 0 and asset.xll_size != 0 and
                    asset.xll_offset + asset.xll_size <= exss_buf.len)
                {
                    xll_xdata = exss_buf[asset.xll_offset .. asset.xll_offset + asset.xll_size];
                    o2o = asset.one_to_one_map_ch_to_spkr;
                    xll_parse_ok = true;
                    xll_dec.parseFrame(xll_xdata, o2o) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => xll_parse_ok = false,
                    };
                }
            }
        }

        // 3) core 扩展声道（XCH/XXCH/XBR）与 X96 解析（ff_dca_core_parse_exss；
        //    XLL 激活时跳过 X96 数据解析，对齐 ffmpeg）
        core_dec.parseCoreExssXbr(
            frame_buf,
            if (exss_buf.len != 0) exss_buf else null,
            em,
            xbr_off,
            xbr_sz,
            xxch_off,
            xxch_sz,
            x96_off,
            x96_sz,
            xll_parse_ok,
        ) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Corrupt,
        };

        // 4) 决定 core 合成模式（对齐 ffmpeg：有 XLL 时忽略 core CSS X96；
        //    chset base 频 = 96k 且 core 48k → XLL 残余上混需 96k core 输入）
        var want_core_x96 = false;
        if (xll_parse_ok) {
            want_core_x96 = xll_dec.chset[0].freq == 96000 and core_dec.sample_rate == 48000;
        } else {
            want_core_x96 = core_dec.x96_active;
        }
        core_dec.filter(&frame, want_core_x96) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Corrupt,
        };

        var spk_planes: [SPK]?[]const i32 = [_]?[]const i32{null} ** SPK;
        for (0..SPK) |s| spk_planes[s] = core_dec.speakerPlane(s);

        var xll_ok = false;
        var xll_out_mask: u32 = core_dec.ch_mask;
        var xll_storage: u8 = 24;

        // 5) XLL 上混（filter 失败回落 core 输出）
        if (xll_parse_ok) {
            var fok = true;
            xll_dec.filterFrame(&spk_planes) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => fok = false,
            };
            if (fok) {
                xll_ok = true;
                xll_storage = xll_dec.outputStorageBitRes();
                xll_out_mask = xll_dec.outputMask();
                if (xll_dec.x_imax_syncword_present) {
                    xll_x_profile = 2;
                } else if (xll_dec.x_syncword_present) {
                    xll_x_profile = 1;
                }
            }
        }

        if (ui >= skip_units) {
            if (xll_ok) {
                var order: [8]u32 = undefined;
                const nch = core.remapOrder(xll_out_mask, &order);
                const n = xll_dec.outputNsamples();
                if (sr == 0) {
                    sr = xll_dec.outputSampleRate();
                    ch = @intCast(nch);
                    xll_used = true;
                }
                for (0..n) |nn| {
                    var c: usize = 0;
                    while (c < nch) : (c += 1) {
                        const pl = xll_dec.plane(order[c]) orelse return error.Corrupt;
                        try list.append(a, toXllS16(pl[nn], xll_storage));
                    }
                }
            } else {
                if (sr == 0) {
                    sr = frame.sample_rate;
                    ch = @intCast(frame.nch);
                }
                for (0..frame.nsamples) |nn| {
                    for (0..frame.nch) |c| {
                        try list.append(a, toS16(frame.planes[c][nn]));
                    }
                }
            }
        }
        ui += 1;
    }
    if (sr == 0 or ch == 0 or list.items.len == 0) return error.Corrupt;

    const pcm = try list.toOwnedSlice(a);
    return .{
        .pcm = pcm,
        .sample_rate = sr,
        .channels = ch,
        .nsamples = pcm.len / @as(usize, ch),
        .xll_used = xll_used,
        .has_exss = has_exss,
        .xll_x_profile = xll_x_profile,
        .lbr_used = lbr_used,
    };
}

/// LBR float 平面样本 → s16（ffmpeg swresample FLT→S16：
/// av_clip_int16(lrintf(v * 32768))；lrintf = 四舍五入取偶）
fn lbrF32ToS16(v: f32) i16 {
    const scaled = v * 32768.0;
    var r = @round(scaled);
    // half-away → half-even 修正（仅 |小数| == 0.5 时 differs）
    const frac = @abs(scaled - @trunc(scaled));
    if (frac == 0.5 and @mod(r, 2.0) != 0) {
        r -= stdio.math.sign(scaled);
    }
    return @intCast(stdio.math.clamp(@as(i64, @intFromFloat(r)), -32768, 32767));
}

/// XLL 平面样本 → s16。24bit：clip23 后右移 8（丢弃 8 LSB）；
/// storage16：样本即 s16，clamp。
fn toXllS16(v: i32, storage: u8) i16 {
    if (storage > 16) {
        return @intCast(stdio.math.clamp(v, -(1 << 23), (1 << 23) - 1) >> 8);
    }
    return @intCast(stdio.math.clamp(v, -32768, 32767));
}

/// 定位 .dtshd 容器 STRMDATA 载荷（DTSHDHDR 魔数后按 8 字节 tag + 8 字节 BE 大小
/// 的 chunk 链扫描，见 libavformat dtshddec.c）。
fn extractStreamPayload(buf: []const u8) ![]const u8 {
    if (buf.len < 16) return error.UnsupportedFormat;
    // 平铺 chunk 表（ffmpeg dtshddec）：首 chunk tag 即 "DTSHDHDR"，
    // 其后 AUPR-HDR / STRMDATA 等每 chunk = tag(8) + size(8BE) + payload。
    var off: usize = 0;
    while (off + 16 <= buf.len) {
        const tag = buf[off .. off + 8];
        const size = stdio.mem.readInt(u64, buf[off + 8 ..][0..8], .big);
        if (size < 4 or size > buf.len) return error.UnsupportedFormat;
        if (stdio.mem.eql(u8, tag, "STRMDATA")) {
            const start = off + 16;
            if (start + size > buf.len) return error.UnsupportedFormat;
            return buf[start .. start + @as(usize, @intCast(size))];
        }
        off += 16 + @as(usize, @intCast(size));
    }
    return error.UnsupportedFormat;
}

// ---------------------------------------------------------------------------
// XLL 全管线回归：.dtshd STRMDATA 载荷 → 逐单元 core+XLL 上混 → 与 ffmpeg 定点
// s32le 逐字节对照（容器初始 2 个填充单元丢弃，与 ffmpeg/dtshd_dump 一致）。
// ---------------------------------------------------------------------------
const xll51_payload = @embedFile("xll51_24_48_768_payload.bin"); // 48k/24bit 5.1 XLL
const xll51_gt = @embedFile("xll51_24_48_768_gt.s32.bin");
const xll71_payload = @embedFile("xll71_24_48_768_payload.bin"); // 48k/24bit 7.1 双 chset
const xll71_gt = @embedFile("xll71_24_48_768_gt.s32.bin");

const SPK = 32;

fn decodeXllPayloadToS32(payload: []const u8, out: []u8) !usize {
    var core_dec = core.DcaDecoder.init(stdio.testing.allocator);
    defer core_dec.deinit();
    var xll_dec = xll.XllDecoder.init(stdio.testing.allocator);
    defer xll_dec.deinit();

    var ui: usize = 0;
    var pos: usize = 0;
    var off: usize = 0;
    while (off + 4 <= payload.len) {
        if (!stdio.mem.eql(u8, payload[off .. off + 4], &[4]u8{ 0x7F, 0xFE, 0x80, 0x01 })) {
            off += 1;
            continue;
        }
        // core frame_size（帧头 bit46 起 14 位）
        var v: u64 = 0;
        for (0..8) |i| v = (v << 8) | payload[off + 4 + i];
        const core_len = @as(usize, @intCast((v >> 36) & 0x3fff)) + 1;

        // 定位本单元 EXSS（0x64582025），否则单元止于 core 帧尾
        var j = off + core_len;
        var exss_off: ?usize = null;
        while (j + 4 <= payload.len) : (j += 1) {
            if (stdio.mem.eql(u8, payload[j .. j + 4], &[4]u8{ 0x64, 0x58, 0x20, 0x25 })) {
                exss_off = j;
                break;
            }
        }

        var frame: core.DecodedFrame = undefined;
        try core_dec.decode(payload[off .. off + core_len], &frame);

        var spk_planes: [SPK]?[]const i32 = [_]?[]const i32{null} ** SPK;
        for (0..SPK) |s| spk_planes[s] = core_dec.speakerPlane(s);

        var xll_ok = false;
        var out_mask: u32 = core_dec.ch_mask;
        var storage: u8 = 24;
        var nsamples_out: usize = 0;

        if (exss_off) |eo| {
            var asset: exss.Asset = .{};
            try exss.parse(payload[eo..], &asset);
            if (asset.extension_mask & exss.ext_xll != 0 and asset.xll_size != 0) {
                const xdata = payload[eo + asset.xll_offset .. eo + asset.xll_offset + asset.xll_size];
                try xll_dec.parseFrame(xdata, true);
                try xll_dec.filterFrame(&spk_planes);
                xll_ok = true;
                storage = xll_dec.outputStorageBitRes();
                out_mask = xll_dec.outputMask();
            }
        }

        if (ui >= 2) {
            if (xll_ok) {
                nsamples_out = xll_dec.outputNsamples();
                var order: [8]u32 = undefined;
                const nch = core.remapOrder(out_mask, &order);
                for (0..nsamples_out) |n| {
                    var c: usize = 0;
                    while (c < nch) : (c += 1) {
                        const pl = xll_dec.plane(order[c]) orelse return error.Corrupt;
                        var val = pl[n];
                        if (storage > 16) {
                            val = stdio.math.clamp(val, -(1 << 23), (1 << 23) - 1);
                            stdio.mem.writeInt(i32, out[pos..][0..4], val << 8, .little);
                        } else {
                            val = stdio.math.clamp(val, -32768, 32767);
                            stdio.mem.writeInt(i32, out[pos..][0..4], @as(i32, @intCast(val)) << 16, .little);
                        }
                        pos += 4;
                    }
                }
            } else {
                for (0..frame.nsamples) |n| {
                    for (0..frame.nch) |c| {
                        const val = frame.planes[c][n];
                        stdio.mem.writeInt(i32, out[pos..][0..4], val << 8, .little);
                        pos += 4;
                    }
                }
            }
        }
        off += core_len;
        ui += 1;
    }
    return pos;
}

test "dts xll: 5.1 48k/24bit 全 6 声道 XLL 上混 == ffmpeg s32le（含 core LFE 平面）" {
    var buf: [49152]u8 = undefined;
    const n = try decodeXllPayloadToS32(xll51_payload, &buf);
    try stdio.testing.expectEqual(@as(usize, 49152), n);
    try stdio.testing.expectEqualSlices(u8, xll51_gt, buf[0..n]);
}

test "dts xll: 7.1 48k/24bit 双 chset（层次 dmix 撤销）== ffmpeg s32le" {
    var buf: [65536]u8 = undefined;
    const n = try decodeXllPayloadToS32(xll71_payload, &buf);
    try stdio.testing.expectEqual(@as(usize, 65536), n);
    try stdio.testing.expectEqualSlices(u8, xll71_gt, buf[0..n]);
}

// ---------------------------------------------------------------------------
// 生产整合回归：decoder.open（fmt/dts）对 .dtshd 容器全链路 → s16
// ---------------------------------------------------------------------------
// 输出语义：ffmpeg `-flags2 skip_manual -f s32le`（24bit<<8 / 16bit<<16）再经
// s32→s16 转换（av_clip_int16(v>>16)）即为本路径 s16 → 逐样本相等。

const core51_payload = @embedFile("core51_24_48_768_payload.bin");
const core51_gt = @embedFile("core51_24_48_768_gt.s32.bin");

/// 在测试内存里构造最小 .dtshd 容器：DTSHDHDR + 占位 chunk + AUPR-HDR +
/// STRMDATA(payload)。AUPR 的 initial_padding/pad 决定 open 丢弃的初始单元数。
fn makeDtshdContainer(a: stdio.mem.Allocator, payload: []const u8, samples_per_frame: u16, initial_padding: u16) ![]u8 {
    var aupr: [21]u8 = undefined;
    @memset(&aupr, 0);
    stdio.mem.writeInt(u32, aupr[6..10], 6, .big); // num_frames（展示用）
    stdio.mem.writeInt(u16, aupr[10..12], samples_per_frame, .big);
    aupr[3] = 0xBB;
    aupr[4] = 0x80; // sample_rate = 48000（仅展示）
    const aupr_hdr = [_]u8{ 0x41, 0x55, 0x50, 0x52, 0x2D, 0x48, 0x44, 0x52 };
    stdio.mem.writeInt(u16, aupr[19..21], initial_padding, .big);

    const filler = [_]u8{0xAB} ** 12;
    const len = 16 + filler.len + 16 + aupr.len + 16 + payload.len;
    const out = try a.alloc(u8, len);
    @memcpy(out[0..8], "DTSHDHDR");
    stdio.mem.writeInt(u64, out[8..][0..8], filler.len, .big);
    @memcpy(out[16 .. 16 + filler.len], &filler);
    var off: usize = 16 + filler.len;
    @memcpy(out[off .. off + 8], &aupr_hdr);
    stdio.mem.writeInt(u64, out[off + 8 ..][0..8], aupr.len, .big);
    @memcpy(out[off + 16 .. off + 16 + aupr.len], &aupr);
    off += 16 + aupr.len;
    @memcpy(out[off .. off + 8], "STRMDATA");
    stdio.mem.writeInt(u64, out[off + 8 ..][0..8], payload.len, .big);
    @memcpy(out[off + 16 ..], payload);
    return out;
}

/// 解码一个 .dtshd 容器（经 fmt/dts.open 生产路径）为交错 s16；
/// 返回 owned s16（调用方 free）与 Info 引用快照。
const OpenResult = struct {
    pcm: []i16,
    info: decoder2.Info,
};

fn openContainerToS16(a: stdio.mem.Allocator, payload: []const u8, spf: u16, pad: u16) !OpenResult {
    const container = try makeDtshdContainer(a, payload, spf, pad);
    defer a.free(container);
    var reader = io2.Reader.openMem(container);
    var info: decoder2.Info = undefined;
    var dec = try open(a, &reader, &info);
    defer dec.deinit();

    var list = stdio.ArrayList(i16).empty;
    defer list.deinit(a);
    var out: [32768]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&out, 1024, &ch);
        if (n == 0) break;
        const bytes = n * @as(usize, ch) * 2;
        const sl = stdio.mem.sliceAsBytes(list.addManyAsSlice(a, n * @as(usize, ch)) catch return error.OutOfMemory);
        @memcpy(sl[0..bytes], out[0..bytes]);
    }
    const pcm = try list.toOwnedSlice(a);
    return .{ .pcm = pcm, .info = info };
}

fn expectS16EqS32Downshift(s16: []const i16, gt_s32: []const u8) !void {
    try stdio.testing.expectEqual(gt_s32.len / 4, s16.len);
    var i: usize = 0;
    while (i < s16.len) : (i += 1) {
        const v = stdio.mem.readInt(i32, gt_s32[i * 4 ..][0..4], .little);
        const exp: i16 = @intCast(v >> 16);
        try stdio.testing.expectEqual(exp, s16[i]);
    }
}

test "dts 生产: .dtshd 容器 XLL 5.1 48k → open 全链路 s16 == ffmpeg s32>>16" {
    const r = try openContainerToS16(stdio.testing.allocator, xll51_payload, 512, 1024);
    defer stdio.testing.allocator.free(r.pcm);
    try stdio.testing.expectEqual(@as(u32, 48000), r.info.sample_rate);
    try stdio.testing.expectEqual(@as(u8, 6), r.info.channels);
    try stdio.testing.expectEqualStrings("dtshd", r.info.format_name);
    try stdio.testing.expectEqualStrings("DTS-HD MA", r.info.profile.?);
    try expectS16EqS32Downshift(r.pcm, xll51_gt);
}

test "dts 生产: .dtshd 容器 XLL 7.1 48k 双 chset → open 全链路 s16 == ffmpeg s32>>16" {
    const r = try openContainerToS16(stdio.testing.allocator, xll71_payload, 512, 1024);
    defer stdio.testing.allocator.free(r.pcm);
    try stdio.testing.expectEqual(@as(u32, 48000), r.info.sample_rate);
    try stdio.testing.expectEqual(@as(u8, 8), r.info.channels);
    try stdio.testing.expectEqualStrings("DTS-HD MA", r.info.profile.?);
    try expectS16EqS32Downshift(r.pcm, xll71_gt);
}

test "dts 生产: .dtshd 容器无 XLL（纯 core）→ open 回落 core s16 == ffmpeg s32>>16" {
    const r = try openContainerToS16(stdio.testing.allocator, core51_payload, 512, 1024);
    defer stdio.testing.allocator.free(r.pcm);
    try stdio.testing.expectEqual(@as(u32, 48000), r.info.sample_rate);
    try stdio.testing.expectEqual(@as(u8, 6), r.info.channels);
    try stdio.testing.expectEqualStrings("DTS", r.info.profile.?);
    try expectS16EqS32Downshift(r.pcm, core51_gt);
}

test "dts 生产: 裸 .dts core 载荷（无容器、无 EXSS）→ 既有路径输出 6 帧无跳过" {
    // core51 payload = 6 帧连续 core；裸流不丢弃任何单元 → 6×512×6ch。
    const a = stdio.testing.allocator;
    var reader = io2.Reader.openMem(core51_payload);
    var info: decoder2.Info = undefined;
    var dec = try open(a, &reader, &info);
    defer dec.deinit();
    try stdio.testing.expectEqual(@as(u32, 48000), info.sample_rate);
    try stdio.testing.expectEqual(@as(u8, 6), info.channels);
    try stdio.testing.expectEqualStrings("DTS", info.profile.?);

    var list = stdio.ArrayList(i16).empty;
    defer list.deinit(a);
    var out: [32768]u8 = undefined;
    var nsamp: usize = 0;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&out, 1024, &ch);
        if (n == 0) break;
        const bytes = n * @as(usize, ch) * 2;
        const sl = stdio.mem.sliceAsBytes(list.addManyAsSlice(a, n * @as(usize, ch)) catch return error.OutOfMemory);
        @memcpy(sl[0..bytes], out[0..bytes]);
        nsamp += n;
    }
    try stdio.testing.expectEqual(@as(usize, 6 * 512), nsamp);
    try stdio.testing.expectEqual(@as(usize, 6 * 512 * 6), list.items.len); // 每声道 3072 × 6 声道交错
}

// ---- X96（96k core 合成）与 192k XLL（2 频带 + 96k core 输入）生产回归 ----
const x96_51_payload = @embedFile("x96_51_24_96_1509_payload.bin");
const x96_51_gt = @embedFile("x96_51_24_96_1509_gt.s16.bin");
const xll192_payload = @embedFile("xll192_51_16_192_payload.bin");
const xll192_gt = @embedFile("xll192_51_16_192_gt.s16.bin");

test "dts 生产: .dtshd DTS96/24 core（CSS X96）→ open 96k s16 == ffmpeg -bitexact" {
    const r = try openContainerToS16(stdio.testing.allocator, x96_51_payload, 1024, 2048);
    defer stdio.testing.allocator.free(r.pcm);
    try stdio.testing.expectEqual(@as(u32, 96000), r.info.sample_rate);
    try stdio.testing.expectEqual(@as(u8, 6), r.info.channels);
    try stdio.testing.expectEqualStrings("DTS 96/24", r.info.profile.?);
    const got = stdio.mem.sliceAsBytes(r.pcm);
    try stdio.testing.expectEqualSlices(u8, x96_51_gt, got);
}

test "dts 生产: .dtshd XLL 192k（2 频带 + 96k core 合成）→ open s16 == ffmpeg -bitexact" {
    const r = try openContainerToS16(stdio.testing.allocator, xll192_payload, 2048, 4096);
    defer stdio.testing.allocator.free(r.pcm);
    try stdio.testing.expectEqual(@as(u32, 192000), r.info.sample_rate);
    try stdio.testing.expectEqual(@as(u8, 6), r.info.channels);
    try stdio.testing.expectEqualStrings("DTS-HD MA", r.info.profile.?);
    const got = stdio.mem.sliceAsBytes(r.pcm);
    try stdio.testing.expectEqualSlices(u8, xll192_gt, got);
}

// ---- XCH（CSS 附加声道）与 XXCH（EXSS 附加声道）DTS-HD HRA 回归 ----
// x96_xch：96k/6.1/7ch（core 5.1 + CSS XCH Cs + EXSS X96）
// x96_xxch：96k/7.1/8ch（core 5.1 + EXSS XXCH Lsr/Rsr + EXSS X96）
// golden：ffmpeg -flags2 +skip_manual -bitexact -f s16le（-af atrim 丢容器
// 前 2 个初始填充单元 = 2048 样本），与 open 容器路径逐样本一致。
const x96_xch_payload = @embedFile("x96_xch_61_24_96_3840_payload.bin");
const x96_xch_gt = @embedFile("x96_xch_61_24_96_3840_gt.s16.bin");
const x96_xxch_payload = @embedFile("x96_xxch_71_24_96_3840_payload.bin");
const x96_xxch_gt = @embedFile("x96_xxch_71_24_96_3840_gt.s16.bin");

test "dts 生产: .dtshd HRA 96k/6.1 XCH（CSS XCH + EXSS X96）→ open s16 == ffmpeg -bitexact" {
    const r = try openContainerToS16(stdio.testing.allocator, x96_xch_payload, 1024, 2048);
    defer stdio.testing.allocator.free(r.pcm);
    try stdio.testing.expectEqual(@as(u32, 96000), r.info.sample_rate);
    try stdio.testing.expectEqual(@as(u8, 7), r.info.channels);
    try stdio.testing.expectEqualStrings("DTS-HD HRA", r.info.profile.?);
    const got = stdio.mem.sliceAsBytes(r.pcm);
    try stdio.testing.expectEqualSlices(u8, x96_xch_gt, got);
}

test "dts 生产: .dtshd HRA 96k/7.1 XXCH（EXSS XXCH + EXSS X96）→ open s16 == ffmpeg -bitexact" {
    const r = try openContainerToS16(stdio.testing.allocator, x96_xxch_payload, 1024, 2048);
    defer stdio.testing.allocator.free(r.pcm);
    try stdio.testing.expectEqual(@as(u32, 96000), r.info.sample_rate);
    try stdio.testing.expectEqual(@as(u8, 8), r.info.channels);
    try stdio.testing.expectEqualStrings("DTS-HD HRA", r.info.profile.?);
    const got = stdio.mem.sliceAsBytes(r.pcm);
    try stdio.testing.expectEqualSlices(u8, x96_xxch_gt, got);
}

// ---- XBR（EXSS 扩展码率）DTS-HD HRA 回归 ----
// xbr_xxch：48k/7.1（core 5.1 + EXSS XBR 残差 + EXSS XXCH Lss/Rss）；
// xxch_2046：48k/7.1（core 5.1 + EXSS XBR + EXSS X96 + RSV1）。
// golden：ffmpeg -flags2 skip_manual -bitexact -f s16le 全部 6 个访问单元
//（skip_manual 保留初始填充单元 → open 容器路径 initial_padding=0），逐字节一致。
const xbr_xxch_payload = @embedFile("xbr_xxch_71_24_48_3840_payload.bin");
const xbr_xxch_gt = @embedFile("xbr_xxch_71_24_48_3840_gt.s16.bin");
const xxch2046_payload = @embedFile("xxch_71_24_48_2046_payload.bin");
const xxch2046_gt = @embedFile("xxch_71_24_48_2046_gt.s16.bin");

test "dts 生产: .dtshd HRA 48k/7.1 XBR+XXCH（EXSS XBR 残差写入 core 子带）→ open s16 == ffmpeg -bitexact" {
    const r = try openContainerToS16(stdio.testing.allocator, xbr_xxch_payload, 512, 0);
    defer stdio.testing.allocator.free(r.pcm);
    try stdio.testing.expectEqual(@as(u32, 48000), r.info.sample_rate);
    try stdio.testing.expectEqual(@as(u8, 8), r.info.channels);
    try stdio.testing.expectEqualStrings("DTS-HD HRA", r.info.profile.?);
    const got = stdio.mem.sliceAsBytes(r.pcm);
    try stdio.testing.expectEqualSlices(u8, xbr_xxch_gt, got);
}

test "dts 生产: .dtshd HRA 48k/7.1 XBR+X96+RSV1（RSV 位掩码跳过）→ open s16 == ffmpeg -bitexact" {
    const r = try openContainerToS16(stdio.testing.allocator, xxch2046_payload, 512, 0);
    defer stdio.testing.allocator.free(r.pcm);
    try stdio.testing.expectEqual(@as(u32, 48000), r.info.sample_rate);
    try stdio.testing.expectEqual(@as(u8, 8), r.info.channels);
    try stdio.testing.expectEqualStrings("DTS-HD HRA", r.info.profile.?);
    const got = stdio.mem.sliceAsBytes(r.pcm);
    try stdio.testing.expectEqualSlices(u8, xxch2046_gt, got);
}

// ---------------------------------------------------------------------------
// LBR（DTS Express）合成流回归：无公开真实 LBR 样本（FATE/dcadec-suite 均无），
// 以合成 EXSS-only 流驱动全链路（exss asset LBR 偏移 → lbr.parse 块结构 →
// filterFrame（bank/IMDCT/LFE-IIR 路径）→ lbrF32ToS16 → open 裸流检测），
// 验证结构性正确与确定性输出；数值精度由 lbr.zig 内 FFmpeg 参考向量测试保证。
// ---------------------------------------------------------------------------

/// 测试用 MSB-first 位写入器
const TestBitWriter = struct {
    data: []u8,
    pos: usize = 0,

    fn put(self: *TestBitWriter, v: u32, n: u6) void {
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            const bit: u1 = @intCast((v >> @intCast(n - 1 - i)) & 1);
            if (bit != 0) self.data[self.pos >> 3] |= @as(u8, 1) << @intCast(7 - (self.pos & 7));
            self.pos += 1;
        }
    }
};

test "lbr 生产: 合成纯 EXSS LBR 流（8k mono）→ open 全链路 s16" {
    const a = stdio.testing.allocator;

    // ---- LBR 帧字节 ----
    // decoder init: sr=8000(code1) ch_mask=0x0001(C) ver=0x0800 flags=0x14(带限NONE)
    //               码率 96000/96000 → freq_range[1]=1, nsubbands=16, limited_range=1
    var lbr_frame: [64]u8 = undefined;
    @memset(&lbr_frame, 0);
    var lp: usize = 0;
    lbr_frame[lp] = 0x0A;
    lbr_frame[lp + 1] = 0x80;
    lbr_frame[lp + 2] = 0x19;
    lbr_frame[lp + 3] = 0x21; // sync
    lp += 4;
    lbr_frame[lp] = 2;
    lp += 1; // decoder init
    lbr_frame[lp] = 1;
    lp += 1; // sr_code=1 → dca 采样率表 code1 = 16000
    lbr_frame[lp] = 0x01;
    lbr_frame[lp + 1] = 0x00;
    lp += 2; // ch_mask le16 = 0x0001 (C)
    lbr_frame[lp] = 0x00;
    lbr_frame[lp + 1] = 0x08;
    lp += 2; // version le16 = 0x0800
    lbr_frame[lp] = 0x14;
    lp += 1; // flags = band limit none
    lbr_frame[lp] = 0x11;
    lp += 1; // bit_rate_hi nibbles = 1/1
    lbr_frame[lp] = @intCast((96000 & 0xFF));
    lbr_frame[lp + 1] = @intCast((96000 >> 8) & 0xFF);
    lp += 2; // orig le16
    lbr_frame[lp] = @intCast((96000 & 0xFF));
    lbr_frame[lp + 1] = @intCast((96000 >> 8) & 0xFF);
    lp += 2; // scaled le16
    // frame chunk（NO_CSUM）+ 若干子块（数据可任意，截断处按 ffmpeg 语义跳过/随机填充）
    lbr_frame[lp] = 0x06; // frame chunk no csum
    lp += 1;
    const flen_pos = lp;
    lp += 1; // len byte
    // grid1 (0x30) / hr_grid (0x40) / ts1 (0x50) / ts2 (0x60) 各 6 字节随机数据
    const chunk_datas = [4]u8{ 0x30, 0x40, 0x50, 0x60 };
    var body_len: usize = 0;
    for (chunk_datas) |cid| {
        lbr_frame[lp] = cid;
        lbr_frame[lp + 1] = 6;
        lp += 2;
        for (0..6) |k| {
            lbr_frame[lp] = @truncate(0xA5 * (k + 1) + cid);
            lp += 1;
        }
        body_len += 8;
    }
    lbr_frame[flen_pos] = @intCast(body_len);
    const lbr_size = lp;

    // ---- EXSS 子流（coding_mode = 2 → 纯 LBR）----
    // header_size 须覆盖 descriptor（asset 数据自 header_size 字节起；
    // lbr_offset = header_size）。descriptor 止于位 170 → header_size=22。
    const hdr_size: usize = 22;
    var exss_buf_t: [128]u8 = undefined;
    @memset(&exss_buf_t, 0);
    var w = TestBitWriter{ .data = &exss_buf_t };
    w.put(0x64582025, 32);
    w.put(0, 8); // user
    w.put(0, 2); // exss_index
    w.put(0, 1); // wide = 0
    w.put(@intCast(hdr_size - 1), 8); // header_size
    w.put(@intCast(lbr_size + hdr_size - 1), 16); // exss_size
    w.put(1, 1); // static_fields
    w.put(0, 2); // ref clock
    w.put(0, 3); // frame duration
    w.put(0, 1); // timecode
    w.put(0, 3); // npresents-1
    w.put(0, 3); // nassets-1
    w.put(0, 1); // active asset mask（=0 → 无 asset mask 字节，popcount=0）
    w.put(0, 1); // mix = 0
    w.put(@intCast(lbr_size - 1), 16); // asset size
    const descr_pos = w.pos;
    w.put(8 - 1, 9); // descr_size（覆盖到 lbr 参数后字节对齐）
    w.put(0, 3); // asset index
    w.put(0, 1); // type present
    w.put(0, 1); // lang present
    w.put(0, 1); // text present
    w.put(16 - 1, 5); // pcm_bit_res
    w.put(1, 4); // sr code（code1 → 16000，dca 采样率表）
    w.put(0, 8); // nchannels_total-1 = 0 → 1
    w.put(0, 1); // o2o = 0
    w.put(0, 3); // representation type
    w.put(0, 1); // drc
    w.put(0, 1); // 对白归一
    w.put(2, 2); // coding_mode = 2（LBR）
    w.put(@intCast(lbr_size - 1), 14); // lbr_size
    w.put(0, 1); // sync distance flag
    // 字节对齐到 descriptor 末尾（descr_size=8 → 止于 descr_pos+64 位）
    w.pos = (descr_pos + 8 * 8) & ~@as(usize, 7);
    const exss_size: usize = hdr_size + lbr_size;
    try testing.expect(w.pos / 8 <= hdr_size);
    try testing.expect(exss_size <= exss_buf_t.len);
    // LBR 帧数据置于 asset 起始（lbr_offset = header_size）
    @memcpy(exss_buf_t[hdr_size .. hdr_size + lbr_size], lbr_frame[0..lbr_size]);

    // 拼接为多单元裸流（2 帧）
    var stream = stdio.ArrayList(u8).empty;
    defer stream.deinit(a);
    for (0..2) |_| {
        try stream.appendSlice(a, exss_buf_t[0..exss_size]);
    }

    var reader = io2.Reader.openMem(stream.items);
    var info: decoder2.Info = undefined;
    var dec = try open(a, &reader, &info);
    defer dec.deinit();

    try stdio.testing.expectEqual(@as(u32, 16000), info.sample_rate);
    try stdio.testing.expectEqual(@as(u8, 1), info.channels);
    try stdio.testing.expectEqualStrings("DTS Express", info.profile.?);
    try stdio.testing.expectEqualStrings("dts", info.format_name);

    // 读取全部输出：每帧 1024<<freq_range(1) = 2048 样本 × 1 声道
    var list = stdio.ArrayList(i16).empty;
    defer list.deinit(a);
    var out: [4096]u8 = undefined;
    while (true) {
        var oc: u8 = 0;
        const n = try dec.read(&out, 1024, &oc);
        if (n == 0) break;
        try stdio.testing.expectEqual(@as(u8, 1), oc);
        const bytes = n * 2;
        const sl = stdio.mem.sliceAsBytes(list.addManyAsSlice(a, n) catch return error.OutOfMemory);
        @memcpy(sl[0..bytes], out[0..bytes]);
    }
    try stdio.testing.expectEqual(@as(usize, 2 * 2048), list.items.len);
}
