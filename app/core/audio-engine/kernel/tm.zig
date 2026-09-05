const std = @import("std");
const decoder = @import("decoder.zig");
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, f: *anyopaque) usize;
pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 3) return;
    var info: decoder.Info = undefined;
    var dc = try decoder.open(gpa, args[1], &info);
    defer dc.deinit();
    std.debug.print("ch={d} sr={d} codec={s}\n", .{ info.channels, info.sample_rate, info.codec_name });
    var buf: [16384]u8 = undefined;
    var ch: u8 = 0;
    var o = std.ArrayList(u8).empty;
    defer o.deinit(gpa);
    while (true) {
        const n = dc.read(&buf, 2048, &ch) catch |e| { std.debug.print("err {s}\n", .{@errorName(e)}); break; };
        if (n == 0) break;
        try o.appendSlice(gpa, buf[0 .. n * ch * 2]);
    }
    const f = fopen(args[2], "wb");
    if (f) |fp| _ = fwrite(o.items.ptr, 1, o.items.len, fp);
    std.debug.print("frames={d}\n", .{o.items.len / @as(usize, ch) / 2});
}
