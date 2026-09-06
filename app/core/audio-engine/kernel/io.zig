// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 输入抽象（docs/audio-kernel-zig.md §6.1）
//!
//! `Reader` 提供统一的只读字节流视图，三种形态：
//!   - file     ：本地文件（std.Io，跨平台：Linux/macOS/Windows）
//!   - memory   ：内存切片（零拷贝、零分配，探针/测试主力）
//!   - callback ：预留的流式输入（fd / 管道 / 未来网络流，§4.3 网络走预下载临时文件）
//!
//! 实现说明（Zig 0.16 std.Io 模型）：
//!   - File 采用**位置读取**（readPositionalAll），无隐式文件位置状态，
//!     天然线程安全；`peek`/`read`/`seek` 均为纯偏移运算；
//!   - file 形态无需内部缓冲；callback 形态因底层无 offset，`peek` 需缓冲；
//!   - `abort` 置原子标志，所有 read/peek/seek 立即返回 error.Aborted
//!     （替代 FFmpeg AVIOInterruptCB，§13.1），保证 SIGTERM / stop 即时响应。

const std = @import("std");
const Error = @import("error.zig").Error;

/// 输入形态
pub const Kind = enum { file, memory, callback };

/// 定位基准（0.16 移除 std.fs.File.SeekOrigin，此处保持同义语义；
/// callback 形态 whence 数值：0=start 1=current 2=end）
pub const SeekOrigin = enum { start, current, end };

/// callback 形态的 peek 缓冲大小（file 形态无缓冲，见文件头说明）
const peek_buffer_size = 16 * 1024;

/// file 形态前瞻缓存块大小（块内逐字节消费零系统调用）
const file_cache_size = 16 * 1024;

pub const Reader = struct {
    kind: Kind,
    /// 数据源形态
    file: ?std.Io.File = null,
    io: ?std.Io = null, // 与 file 配对保存的 IO 实现实例
    data: ?[]const u8 = null,
    /// 流式形态（预留）
    on_read: ?*const fn (ctx: *anyopaque, buf: []u8) usize = null,
    /// 流式 seek：buffered = 调用时 peek 缓冲中未消费的字节数（io.zig 即将丢弃）。
    /// 回调应按"逻辑位置前移 off"（当前 pos 处起点）从流源同步跳过，
    /// 其中 buffered 字节已在缓冲里被丢弃，只需再从源额外跳过 off - buffered（若为正）。
    on_seek: ?*const fn (ctx: *anyopaque, off: i64, whence: i32, buffered: usize) bool = null,
    ctx: ?*anyopaque = null,

    /// 逻辑读取位置（read 前进，seek 重置）
    pos: u64 = 0,
    /// 已知总大小（未知 = 0）
    size_hint: u64 = 0,

    /// 中断标志：置位后所有 IO 操作返回 error.Aborted（§13.1）
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // ---- callback 形态的 peek 缓冲 ----
    buffer: []u8 = &.{},
    buf_pos: usize = 0,
    buf_len: usize = 0,

    // ---- file 形态的前瞻缓冲（消除逐字节位置读的系统调用）----
    // 位级解码器（FLAC 等）每次只取 1 字节；若直接走位置读会为每个字节付一次
    // pread 系统调用（27MB 文件 ≈ 2700 万次 → 解码墙钟大半耗在 sys 侧）。
    // 此处以「已消费字节位置 pos」为逻辑游标，预读块缓存不推进 pos（可见性透明：
    // read 仍严格按消费字节前进、seek/peek 语义不变），见 readFile/peekFile。
    file_cache: [file_cache_size]u8 = undefined,
    /// 缓存块起始的文件偏移（file_cache[0] 对应偏移）
    file_cache_start: u64 = 0,
    /// 缓存中有效字节数（0 = 无效）
    file_cache_len: usize = 0,

    /// 打开本地文件（file 形态）
    pub fn openPath(path: []const u8) Error!Reader {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch return error.OpenFailed;
        return .{
            .kind = .file,
            .file = file,
            .io = io,
            .size_hint = std.Io.File.length(file, io) catch 0,
        };
    }

    /// 以内存切片构造（零拷贝、零分配）
    pub fn openMem(data: []const u8) Reader {
        return .{ .kind = .memory, .data = data, .size_hint = data.len };
    }

    /// 读取（消耗位置）。返回实际读入字节数；0 = EOF。
    pub fn read(self: *Reader, buf: []u8) Error!usize {
        if (self.aborted.load(.acquire)) return error.Aborted;
        return switch (self.kind) {
            .memory => self.readMem(buf),
            .file => self.readFile(buf),
            .callback => self.readBuffered(buf),
        };
    }

    /// 查看（不消耗位置）。返回实际可读字节数（<= buf.len）。
    pub fn peek(self: *Reader, buf: []u8) Error!usize {
        if (self.aborted.load(.acquire)) return error.Aborted;
        return switch (self.kind) {
            .memory => self.peekMem(buf),
            .file => self.peekFile(buf),
            .callback => self.peekBuffered(buf),
        };
    }

    /// 定位。file/memory 形态纯偏移运算；callback 形态委托回调。
    pub fn seek(self: *Reader, off: i64, whence: SeekOrigin) Error!void {
        if (self.aborted.load(.acquire)) return error.Aborted;
        switch (self.kind) {
            .memory, .file => {
                const end_size = if (self.kind == .file) (try self.size()) else self.data.?.len;
                const base: i64 = switch (whence) {
                    .start => 0,
                    .current => @intCast(self.pos),
                    .end => @intCast(end_size),
                };
                const new_pos = base + off;
                if (new_pos < 0) return error.SeekFailed;
                self.pos = @intCast(new_pos);
                if (self.kind == .file) self.invalidateFileCache();
            },
            // 流式形态：允许回调自行定位；成功后无法获知新位置，
            // 调用方随后应通过 read 重新建立 pos（流式输入一般不 seek）。
            .callback => {
                const buffered = self.buf_len - self.buf_pos;
                // seek 目标落在已缓冲但未消费的范围内 → 仅前移缓冲游标，
                // 避免清空缓冲丢失已读数据（如 metadata 小块跳过）。
                if (whence == .current and off >= 0 and @as(u64, @intCast(off)) <= buffered) {
                    self.buf_pos += @intCast(off);
                    self.pos += @intCast(off);
                    return;
                }
                self.buf_pos = 0;
                self.buf_len = 0;
                const w: i32 = switch (whence) {
                    .start => 0,
                    .current => 1,
                    .end => 2,
                };
                if (!self.on_seek.?(self.ctx.?, off, w, buffered)) return error.SeekFailed;
            },
        }
    }

    /// 已知输入总大小（字节）
    pub fn size(self: *Reader) Error!u64 {
        return switch (self.kind) {
            .memory => self.data.?.len,
            .file => std.Io.File.length(self.file.?, self.io.?) catch return error.IoError,
            .callback => if (self.size_hint > 0) self.size_hint else error.IoError,
        };
    }

    /// 中断：置位原子标志，所有 read/peek/seek 立即返回 error.Aborted（§13.1）。
    /// 由引擎 stop / SIGTERM 路径调用，替代 FFmpeg AVIOInterruptCB。
    pub fn abort(self: *Reader) void {
        self.aborted.store(true, .seq_cst);
    }

    /// 关闭底层资源（file 句柄）。memory/callback 形态为空操作。
    pub fn deinit(self: *Reader) void {
        switch (self.kind) {
            .file => std.Io.File.close(self.file.?, self.io.?),
            .memory, .callback => {},
        }
    }

    // ---- memory 形态 ----

    fn readMem(self: *Reader, buf: []u8) usize {
        const n = self.peekMem(buf);
        self.pos += n;
        return n;
    }

    fn peekMem(self: *Reader, buf: []u8) usize {
        const end: usize = @min(self.pos, self.data.?.len);
        const n: usize = @min(buf.len, self.data.?.len - end);
        @memcpy(buf[0..n], self.data.?[end .. end + n]);
        return n;
    }

    // ---- file 形态（位置读 + 前瞻缓存）----

    fn invalidateFileCache(self: *Reader) void {
        self.file_cache_len = 0;
    }

    fn readFile(self: *Reader, buf: []u8) Error!usize {
        const start = self.pos;
        var written: usize = 0;
        while (written < buf.len) {
            const abs = start + written;
            if (abs >= self.file_cache_start and abs < self.file_cache_start + self.file_cache_len) {
                buf[written] = self.file_cache[abs - self.file_cache_start];
                written += 1;
            } else {
                const remain = buf.len - written;
                if (remain >= self.file_cache.len) {
                    // 大请求直接穿透底层（一次系统调用，不进缓存）
                    const n = try self.readFileAt(buf[written..], abs);
                    self.file_cache_start = abs;
                    self.file_cache_len = 0;
                    if (n == 0) break;
                    written += n;
                } else {
                    // 缓存空且请求小 → 预读一满块，随后逐字节从缓存服务
                    const n = try self.readFileAt(self.file_cache[0..], abs);
                    self.file_cache_start = abs;
                    self.file_cache_len = n;
                    if (n == 0) break;
                }
            }
        }
        self.pos = start + written;
        return written;
    }

    fn peekFile(self: *Reader, buf: []u8) Error!usize {
        const start = self.pos;
        var written: usize = 0;
        while (written < buf.len) {
            const abs = start + written;
            if (abs >= self.file_cache_start and abs < self.file_cache_start + self.file_cache_len) {
                buf[written] = self.file_cache[abs - self.file_cache_start];
                written += 1;
            } else {
                // 缓存未覆盖部分直接位置读（不消耗、不改缓存）
                const n = try self.readFileAt(buf[written..], abs);
                written += n;
                break;
            }
        }
        return written;
    }

    fn readFileAt(self: *Reader, buf: []u8, offset: u64) Error!usize {
        return std.Io.File.readPositionalAll(self.file.?, self.io.?, buf, offset) catch return error.IoError;
    }

    // ---- callback 形态（带缓冲，peek 需要）----

    fn readBuffered(self: *Reader, buf: []u8) Error!usize {
        // 大请求直接穿透底层，避免拷贝
        if (buf.len >= peek_buffer_size) {
            self.buf_pos = 0;
            self.buf_len = 0;
            const n = self.on_read.?(self.ctx.?, buf);
            self.pos += n;
            return n;
        }
        var written: usize = 0;
        while (written < buf.len) {
            if (self.buf_pos >= self.buf_len) {
                const n = self.on_read.?(self.ctx.?, self.buffer);
                self.buf_pos = 0;
                self.buf_len = n;
                if (n == 0) break; // EOF
            }
            const avail = self.buf_len - self.buf_pos;
            const take = @min(avail, buf.len - written);
            @memcpy(buf[written .. written + take], self.buffer[self.buf_pos .. self.buf_pos + take]);
            self.buf_pos += take;
            self.pos += take;
            written += take;
        }
        return written;
    }

    fn peekBuffered(self: *Reader, buf: []u8) Error!usize {
        // 确保缓冲至少覆盖 buf.len（尽力：缓冲满或 EOF 即止）
        while (self.buf_len - self.buf_pos < buf.len) {
            if (self.buf_pos == 0 and self.buf_len == self.buffer.len) break; // 缓冲已满
            if (self.buf_pos > 0) {
                // 压实剩余数据到缓冲头
                const remaining = self.buf_len - self.buf_pos;
                std.mem.copyForwards(u8, self.buffer[0..remaining], self.buffer[self.buf_pos..self.buf_len]);
                self.buf_pos = 0;
                self.buf_len = remaining;
            }
            const n = self.on_read.?(self.ctx.?, self.buffer[self.buf_len..]);
            if (n == 0) break; // EOF
            self.buf_len += n;
        }
        const avail = @min(self.buf_len - self.buf_pos, buf.len);
        @memcpy(buf[0..avail], self.buffer[self.buf_pos .. self.buf_pos + avail]);
        return avail;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "openMem: read 前进 / peek 不消耗" {
    var r = Reader.openMem("ABCDEFGH");
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try r.read(&buf));
    try testing.expectEqualStrings("ABCD", &buf);
    // peek 不消耗位置
    try testing.expectEqual(@as(usize, 2), try r.peek(buf[0..2]));
    try testing.expectEqualStrings("EF", buf[0..2]);
    try testing.expectEqual(@as(usize, 4), try r.read(&buf));
    try testing.expectEqualStrings("EFGH", &buf);
    // EOF
    try testing.expectEqual(@as(usize, 0), try r.read(&buf));
}

test "openMem: seek 三种 origin" {
    var r = Reader.openMem("0123456789");
    var buf: [2]u8 = undefined;
    try r.seek(5, .start);
    try testing.expectEqual(@as(usize, 2), try r.read(&buf));
    try testing.expectEqualStrings("56", &buf);
    // 相对 current 回退
    try r.seek(-2, .current);
    try testing.expectEqual(@as(usize, 2), try r.read(&buf));
    try testing.expectEqualStrings("56", &buf);
    // end
    try r.seek(-4, .end);
    try testing.expectEqual(@as(usize, 2), try r.read(&buf));
    try testing.expectEqualStrings("67", &buf);
    // 越界前 seek 失败
    try testing.expectError(error.SeekFailed, r.seek(-1, .start));
}

test "openMem: abort 后 read/peek/seek 返回 Aborted" {
    var r = Reader.openMem("hello");
    r.abort();
    var buf: [4]u8 = undefined;
    try testing.expectError(error.Aborted, r.read(&buf));
    try testing.expectError(error.Aborted, r.peek(&buf));
    try testing.expectError(error.Aborted, r.seek(0, .start));
}

test "openPath: 文件 read/peek/seek/size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = "file-content-1234567890";
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try tmp.dir.createFile(io, "t.bin", .{});
    try std.Io.File.writeStreamingAll(f, io, data);
    std.Io.File.close(f, io);

    const full = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "t.bin" });
    defer testing.allocator.free(full);

    var r = try Reader.openPath(full);
    defer r.deinit();

    try testing.expectEqual(@as(u64, data.len), try r.size());

    // peek 前 4 字节（不消耗）
    var head: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try r.peek(&head));
    try testing.expectEqualStrings("file", &head);
    // peek 后位置未动
    try testing.expectEqual(@as(u64, 0), r.pos);

    // seek 后 read
    try r.seek(5, .start);
    var chunk: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try r.read(&chunk));
    try testing.expectEqualStrings("conte", &chunk);

    // seek(0) 后完整读
    try r.seek(0, .start);
    var all: [data.len]u8 = undefined;
    try testing.expectEqual(@as(usize, data.len), try r.read(&all));
    try testing.expectEqualStrings(data, &all);

    // EOF
    try testing.expectEqual(@as(usize, 0), try r.read(&all));

    // end 定位
    try r.seek(-4, .end);
    try testing.expectEqual(@as(usize, 4), try r.read(chunk[0..4]));
    try testing.expectEqualStrings("7890", chunk[0..4]);

    // 越界前 seek 失败
    try testing.expectError(error.SeekFailed, r.seek(-1, .start));
}

test "openPath: 不存在的文件返回 OpenFailed" {
    try testing.expectError(error.OpenFailed, Reader.openPath("/nonexistent/definitely-missing.bin"));
}

test "callback 形态: 基本读取" {
    const Ctx = struct {
        data: []const u8,
        pos: usize = 0,

        fn readFn(ctx: *anyopaque, buf: []u8) usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.pos >= self.data.len) return 0; // EOF
            const n = @min(buf.len, self.data.len - self.pos);
            @memcpy(buf[0..n], self.data[self.pos .. self.pos + n]);
            self.pos += n;
            return n;
        }
    };
    var ctx = Ctx{ .data = "stream-data" };
    var r = Reader{
        .kind = .callback,
        .on_read = Ctx.readFn,
        .ctx = @ptrCast(&ctx),
        .size_hint = ctx.data.len,
        .buffer = testing.allocator.alloc(u8, peek_buffer_size) catch unreachable,
    };
    defer testing.allocator.free(r.buffer);

    var buf: [64]u8 = undefined;
    // peek 不消耗
    try testing.expectEqual(@as(usize, 6), try r.peek(buf[0..6]));
    try testing.expectEqualStrings("stream", buf[0..6]);
    // read 消耗
    try testing.expectEqual(@as(usize, ctx.data.len), try r.read(&buf));
    try testing.expectEqualStrings(ctx.data, buf[0..ctx.data.len]);
}
