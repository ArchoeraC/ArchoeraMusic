//! PLC 局部测试：`opus.open` + 指定包号丢包 → s16 交错 PCM 到 stdout。
//! 用法：./plc_test <file.ogg> <lost_packet_number> [lost_count] > out.pcm
//! 对照：./plc_ref2 <file.ogg> <lost_packet_number> <lost_count> > ref.pcm
const std = @import("std");
const decoder = @import("decoder.zig");
const opus = @import("fmt/opus/lib.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 3) return error.InvalidArgs;
    const lost_n = try std.fmt.parseInt(usize, args[2], 10);
    const lost_cnt: usize = if (args.len >= 4) try std.fmt.parseInt(usize, args[3], 10) else 1;

    var reader = try @import("io.zig").Reader.openPath(args[1]);
    var info: decoder.Info = undefined;
    var d = try opus.open(gpa, &reader, &info);
    opus.setLostAt(d.ctx, lost_n);
    opus.setLostCount(d.ctx, lost_cnt);

    const frame_bytes = @as(usize, info.channels) * 2;
    var pcm: [4096]u8 = undefined;
    var total: u64 = 0;
    var out_ch: u8 = 0;
    while (true) {
        const n = try d.read(&pcm, pcm.len / frame_bytes, &out_ch);
        if (n == 0) break;
        total += n;
        var written: usize = 0;
        while (written < n * frame_bytes) {
            const c = std.c.write(std.c.STDOUT_FILENO, pcm[written..].ptr, n * frame_bytes - written);
            if (c < 0) return error.WriteFailed;
            written += @intCast(c);
        }
    }
    d.deinit();
}
