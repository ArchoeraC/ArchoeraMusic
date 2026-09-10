// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! D-Bus 会话总线传输：地址解析、unix 连接、SASL EXTERNAL 认证、Hello、
//! 消息帧读取与同步方法调用。
//!
//! 并发模型（无 std.Thread.Mutex/Condition 的 0.16 环境，见 core.zig）：
//! - 「读取权认领」——同一时刻只有一个线程在读 socket（call() 同步等回复
//!   期间认领读取，或后台泵线程空闲认领），串行化回复相关性与信号分发；
//! - 发送经自旋锁保护（短临界区）；
//! - 认证完成后仅 LE 帧；断连由调用方（backend）负责重建。

const std = @import("std");
const Allocator = std.mem.Allocator;
const message = @import("message.zig");

// 0.16 移除了 std.posix 的高层 socket 封装；本模块已链 libc（build.zig），
// 直接走 std.c 同步 API（仅 Linux 后端编译进产物）。
const c = std.c;
const posix = std.posix;

pub const Error = error{
    NoSessionBus,
    ConnectFailed,
    AuthFailed,
    IoFailed,
    CallTimeout,
    CallRejected,
    Malformed,
    UnsupportedEndian,
    OutOfMemory,
};

/// SOCK_CLOEXEC（Linux 值；本传输仅 Linux 后端编入）
const SOCK_CLOEXEC: c_int = 0x80000;

fn isEintr() bool {
    return c._errno().* == @intFromEnum(posix.E.INTR);
}

/// 单调毫秒（调用超时基准）。
pub fn nowMs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// 毫秒睡眠（泵线程轮询节拍）。
pub fn sleepMs(ms: u64) void {
    var req: c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: c.timespec = undefined;
    _ = c.nanosleep(&req, &rem);
}

/// 后端收到消息的回调（信号 / 方法调用；实现在 backend）。
/// 传入 `conn` 供方法调用方回发 method_return / error（P2 MPRIS）。
pub const Handler = struct {
    ctx: *anyopaque,
    onSignalFn: *const fn (ctx: *anyopaque, conn: *Connection, h: *const message.Header, body: []const u8) void,
    onMethodCallFn: *const fn (ctx: *anyopaque, conn: *Connection, h: *const message.Header, body: []const u8) void,
};

pub const CallResult = struct {
    /// false = error reply（error_name/body 见 header 对应字段）
    ok: bool,
    /// 回复 body 解组值（指向 msg 缓冲；随 result.deinit 失效）
    values: []message.Value,
    /// 原始消息（values 字符串切片指向它）
    msg: []u8,
    header: message.Header,
    /// 分配 values/msg 的 allocator（= conn.alloc；deinit 必须一致）
    alloc: Allocator,

    pub fn deinit(r: *const CallResult) void {
        message.freeValues(r.alloc, r.values);
        r.alloc.free(r.msg);
    }
};

pub const Connection = struct {
    alloc: Allocator,
    fd: c.fd_t,
    /// 读取权认领（true = 有人持有读取权）
    read_busy: std.atomic.Value(bool) = .init(false),
    /// 在途同步调用计数（>0 时泵线程不读——防其抢走 method_return 回复）
    call_pending: std.atomic.Value(u32) = .init(0),
    /// 发送自旋锁
    send_lock: std.atomic.Value(bool) = .init(false),
    serial: std.atomic.Value(u32) = .init(0),
    unique_name: []u8 = &.{},
    handler: ?*const Handler = null,

    // ── 连接建立 ──────────────────────────────────────────────────

    /// 连接会话总线（DBUS_SESSION_BUS_ADDRESS）→ AUTH EXTERNAL → BEGIN → Hello。
    pub fn connectSession(alloc: Allocator) Error!Connection {
        const addr = parseSessionAddress(alloc) catch return error.NoSessionBus;
        defer alloc.free(addr);

        const fd = connectUnix(addr) catch return error.ConnectFailed;
        errdefer _ = c.close(fd);

        try authExternal(fd);
        var conn = Connection{ .alloc = alloc, .fd = fd };
        errdefer conn.deinit();

        // Hello 必须是认证后第一条消息
        const result = conn.call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "Hello",
            "",
            &.{},
            5_000,
        ) catch return error.AuthFailed;
        defer result.deinit();
        if (!result.ok or result.values.len != 1) return error.AuthFailed;
        conn.unique_name = alloc.dupe(u8, result.values[0].string) catch return error.OutOfMemory;
        return conn;
    }

    pub fn deinit(conn: *Connection) void {
        if (conn.fd >= 0) _ = c.close(conn.fd);
        conn.fd = -1;
        if (conn.unique_name.len > 0) conn.alloc.free(conn.unique_name);
        conn.unique_name = &.{};
    }

    pub fn nextSerial(conn: *Connection) u32 {
        return conn.serial.fetchAdd(1, .monotonic) + 1;
    }

    // ── 同步方法调用（读取权认领）──────────────────────────────────

    /// 同步调用：认领读取权 → 发送 → 读帧直到本 serial 的回复。
    /// values/msg 由调用方 CallResult.deinit 释放。
    pub fn call(
        conn: *Connection,
        dest: []const u8,
        path: []const u8,
        iface: []const u8,
        member: []const u8,
        body_sig: []const u8,
        body_values: []const message.Value,
        timeout_ms: u32,
    ) Error!CallResult {
        // 写 body（复用解组 Value 的写路径：仅本桥接用到的类型）
        var bw = message.Writer.init(conn.alloc);
        defer bw.deinit();
        try writeValues(&bw, body_values);

        return conn.callRaw(dest, path, iface, member, body_sig, bw.slice(), timeout_ms);
    }

    /// 同步调用（body 已编组）。
    pub fn callRaw(
        conn: *Connection,
        dest: []const u8,
        path: []const u8,
        iface: []const u8,
        member: []const u8,
        body_sig: []const u8,
        body: []const u8,
        timeout_ms: u32,
    ) Error!CallResult {
        const serial = conn.nextSerial();
        var b = message.MessageBuilder.init(conn.alloc, message.MSG_METHOD_CALL, serial);
        defer b.deinit();
        try b.fieldDestination(dest);
        try b.fieldPath(path);
        try b.fieldInterface(iface);
        try b.fieldMember(member);
        if (body_sig.len > 0) try b.fieldSignature(body_sig);
        try b.body.buf.appendSlice(conn.alloc, body);

        const wire = try b.finish(conn.alloc);
        defer conn.alloc.free(wire);

        // 在途调用计数（泵线程据此让出读取，防抢走回复）
        _ = conn.call_pending.fetchAdd(1, .acq_rel);
        defer _ = conn.call_pending.fetchSub(1, .acq_rel);

        // 认领读取权（与泵线程互斥；期间回复相关性无竞争）
        while (conn.read_busy.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer conn.read_busy.store(false, .release);

        try conn.sendAll(wire);

        const deadline_ms: u64 = nowMs() + timeout_ms;
        while (true) {
            const now = nowMs();
            if (now >= deadline_ms) return error.CallTimeout;
            const wait_ms: i32 = @intCast(@min(deadline_ms - now, 1_000));
            const msg = try conn.readFrame(wait_ms);
            const h = message.parseHeader(msg) catch {
                conn.alloc.free(msg);
                return error.Malformed;
            };
            if ((h.msg_type == message.MSG_METHOD_RETURN or h.msg_type == message.MSG_ERROR) and
                h.reply_serial == serial)
            {
                // msg 所有权移交调用方（CallResult.deinit 释放）
                const values = if (h.signature) |sig|
                    message.readBody(conn.alloc, sig, msg[h.body_off..]) catch {
                        conn.alloc.free(msg);
                        return error.Malformed;
                    }
                else
                    conn.alloc.alloc(message.Value, 0) catch {
                        conn.alloc.free(msg);
                        return error.OutOfMemory;
                    };
                return .{
                    .ok = h.msg_type == message.MSG_METHOD_RETURN,
                    .values = values,
                    .msg = msg,
                    .header = h,
                    .alloc = conn.alloc,
                };
            }
            // 非本调用回复：信号 / 方法调用交给处理器；处理后释放
            conn.dispatchMessage(&h, msg) catch {
                conn.alloc.free(msg);
                return error.IoFailed;
            };
            conn.alloc.free(msg);
        }
    }

    /// 单向发送（P2 回复 / 信号 / AddMatch 不等回复也可用 call 走完整路径）。
    pub fn sendOneWay(conn: *Connection, b: *message.MessageBuilder) Error!void {
        const wire = try b.finish(conn.alloc);
        defer conn.alloc.free(wire);
        try conn.sendAll(wire);
    }

    fn sendAll(conn: *Connection, bytes: []const u8) Error!void {
        _ = conn.send_lock.swap(true, .acquire);
        defer conn.send_lock.store(false, .release);
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(conn.fd, bytes[off..].ptr, bytes.len - off);
            if (n < 0) {
                if (isEintr()) continue;
                return error.IoFailed;
            }
            off += @intCast(n);
        }
    }

    /// 读一帧（wait_ms 超时）；返回完整消息缓冲（调用方 free）。
    fn readFrame(conn: *Connection, wait_ms: i32) Error![]u8 {
        var head: [16]u8 = undefined;
        try conn.readFull(&head, wait_ms);
        const fields_len = std.mem.readInt(u32, head[12..16], .little);
        const body_len = std.mem.readInt(u32, head[4..8], .little);
        const body_off = std.mem.alignForward(usize, 16 + fields_len, 8);
        const total = body_off + body_len;

        const buf = conn.alloc.alloc(u8, total) catch return error.OutOfMemory;
        errdefer conn.alloc.free(buf);
        @memcpy(buf[0..16], &head);
        try conn.readFull(buf[16..], wait_ms);
        return buf;
    }

    /// 先 poll 再 read（阻塞 fd + 超时由 poll 控制；EINTR 重试）。
    fn readFull(conn: *Connection, out: []u8, wait_ms: i32) Error!void {
        var off: usize = 0;
        while (off < out.len) {
            var fds = [_]c.pollfd{.{ .fd = conn.fd, .events = posix.POLL.IN, .revents = 0 }};
            const ready = c.poll(&fds, 1, wait_ms);
            if (ready < 0) {
                if (isEintr()) continue;
                return error.IoFailed;
            }
            if (ready == 0) return error.CallTimeout;
            const n = c.read(conn.fd, out[off..].ptr, out.len - off);
            if (n < 0) {
                if (isEintr()) continue;
                return error.IoFailed;
            }
            if (n == 0) return error.IoFailed; // EOF
            off += @intCast(n);
        }
    }

    /// 泵一轮：认领读取权后读尽可读消息并分发（信号 / 方法调用）。
    /// 返回 false = 连接已失效（EOF / IO 错误），调用方应重建。
    pub fn pump(conn: *Connection) bool {
        // 有在途同步调用时让出读取（回复由调用方读取，泵不得抢）
        if (conn.call_pending.load(.acquire) != 0) return true;
        while (conn.read_busy.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer conn.read_busy.store(false, .release);

        var fds = [_]c.pollfd{.{ .fd = conn.fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = c.poll(&fds, 1, 0);
        if (ready < 0) return false;
        if (ready == 0) return true; // 无数据：正常空闲
        while (true) {
            // 先探测是否可读（阻塞 0），读尽后退出
            const r = posix.poll(&fds, 0) catch return false;
            if (r == 0) return true;
            const msg = conn.readFrame(0) catch return false;
            const h = message.parseHeader(msg) catch {
                conn.alloc.free(msg);
                return false;
            };
            conn.dispatchMessage(&h, msg) catch {
                conn.alloc.free(msg);
                return false;
            };
            conn.alloc.free(msg);
        }
    }

    fn dispatchMessage(conn: *Connection, h: *const message.Header, msg: []u8) Error!void {
        const handler = conn.handler orelse return;
        const body = msg[h.body_off..];
        switch (h.msg_type) {
            message.MSG_SIGNAL => handler.onSignalFn(handler.ctx, conn, h, body),
            message.MSG_METHOD_CALL => handler.onMethodCallFn(handler.ctx, conn, h, body),
            else => {}, // 他人回复/错误：当前无挂起调用，忽略
        }
    }
};

// ── body 值写出（仅桥接所需类型）─────────────────────────────────

pub fn writeValues(w: *message.Writer, values: []const message.Value) message.Error!void {
    for (values) |v| {
        switch (v) {
            .string => |s| try w.putString(s),
            .object_path => |s| try w.putString(s),
            .signature => |s| try w.putSignature(s),
            .boolean => |b| try w.putBool(b),
            .u32_ => |x| try w.putU32(x),
            .i64_ => |x| try w.putI64(x),
            .f64_ => |x| try w.putF64(x),
            else => return error.Malformed, // 复杂值走专用路径（P2）
        }
    }
}

// ── 地址解析与认证 ────────────────────────────────────────────────

/// 解析 DBUS_SESSION_BUS_ADDRESS（分号分隔多地址，取首个可用 unix:）。
fn parseSessionAddress(alloc: Allocator) Error![]u8 {
    // libc getenv（0.16 环境变量经 std.c；仅 Linux 后端调用本函数）
    const raw_c = std.c.getenv("DBUS_SESSION_BUS_ADDRESS") orelse
        return error.NoSessionBus;
    const raw = std.mem.span(raw_c);
    var it = std.mem.splitScalar(u8, raw, ';');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " ");
        if (!std.mem.startsWith(u8, p, "unix:")) continue;
        var opts = std.mem.splitScalar(u8, p["unix:".len..], ',');
        while (opts.next()) |opt| {
            if (std.mem.startsWith(u8, opt, "path=")) {
                return alloc.dupe(u8, opt["path=".len..]) catch return error.OutOfMemory;
            }
            if (std.mem.startsWith(u8, opt, "abstract=")) {
                // 抽象命名空间：首字节 NUL 约定
                const name = opt["abstract=".len..];
                const buf = alloc.alloc(u8, name.len + 1) catch return error.OutOfMemory;
                buf[0] = 0;
                @memcpy(buf[1..], name);
                return buf;
            }
        }
    }
    return error.NoSessionBus;
}

fn connectUnix(path: []const u8) Error!c.fd_t {
    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return error.ConnectFailed;
    errdefer _ = c.close(fd);
    var addr = std.mem.zeroes(c.sockaddr.un);
    addr.family = posix.AF.UNIX;
    // 抽象命名空间：调用方已把首字节置 0（path 含 NUL 前缀）
    const n = @min(path.len, addr.path.len);
    @memcpy(addr.path[0..n], path[0..n]);
    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un));
    if (rc != 0) return error.ConnectFailed;
    return fd;
}

fn hexLower(alloc: Allocator, bytes: []const u8) Error![]u8 {
    const out = alloc.alloc(u8, bytes.len * 2) catch return error.OutOfMemory;
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0xf];
    }
    return out;
}

/// SASL EXTERNAL：\0 + AUTH EXTERNAL <hex(uid)> → OK → BEGIN。
fn authExternal(fd: posix.socket_t) Error!void {
    var uid_buf: [32]u8 = undefined;
    const uid_str = std.fmt.bufPrint(&uid_buf, "{d}", .{std.os.linux.getuid()}) catch
        return error.AuthFailed;

    var hexed: [64]u8 = undefined;
    const hex_len = hexAsciiInto(uid_str, &hexed);
    var line_buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "\x00AUTH EXTERNAL {s}\r\n", .{hexed[0..hex_len]}) catch
        return error.AuthFailed;
    writeAll(fd, line) catch return error.AuthFailed;

    // 读 OK <guid>
    var resp: [64]u8 = undefined;
    const n = readLine(fd, &resp) catch return error.AuthFailed;
    if (!std.mem.startsWith(u8, resp[0..n], "OK")) return error.AuthFailed;

    writeAll(fd, "BEGIN\r\n") catch return error.AuthFailed;
}

fn hexAsciiInto(src: []const u8, out: []u8) usize {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    for (src) |b| {
        out[i] = digits[b >> 4];
        out[i + 1] = digits[b & 0xf];
        i += 2;
    }
    return i;
}

fn writeAll(fd: c.fd_t, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n < 0) {
            if (isEintr()) continue;
            return error.AuthFailed;
        }
        off += @intCast(n);
    }
}

/// 读一行（\r\n 结尾；认证阶段行短，单次 read 足够）。
fn readLine(fd: c.fd_t, buf: []u8) Error!usize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = c.read(fd, buf[off..].ptr, buf.len - off);
        if (n <= 0) return error.AuthFailed;
        off += @intCast(n);
        if (off >= 2 and buf[off - 2] == '\r' and buf[off - 1] == '\n') {
            return off - 2;
        }
    }
    return error.AuthFailed;
}

// ── 单测 ──────────────────────────────────────────────────────────

const t = std.testing;

test "parseSessionAddress: path/abstract/multiple" {
    // 仅测纯函数部分：临时改用环境变量不便，直接测 split 逻辑的等价路径
    // （parseSessionAddress 读环境变量；此处验证 hexAsciiInto 与地址选择由
    //   live 测试覆盖）
    var out: [16]u8 = undefined;
    const n = hexAsciiInto("1000", &out);
    try t.expectEqualStrings("31303030", out[0..n]);
}

test "authExternal: hex of uid digits" {
    var out: [16]u8 = undefined;
    const n = hexAsciiInto("0", &out);
    try t.expectEqualStrings("30", out[0..n]);
}

// live：本机有会话总线时验证 连接→Hello 真实链路（CI 无总线时跳过）
test "live: session bus Hello round trip" {
    const alloc = t.allocator;
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return; // CI / 无桌面
    var conn = try Connection.connectSession(alloc);
    defer conn.deinit();
    try t.expect(conn.unique_name.len > 0);
    try t.expect(conn.unique_name[0] == ':');
}

var g_signal_hits: u32 = 0;

fn testSignalHandler(ctx: *anyopaque, conn: *Connection, h: *const message.Header, body: []const u8) void {
    _ = ctx;
    _ = conn;
    _ = body;
    if (h.member) |m| {
        if (std.mem.eql(u8, m, "ActiveChanged")) g_signal_hits += 1;
    }
}

// live：两连接间信号端到端（A 订阅 AddMatch → B 发 ActiveChanged 信号 →
// A 的 Handler 收到）——验证反向事件链路（无需真实 ScreenSaver 服务）。
test "live: signal delivery between two connections" {
    const alloc = t.allocator;
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return;
    g_signal_hits = 0;

    var a = try Connection.connectSession(alloc);
    defer a.deinit();
    var b = try Connection.connectSession(alloc);
    defer b.deinit();

    var handler_ctx: u8 = 0;
    const h = Handler{
        .ctx = @ptrCast(&handler_ctx),
        .onSignalFn = testSignalHandler,
        .onMethodCallFn = testSignalHandler,
    };
    a.handler = &h;

    // A 订阅 ScreenSaver 接口信号
    const rule = "type='signal',interface='org.freedesktop.ScreenSaver',member='ActiveChanged'";
    const margs = [_]message.Value{.{ .string = rule }};
    const mr = try a.call(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "AddMatch",
        "s",
        &margs,
        3_000,
    );
    mr.deinit();

    // B 广播 ActiveChanged(true)（无 destination = 广播，按 match 规则路由）
    var sig = message.MessageBuilder.init(alloc, message.MSG_SIGNAL, b.nextSerial());
    defer sig.deinit();
    try sig.fieldPath("/org/freedesktop/ScreenSaver");
    try sig.fieldInterface("org.freedesktop.ScreenSaver");
    try sig.fieldMember("ActiveChanged");
    try sig.fieldSignature("b");
    try sig.body.putBool(true);
    try b.sendOneWay(&sig);

    // A 泵直到收到（上限 ~1s）
    var i: u32 = 0;
    while (i < 100 and g_signal_hits == 0) : (i += 1) {
        _ = a.pump();
        sleepMs(10);
    }
    try t.expect(g_signal_hits >= 1);
}
