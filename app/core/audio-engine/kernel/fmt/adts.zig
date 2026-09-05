//! ADTS 裸流容器（AAC ADTS，ISO 14496-3 §1.8.2）：帧同步定位 + 头解析，
//! 载荷逐帧喂给 fmt/aac/lib.zig（AAC-LC 自研解码核心）。
//!
//! 帧结构：syncword(12)=0xFFF | id(1) | layer(2)=0 | protection_absent(1)
//!         | profile(2) | sf_index(4) | private(1) | chan_cfg(3) | ...
//!         | aac_frame_length(13，含头) | buffer_fullness(11) | rdb(2)
//! 头长 7 字节；protection_absent==0 时其后跟 2 字节 CRC（载荷前）。
//!
//! 范围（Phase C）：profile=LC、rdb=1；chan_config ≤ 7（mono~7.1）已支持；
//! 其余（HE-AAD/LD/多声道/PCE）→ UnsupportedFormat 回退 FFmpeg 主后端（§8.3）。
//!
//! Seek：按帧头顺序跳过累计样本（每帧固定 1024），无需解码即可定位；
//! 时长：open 时 ADTS 帧头跳帧计数（帧数 × 1024 = exact；扫描区上限
//! 128 MiB / 重同步失败 → 回落首帧码率估算 estimate）。

const std = @import("std");
const Error = @import("../error.zig").Error;
const io = @import("../io.zig");
const decoder = @import("../decoder.zig");
const asc = @import("aac/asc.zig");
const aacmod = @import("aac/lib.zig");
const BitReader = @import("aac/bitreader.zig").BitReader;

const header_size = asc.AdtsHeader.header_size; // 7

/// 帧数扫描区上限（超出 → 码率估算；典型 AAC 文件远小于此）
const scan_bytes_cap: u64 = 128 * 1024 * 1024;
/// 重同步搜索窗口（伪同步/垃圾时向前找下一帧头）
const resync_window: usize = 64 * 1024;

pub const AdtsCtx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,
    aac: aacmod.Aac,

    /// 未消费的输入缓冲（跨帧残留）
    pending: std.ArrayList(u8),
    /// 输入是否已到 EOF
    input_eof: bool = false,

    /// 文件大小（估算时长用）
    file_size: u64 = 0,
    /// 首帧码率（bps）
    bitrate: u64 = 0,

    /// 帧载荷解码缓冲（含零填充供 ESC showBits 使用）
    frame_buf: [64 * 1024 + 64]u8 = undefined,
    /// 连续解码失败计数（超过上限放弃）
    consecutive_errors: u32 = 0,
    /// 累计跳过的坏帧
    skipped_frames: u64 = 0,

    pub fn deinitSelf(self: *AdtsCtx) void {
        self.pending.deinit(self.allocator);
        self.aac.deinit(); // AAC 元素槽位/SBR 堆分配状态（out_buf 见下）
        self.aac.out_buf.deinit(self.aac.gpa);
        self.reader.deinit();
        self.allocator.destroy(self);
    }
};

// ---------------- 帧定位 ----------------

/// 在 buf[off..] 中查找下一个同步字，返回帧起点（未找到返回 null）。
fn findSync(buf: []const u8, off: usize) ?usize {
    var i = off;
    while (i + 1 < buf.len) : (i += 1) {
        if (buf[i] == 0xFF and (buf[i + 1] & 0xF6) == 0xF0) {
            // 11111111 1111 0LLP：sync12+id(MPEG4=0/MPEG2=1 都接受)+layer=00
            return i;
        }
    }
    return null;
}

const FrameHeader = asc.AdtsHeader;

const FrameInfo = struct { hdr: FrameHeader, payload_off: usize, payload_len: usize };

/// 解析 off 处的完整帧头并校验约束（LC / mono-stereo / rdb=1）。
fn parseFrameAt(ctx: *AdtsCtx, off: usize) Error!FrameInfo {
    const buf = ctx.pending.items;
    var hdr = try asc.parseAdts(buf[off .. off + header_size]);
    if (!hdr.crc_absent) {
        // 有 CRC：帧头后 2 字节 CRC 属于本帧（FFmpeg adts demuxer 同样计入）
        hdr.frame_length += 0; // frame_length 字段本身含 CRC 区
    }
    if (hdr.object_type != 2 and hdr.object_type != 1 and hdr.object_type != 4) return error.UnsupportedFormat; // LC/Main/LTP
    if (hdr.num_aac_frames != 1) return error.UnsupportedFormat; // rdb>1 不支持
    if (hdr.frame_length < header_size) return error.Corrupt;

    const hdr_len: usize = if (hdr.crc_absent) header_size else header_size + 2;
    if (hdr.frame_length < hdr_len) return error.Corrupt;
    const payload_len: usize = hdr.frame_length - hdr_len;
    return .{ .hdr = hdr, .payload_off = off + hdr_len, .payload_len = payload_len };
}

/// 确保缓冲内有一个可解析的完整帧；成功返回帧信息（相对 pending 的偏移）。
/// 返回 null 表示数据耗尽且无更多帧。
fn fillNextFrame(ctx: *AdtsCtx) Error!?FrameInfo {
    while (true) {
        if (findSync(ctx.pending.items, 0)) |off| {
            if (off > 0) {
                // 丢弃同步字之前的垃圾
                std.mem.copyForwards(u8, ctx.pending.items[0 .. ctx.pending.items.len - off], ctx.pending.items[off..]);
                ctx.pending.shrinkRetainingCapacity(ctx.pending.items.len - off);
            }
            if (ctx.pending.items.len >= header_size) {
                const fi = parseFrameAt(ctx, 0) catch |e| switch (e) {
                    error.UnsupportedFormat => return e,
                    error.Corrupt => {
                        // 伪同步：前进 1 字节继续找
                        std.mem.copyForwards(u8, ctx.pending.items[0 .. ctx.pending.items.len - 1], ctx.pending.items[1..]);
                        ctx.pending.shrinkRetainingCapacity(ctx.pending.items.len - 1);
                        continue;
                    },
                    else => return e,
                };
                if (ctx.pending.items.len >= fi.payload_off + fi.payload_len) {
                    return fi;
                }
            }
        }
        // 补读数据
        if (!ctx.input_eof) {
            var tmp: [16 * 1024]u8 = undefined;
            const n = ctx.reader.read(&tmp) catch |e| switch (e) {
                error.Aborted => return e,
                else => 0,
            };
            if (n == 0) {
                ctx.input_eof = true;
                if (findSync(ctx.pending.items, 0) == null) return null;
                continue;
            }
            try ctx.pending.appendSlice(ctx.allocator, tmp[0..n]);
            continue;
        }
        return null;
    }
}

// ---------------- VTable ----------------

fn decodeOneFrame(ctx: *AdtsCtx) Error!bool {
    const fi = (try fillNextFrame(ctx)) orelse return false;
    const payload = ctx.pending.items[fi.payload_off .. fi.payload_off + fi.payload_len];
    if (payload.len > 64 * 1024) return error.Corrupt;
    // 带零填充的工作区（ESC 路径 showBits(32) 可能越过真实结尾）
    @memcpy(ctx.frame_buf[0..payload.len], payload);
    @memset(ctx.frame_buf[payload.len .. payload.len + 64], 0);

    var br = BitReader.init(ctx.frame_buf[0 .. payload.len + 64]);
    if (ctx.aac.decodeFrame(&br)) |_| {
        ctx.consecutive_errors = 0;
    } else |e| switch (e) {
        error.Aborted, error.OutOfMemory => return e,
        else => {
            // 坏帧：丢弃输出、保留容器状态，重同步到下一帧（§13.3，对齐
            // FFmpeg ADTS demuxer 的错误恢复语义）；连续失败超限才放弃
            ctx.aac.out_pos = 0;
            ctx.aac.out_buf.clearRetainingCapacity();
            ctx.skipped_frames += 1;
            ctx.consecutive_errors += 1;
            // 坏帧容错：静默跳过并计数（§13.3）；连续失败超限才上报
            _ = &ctx.consecutive_errors;
            if (ctx.consecutive_errors > 16) return e;
        },
    }

    const consumed = fi.payload_off + fi.payload_len;
    std.mem.copyForwards(u8, ctx.pending.items[0 .. ctx.pending.items.len - consumed], ctx.pending.items[consumed..]);
    ctx.pending.shrinkRetainingCapacity(ctx.pending.items.len - consumed);
    return true;
}

fn readImpl(opaque_ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const ctx: *AdtsCtx = @ptrCast(@alignCast(opaque_ctx));
    out_channels.* = ctx.aac.channels;
    if (max_samples == 0 or out.len == 0) return 0;

    var produced: usize = 0;
    var dst_off: usize = 0;
    // 声道数可能随首帧（PCE 解析 / PS 检测）变化：frame_bytes/容量随其后更新
    var frame_bytes: usize = @as(usize, ctx.aac.channels) * 2;

    while (produced < max_samples) {
        const avail_bytes = ctx.aac.out_buf.items.len - ctx.aac.out_pos;
        if (avail_bytes == 0) {
            ctx.aac.out_pos = 0;
            ctx.aac.out_buf.clearRetainingCapacity();
            if (!try decodeOneFrame(ctx)) break; // EOF
            if (@as(usize, ctx.aac.channels) * 2 != frame_bytes) {
                frame_bytes = @as(usize, ctx.aac.channels) * 2;
                out_channels.* = ctx.aac.channels;
            }
            continue;
        }
        if (frame_bytes == 0) break;
        const want_frames = @min(
            (out.len - dst_off) / frame_bytes,
            max_samples - produced,
        );
        if (want_frames == 0) break; // 输出缓冲已满，不再解码
        const take_bytes = @min(avail_bytes, want_frames * frame_bytes);
        @memcpy(out[dst_off .. dst_off + take_bytes], ctx.aac.out_buf.items[ctx.aac.out_pos .. ctx.aac.out_pos + take_bytes]);
        ctx.aac.out_pos += take_bytes;
        dst_off += take_bytes;
        produced += take_bytes / frame_bytes;
    }
    return produced;
}

fn positionMsImpl(opaque_ctx: *anyopaque) i64 {
    const ctx: *AdtsCtx = @ptrCast(@alignCast(opaque_ctx));
    if (ctx.aac.sample_rate == 0) return 0;
    const ms = @divTrunc(@as(i128, @intCast(ctx.aac.pos_samples)) * 1000, @as(i128, ctx.aac.sample_rate));
    return @intCast(ms);
}

fn seekMsImpl(opaque_ctx: *anyopaque, ms: i64) Error!void {
    const ctx: *AdtsCtx = @ptrCast(@alignCast(opaque_ctx));
    if (ms <= 0) {
        // 重置到文件头重新同步
        ctx.reader.seek(0, .start) catch {};
        ctx.pending.clearRetainingCapacity();
        ctx.input_eof = false;
        ctx.aac.pos_samples = 0;
        ctx.aac.out_pos = 0;
        ctx.aac.out_buf.clearRetainingCapacity();
        return;
    }

    // 目标样本序号；按帧头跳过（无需解码）
    const target_sample: u128 = @intCast(@divTrunc(@as(i128, ms) * ctx.aac.sample_rate, 1000));
    const cur: u128 = ctx.aac.pos_samples;
    if (target_sample <= cur) {
        // 向后 seek：从头重扫
        ctx.reader.seek(0, .start) catch {};
        ctx.pending.clearRetainingCapacity();
        ctx.input_eof = false;
        ctx.aac.pos_samples = 0;
        ctx.aac.out_pos = 0;
        ctx.aac.out_buf.clearRetainingCapacity();
    }

    // 逐帧头推进到目标帧边界
    var guard: u32 = 0;
    while (@as(u128, ctx.aac.pos_samples) < target_sample) {
        guard += 1;
        if (guard > 10_000_000) return error.SeekFailed;
        const fi = (try fillNextFrame(ctx)) orelse break;
        // 跳过该帧（不解码）
        const consumed = fi.payload_off + fi.payload_len;
        std.mem.copyForwards(u8, ctx.pending.items[0 .. ctx.pending.items.len - consumed], ctx.pending.items[consumed..]);
        ctx.pending.shrinkRetainingCapacity(ctx.pending.items.len - consumed);
        ctx.aac.pos_samples += ctx.aac.frame_samples;
    }

    // 清空输出游标状态（seek 后从新位置重新解码输出）
    ctx.aac.out_pos = 0;
    ctx.aac.out_buf.clearRetainingCapacity();
}

fn deinitImpl(opaque_ctx: *anyopaque) void {
    const ctx: *AdtsCtx = @ptrCast(@alignCast(opaque_ctx));
    ctx.deinitSelf();
}

const vtable = decoder.Decoder.VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

// ---------------- 打开 ----------------

/// ID3v2 syncsafe 4 字节大小（高位置 1 即终止）
fn syncsafe(b: []const u8) usize {
    var size: usize = 0;
    for (b) |byte| {
        if (byte & 0x80 != 0) return 0;
        size = (size << 7) | byte;
    }
    return size;
}

pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    // 可选 ID3v2 前导（ADTS 裸流允许，如 aacPlusDecoderCheckPackage File1.aac）
    var id3head: [10]u8 = undefined;
    const ni = try reader.peek(&id3head);
    if (ni >= 3 and std.mem.eql(u8, id3head[0..3], "ID3")) {
        const tag_size = syncsafe(id3head[6..10]);
        try reader.seek(@intCast(10 + tag_size), .start);
    }
    // 探测首个帧头
    var head: [header_size]u8 = undefined;
    const n = try reader.peek(&head);
    if (n < header_size) return error.Corrupt;
    if (head[0] != 0xFF or (head[1] & 0xF6) != 0xF0) return error.UnsupportedFormat;

    const hdr0 = try asc.parseAdts(&head);
    if (hdr0.object_type != 2 and hdr0.object_type != 1 and hdr0.object_type != 4) return error.UnsupportedFormat; // LC/Main/LTP
    if (hdr0.num_aac_frames != 1) return error.UnsupportedFormat;


    const ctx = try allocator.create(AdtsCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .reader = reader.*,
        .pending = .empty,
        .aac = .{}, // 定义基线：重型状态指针为 null（initCommon 前 deinit 安全）
    };
    ctx.file_size = reader.size() catch 0;
    ctx.bitrate = blk: {
        if (hdr0.samples > 0 and hdr0.sample_rate > 0)
            break :blk @as(u64, hdr0.frame_length) * 8 * hdr0.sample_rate / hdr0.samples;
        break :blk 0;
    };

    // 时长：ADTS 帧头跳帧计数（帧数 × 每帧样本 = exact）。扫描不可靠
    // （重同步失败）或超限时回落首帧码率估算。截断尾帧不计（与解码路径
    // 一致：载荷不完整的帧不解码）。
    const data_start = reader.pos;
    var duration_us: i64 = -1;
    var known: decoder.DurationKnown = .unknown;
    var frames: ?u64 = null;
    if (ctx.file_size > 0 and ctx.file_size <= scan_bytes_cap) {
        frames = countFrames(reader, data_start, ctx.file_size);
    }
    if (frames) |nf| {
        if (hdr0.samples > 0 and hdr0.sample_rate > 0) {
            duration_us = @intCast(nf * @as(u64, hdr0.samples) * 1_000_000 / hdr0.sample_rate);
            known = .exact;
        }
    } else if (ctx.bitrate > 0 and ctx.file_size > 0) {
        duration_us = @intCast(ctx.file_size * 8 * 1_000_000 / ctx.bitrate);
        known = .estimate;
    }

    try ctx.aac.initCommon(allocator, .{
        .object_type = hdr0.object_type,
        .sample_rate = hdr0.sample_rate,
        .sampling_index = hdr0.sampling_index,
        .chan_config = hdr0.chan_config,
        .sbr = -1,
        .ps = -1,
    });

    // chan_config=0（PCE）：布局/声道数由首帧的 program_config_element 决定。
    // 预解码首帧以确定声道数（PCE 帧本身不产音频输出，结果留在 out_buf 供首读）。
    if (ctx.aac.channels == 0) {
        _ = decodeOneFrame(ctx) catch |e| {
            if (e != error.Corrupt) return e;
        };
    }

    // 首帧必须可解析（校验真实数据完整性由后续读取处理）
    info.* = .{
        .sample_rate = if (ctx.aac.sbr_enabled) ctx.aac.sample_rate * 2 else ctx.aac.sample_rate,
        .channels = ctx.aac.channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = known,
        .codec_name = "aac",
        .format_name = "adts",
        .metadata = .{},
    };
    return .{ .vtable = &vtable, .ctx = @ptrCast(ctx) };
}

/// ADTS 跳帧计数（chunked 顺序扫描；伪同步/垃圾重同步，重同步窗口内找不到
/// 合法帧头 → null）。完整帧计数（截断尾帧不计，与解码路径一致）。
/// 成功/失败均恢复读位置到 start_pos。
fn countFrames(reader: *io.Reader, start_pos: u64, file_size: u64) ?u64 {
    var buf: [64 * 1024]u8 = undefined;
    var have: usize = 0; // buf[0..have] = 文件偏移 scan_pos 起的未消费字节
    var scan_pos: u64 = start_pos;
    var frames: u64 = 0;
    while (true) {
        if (have == 0) {
            if (scan_pos >= file_size) break;
            reader.seek(@intCast(scan_pos), .start) catch return null;
            have = reader.read(&buf) catch return null;
            if (have == 0) break; // EOF
        }
        if (have < header_size) {
            // 补读一次；仍不足 → 尾部残头不计
            reader.seek(@intCast(scan_pos + have), .start) catch return null;
            const n = reader.read(buf[have..]) catch return null;
            if (n == 0) break;
            have += n;
            continue;
        }
        // 帧头合法性（sync + 13 位 aac_frame_length 含头/CRC）
        const ok_sync = buf[0] == 0xFF and (buf[1] & 0xF6) == 0xF0;
        var flen: usize = 0;
        if (ok_sync) {
            const size: usize = (@as(usize, buf[3] & 0x03) << 11) | (@as(usize, buf[4]) << 3) | (buf[5] >> 5);
            if (size >= header_size and size <= 8191) flen = size;
        }
        if (flen == 0) {
            // 重同步：窗口内找下一 sync
            var found: ?usize = null;
            var i: usize = 1;
            while (i + 1 < have) : (i += 1) {
                if (buf[i] == 0xFF and (buf[i + 1] & 0xF6) == 0xF0) {
                    found = i;
                    break;
                }
            }
            if (found) |off| {
                scan_pos += off;
                std.mem.copyForwards(u8, buf[0 .. have - off], buf[off..have]);
                have -= off;
                continue;
            }
            if (have >= resync_window) return null; // 垃圾段过长 → 放弃扫描
            // 窗口未到上限：滑动保留最后 2 字节（跨块 sync），继续读
            const keep: usize = 1;
            scan_pos += have - keep;
            std.mem.copyForwards(u8, buf[0..keep], buf[have - keep .. have]);
            have = keep;
            reader.seek(@intCast(scan_pos + have), .start) catch return null;
            const n = reader.read(buf[have..]) catch return null;
            if (n == 0) break;
            have += n;
            continue;
        }
        // 完整帧（载荷在文件内）才计数；跨块 → 补读一次，仍不完整（EOF）→
        // 截断帧不计（与解码路径一致：载荷不完整的帧不解码）
        if (@as(u64, flen) > @as(u64, have)) {
            reader.seek(@intCast(scan_pos + have), .start) catch return null;
            const n = reader.read(buf[have..]) catch return null;
            if (n == 0) break;
            have += n;
            if (@as(u64, flen) > @as(u64, have)) break;
        }
        frames += 1;
        scan_pos += flen;
        std.mem.copyForwards(u8, buf[0 .. have - flen], buf[flen..have]);
        have -= flen;
    }
    reader.seek(@intCast(start_pos), .start) catch return null;
    return frames;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "adts: 时长 exact（跳帧计数：帧数 × 1024 / 采样率）" {
    // 5 帧 × 47B（7B 头 + 40B 载荷）@ 16kHz mono LC（synthetic）
    var file: [5 * 47]u8 = undefined;
    for (0..5) |i| {
        const off = i * 47;
        file[off] = 0xFF;
        file[off + 1] = 0xF1; // MPEG-4 / layer 0 / protection_absent
        file[off + 2] = 0x60; // profile=LC / sf_index=8(16kHz) / chan_cfg bit2=0
        file[off + 3] = 0x40; // chan_cfg 低 2 位 / frame_length[12:11]=0
        file[off + 4] = 0x05; // frame_length[10:3] = 5 → 47
        file[off + 5] = 0xFF; // frame_length[2:0]=7 + buffer_fullness[10:6]
        file[off + 6] = 0xFC; // buffer_fullness[5:0] / rdb=0
        @memset(file[off + 7 .. off + 47], 0x11);
    }
    var reader = io.Reader.openMem(&file);
    var info: decoder.Info = undefined;
    var dec = try open(testing.allocator, &reader, &info);
    defer dec.deinit();
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
    // 5 帧 × 1024 样本 / 16kHz = 320ms
    try testing.expectEqual(@as(i64, 320_000), info.duration_us);
    try testing.expectEqual(@as(u32, 16000), info.sample_rate);
    try testing.expectEqual(@as(u8, 1), info.channels);
}

test "adts: 尾部截断帧不计入时长（与解码路径一致）" {
    // 3 个完整帧 + 20B 残头（载荷不足 47B → 不解码不计）
    var file: [3 * 47 + 20]u8 = undefined;
    for (0..3) |i| {
        const off = i * 47;
        file[off] = 0xFF;
        file[off + 1] = 0xF1;
        file[off + 2] = 0x60;
        file[off + 3] = 0x40;
        file[off + 4] = 0x05;
        file[off + 5] = 0xFF;
        file[off + 6] = 0xFC;
        @memset(file[off + 7 .. off + 47], 0x22);
    }
    // 残头：合法 sync + frame_length=47，但载荷被文件尾截断
    file[3 * 47] = 0xFF;
    file[3 * 47 + 1] = 0xF1;
    file[3 * 47 + 2] = 0x60;
    file[3 * 47 + 3] = 0x40;
    file[3 * 47 + 4] = 0x05;
    file[3 * 47 + 5] = 0xFF;
    file[3 * 47 + 6] = 0xFC;
    @memset(file[3 * 47 + 7 ..], 0x33);
    var reader = io.Reader.openMem(&file);
    var info: decoder.Info = undefined;
    var dec = try open(testing.allocator, &reader, &info);
    defer dec.deinit();
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
    try testing.expectEqual(@as(i64, 192_000), info.duration_us); // 3 帧 × 1024 / 16k
}
