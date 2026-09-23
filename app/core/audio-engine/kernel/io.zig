// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

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
pub const peek_buffer_size = 16 * 1024;

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

    /// 宿主是否支持**任意重定位**（绝对 start / 向后 / end）。file 与 memory 恒为
    /// true；callback 默认 true（宿主注入的传输如 HTTP AVIO 支持 Range 重定位）。
    /// **前向-only 合成流**（如 mka 逐块喂内层解码器的 feed）须显式置 false：
    /// 依赖随机访问的优化（Ogg 尾页时长扫描等）会据此跳过，避免在不可重定位的
    /// 宿主上做「跳过去再跳回来」而错位/丢失流。
    random_access: bool = true,

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

    /// 打开本地文件（file 形态；用调用方传入的 Io——sync 直通/测试给全局实例，
    /// task 接线时 Pool worker 可传自己的每线程 Io）
    pub fn openPathWith(io: std.Io, path: []const u8) Error!Reader {
        const file = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch return error.OpenFailed;
        return .{
            .kind = .file,
            .file = file,
            .io = io,
            .size_hint = std.Io.File.length(file, io) catch 0,
        };
    }

    /// 打开本地文件（file 形态；便捷入口，使用进程全局单线程 Io 实例）
    pub fn openPath(path: []const u8) Error!Reader {
        return openPathWith(std.Io.Threaded.global_single_threaded.io(), path);
    }

    /// 以内存切片构造（零拷贝、零分配）
    pub fn openMem(data: []const u8) Reader {
        return .{ .kind = .memory, .data = data, .size_hint = data.len };
    }

    /// 以**回调流**构造（流式输入：网络 URL / 管道 / 宿主注入传输）。
    ///
    /// 内核保持零网络栈——传输由宿主（C 壳）注入，本层只消费字节流。
    /// `ctx` 与 `peek_buffer` 的所有权归调用方：Reader 不释放 ctx，`deinit`
    /// 对 callback 形态为空操作；`peek_buffer` 须存活到解码会话结束（peek
    /// 依赖它做前瞻）。`size_hint` = 已知总字节数（0 = 未知，seek end 不可用）。
    ///
    /// `on_read(ctx, buf)`：填充 buf，返回实际字节数（0 = EOF）。
    /// `on_seek(ctx, off, whence, buffered)`：whence 0=start / 1=current / 2=end；
    /// 语义见字段注释（current 须按 `off - buffered` 前移底层流）。
    pub const Callback = struct {
        ctx: *anyopaque,
        on_read: *const fn (ctx: *anyopaque, buf: []u8) usize,
        on_seek: *const fn (ctx: *anyopaque, off: i64, whence: i32, buffered: usize) bool,
        size_hint: u64 = 0,
        /// 宿主是否支持任意重定位；默认 true，前向-only 合成 feed 传 false。
        random_access: bool = true,
    };

    pub fn openCallback(cb: Callback, peek_buffer: []u8) Reader {
        return .{
            .kind = .callback,
            .on_read = cb.on_read,
            .on_seek = cb.on_seek,
            .ctx = cb.ctx,
            .size_hint = cb.size_hint,
            .random_access = cb.random_access,
            .buffer = peek_buffer,
        };
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

    /// 从**绝对偏移**读取，不消耗 `pos`、不使用/不改动 file 前瞻缓存。
    ///   - file：一次 `readPositionalAll` 直达（无 16KB 预读、无缓存二次拷贝）；
    ///   - memory：目标切片直接 `memcpy`；
    ///   - callback：无绝对偏移原语，退化为 `seek(offset,.start)` + 普通 `read`
    ///     （pos 与底层流同步，语义与既有逐段 seek+read 一致）。
    /// 供**按段/按绝对偏移定位的批量 PCM 读取**（如 wav `readData`）：这类读取每次
    /// 都显式定位，file 前瞻缓存在每次定位时已被 invalidate、永不会命中，走缓存只会
    /// 多付一次满块预读 + 一整块二次拷贝。调用方须自行按逻辑游标记账。
    /// 返回实际读入字节数（0 = EOF）。
    pub fn readAt(self: *Reader, buf: []u8, offset: u64) Error!usize {
        if (self.aborted.load(.acquire)) return error.Aborted;
        return switch (self.kind) {
            .file => self.readFileAt(buf, offset),
            .memory => blk: {
                const data = self.data.?;
                const p = @min(offset, data.len);
                const n = @min(buf.len, data.len - p);
                @memcpy(buf[0..n], data[p .. p + n]);
                break :blk n;
            },
            .callback => blk: {
                try self.seek(@intCast(offset), .start);
                break :blk try self.read(buf);
            },
        };
    }

    /// 单字节读取快路径（位级解码器逐字节取数专用；无新增缓冲）。
    /// 语义与 `read(&one)` 完全一致（含 abort/EOF），但省去通用 read 的切片/循环开销：
    ///   - memory：直接索引，零调用；
    ///   - file：命中前瞻缓存直接取，未命中走既有 readFile（其内部预读块，非新增缓冲）；
    ///   - callback：命中既有 peek 缓冲直接取，未命中走既有 readBuffered。
    /// 返回 null = EOF（与 read 返回 0 等价）。
    pub fn readByte(self: *Reader) Error!?u8 {
        if (self.aborted.load(.acquire)) return error.Aborted;
        switch (self.kind) {
            .memory => {
                const data = self.data.?;
                const p = self.pos;
                if (p >= data.len) return null;
                self.pos = p + 1;
                return data[p];
            },
            .file => {
                const p = self.pos;
                if (p >= self.file_cache_start and p < self.file_cache_start + self.file_cache_len) {
                    self.pos = p + 1;
                    return self.file_cache[p - self.file_cache_start];
                }
                var one: [1]u8 = undefined;
                const n = try self.readFile(&one);
                return if (n == 0) null else one[0];
            },
            .callback => {
                if (self.buf_pos >= self.buf_len) {
                    const n = self.on_read.?(self.ctx.?, self.buffer);
                    self.buf_pos = 0;
                    self.buf_len = n;
                    if (n == 0) return null;
                }
                const b = self.buffer[self.buf_pos];
                self.buf_pos += 1;
                self.pos += 1;
                return b;
            },
        }
    }

    /// 定位。file/memory 形态纯偏移运算；callback 形态委托回调。
    pub fn seek(self: *Reader, off: i64, whence: SeekOrigin) Error!void {
        if (self.aborted.load(.acquire)) return error.Aborted;
        switch (self.kind) {
            .memory, .file => {
                // size() 仅 end 定位需要；file 形态 size() 是一次 fstat 系统调用，
                // start/current（位置读常态）不得为它付费（wav/PCM 每次 readData 都
                // 先 seek(start)，此前每个 chunk 白付一次 fstat）。语义不变。
                const base: i64 = switch (whence) {
                    .start => 0,
                    .current => @intCast(self.pos),
                    .end => if (self.kind == .file)
                        @intCast(try self.size())
                    else
                        @intCast(self.data.?.len),
                };
                const new_pos = base + off;
                if (new_pos < 0) return error.SeekFailed;
                self.pos = @intCast(new_pos);
                if (self.kind == .file) self.invalidateFileCache();
            },
            // 流式形态：委托回调定位。逻辑目标位置在触碰宿主/缓冲**之前**算好，
            // 任一失败路径都不留「宿主已动、内核游标未同步」或「缓冲已丢」的中间态
            // （此前先清缓冲再委托宿主，宿主 seek 失败/end 大小未知时游标会与底层
            //  流错位，后续读取跳字节）。
            .callback => {
                const buffered = self.buf_len - self.buf_pos;
                const base: i64 = switch (whence) {
                    .start => 0,
                    .current => @intCast(self.pos),
                    .end => @intCast(self.size() catch return error.SeekFailed),
                };
                const np = base + off;
                if (np < 0) return error.SeekFailed;

                // 目标落在**当前缓冲窗口** [base, base+buf_len]（base = pos − buf_pos，
                // 含已消费但仍在缓冲内的字节）→ 仅移动缓冲游标（start/current/end
                // 均可；宿主不动，免一次网络 Range 往返）。不少解码器每帧做
                // 小幅负向 current 定位（AC3/MP3 回退数个字节以重同步），窗口内
                // 本地命中可避免这种高频宿主重定位。
                // 不变量：底层流位置恒 = pos + buffered，故跨缓冲的相对定位
                // （whence=current, off−buffered）在窗口外仍正确。
                const base_abs: i64 = @as(i64, @intCast(self.pos)) - @as(i64, @intCast(self.buf_pos));
                if (np >= base_abs and np <= base_abs + @as(i64, @intCast(self.buf_len))) {
                    self.buf_pos = @intCast(np - base_abs);
                    self.pos = @intCast(np);
                    return;
                }

                // 窗口外：委托宿主重定位。**成功后才**丢弃预读缓冲并同步游标；
                // 失败原样保留（宿主与内核游标一致，读到的仍是正确字节）。
                const on_seek = self.on_seek orelse return error.SeekFailed;
                const w: i32 = switch (whence) {
                    .start => 0,
                    .current => 1,
                    .end => 2,
                };
                if (!on_seek(self.ctx.?, off, w, buffered)) return error.SeekFailed;
                self.buf_pos = 0;
                self.buf_len = 0;
                self.pos = @intCast(np);
            },
        }
    }

    /// AS4：把 Reader 复位到源起点（hinted open 失败后回退 probe 前用）。
    ///   - memory/file：游标清零、file 前瞻缓存失效；
    ///   - callback：先委托宿主 seek 到绝对 0（须支持重定位），成功后再清本地
    ///     peek 缓冲并同步游标；宿主拒绝 → error.SeekFailed（调用方放弃回退）。
    pub fn rewind(self: *Reader) Error!void {
        if (self.aborted.load(.acquire)) return error.Aborted;
        switch (self.kind) {
            .memory => self.pos = 0,
            .file => {
                self.pos = 0;
                self.invalidateFileCache();
            },
            .callback => {
                const buffered = self.buf_len - self.buf_pos;
                const on_seek = self.on_seek orelse return error.SeekFailed;
                if (!on_seek(self.ctx.?, 0, 0, buffered)) return error.SeekFailed;
                self.buf_pos = 0;
                self.buf_len = 0;
                self.pos = 0;
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
            // 缓存覆盖部分**整段 memcpy**（此前逐字节循环：小请求预读一满块后要
            // 走 buf.len 次单字节拷贝，PCM 每 chunk 8KB → 8K 次迭代，是公共
            // PCM 地板的指令大头）。缓存内容/系统调用次数/pos 语义均不变。
            if (abs >= self.file_cache_start and abs < self.file_cache_start + self.file_cache_len) {
                const rel = abs - self.file_cache_start;
                const take = @min(self.file_cache_len - rel, buf.len - written);
                @memcpy(buf[written .. written + take], self.file_cache[rel .. rel + take]);
                written += take;
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
                    // 缓存空且请求小 → 预读一满块，随后从缓存服务（下一轮整段拷贝）
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
        // 大请求：先把 peek 缓冲中**未消费**的字节交还本次读取（否则直接穿透
        // 底层会丢弃已预读数据 → 数据缺失/损坏），余量再直接穿透底层避免二次拷贝。
        // 仅当「未消费缓冲可被本次请求全部取走」时才直接穿透——否则余量会被跳过
        // （丢字节）；此时退回下方通用小请求循环（逐块消费缓冲后按需续读底层）。
        // N4：以本 Reader 实际缓冲长度判断（支持变长缓冲；默认 = peek_buffer_size）。
        if (buf.len >= self.buffer.len and (self.buf_len - self.buf_pos) <= buf.len) {
            var written: usize = 0;
            const avail = self.buf_len - self.buf_pos;
            if (avail > 0) {
                const take = @min(avail, buf.len);
                @memcpy(buf[0..take], self.buffer[self.buf_pos .. self.buf_pos + take]);
                self.buf_pos += take;
                self.pos += take;
                written = take;
                if (self.buf_pos >= self.buf_len) {
                    self.buf_pos = 0;
                    self.buf_len = 0;
                }
            }
            if (written == buf.len) return written;
            const n = self.on_read.?(self.ctx.?, buf[written..]);
            self.pos += n;
            return written + n;
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

test "readAt: memory 绝对偏移读取，不改 pos" {
    var r = Reader.openMem("0123456789");
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try r.readAt(&buf, 3));
    try testing.expectEqualStrings("3456", &buf);
    try testing.expectEqual(@as(u64, 0), r.pos); // 不消耗位置
    // 越界偏移 clamp 到 EOF（返回 0），不越界
    try testing.expectEqual(@as(usize, 0), try r.readAt(&buf, 999));
}

test "readAt: file 绝对偏移读取，不改 pos；与 read 交错一致" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const data = "abcdefghijklmnop";
    const f = try tmp.dir.createFile(io, "ra.bin", .{});
    try std.Io.File.writeStreamingAll(f, io, data);
    std.Io.File.close(f, io);
    const full = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "ra.bin" });
    defer testing.allocator.free(full);

    var r = try Reader.openPath(full);
    defer r.deinit();
    var buf: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try r.readAt(&buf, 4));
    try testing.expectEqualStrings("efghi", &buf);
    try testing.expectEqual(@as(u64, 0), r.pos);
    // 随后普通 read 仍从 pos=0 起（readAt 不触碰游标/缓存）
    try testing.expectEqual(@as(usize, 3), try r.read(buf[0..3]));
    try testing.expectEqualStrings("abc", buf[0..3]);
    // 大偏移直达（不经前瞻缓存，一次位置读）
    var big: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), try r.readAt(&big, 8));
    try testing.expectEqualStrings("ijklmnop", &big);
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

test "openCallback: read/peek/seek 与底层流位置一致" {
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

        /// whence 0/1/2；current 按 `off - buffered` 前移底层流（io.zig 契约）。
        fn seekFn(ctx: *anyopaque, off: i64, whence: i32, buffered: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const base: i64 = switch (whence) {
                0 => 0,
                1 => @as(i64, @intCast(self.pos)) - @as(i64, @intCast(buffered)),
                2 => @intCast(self.data.len),
                else => return false,
            };
            const np = base + off;
            if (np < 0 or np > @as(i64, @intCast(self.data.len))) return false;
            self.pos = @intCast(np);
            return true;
        }
    };
    const payload = "0123456789abcdefghij"; // 20 字节
    var ctx = Ctx{ .data = payload };
    const peek_buf = try testing.allocator.alloc(u8, peek_buffer_size);
    defer testing.allocator.free(peek_buf);
    var r = Reader.openCallback(.{
        .ctx = @ptrCast(&ctx),
        .on_read = Ctx.readFn,
        .on_seek = Ctx.seekFn,
        .size_hint = payload.len,
    }, peek_buf);

    try testing.expectEqual(@as(u64, payload.len), try r.size());

    // peek 触发前瞻缓冲（ctx.pos 领先 reader.pos），但不消耗
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try r.peek(&buf));
    try testing.expectEqualStrings("0123", &buf);
    try testing.expectEqual(@as(u64, 0), r.pos);

    // read 从缓冲消费
    try testing.expectEqual(@as(usize, 2), try r.read(buf[0..2]));
    try testing.expectEqualStrings("01", buf[0..2]);

    // current 回退：跨过缓冲区，验证 off-buffered 语义
    try r.seek(10, .start);
    try testing.expectEqual(@as(usize, 4), try r.read(&buf));
    try testing.expectEqualStrings("abcd", &buf);

    // current 相对回退（pos 14 → 12）
    try r.seek(-2, .current);
    try testing.expectEqual(@as(usize, 2), try r.read(buf[0..2]));
    try testing.expectEqualStrings("cd", buf[0..2]);

    // end / start
    try r.seek(-2, .end);
    try testing.expectEqual(@as(usize, 2), try r.read(buf[0..2]));
    try testing.expectEqualStrings("ij", buf[0..2]);
    try r.seek(0, .start);
    try testing.expectEqual(@as(usize, 4), try r.read(&buf));
    try testing.expectEqualStrings("0123", &buf);

    // 越界 seek 失败
    try testing.expectError(error.SeekFailed, r.seek(-1, .start));
}

test "openCallback: 大请求先交还已预读字节（不丢数据）" {
    const Ctx = struct {
        data: []const u8,
        pos: usize = 0,
        fn readFn(ctx: *anyopaque, buf: []u8) usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.pos >= self.data.len) return 0;
            const n = @min(buf.len, self.data.len - self.pos);
            @memcpy(buf[0..n], self.data[self.pos .. self.pos + n]);
            self.pos += n;
            return n;
        }
        fn seekFn(ctx: *anyopaque, off: i64, whence: i32, buffered: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const base: i64 = switch (whence) {
                0 => 0,
                1 => @as(i64, @intCast(self.pos)) - @as(i64, @intCast(buffered)),
                2 => @intCast(self.data.len),
                else => return false,
            };
            const np = base + off;
            if (np < 0 or np > @as(i64, @intCast(self.data.len))) return false;
            self.pos = @intCast(np);
            return true;
        }
    };
    const payload = "0123456789abcdefghij"; // 20 字节
    var ctx = Ctx{ .data = payload };
    const peek_buf = try testing.allocator.alloc(u8, peek_buffer_size);
    defer testing.allocator.free(peek_buf);
    var r = Reader.openCallback(.{
        .ctx = @ptrCast(&ctx),
        .on_read = Ctx.readFn,
        .on_seek = Ctx.seekFn,
        .size_hint = payload.len,
    }, peek_buf);

    // peek 把整段读进 peek 缓冲（未消费），随后大请求必须先把缓冲交还，不能丢
    var small: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try r.peek(&small));
    const big = try testing.allocator.alloc(u8, peek_buffer_size);
    defer testing.allocator.free(big);
    const n = try r.read(big);
    try testing.expectEqual(@as(usize, payload.len), n);
    try testing.expectEqualStrings(payload, big[0..payload.len]);
    // 之后到 EOF
    try testing.expectEqual(@as(usize, 0), try r.read(big));
}

/// 回调流测试夹具：内存字节 + 精确 seek；记录宿主 seek 次数与可选「注入失败点」。
/// 语义与 zk_read_cb / zk_seek_cb 契约一致（current 按 off - buffered 前移底层流）。
const CbHarness = struct {
    data: []const u8,
    pos: usize = 0,
    /// 宿主被调用 on_seek 的次数（证明窗口内定位未触碰宿主）。
    seeks: usize = 0,
    /// 非 0：宿主 seek 到此绝对位置时返回失败（模拟不可重定位/断流）。
    fail_at: i64 = -1,
    /// 单次 on_read 返回上限（模拟网络分块；0 = 不限）。
    max_read: usize = 0,

    fn readFn(ctx: *anyopaque, buf: []u8) usize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.pos >= self.data.len) return 0; // EOF
        var n = @min(buf.len, self.data.len - self.pos);
        if (self.max_read != 0 and n > self.max_read) n = self.max_read;
        @memcpy(buf[0..n], self.data[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }

    fn seekFn(ctx: *anyopaque, off: i64, whence: i32, buffered: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.seeks += 1;
        const base: i64 = switch (whence) {
            0 => 0,
            1 => @as(i64, @intCast(self.pos)) - @as(i64, @intCast(buffered)),
            2 => @intCast(self.data.len),
            else => return false,
        };
        const np = base + off;
        if (np < 0 or np > @as(i64, @intCast(self.data.len))) return false;
        if (self.fail_at >= 0 and np == self.fail_at) return false; // 注入失败
        self.pos = @intCast(np);
        return true;
    }
};

fn cbReader(h: *CbHarness, peek_buf: []u8) Reader {
    return Reader.openCallback(.{
        .ctx = @ptrCast(h),
        .on_read = CbHarness.readFn,
        .on_seek = CbHarness.seekFn,
        .size_hint = h.data.len,
    }, peek_buf);
}

test "openCallback: EOF 后 seek 回起点逐字节一致" {
    const payload = "0123456789abcdefghij"; // 20 字节
    var h = CbHarness{ .data = payload };
    const peek_buf = try testing.allocator.alloc(u8, peek_buffer_size);
    defer testing.allocator.free(peek_buf);
    var r = cbReader(&h, peek_buf);

    var buf: [64]u8 = undefined;
    // 先读满整段，再读到 EOF（EOF 后底层流位于末尾、内核缓冲为空）
    try testing.expectEqual(@as(usize, payload.len), try r.read(&buf));
    try testing.expectEqualStrings(payload, buf[0..payload.len]);
    try testing.expectEqual(@as(usize, 0), try r.read(&buf));
    try testing.expectEqual(@as(usize, 0), try r.read(&buf)); // EOF 可重复

    // EOF 后 seek 回起点：缓冲为空 → 必走宿主重定位
    try r.seek(0, .start);
    try testing.expectEqual(@as(u64, 0), r.pos);
    try testing.expectEqual(@as(usize, payload.len), try r.read(&buf));
    try testing.expectEqualStrings(payload, buf[0..payload.len]);

    // 再 EOF、再 seek 到中间（覆盖「EOF 后任意重定位」）
    try testing.expectEqual(@as(usize, 0), try r.read(&buf));
    try r.seek(7, .start);
    var one: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try r.read(&one));
    try testing.expectEqualStrings("789a", &one);
}

test "openCallback: 缓冲窗口内 start/end/current 定位不触碰宿主" {
    const payload = "0123456789abcdefghij"; // 20 字节
    // 分块 5：peek 10 只把 [0,10) 读进缓冲（宿主 pos=10），窗口之外才会碰宿主。
    var h = CbHarness{ .data = payload, .max_read = 5 };
    const peek_buf = try testing.allocator.alloc(u8, peek_buffer_size);
    defer testing.allocator.free(peek_buf);
    var r = cbReader(&h, peek_buf);

    // peek 10 → 宿主 pos 领先 10（缓冲 [0,10)），内核 pos=0；peek 不调用 on_seek。
    var pre: [10]u8 = undefined;
    try testing.expectEqual(@as(usize, 10), try r.peek(&pre));
    try testing.expectEqualStrings("0123456789", &pre);
    try testing.expectEqual(@as(usize, 0), h.seeks);
    try testing.expectEqual(@as(u64, 0), r.pos);

    // start 窗口内前进 / 回退均纯内存定位
    try r.seek(4, .start);
    try testing.expectEqual(@as(usize, 0), h.seeks);
    try testing.expectEqual(@as(u8, '4'), (try r.readByte()).?);
    try testing.expectEqual(@as(u64, 5), r.pos);
    try r.seek(1, .start); // 回退
    try testing.expectEqual(@as(usize, 0), h.seeks);
    try testing.expectEqual(@as(u8, '1'), (try r.readByte()).?);

    // current 窗口内前进
    try r.seek(3, .current);
    try testing.expectEqual(@as(usize, 0), h.seeks);
    try testing.expectEqual(@as(u8, '5'), (try r.readByte()).?); // pos 2 → +3 → 5

    // end 定位落在窗口内（size=20，off=-16 → 4）
    try r.seek(-16, .end);
    try testing.expectEqual(@as(usize, 0), h.seeks);
    try testing.expectEqual(@as(u8, '4'), (try r.readByte()).?);

    // 窗口外 → 才委托宿主
    try r.seek(15, .start);
    try testing.expectEqual(@as(usize, 1), h.seeks);
    try testing.expectEqual(@as(u8, 'f'), (try r.readByte()).?);
}

test "openCallback: 宿主 seek 失败时保留预读与游标（不跳字节）" {
    const payload = "0123456789"; // 10 字节
    // 分块 5：peek 5 只驻留 [0,5)，窗口外的目标（7）必然委托宿主。
    var h = CbHarness{ .data = payload, .max_read = 5 };
    const peek_buf = try testing.allocator.alloc(u8, peek_buffer_size);
    defer testing.allocator.free(peek_buf);
    var r = cbReader(&h, peek_buf);

    // peek 5 → 缓冲 [0,5) 已读入宿主，内核 pos=0
    var pre: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try r.peek(&pre));
    // 消费 2 → 内核 pos=2，未消费缓冲 [2,5)
    var two: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try r.read(&two));
    try testing.expectEqualStrings("01", &two);

    // 注入：宿主 seek 到 7 失败（窗口外 → 走宿主）
    h.fail_at = 7;
    try testing.expectError(error.SeekFailed, r.seek(7, .start));
    // 失败后游标与预读必须原样保留：继续读仍是正确字节（此前会丢掉缓冲并从
    // 宿主当前位置读 → 跳字节，读到 "567" 而非 "234"）。
    try testing.expectEqual(@as(u64, 2), r.pos);
    var three: [3]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try r.read(&three));
    try testing.expectEqualStrings("234", &three);

    // 宿主恢复正常后可再次定位
    h.fail_at = -1;
    try r.seek(7, .start);
    try testing.expectEqual(@as(u8, '7'), (try r.readByte()).?);
}

test "openCallback: current 负向 seek 跨缓冲由宿主回退且位置正确" {
    const payload = "0123456789abcdefghijklmnopqrstuvwxyzABCD"; // 40 字节
    // 分块 8：读 20 字节后缓冲窗口 base=16（[16,24)），回退到 12 必须委托宿主。
    var h = CbHarness{ .data = payload, .max_read = 8 };
    const peek_buf = try testing.allocator.alloc(u8, peek_buffer_size);
    defer testing.allocator.free(peek_buf);
    var r = cbReader(&h, peek_buf);

    var twenty: [20]u8 = undefined;
    try testing.expectEqual(@as(usize, 20), try r.read(&twenty));
    try testing.expectEqualStrings(payload[0..20], &twenty);
    try testing.expectEqual(@as(u64, 20), r.pos);
    try testing.expectEqual(@as(usize, 0), h.seeks); // 顺序读未触发宿主定位

    // current 回退 -8 → 12：目标在当前缓冲窗口 [16,24) 之前 → 宿主回退
    try r.seek(-8, .current);
    try testing.expectEqual(@as(u64, 12), r.pos);
    try testing.expectEqual(@as(usize, 1), h.seeks);
    var four: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try r.read(&four));
    try testing.expectEqualStrings("cdef", &four);
}
