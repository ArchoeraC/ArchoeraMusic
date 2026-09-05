//! AMR 解码器（.amr 容器 + OpenCORE AMR-NB 解码）
//!
//! 文档（docs/audio-kernel-zig.md §9.13）：`#!AMR\n` 头 + 帧重同步自研（~100 行），
//! 解码走 vendored OpenCORE AMR-NB（Apache-2.0，`kernel/c/amr/`，按 `-x c` 编译）。
//!
//! AMR 帧结构（octet-aligned）：
//!   - 每帧 20ms；AMR-NB = 160 样本 @ 8kHz；
//!   - 首字节：P(1) + FT(4) + Q(1) + 保留(2)；FT = (byte0 >> 3) & 0xF；
//!   - 帧类型 → 载荷字节数表（12,13,15,17,19,20,26,31,5,6,5,5,0,0,0,0）；
//!   - SID/NO_DATA 帧（type 8-15）载荷 0 或小，解码器输出静音/舒适噪声。
//!
//! 接口（`interf_dec.h`）：`Decoder_Interface_init` / `Decoder_Interface_Decode`
//! （输入含 1 字节头，输出 160 s16 @ 8kHz）/ `Decoder_Interface_exit`。
//!
//! 时长：open 时 ToC 跳帧计数（每帧 20ms 固定，帧数 × 20ms = exact；
//! 扫描区上限 64 MiB，超出按首帧模式 CBR 外推 estimate）。

const std = @import("std");
const Error = @import("../error.zig").Error;
const io = @import("../io.zig");
const decoder = @import("../decoder.zig");

const c = @cImport(@cInclude("interf_dec.h"));

/// AMR-NB 帧载荷字节数（octet-aligned；type 12-15 无数据）
const frame_sizes = [16]u8{ 12, 13, 15, 17, 19, 20, 26, 31, 5, 6, 5, 5, 0, 0, 0, 0 };

/// 帧数扫描区上限（AMR 为语音格式，文件极小；超限按 CBR 外推估算）
const scan_bytes_cap: u64 = 64 * 1024 * 1024;
/// 每帧样本数（20ms @ 8kHz）
const frame_samples: u64 = 160;

const Ctx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,
    dec_state: ?*anyopaque = null,

    /// 当前帧缓冲（头 1 字节 + 载荷，最大 32 字节）
    frame_buf: [33]u8 = undefined,
    frame_len: usize = 0,
    frame_loaded: bool = false,
    eof: bool = false,

    /// 解码输出缓冲（每帧 160 s16）
    pcm: [160]i16 = undefined,
    pcm_len: usize = 0,
    pcm_pos: usize = 0,
    samples_done: u64 = 0,
};

pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const f = try allocator.create(Ctx);
    errdefer allocator.destroy(f);
    f.* = .{ .allocator = allocator, .reader = reader.* };
    errdefer f.reader.deinit();

    // 校验 `#!AMR\n` 头
    var hdr: [6]u8 = undefined;
    const n = try f.reader.read(&hdr);
    if (n < 6 or !std.mem.eql(u8, &hdr, "#!AMR\n")) return error.Corrupt;

    f.dec_state = c.Decoder_Interface_init();
    errdefer c.Decoder_Interface_exit(f.dec_state);

    // 时长：ToC 跳帧计数（帧数 × 20ms，exact）；扫描不可靠/超限时按首帧
    // 模式 CBR 外推（estimate）。每帧 20ms 固定，帧数是唯一自由度。
    const data_start: u64 = 6; // "#!AMR\n" 之后
    const file_size = f.reader.size() catch 0;
    var duration_us: i64 = -1;
    var known: decoder.DurationKnown = .unknown;
    if (file_size > data_start) blk: {
        if (file_size - data_start <= scan_bytes_cap) {
            if (countFrames(f, data_start)) |frames| {
                duration_us = @intCast(frames * frame_samples * 1_000_000 / 8000);
                known = .exact;
                break :blk;
            }
        }
        // 首帧模式 CBR 外推（estimate）
        f.reader.seek(@intCast(data_start), .start) catch break :blk;
        var toc: [1]u8 = undefined;
        const m = f.reader.peek(&toc) catch 0;
        if (m == 1) {
            const au_bytes: u64 = 1 + frame_sizes[(toc[0] >> 3) & 0xF];
            const frames = (file_size - data_start) / au_bytes;
            duration_us = @intCast(frames * frame_samples * 1_000_000 / 8000);
            known = .estimate;
        }
    }
    f.reader.seek(@intCast(data_start), .start) catch {};

    info.* = .{
        .sample_rate = 8000,
        .channels = 1,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = known,
        .codec_name = "amr",
        .format_name = "amr",
        .metadata = .{},
    };
    return .{ .vtable = &vtable, .ctx = f };
}

/// ToC 跳帧计数（chunked 顺序扫描；帧定长 ≤32B，滑窗处理跨块帧）。
/// 截断尾帧与解码路径一致（解码器对载荷不足帧补 0 并输出）→ exact。
/// 扫描失败返回 null（调用方回落估算），失败/成功均恢复读位置。
fn countFrames(f: *Ctx, start_pos: u64) ?u64 {
    const file_size = f.reader.size() catch return null;
    if (file_size <= start_pos or file_size - start_pos > scan_bytes_cap) return null;
    var buf: [4096]u8 = undefined;
    var have: usize = 0; // buf[0..have] = 文件偏移 scan_pos 起的未消费字节
    var scan_pos: u64 = start_pos;
    var frames: u64 = 0;
    while (true) {
        if (have == 0) {
            f.reader.seek(@intCast(scan_pos), .start) catch return null;
            have = f.reader.read(&buf) catch return null;
            if (have == 0) break; // EOF：扫描完成
        }
        const step = 1 + @as(u64, frame_sizes[(buf[0] >> 3) & 0xF]);
        if (step > have) {
            // 块尾不足一帧：补读；EOF 则按截断帧计（与解码补 0 输出一致）
            f.reader.seek(@intCast(scan_pos + have), .start) catch return null;
            const n = f.reader.read(buf[have..]) catch return null;
            if (n == 0) {
                frames += 1;
                break;
            }
            have += n;
            continue;
        }
        frames += 1;
        scan_pos += step;
        std.mem.copyForwards(u8, buf[0 .. have - @as(usize, @intCast(step))], buf[@intCast(step)..have]);
        have -= @intCast(step);
    }
    f.reader.seek(@intCast(start_pos), .start) catch return null;
    return frames;
}

const VTable = decoder.Decoder.VTable;
const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    out_channels.* = 1;
    if (max_samples == 0 or out.len == 0) return 0;

    var produced: usize = 0;
    while (produced < max_samples) {
        if (f.pcm_pos >= f.pcm_len) {
            if (!try decodeNextFrame(f)) break;
            f.pcm_pos = 0;
            continue;
        }
        const avail = f.pcm_len - f.pcm_pos;
        const take = @min(avail, max_samples - produced);
        @memcpy(out[produced * 2 ..][0 .. take * 2], std.mem.sliceAsBytes(f.pcm[f.pcm_pos .. f.pcm_pos + take]));
        f.pcm_pos += take;
        produced += take;
    }
    return produced;
}

/// 解码下一帧 → f.pcm（160 s16）。返回是否有新样本。
fn decodeNextFrame(f: *Ctx) Error!bool {
    if (f.eof) return false;
    // 读帧头字节
    var hb: [1]u8 = undefined;
    const n0 = try f.reader.read(&hb);
    if (n0 == 0) {
        f.eof = true;
        return false;
    }
    const ftype: usize = (hb[0] >> 3) & 0xF;
    const sz: usize = frame_sizes[ftype];
    f.frame_buf[0] = hb[0];
    var filled: usize = 0;
    if (sz > 0) {
        // 读载荷（不足则填 0）
        var buf: [32]u8 = undefined;
        const m = try f.reader.read(buf[0..sz]);
        @memcpy(f.frame_buf[1 .. 1 + m], buf[0..m]);
        if (m < sz) @memset(f.frame_buf[1 + m .. 1 + sz], 0);
        filled = m;
    }
    // 输出缓冲清零，解码
    @memset(&f.pcm, 0);
    c.Decoder_Interface_Decode(f.dec_state, &f.frame_buf, &f.pcm, 0);
    f.pcm_len = 160;
    f.samples_done += 160;
    return true;
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    return @intCast((@as(u128, f.samples_done) * 1000) / 8000);
}

fn seekMsImpl(ctx: *anyopaque, ms_arg: i64) Error!void {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    const ms: i64 = if (ms_arg < 0) 0 else ms_arg;
    const target_frames: u64 = @intCast((@as(u128, @intCast(ms)) * 8000) / (1000 * 160));
    // 重置解码状态（AMR 内部有 LPC 预测状态）
    f.eof = false;
    f.pcm_pos = 0;
    f.pcm_len = 0;
    f.samples_done = 0;
    if (f.dec_state) |st| c.Decoder_Interface_exit(st);
    f.dec_state = c.Decoder_Interface_init();
    // 回到数据开始（跳过 #!AMR\n 头）
    try f.reader.seek(0, .start);
    try f.reader.seek(6, .current);
    // 逐帧跳过（读帧头 + seek 载荷，不解码）
    var n: u64 = 0;
    while (n < target_frames) : (n += 1) {
        var hb: [1]u8 = undefined;
        const m = try f.reader.read(&hb);
        if (m == 0) {
            f.eof = true;
            break;
        }
        const ftype: usize = (hb[0] >> 3) & 0xF;
        const sz: usize = frame_sizes[ftype];
        if (sz == 0) {
            f.eof = true;
            break;
        }
        try f.reader.seek(@intCast(sz), .current);
        f.samples_done += 160;
    }
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    if (f.dec_state) |st| c.Decoder_Interface_exit(st);
    f.reader.deinit();
    f.allocator.destroy(f);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "amr: 集成解码（open + 读取）" {
    const data = @embedFile("amr_tiny.amr");
    var reader = io.Reader.openMem(data);
    var info: decoder.Info = undefined;
    var dc = try open(std.testing.allocator, &reader, &info);
    defer dc.deinit();
    try std.testing.expectEqual(@as(u32, 8000), info.sample_rate);
    try std.testing.expectEqual(@as(u8, 1), info.channels);
    // 时长 exact：amr_tiny.amr = 11 帧 × 20ms（ffprobe 同值 0.22s）
    try std.testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
    try std.testing.expectEqual(@as(i64, 220_000), info.duration_us);

    var buf: [4096]u8 = undefined;
    var ch: u8 = 0;
    var total: usize = 0;
    while (true) {
        const n = try dc.read(&buf, 1024, &ch);
        if (n == 0) break;
        total += n * ch * 2;
        if (total > 1024 * 1024) break;
    }
    try std.testing.expect(total > 0);
}
