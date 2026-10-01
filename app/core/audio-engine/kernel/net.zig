// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! EraAudio 原生网络传输（HTTP/1.1，docs/audio-kernel-zig.md §6.1/§7）
//!
//! 定位：让**内核自身**具备网络直链解析与拉流能力，取代此前「内核零网络栈、
//! 传输全部交给宿主 C 壳经 FFmpeg AVIO 注入」的模式（对照
//! `pipeline.c :: pipeline_era_url_open`）。本模块自带：
//!   - URL 解析（scheme/host/port/path+query）；
//!   - TCP 连接（`std.Io.net`）与 TLS 握手（`std.crypto.tls.Client`，仅密码学原语
//!     复用标准库，**不使用** `std.http`，请求/响应解析完全自研）；
//!   - HTTP/1.1 请求构造（GET + `Range` + `Connection: close`）、响应头解析、
//!     重定向跟随、`Content-Length` / `chunked` 正文解码；
//!   - 随机访问：`seek` 以 `Range` 重新发起请求（服务端忽略 Range 时前向丢弃兜底）。
//!
//! 并发/生命周期：一个 `HttpStream` 对应一路播放源，自持连接；Io 为**全进程
//! 单一常驻实例**（见 globalIo，避免每路 Threaded 的 SIGIO handler 互相覆盖）；
//! 被内核解码线程串行调用（同步/run-to-completion），不自持解码线程。`abort` 置位并尽力 `shutdown` 连接以解除阻塞读（best-effort）。
//!
//! 断流重连 / 读超时（对齐 FFmpeg AVIO 的 `rw_timeout` / `reconnect*`）：
//!   - 瞬时读错误 / 长度内提前 EOF / 读超时 → 自 `net_pos` 以 `Range` 重连续传；
//!     重试上限 + 指数退避，见 `configureFromEnv` / `backoffSleep`；
//!   - 读超时：`std.Io.net` 不暴露 socket 读超时（且 std 阻塞读不允许 EAGAIN，
//!     不能用 SO_RCVTIMEO），改以 watchdog 线程轮询——超时即对本连接
//!     `shutdown(.both)` 解阻塞，读线程据 `wd_fired` 判为瞬时超时并重连；
//!   - 低进展连击上限：一段连接交付量低于 `min_progress_bytes` 记为低进展，连续
//!     `max_low_progress_streak` 次后停止重连（防逐字节滴流无限续传）；
//!   - 配置：`ARCHOERA_ERA_HTTP_TIMEOUT_MS`（默认 15000；0 关闭 watchdog）、
//!     `ARCHOERA_ERA_HTTP_RECONNECT`（默认开；0 关闭）、
//!     `ARCHOERA_ERA_HTTP_RECONNECT_MAX`（默认 3）、
//!     `ARCHOERA_ERA_HTTP_RECONNECT_DELAY_MS`（默认 500）、
//!     `ARCHOERA_ERA_HTTP_MIN_PROGRESS_KB`（默认 64）、
//!     `ARCHOERA_ERA_HTTP_RECONNECT_STREAK`（默认 8）。
//!   落地路径保留宿主 AVIO 回退，异常源仍可回退既有传输。
//!
//! 命名：本文件符号为自有命名（`HttpStream` / `era_net_*`），不照搬上游标识符。

const std = @import("std");
const era_log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// TLS 读缓冲下限（std.crypto.tls.Client 要求 input 缓冲 ≥ min_buffer_len）
const tls_buffer_size = std.crypto.tls.Client.min_buffer_len;
/// 请求目标（path?query）缓冲上限
const target_max = 4096;
/// 主机名缓冲上限（RFC 1035 名称 ≤255）
const host_max = 256;
/// 重定向跟随上限
const max_redirects = 6;
/// seek 前向「同一连接内丢弃」而非重连的距离上限（字节）
const forward_discard_limit = 1 << 20;

/// 读超时默认值（ms；对齐 FFmpeg AVIO 的 rw_timeout=15s）；0 = 关闭 watchdog。
const default_timeout_ms: u32 = 15000;
/// 断流重连默认：最多 3 次，首次退避 500ms，指数增长、上限 5s。
const default_reconnect_max: u32 = 3;
const default_reconnect_delay_ms: u32 = 500;
const max_backoff_ms: u32 = 5000;
/// 读超时 watchdog 轮询间隔（ms）。
const watchdog_poll_ms: u32 = 50;

/// 单个 User-Agent
const user_agent = "ArchoeraMusic/0.9 (EraAudio)";

/// 读取宿主环境变量（内核经宿主 CRT getenv；缺失返回 null）。
fn envStr(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.span(p);
}

/// 读取非负整数环境变量（缺失/非法 → default）。
fn envInt(name: [*:0]const u8, default: u32) u32 {
    const s = envStr(name) orelse return default;
    return std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t"), 10) catch default;
}

/// 进程级 Io（单例、惰性初始化、**从不 deinit**）。
///
/// 每路 HttpStream 各建 `std.Io.Threaded` 会在会话切换/关闭时 `deinit` 恢复**旧
/// SIGIO handler**（Threaded 以 SIGIO 打断阻塞 syscall）：旧实例先 deinit 会把 handler
/// 还原为 SIG_DFL，之后仍活跃实例触发 SIGIO 即令进程被信号终止（实机表现为跳转/切会话
/// 后进程退出，shell 报 "I/O possible"）。故全进程共用一个常驻 Io，避免信号处理器互相覆盖。
var g_io_state = std.atomic.Value(u8).init(0); // 0=未初始化 1=初始化中 2=就绪
var g_threaded: std.Io.Threaded = undefined;
var g_io: Io = undefined;

fn globalIo() Io {
    if (g_io_state.load(.acquire) == 2) return g_io;
    if (g_io_state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
        g_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
        g_io = g_threaded.io();
        g_io_state.store(2, .release);
        return g_io;
    }
    while (g_io_state.load(.acquire) != 2) std.atomic.spinLoopHint();
    return g_io;
}

/// 网络传输错误（统一聚合，Engine 侧经 err.statusOf 映射为稳定状态码）
pub const NetError = error{
    BadUrl,
    UnsupportedScheme,
    ConnectFailed,
    TlsFailed,
    TlsNoCa,
    HttpStatus,
    HttpProtocol,
    HttpHeadersOversize,
    TooManyRedirects,
    SeekFailed,
    Aborted,
    OutOfMemory,
    IoError,
};

/// URL 解析结果（切片指向传入的原始字符串，调用方须保证其生命周期覆盖使用期）
pub const UrlParts = struct {
    tls: bool,
    host: []const u8,
    port: u16,
    /// 请求目标（path + '?' + query），保证以 '/' 开头
    target: []const u8,
    /// Host 头取值（host，非默认端口时 host:port）
    host_header: []const u8,
};

/// 解析 http(s):// 绝对 URL。[host_header_buf] 用于拼装 Host 头（须 ≥ host_max+8）。
pub fn parseUrl(raw: []const u8, host_header_buf: []u8) NetError!UrlParts {
    const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return error.BadUrl;
    const scheme = raw[0..scheme_end];
    const tls = if (std.ascii.eqlIgnoreCase(scheme, "https"))
        true
    else if (std.ascii.eqlIgnoreCase(scheme, "http"))
        false
    else
        return error.UnsupportedScheme;

    var rest = raw[scheme_end + 3 ..];
    // 丢弃 userinfo@（不支持带凭据的源；忽略即可）
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        if (slash == null or at < slash.?) rest = rest[at + 1 ..];
    }

    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    if (authority.len == 0) return error.BadUrl;

    var host: []const u8 = undefined;
    var port: u16 = if (tls) 443 else 80;
    var port_txt: ?[]const u8 = null;
    var ipv6 = false;
    if (authority[0] == '[') {
        // IPv6 字面量 [addr]:port
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.BadUrl;
        host = authority[1..close];
        ipv6 = true;
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return error.BadUrl;
            port_txt = authority[close + 2 ..];
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port_txt = authority[colon + 1 ..];
    } else {
        host = authority;
    }
    if (host.len == 0) return error.BadUrl;
    if (port_txt) |pt| {
        port = std.fmt.parseInt(u16, pt, 10) catch return error.BadUrl;
    }

    // 请求目标：path[?query]，缺省 "/"
    const path_and_more = rest[authority_end..];
    var target: []const u8 = if (path_and_more.len == 0) "/" else blk: {
        // 丢弃 fragment
        const frag = std.mem.indexOfScalar(u8, path_and_more, '#') orelse path_and_more.len;
        break :blk path_and_more[0..frag];
    };
    if (target.len == 0) target = "/";
    if (target[0] == '?') {
        // 绝对 URI 中 query 前应有路径；补一个 '/'
        target = "/";
    }

    // Host 头：host[:port]（默认端口省略；IPv6 字面量带方括号）
    const default_port: u16 = if (tls) 443 else 80;
    var hh_len: usize = 0;
    if (port == default_port) {
        if (ipv6) {
            const s = std.fmt.bufPrint(host_header_buf, "[{s}]", .{host}) catch return error.BadUrl;
            hh_len = s.len;
        } else {
            if (host.len > host_header_buf.len) return error.BadUrl;
            @memcpy(host_header_buf[0..host.len], host);
            hh_len = host.len;
        }
    } else {
        const s = if (ipv6)
            std.fmt.bufPrint(host_header_buf, "[{s}]:{d}", .{ host, port }) catch return error.BadUrl
        else
            std.fmt.bufPrint(host_header_buf, "{s}:{d}", .{ host, port }) catch return error.BadUrl;
        hh_len = s.len;
    }

    return .{
        .tls = tls,
        .host = host,
        .port = port,
        .target = target,
        .host_header = host_header_buf[0..hh_len],
    };
}

/// 解析重定向 Location（绝对 / 根相对 / 相对），结果写入 [out]（ArrayList），
/// 成功返回完整新 URL 切片（指向 out.items）。
pub fn resolveLocation(
    allocator: Allocator,
    base_url: []const u8,
    location: []const u8,
    out: *std.ArrayList(u8),
) NetError![]const u8 {
    out.clearRetainingCapacity();
    const loc = std.mem.trim(u8, location, " \t\r\n");
    if (loc.len == 0) return error.BadUrl;
    if (std.ascii.startsWithIgnoreCase(loc, "http://") or
        std.ascii.startsWithIgnoreCase(loc, "https://"))
    {
        out.appendSlice(allocator, loc) catch return error.OutOfMemory;
        return out.items;
    }
    // 拆分 base 的 scheme://authority 前缀
    const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse return error.BadUrl;
    const after = base_url[scheme_end + 3 ..];
    const auth_end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    out.print(allocator, "{s}://{s}", .{ base_url[0..scheme_end], after[0..auth_end] }) catch
        return error.OutOfMemory;
    if (loc[0] == '/') {
        out.appendSlice(allocator, loc) catch return error.OutOfMemory;
    } else {
        // 相对：以 base 路径所在目录拼接
        const path_and_more = after[auth_end..];
        const q = std.mem.indexOfAny(u8, path_and_more, "?#") orelse path_and_more.len;
        const path = path_and_more[0..q];
        const dir_end = if (path.len == 0) 0 else (std.mem.lastIndexOfScalar(u8, path, '/') orelse 0);
        out.appendSlice(allocator, path[0..dir_end]) catch return error.OutOfMemory;
        out.appendSlice(allocator, "/") catch return error.OutOfMemory;
        out.appendSlice(allocator, loc) catch return error.OutOfMemory;
    }
    return out.items;
}

/// 已解析的响应头（指向内部 head 缓冲；仅在本次响应头有效期内使用）
const ResponseHead = struct {
    status: u16,
    content_length: ?u64 = null,
    /// Content-Range 中的总长度（bytes start-end/total）
    content_range_total: ?u64 = null,
    /// Content-Range 中的起始偏移
    content_range_start: ?u64 = null,
    chunked: bool = false,
    location: ?[]const u8 = null,
};

/// 一路 HTTP(S) 播放源：自持 Io/连接/缓冲，提供顺序读与随机 seek。
pub const HttpStream = struct {
    gpa: Allocator,

    /// 当前完整 URL（owned；重定向时可被替换）
    cur_url: []u8,
    /// 迭代用临时缓冲（重定向解析）
    url_scratch: std.ArrayList(u8),

    // IO 实例（全进程单一常驻；见 globalIo）
    io: Io,

    // CA（https 首次连接时惰性扫描一次，之后复用）
    ca_lock: std.Io.RwLock = .init,
    ca: std.crypto.Certificate.Bundle = .empty,
    ca_ready: bool = false,

    // 连接状态
    connected: bool = false,
    using_tls: bool = false,
    stream: std.Io.net.Stream = undefined,
    stream_reader: std.Io.net.Stream.Reader = undefined,
    stream_writer: std.Io.net.Stream.Writer = undefined,
    tls: std.crypto.tls.Client = undefined,

    // 大缓冲（保持稳定地址：被 stream/tls 接口引用）
    sock_read_buffer: [tls_buffer_size]u8 = undefined,
    sock_write_buffer: [tls_buffer_size]u8 = undefined,
    tls_read_buffer: [tls_buffer_size]u8 = undefined,
    tls_write_buffer: [1024]u8 = undefined,

    // 当前响应的正文状态
    content_length: ?u64 = null,
    body_remaining: ?u64 = null, // content-length 剩余
    chunked: bool = false,
    chunk_remaining: u64 = 0,
    total_size: u64 = 0, // 0 = 未知

    /// 下一次正文读取对应的绝对偏移（与 io.Reader 逻辑游标 + buffered 对齐）
    net_pos: u64 = 0,
    /// 读错误（回调无法返回错误，记此供诊断；0 = 无）
    io_error: i32 = 0,
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // ── 断流重连 / 读超时（env 注入；见 configureFromEnv）─────────────
    reconnect_enabled: bool = true,
    reconnect_max: u32 = default_reconnect_max,
    reconnect_delay_ms: u32 = default_reconnect_delay_ms,
    /// 累计重连次数（诊断/日志；跨调用累加）。
    reconnect_count: u32 = 0,
    /// 单次读超时（ms；0 = 关闭 watchdog，仅靠对端错误/EOF 触发重连）。
    timeout_ms: u32 = default_timeout_ms,
    /// 实质进展阈值（字节）：一段连接交付量低于此值记为「低进展」。
    min_progress_bytes: u64 = 64 << 10,
    /// 低进展连击上限：连续这么多次低进展重连后放弃（防逐字节滴流）。
    max_low_progress_streak: u32 = 8,
    /// 自上次重连以来自网络交付的字节数（进度结算用）。
    progress_bytes: u64 = 0,
    /// 当前低进展连击数。
    low_progress_streak: u32 = 0,

    // 读超时 watchdog（timeout_ms>0 时启动；见 startWatchdog）
    wd_mu: Io.Mutex = .init,
    wd_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wd_fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wd_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wd_deadline_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// 本轮读对应的连接（arm 时快照；watchdog 经 shutdown 解阻塞）。
    wd_stream: std.Io.net.Stream = undefined,
    wd_thread: std.Thread = undefined,
    wd_started: bool = false,

    // ── 生命周期 ──────────────────────────────────────────────────────

    /// 打开参数（宿主/测试可覆盖；null = 读环境变量默认）。
    pub const Options = struct {
        timeout_ms: ?u32 = null,
        reconnect_enabled: ?bool = null,
        reconnect_max: ?u32 = null,
        reconnect_delay_ms: ?u32 = null,
        /// 实质进展阈值（KB）；低于此值的重连间隔计为低进展。
        min_progress_kb: ?u32 = null,
        /// 低进展连击上限（超出即停止重连，防逐字节滴流）。
        max_low_progress_streak: ?u32 = null,
    };

    /// 打开 URL（连接 + 首个请求 + 响应头解析由 [start] 完成）。
    pub fn open(gpa: Allocator, url: []const u8) NetError!*HttpStream {
        return openWith(gpa, url, .{});
    }

    /// 同 [open]，另指定 [Options] 覆盖（用于测试/宿主定向配置）。
    pub fn openWith(gpa: Allocator, url: []const u8, opts: Options) NetError!*HttpStream {
        const self = gpa.create(HttpStream) catch return error.OutOfMemory;
        self.* = .{
            .gpa = gpa,
            .cur_url = gpa.dupe(u8, url) catch {
                gpa.destroy(self);
                return error.OutOfMemory;
            },
            .url_scratch = .empty,
            .io = undefined,
        };
        self.io = globalIo();
        self.configureFromEnv(opts);
        self.startWatchdog();
        errdefer {
            self.stopWatchdog();
            self.disconnect();
            self.ca.deinit(gpa);
            self.url_scratch.deinit(gpa);
            gpa.free(self.cur_url);
            gpa.destroy(self);
        }
        try self.start(0);
        return self;
    }

    /// 读取断流重连 / 读超时配置：先取环境变量默认，再用 [opts] 覆盖。
    ///   - `ARCHOERA_ERA_HTTP_TIMEOUT_MS`（默认 15000；0 = 关闭 watchdog）
    ///   - `ARCHOERA_ERA_HTTP_RECONNECT`（默认开；`0` 关闭）
    ///   - `ARCHOERA_ERA_HTTP_RECONNECT_MAX`（默认 3）
    ///   - `ARCHOERA_ERA_HTTP_RECONNECT_DELAY_MS`（默认 500）
    fn configureFromEnv(self: *HttpStream, opts: Options) void {
        self.timeout_ms = opts.timeout_ms orelse
            envInt("ARCHOERA_ERA_HTTP_TIMEOUT_MS", default_timeout_ms);
        if (opts.reconnect_enabled) |b| {
            self.reconnect_enabled = b;
        } else if (envStr("ARCHOERA_ERA_HTTP_RECONNECT")) |s| {
            self.reconnect_enabled = !(s.len == 1 and s[0] == '0');
        }
        self.reconnect_max = opts.reconnect_max orelse
            envInt("ARCHOERA_ERA_HTTP_RECONNECT_MAX", default_reconnect_max);
        self.reconnect_delay_ms = opts.reconnect_delay_ms orelse
            envInt("ARCHOERA_ERA_HTTP_RECONNECT_DELAY_MS", default_reconnect_delay_ms);
        if (self.reconnect_delay_ms == 0) self.reconnect_delay_ms = 1;
        const min_kb = opts.min_progress_kb orelse
            envInt("ARCHOERA_ERA_HTTP_MIN_PROGRESS_KB", 64);
        self.min_progress_bytes = @as(u64, min_kb) << 10;
        self.max_low_progress_streak = opts.max_low_progress_streak orelse
            envInt("ARCHOERA_ERA_HTTP_RECONNECT_STREAK", 8);
        if (self.max_low_progress_streak == 0) self.max_low_progress_streak = 1;
    }

    /// 关闭并释放（调用方须保证仅调用一次；调用后句柄不可再用）。
    pub fn close(self: *HttpStream) void {
        self.stopWatchdog();
        self.disconnect();
        self.ca.deinit(self.gpa);
        self.url_scratch.deinit(self.gpa);
        self.gpa.free(self.cur_url);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    // ── 读写 / 定位（供 io.Reader.Callback 桥接）────────────────────────

    /// 已知内容总长度（0 = 未知）。
    pub fn sizeHint(self: *const HttpStream) u64 {
        return self.total_size;
    }

    /// 顺序读取（0 = EOF）。网络错误置 [io_error] 后返回 0。
    pub fn read(self: *HttpStream, buf: []u8) usize {
        if (buf.len == 0) return 0;
        return self.readBody(buf) catch |e| {
            self.io_error = @intCast(@intFromError(e));
            return 0;
        };
    }

    /// 定位。whence：0=start / 1=current / 2=end；`buffered` = 调用方预读缓冲中
    /// 尚未消费的字节数（底层流领先逻辑游标 buffered）。成功返回 true。
    pub fn seek(self: *HttpStream, off: i64, whence: i32, buffered: usize) bool {
        if (self.aborted.load(.acquire)) return false;
        const base: i64 = switch (whence) {
            0 => 0,
            1 => @as(i64, @intCast(self.net_pos)) - @as(i64, @intCast(buffered)),
            2 => blk: {
                if (self.total_size == 0) return false; // 总长未知：end 不可用
                break :blk @intCast(self.total_size);
            },
            else => return false,
        };
        const target_i = base + off;
        if (target_i < 0) return false;
        const target: u64 = @intCast(target_i);
        if (self.total_size > 0 and target > self.total_size) return false;
        self.seekTo(target) catch |e| {
            self.io_error = @intCast(@intFromError(e));
            return false;
        };
        return true;
    }

    /// 请求中断：置位并尽力关闭底层连接以解除阻塞读（best-effort）。
    pub fn abort(self: *HttpStream) void {
        self.aborted.store(true, .seq_cst);
        self.wd_mu.lockUncancelable(self.io);
        if (self.connected) {
            self.stream.shutdown(self.io, .both) catch {};
        }
        self.wd_mu.unlock(self.io);
    }

    // ── 内部：连接 / 请求 / 响应 ───────────────────────────────────────

    fn disconnect(self: *HttpStream) void {
        self.wd_mu.lockUncancelable(self.io);
        defer self.wd_mu.unlock(self.io);
        if (!self.connected) return;
        self.stream.close(self.io);
        self.connected = false;
        self.body_remaining = null;
        self.chunked = false;
        self.chunk_remaining = 0;
        self.content_length = null;
        self.tls = undefined;
    }

    /// 加载 CA bundle（首次 https 连接时；失败返回 TlsNoCa，交由上层回退）。
    fn ensureCa(self: *HttpStream) NetError!void {
        if (self.ca_ready) return;
        const now = Io.Clock.real.now(self.io);
        self.ca.rescan(self.gpa, self.io, now) catch return error.TlsNoCa;
        self.ca_ready = true;
    }

    // ── 读超时 watchdog（timeout_ms>0 时启用）──────────────────────────
    //
    // std.Io.net 不暴露 socket 读超时，且 std 的阻塞读不允许 EAGAIN，故不能用
    // SO_RCVTIMEO。改以独立 watchdog 线程轮询：某次阻塞读超过 timeout_ms 时，
    // 对该连接 `shutdown(.both)` 解阻塞（读线程据 wd_fired 判为瞬时超时→重连）。

    fn startWatchdog(self: *HttpStream) void {
        if (self.timeout_ms == 0) return;
        self.wd_stop.store(false, .release);
        self.wd_thread = std.Thread.spawn(.{}, watchdogMain, .{self}) catch return;
        self.wd_started = true;
    }

    fn stopWatchdog(self: *HttpStream) void {
        if (!self.wd_started) return;
        self.wd_stop.store(true, .release);
        self.wd_thread.join();
        self.wd_started = false;
    }

    fn watchdogMain(self: *HttpStream) void {
        while (!self.wd_stop.load(.acquire)) {
            if (self.wd_active.load(.acquire) and !self.wd_fired.load(.acquire)) {
                const now = Io.Clock.awake.now(self.io).toMilliseconds();
                const dl = self.wd_deadline_ms.load(.acquire);
                if (dl != 0 and now >= dl) {
                    // 与 disconnect/close/abort 串行，避免对已关闭/复用的句柄 shutdown。
                    self.wd_mu.lockUncancelable(self.io);
                    if (!self.wd_stop.load(.acquire) and
                        self.wd_active.load(.acquire) and
                        !self.wd_fired.load(.acquire))
                    {
                        self.wd_fired.store(true, .release);
                        self.wd_active.store(false, .release);
                        self.wd_stream.shutdown(self.io, .both) catch {};
                    }
                    self.wd_mu.unlock(self.io);
                }
            }
            Io.sleep(self.io, .fromMilliseconds(watchdog_poll_ms), .awake) catch {};
        }
    }

    /// 标记一次阻塞读开始（快照连接 + 设定 deadline）。
    fn wdArm(self: *HttpStream) void {
        if (self.timeout_ms == 0) return;
        self.wd_mu.lockUncancelable(self.io);
        self.wd_stream = self.stream;
        self.wd_fired.store(false, .release);
        const deadline = Io.Clock.awake.now(self.io).toMilliseconds() + @as(i64, self.timeout_ms);
        self.wd_deadline_ms.store(deadline, .release);
        self.wd_active.store(true, .release);
        self.wd_mu.unlock(self.io);
    }

    /// 标记一次阻塞读结束；返回本轮是否被 watchdog 判超时。
    fn wdDisarm(self: *HttpStream) bool {
        if (self.timeout_ms == 0) return false;
        self.wd_mu.lockUncancelable(self.io);
        self.wd_active.store(false, .release);
        self.wd_deadline_ms.store(0, .release);
        const fired = self.wd_fired.load(.acquire);
        self.wd_fired.store(false, .release);
        self.wd_mu.unlock(self.io);
        return fired;
    }

    /// 退避等待（指数增长到 [max_backoff_ms]；分段以便及时响应 abort）。
    fn backoffSleep(self: *HttpStream, attempt: u32) NetError!void {
        var delay: u64 = self.reconnect_delay_ms;
        var i: u32 = 1;
        while (i < attempt and delay < max_backoff_ms) : (i += 1) {
            delay = @min(delay * 2, max_backoff_ms);
        }
        if (delay > max_backoff_ms) delay = max_backoff_ms;
        var left = delay;
        while (left > 0) {
            if (self.aborted.load(.acquire)) return error.Aborted;
            const step: u32 = @intCast(@min(left, 100));
            Io.sleep(self.io, .fromMilliseconds(step), .awake) catch {};
            left -= step;
        }
    }

    /// 建立连接并发送 `Range: bytes=<range_start>-` 请求，解析响应头。
    /// 跟随重定向（最多 max_redirects）。
    fn start(self: *HttpStream, range_start: u64) NetError!void {
        var redirects: usize = 0;
        while (true) {
            var host_buf: [host_max + 16]u8 = undefined;
            const parts = try parseUrl(self.cur_url, &host_buf);
            var target_buf: [target_max]u8 = undefined;
            if (parts.target.len > target_buf.len) return error.BadUrl;
            @memcpy(target_buf[0..parts.target.len], parts.target);
            const target = target_buf[0..parts.target.len];

            self.connect(parts.tls, parts.host, parts.port) catch |e| return e;
            try self.sendGet(parts.host_header, target, range_start);
            const head = self.receiveHead() catch |e| {
                self.disconnect();
                return e;
            };

            // 重定向
            if (head.status >= 300 and head.status < 400) {
                const loc = head.location orelse {
                    self.disconnect();
                    return error.HttpProtocol;
                };
                if (redirects >= max_redirects) {
                    self.disconnect();
                    return error.TooManyRedirects;
                }
                const new_url = try resolveLocation(self.gpa, self.cur_url, loc, &self.url_scratch);
                const dup = self.gpa.dupe(u8, new_url) catch return error.OutOfMemory;
                self.gpa.free(self.cur_url);
                self.cur_url = dup;
                redirects += 1;
                self.disconnect();
                continue;
            }

            if (head.status != 200 and head.status != 206) {
                self.disconnect();
                return error.HttpStatus;
            }

            // 记录正文长度/编码（content-length 已含在 head）
            self.content_length = head.content_length;
            self.chunked = head.chunked;
            self.chunk_remaining = 0;

            // 计算总大小与当前正文起点
            var start_off: u64 = 0;
            if (head.status == 206) {
                start_off = head.content_range_start orelse range_start;
                if (head.content_range_total) |t| self.total_size = t;
                self.body_remaining = head.content_length;
            } else { // 200：整段返回
                start_off = 0;
                if (head.content_length) |cl| {
                    if (self.total_size == 0) self.total_size = cl;
                }
                self.body_remaining = head.content_length;
            }
            self.net_pos = start_off;

            // 服务端忽略 Range（返回 200）且目标偏移 > 0：前向丢弃对齐
            if (head.status == 200 and range_start > 0) {
                try self.discard(range_start);
                self.net_pos = range_start;
            }
            return;
        }
    }

    fn connect(self: *HttpStream, tls: bool, host: []const u8, port: u16) NetError!void {
        self.disconnect();
        // IP 字面量（含 IPv6）走 parse，其余走 DNS 解析
        const stream = blk: {
            if (std.Io.net.IpAddress.resolve(self.io, host, port)) |addr| {
                break :blk addr.connect(self.io, .{ .mode = .stream }) catch return error.ConnectFailed;
            } else |_| {}
            const hn = std.Io.net.HostName.init(host) catch return error.ConnectFailed;
            break :blk hn.connect(self.io, port, .{ .mode = .stream }) catch return error.ConnectFailed;
        };
        self.stream = stream;
        // 连接一旦建立，后续任一步骤失败都必须关闭，避免句柄泄漏。
        var ok = false;
        defer if (!ok) self.stream.close(self.io);

        self.using_tls = tls;
        self.stream_writer = self.stream.writer(self.io, &self.sock_write_buffer);
        self.stream_reader = self.stream.reader(self.io, &self.sock_read_buffer);
        if (tls) {
            try self.ensureCa();
            var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
            self.io.random(&entropy);
            const now = Io.Clock.real.now(self.io);
            self.tls = std.crypto.tls.Client.init(
                &self.stream_reader.interface,
                &self.stream_writer.interface,
                .{
                    .host = .{ .explicit = host },
                    .ca = .{ .bundle = .{
                        .gpa = self.gpa,
                        .io = self.io,
                        .lock = &self.ca_lock,
                        .bundle = &self.ca,
                    } },
                    .read_buffer = &self.tls_read_buffer,
                    .write_buffer = &self.tls_write_buffer,
                    .entropy = &entropy,
                    .realtime_now = now,
                    .allow_truncation_attacks = true,
                },
            ) catch return error.TlsFailed;
        }
        ok = true;
        self.connected = true;
    }

    fn reader(self: *HttpStream) *Io.Reader {
        return if (self.using_tls) &self.tls.reader else &self.stream_reader.interface;
    }

    fn sendGet(self: *HttpStream, host_header: []const u8, target: []const u8, range_start: u64) NetError!void {
        if (self.using_tls) {
            writeRequest(&self.tls.writer, host_header, target, range_start) catch return error.IoError;
            self.tls.writer.flush() catch return error.IoError;
            self.stream_writer.interface.flush() catch return error.IoError;
        } else {
            writeRequest(&self.stream_writer.interface, host_header, target, range_start) catch return error.IoError;
            self.stream_writer.interface.flush() catch return error.IoError;
        }
    }

    fn writeRequest(
        w: *Io.Writer,
        host_header: []const u8,
        target: []const u8,
        range_start: u64,
    ) !void {
        var buf: [target_max + host_max + 256]u8 = undefined;
        const head = std.fmt.bufPrint(
            &buf,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "User-Agent: {s}\r\n" ++
                "Accept: */*\r\n" ++
                "Range: bytes={d}-\r\n" ++
                "Connection: close\r\n" ++
                "\r\n",
            .{ target, host_header, user_agent, range_start },
        ) catch return error.IoError;
        try w.writeAll(head);
    }

    /// 解析状态行 + 响应头（不含正文）。`location` 切片指向内部读缓冲，
    /// 仅在本次 receiveHead 返回后、再次读取前有效。
    fn receiveHead(self: *HttpStream) NetError!ResponseHead {
        // 响应头读取同样纳入读超时（连接/首包停滞时可被 watchdog 打断）。
        self.wdArm();
        defer _ = self.wdDisarm();
        const r = self.reader();
        var head = ResponseHead{ .status = 0 };

        const status_line = r.takeDelimiterInclusive('\n') catch return error.HttpProtocol;
        const line = std.mem.trimEnd(u8, status_line, "\r\n");
        // "HTTP/1.x <code> <reason>"
        if (line.len < 12 or !std.mem.startsWith(u8, line, "HTTP/")) return error.HttpProtocol;
        const code = std.fmt.parseInt(u16, line[9..12], 10) catch return error.HttpProtocol;
        head.status = code;

        while (true) {
            const hl = r.takeDelimiterInclusive('\n') catch return error.HttpProtocol;
            const hline = std.mem.trimEnd(u8, hl, "\r\n");
            if (hline.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, hline, ':') orelse continue;
            const name = std.mem.trim(u8, hline[0..colon], " \t");
            const value = std.mem.trim(u8, hline[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                head.content_length = std.fmt.parseInt(u64, value, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(name, "content-range")) {
                head.content_range_start = parseContentRangeStart(value);
                head.content_range_total = parseContentRangeTotal(value);
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                head.chunked = asciiContainsIgnoreCase(value, "chunked");
            } else if (std.ascii.eqlIgnoreCase(name, "location")) {
                head.location = value;
            }
        }
        return head;
    }

    // ── 内部：正文读取 ─────────────────────────────────────────────────

    /// 读取正文（带断流重连：瞬时错误 / 读超时 / 长度内提前 EOF → 自 net_pos 以
    /// Range 续传）。重试次数由 [reconnect_max] 限定，退避见 [backoffSleep]。
    fn readBody(self: *HttpStream, buf: []u8) NetError!usize {
        var tries: u32 = 0;
        while (true) {
            if (self.aborted.load(.acquire)) return error.Aborted;
            if (!self.connected) {
                if (!self.reconnectable(tries)) return error.IoError;
                try self.reconnectStep(&tries);
                continue;
            }
            self.wdArm();
            const r = self.readOnce(buf);
            const fired = self.wdDisarm();
            if (r) |n| {
                if (n > 0) {
                    self.progress_bytes += n; // 进度结算（低进展连击判定用）
                    return n; // 有数据：正常返回（若超时已置位，下次读取处理）
                }
                if (fired) {
                    // 读超时（watchdog 已 shutdown 连接）→ 续传
                    if (!self.reconnectable(tries)) return 0;
                    try self.reconnectStep(&tries);
                    continue;
                }
                if (self.truncated() and self.reconnectable(tries)) {
                    try self.reconnectStep(&tries);
                    continue;
                }
                return 0; // 正常 EOF
            } else |e| {
                if (e == error.Aborted) return e;
                if (!self.reconnectable(tries)) return e;
                try self.reconnectStep(&tries);
                continue;
            }
        }
    }

    /// 单次正文读取（不含重连）：chunked / Content-Length / 读到连接 EOF。
    fn readOnce(self: *HttpStream, buf: []u8) NetError!usize {
        if (!self.connected) return error.IoError;
        if (self.chunked) return self.readChunked(buf);
        if (self.body_remaining) |remaining| {
            if (remaining == 0) return 0;
            const want = @min(buf.len, remaining);
            const n = self.reader().readSliceShort(buf[0..want]) catch return error.IoError;
            self.body_remaining = remaining - n;
            self.net_pos += n;
            return n;
        }
        // 无长度信息：读到连接 EOF
        const n = self.reader().readSliceShort(buf) catch return error.IoError;
        self.net_pos += n;
        return n;
    }

    /// 当前响应是否在读完前中断（长度已知但剩余 > 0 / chunked 未见终止块）。
    fn truncated(self: *HttpStream) bool {
        if (self.chunked) return true;
        if (self.body_remaining) |rem| return rem > 0;
        return false;
    }

    fn reconnectable(self: *HttpStream, tries: u32) bool {
        return self.reconnect_enabled and
            tries < self.reconnect_max and
            self.low_progress_streak < self.max_low_progress_streak;
    }

    /// 一次重连尝试：结算上一段进度 → 退避 → 从 net_pos 以 Range 重开。
    /// start 失败不抛错（由调用方循环按剩余次数继续），仅 abort 直接上抛。
    fn reconnectStep(self: *HttpStream, tries: *u32) NetError!void {
        // 进度结算：低于阈值视为低进展并累计连击，否则清零（健康流不受限）。
        if (self.progress_bytes < self.min_progress_bytes) {
            self.low_progress_streak += 1;
        } else {
            self.low_progress_streak = 0;
        }
        self.progress_bytes = 0;

        tries.* += 1;
        self.reconnect_count += 1;
        era_log.emit(2, "kernel:net", "HTTP 断流/超时重连（累计 {d} 次，低进展 {d}/{d}）：自 {d} 字节 Range 续传", .{
            self.reconnect_count, self.low_progress_streak, self.max_low_progress_streak, self.net_pos,
        });
        try self.backoffSleep(tries.*);
        if (self.aborted.load(.acquire)) return error.Aborted;
        self.disconnect();
        self.start(self.net_pos) catch |e| {
            if (e == error.Aborted) return e;
            era_log.emit(2, "kernel:net", "重连失败（{s}），按剩余次数重试", .{@errorName(e)});
        };
    }

    fn readChunked(self: *HttpStream, buf: []u8) NetError!usize {
        if (self.chunk_remaining == 0) {
            const size_line = self.reader().takeDelimiterInclusive('\n') catch return error.IoError;
            const clean = std.mem.trimEnd(u8, size_line, "\r\n");
            const semi = std.mem.indexOfScalar(u8, clean, ';') orelse clean.len;
            const size = std.fmt.parseInt(u64, std.mem.trim(u8, clean[0..semi], " \t"), 16) catch
                return error.HttpProtocol;
            if (size == 0) {
                // 结尾：读 trailer 至空行
                while (true) {
                    const t = self.reader().takeDelimiterInclusive('\n') catch return error.IoError;
                    if (std.mem.trimEnd(u8, t, "\r\n").len == 0) break;
                }
                self.chunked = false;
                return 0;
            }
            self.chunk_remaining = size;
        }
        const want = @min(buf.len, self.chunk_remaining);
        const n = self.reader().readSliceShort(buf[0..want]) catch return error.IoError;
        self.chunk_remaining -= n;
        self.net_pos += n;
        if (self.chunk_remaining == 0) {
            // 块尾 CRLF
            _ = self.reader().takeDelimiterInclusive('\n') catch return error.IoError;
        }
        return n;
    }

    /// 丢弃 n 字节（前向对齐；服务端忽略 Range 时用）。
    fn discard(self: *HttpStream, n: u64) NetError!void {
        var left = n;
        var tmp: [4096]u8 = undefined;
        while (left > 0) {
            const want: usize = @intCast(@min(left, tmp.len));
            const got = self.readBody(tmp[0..want]) catch |e| return e;
            if (got == 0) return error.SeekFailed;
            left -= got;
        }
    }

    fn seekTo(self: *HttpStream, target: u64) NetError!void {
        if (target == self.net_pos) return;
        // 同一连接内前向小跳：直接丢弃，避免重连
        if (!self.chunked and self.body_remaining != null and target > self.net_pos) {
            const delta = target - self.net_pos;
            if (delta <= self.body_remaining.? and delta <= forward_discard_limit) {
                self.discard(delta) catch {};
                if (self.net_pos == target) return;
            }
        }
        try self.start(target);
    }

    // ── 回调桥接（io.Reader.Callback 签名）─────────────────────────────

    pub fn readCb(ctx: *anyopaque, buf: []u8) usize {
        const self: *HttpStream = @ptrCast(@alignCast(ctx));
        return self.read(buf);
    }

    pub fn seekCb(ctx: *anyopaque, off: i64, whence: i32, buffered: usize) bool {
        const self: *HttpStream = @ptrCast(@alignCast(ctx));
        return self.seek(off, whence, buffered);
    }
};

// ── 头解析小工具 ───────────────────────────────────────────────────────

/// Content-Range: bytes 0-1023/4096 → 0
fn parseContentRangeStart(v: []const u8) ?u64 {
    const colon_space = std.mem.indexOf(u8, v, "bytes") orelse return null;
    var rest = std.mem.trim(u8, v[colon_space + 5 ..], " \t");
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    rest = std.mem.trim(u8, rest[0..dash], " \t");
    return std.fmt.parseInt(u64, rest, 10) catch null;
}

/// Content-Range: bytes 0-1023/4096 → 4096（"/*" → null）
fn parseContentRangeTotal(v: []const u8) ?u64 {
    const slash = std.mem.lastIndexOfScalar(u8, v, '/') orelse return null;
    const total = std.mem.trim(u8, v[slash + 1 ..], " \t");
    if (total.len == 0 or total[0] == '*') return null;
    return std.fmt.parseInt(u64, total, 10) catch null;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseUrl: http/https/host/port/path/query" {
    var hb: [host_max + 16]u8 = undefined;

    {
        const p = try parseUrl("http://example.com/a/b.mp3?x=1", &hb);
        try testing.expectEqual(false, p.tls);
        try testing.expectEqualStrings("example.com", p.host);
        try testing.expectEqual(@as(u16, 80), p.port);
        try testing.expectEqualStrings("/a/b.mp3?x=1", p.target);
        try testing.expectEqualStrings("example.com", p.host_header);
    }
    {
        const p = try parseUrl("https://h:8443/x", &hb);
        try testing.expectEqual(true, p.tls);
        try testing.expectEqual(@as(u16, 8443), p.port);
        try testing.expectEqualStrings("/x", p.target);
        try testing.expectEqualStrings("h:8443", p.host_header);
    }
    {
        const p = try parseUrl("https://example.com", &hb);
        try testing.expectEqualStrings("/", p.target);
        try testing.expectEqualStrings("example.com", p.host_header);
    }
    {
        const p = try parseUrl("https://[2001:db8::1]:9000/z", &hb);
        try testing.expectEqualStrings("2001:db8::1", p.host);
        try testing.expectEqual(@as(u16, 9000), p.port);
        try testing.expectEqualStrings("[2001:db8::1]:9000", p.host_header);
    }
    // 非法 / 非 http 协议
    try testing.expectError(error.UnsupportedScheme, parseUrl("ftp://x/y", &hb));
    try testing.expectError(error.BadUrl, parseUrl("no-scheme", &hb));
}

test "resolveLocation: 绝对 / 根相对 / 相对" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    {
        const u = try resolveLocation(gpa, "https://a.com/x/y.mp3", "https://b.com/z", &out);
        try testing.expectEqualStrings("https://b.com/z", u);
    }
    {
        const u = try resolveLocation(gpa, "https://a.com/x/y.mp3", "/z", &out);
        try testing.expectEqualStrings("https://a.com/z", u);
    }
    {
        const u = try resolveLocation(gpa, "https://a.com/x/y.mp3", "z2", &out);
        try testing.expectEqualStrings("https://a.com/x/z2", u);
    }
}

test "Content-Range 解析" {
    try testing.expectEqual(@as(?u64, 0), parseContentRangeStart("bytes 0-1023/4096"));
    try testing.expectEqual(@as(?u64, 4096), parseContentRangeTotal("bytes 0-1023/4096"));
    try testing.expectEqual(@as(?u64, null), parseContentRangeTotal("bytes 0-1023/*"));
}

// ── 本地 HTTP/1.1 测试服务器（确定性、无 sleep；支持 Range/重定向/chunked）──

/// 供测试的极简 HTTP 服务端：`/payload`（Range 206）/`/norange`（恒 200）/
/// `/redir`（302 → /payload）/`/chunked`（Transfer-Encoding: chunked）/
/// `/drop`（首次连接发部分正文后断开 → 触发续传）/`/stall`（首次连接发头后停滞
/// → 触发读超时重连）。线程模型：进程常驻 Io + accept 线程 + 每连接一个
/// handler 线程；测试结束置停并统一 join（确定性，无 sleep 等待竞态）。
const TestServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    port: u16,
    stop: std.atomic.Value(bool),
    payload: []const u8,
    thread: std.Thread = undefined,
    started: bool = false,

    mu: std.Io.Mutex = .init,
    handlers: std.ArrayList(std.Thread) = .empty,
    /// 一次性标记：`/drop`、`/stall` 仅首次连接生效（后续请求正常服务）。
    drop_served: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stall_served: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn start(payload: []const u8) !*TestServer {
        const gpa = std.heap.c_allocator;
        const ts = try gpa.create(TestServer);
        ts.* = .{
            .io = undefined,
            .server = undefined,
            .port = 0,
            .stop = std.atomic.Value(bool).init(false),
            .payload = payload,
        };
        ts.io = globalIo();
        const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
        ts.server = addr.listen(ts.io, .{}) catch return error.TestServerListen;
        ts.port = ts.server.socket.address.getPort();
        ts.thread = try std.Thread.spawn(.{}, run, .{ts});
        ts.started = true;
        return ts;
    }

    fn run(ts: *TestServer) void {
        while (!ts.stop.load(.acquire)) {
            const s = ts.server.accept(ts.io) catch return;
            const t = std.Thread.spawn(.{}, connThread, .{ ts, s }) catch {
                s.close(ts.io);
                continue;
            };
            ts.mu.lockUncancelable(ts.io);
            ts.handlers.append(std.heap.c_allocator, t) catch {};
            ts.mu.unlock(ts.io);
        }
    }

    fn connThread(ts: *TestServer, s: std.Io.net.Stream) void {
        handleConn(ts, s);
        s.close(ts.io);
    }

    fn stopAndDestroy(ts: *TestServer) void {
        ts.stop.store(true, .release);
        // 唤醒阻塞中的 accept
        const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(ts.port) };
        if (addr.connect(ts.io, .{ .mode = .stream })) |s| {
            s.close(ts.io);
        } else |_| {}
        if (ts.started) ts.thread.join();
        // accept 已退出 → 不再新增 handler；统一 join 全部在途 handler。
        ts.mu.lockUncancelable(ts.io);
        const hs: []std.Thread = ts.handlers.toOwnedSlice(std.heap.c_allocator) catch &.{};
        ts.mu.unlock(ts.io);
        for (hs) |t| t.join();
        if (hs.len > 0) std.heap.c_allocator.free(hs);
        ts.server.deinit(ts.io);
        std.heap.c_allocator.destroy(ts);
    }
};

fn handleConn(ts: *TestServer, stream: std.Io.net.Stream) void {
    const io = ts.io;
    const payload = ts.payload;
    var rbuf: [2048]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;

    // 请求行
    const req_line_raw = r.takeDelimiterInclusive('\n') catch return;
    const req_line = std.mem.trimEnd(u8, req_line_raw, "\r\n");
    var target: []const u8 = "/";
    {
        var it = std.mem.tokenizeScalar(u8, req_line, ' ');
        _ = it.next();
        target = it.next() orelse "/";
    }

    // 头（收集 Range / 首个空行结束）
    var range_start: u64 = 0;
    var has_range = false;
    while (true) {
        const raw = r.takeDelimiterInclusive('\n') catch return;
        if (raw.len <= 2) break; // "\r\n"
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "range")) {
            // bytes=S-
            const eq = std.mem.indexOfScalar(u8, value, '=') orelse continue;
            const dash = std.mem.indexOfScalarPos(u8, value, eq + 1, '-') orelse continue;
            range_start = std.fmt.parseInt(u64, value[eq + 1 .. dash], 10) catch 0;
            has_range = true;
        }
    }

    var wbuf: [2048]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    const w = &sw.interface;

    if (std.mem.eql(u8, target, "/redir")) {
        w.writeAll("HTTP/1.1 302 Found\r\nLocation: /payload\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch return;
        w.flush() catch {};
        return;
    }

    if (std.mem.eql(u8, target, "/chunked")) {
        w.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n") catch return;
        var off: usize = 0;
        const step: usize = 1500;
        while (off < payload.len) {
            const n = @min(step, payload.len - off);
            var hdr: [32]u8 = undefined;
            const hs = std.fmt.bufPrint(&hdr, "{x}\r\n", .{n}) catch return;
            w.writeAll(hs) catch return;
            w.writeAll(payload[off .. off + n]) catch return;
            w.writeAll("\r\n") catch return;
            off += n;
        }
        w.writeAll("0\r\n\r\n") catch return;
        w.flush() catch {};
        return;
    }

    if (std.mem.eql(u8, target, "/norange")) {
        var hdr: [256]u8 = undefined;
        const hs = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{payload.len}) catch return;
        w.writeAll(hs) catch return;
        w.writeAll(payload) catch return;
        w.flush() catch {};
        return;
    }

    // 统一从 start 起算的半开区间 [start, len)
    var start: u64 = if (has_range) range_start else 0;
    if (start > payload.len) start = payload.len;
    const last: u64 = if (payload.len > 0) payload.len - 1 else 0;
    const body = payload[@intCast(start)..];

    var hdr: [512]u8 = undefined;
    const hs = std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ start, last, payload.len, body.len },
    ) catch return;

    if (std.mem.eql(u8, target, "/drip")) {
        // 每次连接只发 1 字节（逐字节滴流；测低进展连击上限）。
        w.writeAll(hs) catch return;
        if (body.len > 0) w.writeAll(body[0..1]) catch return;
        w.flush() catch {};
        return;
    }

    if (std.mem.eql(u8, target, "/drop")) {
        // 首次连接：发头 + 前 1/3 正文后断开（客户端应自 net_pos 续传）。
        if (!ts.drop_served.swap(true, .acq_rel)) {
            w.writeAll(hs) catch return;
            const part = body.len / 3;
            if (part > 0) w.writeAll(body[0..part]) catch return;
            w.flush() catch {};
            return;
        }
    } else if (std.mem.eql(u8, target, "/stall")) {
        // 首次连接：发头后停滞（客户端应读超时并重连续传）。
        if (!ts.stall_served.swap(true, .acq_rel)) {
            w.writeAll(hs) catch return;
            w.flush() catch {};
            while (!ts.stop.load(.acquire)) {
                Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
            }
            return;
        }
    }

    // /payload 与 /drop、/stall 的后续连接：正常 206 全量正文
    w.writeAll(hs) catch return;
    w.writeAll(body) catch return;
    w.flush() catch {};
}

fn makeTestPayload(allocator: Allocator, n: usize) ![]u8 {
    const p = try allocator.alloc(u8, n);
    for (p, 0..) |*b, i| b.* = @intCast(i % 251);
    return p;
}

fn readAllInto(hs: *HttpStream, out: []u8) !usize {
    var off: usize = 0;
    while (off < out.len) {
        const n = hs.read(out[off..]);
        if (n == 0) break;
        off += n;
    }
    return off;
}

test "HttpStream: 顺序读取 + sizeHint" {
    const payload = try makeTestPayload(testing.allocator, 5000);
    defer testing.allocator.free(payload);
    const ts = try TestServer.start(payload);
    defer ts.stopAndDestroy();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/payload", .{ts.port});
    defer testing.allocator.free(url);

    const hs = try HttpStream.open(testing.allocator, url);
    defer hs.close();
    try testing.expectEqual(@as(u64, payload.len), hs.sizeHint());

    const got = try testing.allocator.alloc(u8, payload.len);
    defer testing.allocator.free(got);
    const n = try readAllInto(hs, got);
    try testing.expectEqual(payload.len, n);
    try testing.expectEqualSlices(u8, payload, got);
}

test "HttpStream: seek start/current/end（Range 重连）" {
    const payload = try makeTestPayload(testing.allocator, 5000);
    defer testing.allocator.free(payload);
    const ts = try TestServer.start(payload);
    defer ts.stopAndDestroy();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/payload", .{ts.port});
    defer testing.allocator.free(url);

    const hs = try HttpStream.open(testing.allocator, url);
    defer hs.close();

    var buf: [256]u8 = undefined;
    // 先读一点推进 net_pos，再 start 定位
    _ = try readAllInto(hs, buf[0..100]);
    try testing.expect(hs.seek(1000, 0, 0));
    var got: [100]u8 = undefined;
    try testing.expectEqual(@as(usize, 100), try readAllInto(hs, &got));
    try testing.expectEqualSlices(u8, payload[1000..1100], &got);

    // current 回退 -500 → 600
    try testing.expect(hs.seek(-500, 1, 0));
    var got2: [50]u8 = undefined;
    try testing.expectEqual(@as(usize, 50), try readAllInto(hs, &got2));
    try testing.expectEqualSlices(u8, payload[600..650], &got2);

    // end -100
    try testing.expect(hs.seek(-100, 2, 0));
    var got3: [100]u8 = undefined;
    try testing.expectEqual(@as(usize, 100), try readAllInto(hs, &got3));
    try testing.expectEqualSlices(u8, payload[4900..5000], &got3);

    // 越界
    try testing.expect(!hs.seek(-1, 0, 0));
    try testing.expect(!hs.seek(6000, 0, 0));
}

test "HttpStream: 跟随重定向" {
    const payload = try makeTestPayload(testing.allocator, 3000);
    defer testing.allocator.free(payload);
    const ts = try TestServer.start(payload);
    defer ts.stopAndDestroy();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/redir", .{ts.port});
    defer testing.allocator.free(url);

    const hs = try HttpStream.open(testing.allocator, url);
    defer hs.close();
    try testing.expectEqual(@as(u64, payload.len), hs.sizeHint());
    const got = try testing.allocator.alloc(u8, payload.len);
    defer testing.allocator.free(got);
    try testing.expectEqual(payload.len, try readAllInto(hs, got));
    try testing.expectEqualSlices(u8, payload, got);
}

test "HttpStream: chunked 正文解码" {
    const payload = try makeTestPayload(testing.allocator, 6000);
    defer testing.allocator.free(payload);
    const ts = try TestServer.start(payload);
    defer ts.stopAndDestroy();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/chunked", .{ts.port});
    defer testing.allocator.free(url);

    const hs = try HttpStream.open(testing.allocator, url);
    defer hs.close();
    const got = try testing.allocator.alloc(u8, payload.len);
    defer testing.allocator.free(got);
    try testing.expectEqual(payload.len, try readAllInto(hs, got));
    try testing.expectEqualSlices(u8, payload, got);
}

test "HttpStream: 服务端忽略 Range（恒 200）下前向 seek" {
    const payload = try makeTestPayload(testing.allocator, 5000);
    defer testing.allocator.free(payload);
    const ts = try TestServer.start(payload);
    defer ts.stopAndDestroy();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/norange", .{ts.port});
    defer testing.allocator.free(url);

    const hs = try HttpStream.open(testing.allocator, url);
    defer hs.close();
    try testing.expectEqual(@as(u64, payload.len), hs.sizeHint());
    try testing.expect(hs.seek(3000, 0, 0));
    var got: [100]u8 = undefined;
    try testing.expectEqual(@as(usize, 100), try readAllInto(hs, &got));
    try testing.expectEqualSlices(u8, payload[3000..3100], &got);
}

test "HttpStream: 断流续传（服务端中途断开 → Range 重连）" {
    const payload = try makeTestPayload(testing.allocator, 8000);
    defer testing.allocator.free(payload);
    const ts = try TestServer.start(payload);
    defer ts.stopAndDestroy();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/drop", .{ts.port});
    defer testing.allocator.free(url);

    const hs = try HttpStream.openWith(testing.allocator, url, .{
        .timeout_ms = 5000,
        .reconnect_delay_ms = 20,
        .reconnect_max = 3,
    });
    defer hs.close();

    const got = try testing.allocator.alloc(u8, payload.len);
    defer testing.allocator.free(got);
    const n = try readAllInto(hs, got);
    try testing.expectEqual(payload.len, n);
    try testing.expectEqualSlices(u8, payload, got);
    try testing.expect(hs.reconnect_count >= 1); // 确实发生过续传
}

test "HttpStream: 读超时 watchdog（停滞 → shutdown 解阻塞 → 重连续传）" {
    const payload = try makeTestPayload(testing.allocator, 4000);
    defer testing.allocator.free(payload);
    const ts = try TestServer.start(payload);
    defer ts.stopAndDestroy();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/stall", .{ts.port});
    defer testing.allocator.free(url);

    const hs = try HttpStream.openWith(testing.allocator, url, .{
        .timeout_ms = 700,
        .reconnect_delay_ms = 20,
        .reconnect_max = 5,
    });
    defer hs.close();

    const got = try testing.allocator.alloc(u8, payload.len);
    defer testing.allocator.free(got);
    const n = try readAllInto(hs, got);
    try testing.expectEqual(payload.len, n);
    try testing.expectEqualSlices(u8, payload, got);
    try testing.expect(hs.reconnect_count >= 1);
}

test "HttpStream: 关闭重连后，中途断开按 EOF 处理（不续传）" {
    const payload = try makeTestPayload(testing.allocator, 8000);
    defer testing.allocator.free(payload);
    const ts = try TestServer.start(payload);
    defer ts.stopAndDestroy();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/drop", .{ts.port});
    defer testing.allocator.free(url);

    const hs = try HttpStream.openWith(testing.allocator, url, .{
        .timeout_ms = 5000,
        .reconnect_enabled = false,
        .reconnect_max = 0,
    });
    defer hs.close();

    // 首个连接只到 1/3 正文即断；关闭重连后读到的长度应 < 全长（视为截断/EOF）。
    const got = try testing.allocator.alloc(u8, payload.len);
    defer testing.allocator.free(got);
    const n = try readAllInto(hs, got);
    try testing.expect(n > 0 and n < payload.len);
    try testing.expectEqual(@as(u32, 0), hs.reconnect_count);
}

test "HttpStream: 低进展连击上限（逐字节滴流 → 有界放弃）" {
    const payload = try makeTestPayload(testing.allocator, 4000);
    defer testing.allocator.free(payload);
    const ts = try TestServer.start(payload);
    defer ts.stopAndDestroy();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/drip", .{ts.port});
    defer testing.allocator.free(url);

    const hs = try HttpStream.openWith(testing.allocator, url, .{
        .timeout_ms = 3000,
        .reconnect_delay_ms = 1,
        .reconnect_max = 100, // 不限单次连击，改由低进展连击上限兜底
        .min_progress_kb = 1,
        .max_low_progress_streak = 3,
    });
    defer hs.close();

    const got = try testing.allocator.alloc(u8, payload.len);
    defer testing.allocator.free(got);
    const n = try readAllInto(hs, got);
    // 每次连接只 1 字节：应在上限内放弃（而非无限重连），且发生过重连。
    try testing.expect(n > 0 and n < payload.len);
    try testing.expect(hs.reconnect_count >= 1);
    try testing.expect(hs.reconnect_count <= 3);
}

test "HttpStream: 多路并存 + 关闭其一不影响另一路（常驻 Io 回归）" {
    const payload = try makeTestPayload(testing.allocator, 3000);
    defer testing.allocator.free(payload);
    const ts = try TestServer.start(payload);
    defer ts.stopAndDestroy();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/payload", .{ts.port});
    defer testing.allocator.free(url);

    const a = try HttpStream.open(testing.allocator, url);
    const b = try HttpStream.open(testing.allocator, url);

    var ba: [100]u8 = undefined;
    var bb: [100]u8 = undefined;
    try testing.expectEqual(@as(usize, 100), try readAllInto(a, &ba));
    try testing.expectEqualSlices(u8, payload[0..100], &ba);
    try testing.expectEqual(@as(usize, 100), try readAllInto(b, &bb));
    try testing.expectEqualSlices(u8, payload[0..100], &bb);

    // 关闭其一，另一路仍应正常读到底（此前每路独立 Threaded，deinit 会覆盖 SIGIO
    // handler 致活跃路被信号终止；常驻 Io 后不再发生）。
    a.close();
    const rest = try testing.allocator.alloc(u8, payload.len - 100);
    defer testing.allocator.free(rest);
    try testing.expectEqual(rest.len, try readAllInto(b, rest));
    try testing.expectEqualSlices(u8, payload[100..], rest);
    b.close();
}
