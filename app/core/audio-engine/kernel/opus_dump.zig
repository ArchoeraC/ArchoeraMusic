//! Opus Ogg 解复用 + CELT 解码对照工具（P1/P2 阶段）
//!
//! 解码 Ogg/Opus 文件：自研 `fmt/ogg.zig` Demux 提取 packets + `fmt/opus/header.zig`
//! 解析 OpusHead + `fmt/opus/packet.zig` 解析 TOC/帧分割。
//!
//! 用法：
//!   ./opus_dump <file.opus>            # P1：仅解复用/解析统计
//!   ./opus_dump <file.opus> --decode   # P2：CELT-only 全解码，f32 交错 PCM 到 stdout
//!   ./opus_dump <file.opus> --s16      # P3：CELT-only 全解码，s16 交错 PCM 到 stdout
//! 与 `opus_demo -d` 的输出（-f32 / 默认 s16）逐字节比对即完成 CELT bit-exact 验收。

const std = @import("std");
const io = @import("io.zig");
const ogg = @import("fmt/ogg.zig");
const opus_header = @import("fmt/opus/header.zig");
const opus_packet = @import("fmt/opus/packet.zig");
const rcmod = @import("fmt/opus/rc.zig");
const celt = @import("fmt/opus/celt.zig");
const celt_types = @import("fmt/opus/celt_types.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: opus_dump <file.opus> [--decode]\n", .{});
        return error.InvalidArgs;
    }
    const do_decode = args.len >= 3 and std.mem.eql(u8, args[2], "--decode");
    const do_s16 = args.len >= 3 and std.mem.eql(u8, args[2], "--s16");
    const do_check = args.len >= 3 and std.mem.eql(u8, args[2], "--check");
    const decode_any = do_decode or do_s16 or do_check;

    var reader = try io.Reader.openPath(args[1]);
    errdefer reader.deinit();

    var dmx = ogg.Demux{ .allocator = gpa, .reader = reader };
    defer dmx.deinit();

    // 首个 packet：OpusHead
    const head_pkt = (try dmx.nextPacket()) orelse return error.Corrupt;
    if (head_pkt.continued) return error.Corrupt;
    const head = try opus_header.parseHead(head_pkt.data);
    std.debug.print("-- OpusHead --\n", .{});
    std.debug.print("version: {d}  channels: {d}  pre_skip: {d}\n", .{ head.version, head.channels, head.pre_skip });
    std.debug.print("input_sr: {d}  output_gain: {d} (Q7.8)  mapping_family: {d}\n", .{ head.input_sample_rate, head.output_gain, head.mapping_family });

    // 第二个 packet：OpusTags（跳过）
    _ = try dmx.nextPacket();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(gpa);

    var celt_f = celt_types.CeltFrame{};
    celt_f.flush();
    celt_f.output_channels = @intCast(head.channels);

    var packets: usize = 0;
    var pre_skip_left: usize = head.pre_skip;
    var decoded: u64 = 0;
    var celt_only = true;

    while (true) {
        const pkt = (try dmx.nextPacket()) orelse break;
        const pp = opus_packet.parse(pkt.data) catch |e| {
            std.debug.print("-- packet {d} parse error: {s}\n", .{ packets, @errorName(e) });
            return e;
        };
        packets += 1;
        if (packets <= 3) {
            std.debug.print("pkt[0]: toc=0x{x:0>2} config={d} mode={s} bw={s} stereo={} frames={d} size={d}\n", .{
                pp.toc, pp.config, modeName(pp.mode), @tagName(pp.bandwidth), pp.stereo, pp.count, pp.frame_size,
            });
        }
        if (decode_any) {
            if (pp.mode != opus_packet.MODE_CELT) {
                std.debug.print("-- packet {d}: non-CELT mode，P2 仅支持 CELT-only\n", .{packets});
                celt_only = false;
                break;
            }
            const frame_size: usize = @intCast(pp.frame_size);
            const end_band = celtEndBand(pp.config);
                for (0..pp.count) |fi| {
                    const frame = pp.frames[fi].data;
                    var rc = rcmod.Rc.decInit(frame);
                    rc.decRawInit(frame, @intCast(frame.len));
                    var out_f: [2][960]f32 = undefined;
                    const n_ch = celt.decodeFrame(&celt_f, &rc, .{ out_f[0][0..frame_size], out_f[1][0..frame_size] }, @intCast(@as(usize, 1) + @intFromBool(pp.stereo)), frame_size, 0, end_band) catch |e| {
                        std.debug.print("-- celt decode error at packet {d} frame {d}: {s}\n", .{ packets, fi, @errorName(e) });
                        return e;
                    };
                    if (do_check) std.debug.print("CK {d} {d} fs={d} tell={d} rng={d}\n", .{ packets, fi, frame_size, rc.tell(), rc.range });
                    for (0..frame_size) |i| {
                    if (pre_skip_left > 0) {
                        pre_skip_left -= 1;
                        continue;
                    }
                    for (0..n_ch) |ch| {
                        const v = out_f[ch][i];
                        if (do_s16) {
                            const s = s16FromF32(v);
                            try out.appendSlice(gpa, std.mem.asBytes(&s));
                        } else {
                            try out.appendSlice(gpa, std.mem.asBytes(&v));
                        }
                    }
                    decoded += 1;
                }
            }
        }
    }

    if (do_decode or do_s16) {
        if (!celt_only) return error.UnsupportedFormat;
        std.debug.print("-- decoded {d} samples (48k, {d} ch)\n", .{ decoded, head.channels });
        var written: usize = 0;
        while (written < out.items.len) {
            const n = std.c.write(std.c.STDOUT_FILENO, out.items[written..].ptr, out.items.len - written);
            if (n < 0) return error.WriteFailed;
            written += @intCast(n);
        }
    } else {
        std.debug.print("-- packets: {d}  final granule: {d}  audio samples: {d}\n", .{ packets, dmx.final_granule, opus_header.totalSamples(dmx.final_granule, head.pre_skip) });
    }
}

fn celtEndBand(config: u8) usize {
    // CELT-only：config 16-19 NB / 20-23 WB / 24-27 SWB / 28-31 FB
    if (config < 20) return 13;
    if (config < 24) return 17;
    if (config < 28) return 19;
    return 21;
}

fn modeName(m: u8) []const u8 {
    return switch (m) {
        opus_packet.MODE_SILK => "silk",
        opus_packet.MODE_HYBRID => "hybrid",
        else => "celt",
    };
}

/// libopus s16 输出链（float build）：
/// RES2INT24(v)=float2int(8388608*v)（截断）→ demo clamp ±0x007fff00 → (s+128)>>8
fn s16FromF32(v: f32) i16 {
    var s: i32 = @intFromFloat(8388608.0 * v);
    if (s > 0x007fff00) s = 0x007fff00;
    if (s < -0x007fff00) s = -0x007fff00;
    s = (s + 128) >> 8;
    return @intCast(s);
}
