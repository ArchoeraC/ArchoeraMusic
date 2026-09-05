const std = @import("std");
const decoder = @import("decoder.zig");
pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const gpa = std.heap.page_allocator;
    var info: decoder.Info = undefined;
    var dc = try decoder.open(gpa, "/tmp/ps_File2.mp4", &info);
    defer dc.deinit();
    var buf: [65536]u8 = undefined;
    var ch: u8 = 0;
    var total: usize = 0;
    while (true) {
        const n = try dc.read(&buf, 4096, &ch);
        if (n == 0) break;
        total += n;
    }
    std.debug.print("解码 {d} 样本\n", .{total});
}
