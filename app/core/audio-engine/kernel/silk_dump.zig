const std = @import("std");
const io = @import("io.zig");
const ogg = @import("fmt/ogg.zig");
const opus_header = @import("fmt/opus/header.zig");
const opus_packet = @import("fmt/opus/packet.zig");
const rcmod = @import("fmt/opus/rc.zig");
const silk = @import("fmt/opus/silk.zig");
const celt = @import("fmt/opus/celt.zig");
const celt_types = @import("fmt/opus/celt_types.zig");

fn celtEndBand(config: u8) usize {
    if (config < 12) return 0;
    if (config < 14) return 19;
    if (config < 16) return 21;
    if (config < 20) return 13;
    if (config < 24) return 17;
    if (config < 28) return 19;
    return 21;
}

fn writePcm(pcm: []i16) void {
    var kk: usize = 0;
    while (kk < pcm.len) : (kk += 1) {
        const v = pcm[kk];
        _ = std.c.write(std.c.STDOUT_FILENO, std.mem.asBytes(&v).ptr, 2);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) return error.InvalidArgs;
    var reader = try io.Reader.openPath(args[1]);
    errdefer reader.deinit();
    var dmx = ogg.Demux{ .allocator = arena.allocator(), .reader = reader };
    defer dmx.deinit();

    const head_pkt = (try dmx.nextPacket()) orelse return error.Corrupt;
    _ = try opus_header.parseHead(head_pkt.data);
    _ = try dmx.nextPacket();

    var dec0 = silk.DecoderState{};
    var dec1 = silk.DecoderState{};
    var sst = silk.StereoDecState{};
    var rsm = silk.ResamplerState{};
    var prev_last: i16 = 0;
    _ = silk.resamplerInit(&rsm, 16000, 48000);
    var packets: usize = 0;
    const do_pcm = args.len >= 3 and std.mem.eql(u8, args[2], "--pcm");
    while (true) {
        const pkt = (try dmx.nextPacket()) orelse break;
        const pp = try opus_packet.parse(pkt.data);
        packets += 1;
        std.debug.print("PKT {d}: mode={d} config={d} count={d} fs={d} stereo={} size={d}\n", .{ packets, pp.mode, pp.config, pp.count, pp.frame_size, pp.stereo, pkt.data.len });
        if (args.len >= 3 and std.mem.eql(u8, args[2], "--celtonly")) {
            for (0..pp.count) |fi| {
                const frame = pp.frames[fi].data;
                var rc2 = rcmod.Rc.decInit(frame);
                rc2.decRawInit(frame, @intCast(frame.len));
                var celt_f2 = celt_types.CeltFrame{};
                celt_f2.flush();
                var out_f2: [2][960]f32 = undefined;
                _ = celt.decodeFrame(&celt_f2, &rc2, .{ out_f2[0][0..@intCast(pp.frame_size)], out_f2[1][0..@intCast(pp.frame_size)] }, @intCast(@as(usize, 1) + @intFromBool(pp.stereo)), @intCast(pp.frame_size), if (pp.mode == opus_packet.MODE_HYBRID) 17 else 0, celtEndBand(pp.config)) catch |e| {
                    std.debug.print("celtonly err {s} tell={d}\n", .{ @errorName(e), rc2.tell() });
                    continue;
                };
                std.debug.print("CK {d} {d} tell={d}\n", .{ packets, fi, rc2.tell() });
            }
            continue;
        }
        if (pp.mode == opus_packet.MODE_HYBRID) {
            dec0.n_frames_decoded = 0;
            dec0.n_frames_per_packet = @intCast(pp.count);
            dec0.nb_subfr = if (pp.frame_size == 960) 4 else 2;
            _ = silk.decoderSetFs(&dec0, 16, 48000);
            var celt_f = celt_types.CeltFrame{};
            celt_f.flush();
            celt_f.output_channels = @intCast(if (pp.stereo) @as(usize, 2) else 1);
            for (0..pp.count) |fi| {
                const frame = pp.frames[fi].data;
                var rc = rcmod.Rc.decInit(frame);
                rc.decRawInit(frame, @intCast(frame.len));
                var out_l: [770]i16 = undefined;
                var out_r: [770]i16 = undefined;
                const fl: usize = @intCast(dec0.frame_length);
                if (pp.stereo) {
                    silk.decodePacketStereo(&dec0, &dec1, &sst, &rc, out_l[0 .. fl + 2], out_r[0 .. fl + 2]);
                } else {
                    silk.decodePacket(&dec0, &rc, out_l[0..fl]);
                }
                var redundancy: i32 = 0;
                const total = @as(i32, @intCast(frame.len * 8));
                if (@as(i32, @intCast(rc.tell())) + 17 + 20 <= total) {
                    redundancy = @intCast(rc.decLog(12));
                    if (redundancy != 0) {
                        _ = rc.decLog(1);
                        const rb = @as(i32, @intCast(rc.decUint(256))) + 2;
                        rc.gb.limit = (frame.len - @as(usize, @intCast(rb))) * 8;
                        rc.rb.bytes -%= @intCast(rb);
                    }
                }
                var out_f: [2][960]f32 = undefined;
                const end_band = celtEndBand(pp.config);
                _ = celt.decodeFrame(&celt_f, &rc, .{ out_f[0][0..@intCast(pp.frame_size)], out_f[1][0..@intCast(pp.frame_size)] }, @intCast(@as(usize, 1) + @intFromBool(pp.stereo)), @intCast(pp.frame_size), 17, end_band) catch |e| {
                    std.debug.print("packet {d} celt err {s}\n", .{ packets, @errorName(e) });
                    continue;
                };
                std.debug.print("CK {d} {d} tell={d} rng={d}\n", .{ packets, fi, rc.tell(), rc.range });
            }
            continue;
        }
        if (pp.mode != opus_packet.MODE_SILK) {
            std.debug.print("packet {d}: not SILK (config {d})\n", .{ packets, pp.config });
            continue;
        }
        dec0.n_frames_decoded = 0;
        dec0.n_frames_per_packet = @intCast(pp.count);
        dec0.nb_subfr = if (pp.frame_size == 960) 4 else 2;
        _ = silk.decoderSetFs(&dec0, 16, 48000);
        dec1 = .{};
        dec1.n_frames_per_packet = @intCast(pp.count);
        dec1.nb_subfr = dec0.nb_subfr;
        _ = silk.decoderSetFs(&dec1, 16, 48000);
        for (0..pp.count) |fi| {
            const frame = pp.frames[fi].data;
            var rc = rcmod.Rc.decInit(frame);
            rc.decRawInit(frame, @intCast(frame.len));
            var out_l: [770]i16 = undefined;
            var out_r: [770]i16 = undefined;
            const fl: usize = @intCast(dec0.frame_length);
            if (pp.stereo) {
                silk.decodePacketStereo(&dec0, &dec1, &sst, &rc, out_l[0 .. fl + 2], out_r[0 .. fl + 2]);
            } else {
                silk.decodePacket(&dec0, &rc, out_l[0..fl]);
            }
            if (do_pcm) {
                var pcm48: [1024]i16 = undefined;
                var rsm_buf: [400]i16 = undefined;
                rsm_buf[0] = prev_last;
                @memcpy(rsm_buf[1..fl], out_l[0 .. @as(usize, @intCast(fl - 1))]);
                if (packets >= 2 and packets <= 3)
                prev_last = out_l[@intCast(fl - 1)];
                _ = silk.resampler(&rsm, pcm48[0..], rsm_buf[0..fl], @intCast(fl));
                writePcm(pcm48[0 .. fl * 3]);
                _ = pp.stereo;
            } else {
                std.debug.print("CK {d} {d} tell={d} rng={d}\n", .{ packets, fi, rc.tell(), rc.range });
            }
        }
    }
}
