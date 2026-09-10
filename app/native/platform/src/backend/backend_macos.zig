// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! macOS 后端（P4，docs/platform-native-bridge.md §4.3）。
//!
//! 无 macOS SDK 头 → 全程 `dlopen` + `objc_msgSend` 运行时直调（不 @cImport
//! 框架头、不链框架，仅 libSystem 的 dlopen/dlsym）；观察者/远程命令目标用
//! 运行时创建的 ObjC 类（`objc_allocateClassPair`+`class_addMethod`）。
//!
//! 覆盖：NSProcessInfo beginActivity 抑制、NSWorkspace 熄屏通知、NSWindow
//! 窗口状态通知、MPNowPlayingInfoCenter + MPRemoteCommandCenter 媒体会话。
//! **仅交叉编译验证**（本机非 macOS，待真机验收）。

const std = @import("std");
const alloc = std.heap.c_allocator;
const core = @import("../core.zig");

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const Class = ?*anyopaque;

// libSystem
extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) Id;
extern "c" fn dlsym(handle: Id, sym: [*:0]const u8) ?*anyopaque;

const RTLD_NOW: c_int = 2;

var g_objc: Id = null;
var g_appkit: Id = null;
var g_media: Id = null;

var g_msgSend: ?*anyopaque = null;
var g_getClass: ?*const fn ([*:0]const u8) Class = null;
var g_sel: ?*const fn ([*:0]const u8) Sel = null;
var g_allocPair: ?*const fn (Class, [*:0]const u8, usize) Class = null;
var g_addMethod: ?*const fn (Class, Sel, *const anyopaque, [*:0]const u8) u8 = null;
var g_registerPair: ?*const fn (Class) void = null;

fn load() bool {
    if (g_msgSend != null) return true;
    g_objc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW) orelse return false;
    g_appkit = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW);
    g_media = dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_NOW);
    g_msgSend = dlsym(g_objc, "objc_msgSend");
    g_getClass = @ptrCast(@alignCast(dlsym(g_objc, "objc_getClass")));
    g_sel = @ptrCast(@alignCast(dlsym(g_objc, "sel_registerName")));
    g_allocPair = @ptrCast(@alignCast(dlsym(g_objc, "objc_allocateClassPair")));
    g_addMethod = @ptrCast(@alignCast(dlsym(g_objc, "class_addMethod")));
    g_registerPair = @ptrCast(@alignCast(dlsym(g_objc, "objc_registerClassPair")));
    return g_msgSend != null and g_getClass != null and g_sel != null;
}

fn cls(name: [*:0]const u8) Id {
    return g_getClass.?(name);
}
fn sel(name: [*:0]const u8) Sel {
    return g_sel.?(name);
}

// ── 消息发送（按 arity/参数类型逐一具型转换）──────────────────────
fn m0(t: Id, s: Sel) Id {
    const f: *const fn (Id, Sel) callconv(.c) Id = @ptrCast(@alignCast(g_msgSend.?));
    return f(t, s);
}
fn m1(t: Id, s: Sel, a: Id) Id {
    const f: *const fn (Id, Sel, Id) callconv(.c) Id = @ptrCast(@alignCast(g_msgSend.?));
    return f(t, s, a);
}
fn m2(t: Id, s: Sel, a: Id, b: Id) Id {
    const f: *const fn (Id, Sel, Id, Id) callconv(.c) Id = @ptrCast(@alignCast(g_msgSend.?));
    return f(t, s, a, b);
}
fn mOpt(t: Id, s: Sel, opts: u64, a: Id) Id {
    const f: *const fn (Id, Sel, u64, Id) callconv(.c) Id = @ptrCast(@alignCast(g_msgSend.?));
    return f(t, s, opts, a);
}
fn mD0(t: Id, s: Sel) f64 {
    const f: *const fn (Id, Sel) callconv(.c) f64 = @ptrCast(@alignCast(g_msgSend.?));
    return f(t, s);
}
fn mD(t: Id, s: Sel, d: f64) Id {
    const f: *const fn (Id, Sel, f64) callconv(.c) Id = @ptrCast(@alignCast(g_msgSend.?));
    return f(t, s, d);
}
fn v1(t: Id, s: Sel, a: Id) void {
    const f: *const fn (Id, Sel, Id) callconv(.c) void = @ptrCast(@alignCast(g_msgSend.?));
    f(t, s, a);
}
fn v2(t: Id, s: Sel, a: Id, b: Id) void {
    const f: *const fn (Id, Sel, Id, Id) callconv(.c) void = @ptrCast(@alignCast(g_msgSend.?));
    f(t, s, a, b);
}
fn v4(t: Id, s: Sel, a: Id, b: Id, c: Id, d: Id) void {
    const f: *const fn (Id, Sel, Id, Id, Id, Id) callconv(.c) void = @ptrCast(@alignCast(g_msgSend.?));
    f(t, s, a, b, c, d);
}

fn nsstr(z: [*:0]const u8) Id {
    return m1(cls("NSString"), sel("stringWithUTF8String:"), @ptrCast(@constCast(z)));
}
fn nsnum(d: f64) Id {
    return mD(cls("NSNumber"), sel("numberWithDouble:"), d);
}

/// 读框架导出的 `NSString * const` 符号（dlsym 得到指针变量，解引用）。
fn nsConst(handle: Id, name: [*:0]const u8) Id {
    if (handle == null) return null;
    const p = dlsym(handle, name) orelse return null;
    const pp: *const Id = @ptrCast(@alignCast(p));
    return pp.*;
}

// ── 观察者状态 ────────────────────────────────────────────────────

var g_screen_events = std.atomic.Value(bool).init(false);
var g_window_events = std.atomic.Value(bool).init(false);
var g_accent_events = std.atomic.Value(bool).init(false);
var g_minimized = std.atomic.Value(bool).init(false);
var g_focused = std.atomic.Value(bool).init(true);
var g_observer_cls: Class = null;
var g_observer: Id = null;

fn emitWindow() void {
    if (!g_window_events.load(.acquire)) return;
    core.dispatch(.{
        .type = core.EVENT_WINDOW_STATE,
        .u = .{ .window = .{
            .minimized = @intFromBool(g_minimized.load(.acquire)),
            .focused = @intFromBool(g_focused.load(.acquire)),
        } },
    });
}
fn emitScreen(active: bool) void {
    if (!g_screen_events.load(.acquire)) return;
    core.dispatch(.{ .type = core.EVENT_SCREEN_STATE, .u = .{ .active = @intFromBool(active) } });
}

fn onAccent(_: Id, _: Sel, _: Id) callconv(.c) void {
    if (!g_accent_events.load(.acquire)) return;
    core.dispatch(.{ .type = core.EVENT_SYSTEM_ACCENT, .u = .{ .active = 1 } });
}

fn onScreensSleep(_: Id, _: Sel, _: Id) callconv(.c) void {
    emitScreen(true);
}
fn onScreensWake(_: Id, _: Sel, _: Id) callconv(.c) void {
    emitScreen(false);
}
fn onMiniaturize(_: Id, _: Sel, _: Id) callconv(.c) void {
    g_minimized.store(true, .release);
    emitWindow();
}
fn onDeminiaturize(_: Id, _: Sel, _: Id) callconv(.c) void {
    g_minimized.store(false, .release);
    emitWindow();
}
fn onBecomeKey(_: Id, _: Sel, _: Id) callconv(.c) void {
    g_focused.store(true, .release);
    emitWindow();
}
fn onResignKey(_: Id, _: Sel, _: Id) callconv(.c) void {
    g_focused.store(false, .release);
    emitWindow();
}

fn mediaCmd(c: i32) void {
    core.dispatch(.{ .type = core.EVENT_MEDIA_COMMAND, .u = .{ .command = c } });
}
fn onPlay(_: Id, _: Sel, _: Id) callconv(.c) c_long {
    mediaCmd(core.CMD_PLAY);
    return 0;
}
fn onPause(_: Id, _: Sel, _: Id) callconv(.c) c_long {
    mediaCmd(core.CMD_PAUSE);
    return 0;
}
fn onToggle(_: Id, _: Sel, _: Id) callconv(.c) c_long {
    mediaCmd(core.CMD_TOGGLE);
    return 0;
}
fn onNext(_: Id, _: Sel, _: Id) callconv(.c) c_long {
    mediaCmd(core.CMD_NEXT);
    return 0;
}
fn onPrev(_: Id, _: Sel, _: Id) callconv(.c) c_long {
    mediaCmd(core.CMD_PREV);
    return 0;
}
fn onStop(_: Id, _: Sel, _: Id) callconv(.c) c_long {
    mediaCmd(core.CMD_STOP);
    return 0;
}
fn onSeek(_: Id, _: Sel, ev: Id) callconv(.c) c_long {
    if (ev != null) {
        const secs = mD0(ev, sel("positionTime"));
        const ms: i64 = @intFromFloat(secs * 1000.0);
        core.dispatch(.{ .type = core.EVENT_MEDIA_SEEK, .u = .{ .seek = .{ .rel_ms = 0, .abs_ms = ms } } });
    }
    return 0;
}

fn addMethod(c: Class, name: [*:0]const u8, imp: *const anyopaque, types: [*:0]const u8) void {
    _ = g_addMethod.?(c, sel(name), imp, types);
}

fn ensureObserver() Id {
    if (g_observer != null) return g_observer;
    if (g_allocPair == null or g_addMethod == null or g_registerPair == null) return null;
    const c = g_allocPair.?(cls("NSObject"), "ArchoeraPlatformObserver", 0) orelse return null;
    addMethod(c, "onScreensSleep:", @ptrCast(&onScreensSleep), "v@:@");
    addMethod(c, "onScreensWake:", @ptrCast(&onScreensWake), "v@:@");
    addMethod(c, "onMiniaturize:", @ptrCast(&onMiniaturize), "v@:@");
    addMethod(c, "onDeminiaturize:", @ptrCast(&onDeminiaturize), "v@:@");
    addMethod(c, "onBecomeKey:", @ptrCast(&onBecomeKey), "v@:@");
    addMethod(c, "onResignKey:", @ptrCast(&onResignKey), "v@:@");
    addMethod(c, "onPlay:", @ptrCast(&onPlay), "q@:@");
    addMethod(c, "onPause:", @ptrCast(&onPause), "q@:@");
    addMethod(c, "onToggle:", @ptrCast(&onToggle), "q@:@");
    addMethod(c, "onNext:", @ptrCast(&onNext), "q@:@");
    addMethod(c, "onPrev:", @ptrCast(&onPrev), "q@:@");
    addMethod(c, "onStop:", @ptrCast(&onStop), "q@:@");
    addMethod(c, "onSeek:", @ptrCast(&onSeek), "q@:@");
    addMethod(c, "onAccent:", @ptrCast(&onAccent), "v@:@");
    g_registerPair.?(c);
    g_observer_cls = c;
    g_observer = m0(c, sel("new"));
    return g_observer;
}

fn observe(center: Id, name: Id, handler: [*:0]const u8) void {
    const obs = ensureObserver();
    if (obs == null or center == null or name == null) return;
    v4(center, sel("addObserver:selector:name:object:"), obs, sel(handler), name, null);
}

// ── 抑制 ──────────────────────────────────────────────────────────

var g_activity: Id = null;

pub fn powerSetSleepInhibit(on: i32) i32 {
    if (!load()) return core.ERR_BACKEND;
    const pi = m0(cls("NSProcessInfo"), sel("processInfo"));
    if (pi == null) return core.ERR_BACKEND;
    if (on != 0) {
        if (g_activity != null) return core.OK;
        const reason = nsstr("ArchoeraMusic playback");
        // NSActivityUserInitiated（含 IdleSystemSleepDisabled）
        const act = mOpt(pi, sel("beginActivityWithOptions:reason:"), 0x00FFFFFF, reason);
        if (act == null) return core.ERR_BACKEND;
        g_activity = act;
        return core.OK;
    } else {
        if (g_activity) |a| {
            v1(pi, sel("endActivity:"), a);
            g_activity = null;
        }
        return core.OK;
    }
}

pub fn powerSetScreenEvents(on: i32) i32 {
    if (!load()) return core.ERR_BACKEND;
    if (on != 0) {
        const ws = m0(cls("NSWorkspace"), sel("sharedWorkspace"));
        const nc = m0(ws, sel("notificationCenter"));
        observe(nc, nsConst(g_appkit, "NSWorkspaceScreensDidSleepNotification"), "onScreensSleep:");
        observe(nc, nsConst(g_appkit, "NSWorkspaceScreensDidWakeNotification"), "onScreensWake:");
        g_screen_events.store(true, .release);
    } else {
        g_screen_events.store(false, .release);
    }
    return core.OK;
}

pub fn windowSetEvents(on: i32) i32 {
    if (!load()) return core.ERR_BACKEND;
    if (on != 0) {
        const nc = m0(cls("NSNotificationCenter"), sel("defaultCenter"));
        observe(nc, nsConst(g_appkit, "NSWindowDidMiniaturizeNotification"), "onMiniaturize:");
        observe(nc, nsConst(g_appkit, "NSWindowDidDeminiaturizeNotification"), "onDeminiaturize:");
        observe(nc, nsConst(g_appkit, "NSWindowDidBecomeKeyNotification"), "onBecomeKey:");
        observe(nc, nsConst(g_appkit, "NSWindowDidResignKeyNotification"), "onResignKey:");
        g_window_events.store(true, .release);
        emitWindow(); // 初值
    } else {
        g_window_events.store(false, .release);
    }
    return core.OK;
}

// ── 媒体会话 ──────────────────────────────────────────────────────

var g_playing: bool = false;
var g_position_ms: i64 = 0;
var g_duration_ms: i64 = -1;

pub fn mediaSetTrack(meta: ?*const core.TrackMeta) i32 {
    if (!load() or g_media == null) return core.ERR_BACKEND;
    const center = m0(cls("MPNowPlayingInfoCenter"), sel("defaultCenter"));
    if (center == null) return core.ERR_BACKEND;
    if (meta == null) {
        v1(center, sel("setNowPlayingInfo:"), null);
        return core.OK;
    }
    const m = meta.?;
    const dict = m0(cls("NSMutableDictionary"), sel("dictionary"));
    if (dict == null) return core.ERR_BACKEND;
    if (m.title.slice()) |t| {
        v2(dict, sel("setObject:forKey:"), nsstrC(t), nsConst(g_media, "MPMediaItemPropertyTitle"));
    }
    if (m.artist.slice()) |a| {
        v2(dict, sel("setObject:forKey:"), nsstrC(a), nsConst(g_media, "MPMediaItemPropertyArtist"));
    }
    if (m.album.slice()) |al| {
        v2(dict, sel("setObject:forKey:"), nsstrC(al), nsConst(g_media, "MPMediaItemPropertyAlbumTitle"));
    }
    if (m.art_url.slice()) |u| {
        const img = loadImage(u);
        if (img != null) {
            const art = m1(m0(cls("MPMediaItemArtwork"), sel("alloc")), sel("initWithImage:"), img);
            if (art != null) {
                v2(dict, sel("setObject:forKey:"), art, nsConst(g_media, "MPMediaItemPropertyArtwork"));
            }
        }
    }
    if (m.duration_ms > 0) {
        v2(dict, sel("setObject:forKey:"), nsnum(@as(f64, @floatFromInt(m.duration_ms)) / 1000.0), nsConst(g_media, "MPMediaItemPropertyPlaybackDuration"));
    }
    v1(center, sel("setNowPlayingInfo:"), dict);
    return core.OK;
}

pub fn mediaSetPlayback(state: i32, position_ms: i64, speed: f64, volume: f64, loop: i32, shuffle: i32) i32 {
    _ = .{ volume, loop, shuffle };
    if (!load() or g_media == null) return core.ERR_BACKEND;
    const center = m0(cls("MPNowPlayingInfoCenter"), sel("defaultCenter"));
    if (center == null) return core.ERR_BACKEND;
    g_playing = state == 1;
    g_position_ms = position_ms;
    // 更新现有 info 的进度/速率（保留曲目信息）
    const info = m0(center, sel("nowPlayingInfo"));
    if (info != null) {
        v2(info, sel("setObject:forKey:"), nsnum(@as(f64, @floatFromInt(position_ms)) / 1000.0), nsConst(g_media, "MPNowPlayingInfoPropertyElapsedPlaybackTime"));
        v2(info, sel("setObject:forKey:"), nsnum(speed), nsConst(g_media, "MPNowPlayingInfoPropertyPlaybackRate"));
        v1(center, sel("setNowPlayingInfo:"), info);
    }
    return core.OK;
}

pub fn mediaSetWindow(w: i64) i32 {
    _ = w;
    return core.OK;
}

/// 注册远程命令目标（首帧时调用一次）。
fn ensureRemoteCommands() void {
    if (g_media == null) return;
    const cc = m0(cls("MPRemoteCommandCenter"), sel("sharedCommandCenter"));
    const obs = ensureObserver();
    if (cc == null or obs == null) return;
    const pairs = [_]struct { cmd: [*:0]const u8, handler: [*:0]const u8 }{
        .{ .cmd = "playCommand", .handler = "onPlay:" },
        .{ .cmd = "pauseCommand", .handler = "onPause:" },
        .{ .cmd = "togglePlayPauseCommand", .handler = "onToggle:" },
        .{ .cmd = "nextTrackCommand", .handler = "onNext:" },
        .{ .cmd = "previousTrackCommand", .handler = "onPrev:" },
        .{ .cmd = "stopCommand", .handler = "onStop:" },
        .{ .cmd = "changePlaybackPositionCommand", .handler = "onSeek:" },
    };
    for (pairs) |p| {
        const command = m0(cc, sel(p.cmd));
        if (command != null) _ = m2(command, sel("addTarget:action:"), obs, sel(p.handler));
    }
}

/// 从 http(s) URL 或本地路径加载 NSImage（失败返回 null）。
fn loadImage(url: []const u8) Id {
    var buf: [1024]u8 = undefined;
    const n = @min(url.len, buf.len - 1);
    @memcpy(buf[0..n], url[0..n]);
    buf[n] = 0;
    const z: [*:0]const u8 = @ptrCast(&buf);
    const nsurl = if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://"))
        m1(cls("NSURL"), sel("URLWithString:"), nsstr(z))
    else
        m1(cls("NSURL"), sel("fileURLWithPath:"), nsstr(z));
    if (nsurl == null) return null;
    return m1(m0(cls("NSImage"), sel("alloc")), sel("initWithContentsOfURL:"), nsurl);
}

fn nsstrC(s: []const u8) Id {
    var buf: [512]u8 = undefined;
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return nsstr(@ptrCast(&buf));
}

// ── 后端接口 ──────────────────────────────────────────────────────

pub fn caps() u32 {
    return core.CAP_POWER_INHIBIT | core.CAP_POWER_SCREEN_STATE | core.CAP_WINDOW_STATE |
        core.CAP_MEDIA_SESSION | core.CAP_APP_INSTANCE | core.CAP_SYSTEM_ACCENT;
}

pub fn init() i32 {
    if (!load()) return core.OK; // 非 macOS 运行环境不应到此；失败不致命
    ensureRemoteCommands();
    return core.OK;
}

pub fn shutdown() i32 {
    if (g_activity) |a| {
        const pi = m0(cls("NSProcessInfo"), sel("processInfo"));
        if (pi != null) v1(pi, sel("endActivity:"), a);
        g_activity = null;
    }
    g_screen_events.store(false, .release);
    g_window_events.store(false, .release);
    return core.OK;
}


// ── 单实例（文件锁）────────────────────────────────────────────────

var g_instance_fd: std.posix.fd_t = -1;

/// 1=首实例（持有锁至进程退出）；0=已有实例；<0=错误。
pub fn appInstanceAcquire() i32 {
    if (g_instance_fd >= 0) return 1; // 幂等
    const dir = if (std.c.getenv("XDG_RUNTIME_DIR")) |p| std.mem.span(p) else "/tmp";
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/archoera_music.lock", .{dir}) catch
        return core.ERR_BACKEND;
    const flags = std.posix.O{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path, flags, 0o600) catch
        return core.ERR_BACKEND;
    const rc = std.c.flock(fd, 2 | 4); // LOCK_EX | LOCK_NB
    if (rc != 0) {
        _ = std.c.close(fd);
        return 0; // 已被其它实例持有
    }
    g_instance_fd = fd;
    return 1;
}


// ── 系统提示（osascript 弹窗）──────────────────────────────────────
pub fn notify(title: []const u8, body: []const u8) i32 {
    const script = std.fmt.allocPrint(alloc,
        "display notification \"{s}\" with title \"{s}\"",
        .{ body, title }) catch return core.ERR_BACKEND;
    defer alloc.free(script);
    const argv = [_][]const u8{ "osascript", "-e", script };
    const io = std.Io.Threaded.global_single_threaded.io();
    const r = std.process.run(alloc, io, .{ .argv = &argv }) catch return core.ERR_BACKEND;
    alloc.free(r.stdout);
    alloc.free(r.stderr);
    return core.OK;
}

// ── 系统主题色：NSColor.controlAccentColor（10.14+）→ sRGB 分量 ──
// 经运行时 objc_msgSend 直调（无 SDK 头）；非 RGB 色彩空间先转 sRGB。
pub fn systemAccent() ?[3]u8 {
    if (!load() or g_appkit == null) return null;
    const NSColor = cls("NSColor");
    if (NSColor == null) return null;
    const cs = sel("controlAccentColor");
    {
        const responds: *const fn (Id, Sel, Sel) callconv(.c) i8 = @ptrCast(@alignCast(g_msgSend.?));
        if (responds(NSColor, sel("respondsToSelector:"), cs) == 0) return null;
    }
    const color = m0(NSColor, cs);
    if (color == null) return null;
    const srgb = m1(color, sel("colorUsingColorSpace:"), m0(cls("NSColorSpace"), sel("sRGBColorSpace")));
    const use = if (srgb != null) srgb else color;
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    var a: f64 = 0;
    const f: *const fn (Id, Sel, *f64, *f64, *f64, *f64) callconv(.c) void = @ptrCast(@alignCast(g_msgSend.?));
    f(use, sel("getRed:green:blue:alpha:"), &r, &g, &b, &a);
    if (a <= 0.0 and r == 0.0 and g == 0.0 and b == 0.0) return null;
    return .{ toU8(r), toU8(g), toU8(b) };
}

fn toU8(x: f64) u8 {
    const v = x * 255.0 + 0.5;
    if (v <= 0.0) return 0;
    if (v >= 255.0) return 255;
    return @intFromFloat(v);
}

pub fn systemAccentSetEvents(on: i32) i32 {
    if (!load()) return core.ERR_BACKEND;
    if (on != 0) {
        g_accent_events.store(true, .release);
        // 分布式通知：外观/强调色偏好变更（跨进程）
        const dnc = m0(cls("NSDistributedNotificationCenter"), sel("defaultCenter"));
        observe(dnc, nsstr("AppleColorPreferencesChangedNotification"), "onAccent:");
        // 本地：系统颜色变更（强调色）
        const nc = m0(cls("NSNotificationCenter"), sel("defaultCenter"));
        observe(nc, nsConst(g_appkit, "NSSystemColorsDidChangeNotification"), "onAccent:");
    } else {
        g_accent_events.store(false, .release);
    }
    return core.OK;
}
