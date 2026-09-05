//! Opus 长流对照 dump：直接驱动 fmt/opus/lib.zig（不经 decoder.zig 全格式工厂），
//! 输出 s16 交错 PCM 到 stdout。便于长样本 mine vs ffmpeg 逐段对拍。
//! 用法：./opus_compare_dump <file.opus> > out.s16
const std = @import("std");
const io = @import("io.zig");
const decoder = @import("decoder.zig");
const opus = @import("fmt/opus/lib.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) return error.InvalidArgs;

    var reader = try io.Reader.openPath(args[1]);
    var info: decoder.Info = undefined;
    var d = try opus.open(arena.allocator(), &reader, &info);
    defer d.deinit();
    std.debug.print("-- sr={d} ch={d} bps={d} codec={s} fmt={s}\n", .{ info.sample_rate, info.channels, info.bits_per_sample, info.codec_name, info.format_name });

    const frame_bytes = @as(usize, info.channels) * 2;
    var pcm: [65536]u8 = undefined;
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
    std.debug.print("-- decoded {d} samples {d} ch\n", .{ total, info.channels });
}
