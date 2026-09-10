// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! MPRIS2 服务端（Linux 媒体会话，P2）：把 OS 媒体键 / 蓝牙耳机 AVRCP /
//! 桌面媒体面板的请求转成 apl 事件交 Dart（bridge §4.1）。
//!
//! 导出：`org.mpris.MediaPlayer2.archoera` @ `/org/mpris/MediaPlayer2`
//!   - `org.mpris.MediaPlayer2`（Root）：Raise/Quit + 静态属性
//!   - `org.mpris.MediaPlayer2.Player`：Play/Pause/Next/... + 播放属性
//!   - `org.freedesktop.DBus.Properties`：Get/GetAll/Set
//!   - `org.freedesktop.DBus.Introspectable`：Introspect（最小 XML）
//!
//! 并发：Dart 线程调 setTrack/setPlayback，泵线程处理方法调用；状态经自旋锁
//! 保护。字符串元数据在 setTrack 内深拷贝（Dart 侧缓冲仅调用期有效）。

const std = @import("std");
const core = @import("../core.zig");
const message = @import("../dbus/message.zig");
const transport = @import("../dbus/transport.zig");

const alloc = std.heap.c_allocator;

const OBJECT_PATH = "/org/mpris/MediaPlayer2";
const IFACE_ROOT = "org.mpris.MediaPlayer2";
const IFACE_PLAYER = "org.mpris.MediaPlayer2.Player";
const IFACE_PROPS = "org.freedesktop.DBus.Properties";
const IFACE_INTROSPECT = "org.freedesktop.DBus.Introspectable";

var g_lock = std.atomic.Value(bool).init(false);

fn lock() void {
    while (g_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}
fn unlock() void {
    g_lock.store(false, .release);
}

// ── 状态 ──────────────────────────────────────────────────────────

var g_service: []const u8 = "org.mpris.MediaPlayer2.archoera";
var g_owned: [64]u8 = undefined; // 服务名后备缓冲（instance 形态）
var g_conn: ?*transport.Connection = null;

const PlayState = enum(i32) { stopped = 0, playing = 1, paused = 2 };
var g_state: PlayState = .stopped;
var g_loop: i32 = 0; // 0=list(Playlist) 1=one(Track)
var g_shuffle: bool = false;
var g_volume: f64 = 1.0;
var g_position_ms: i64 = 0;
var g_position_base: u64 = 0; // 位置基准单调毫秒（playing 时外推）
var g_rate: f64 = 1.0;

var g_track_serial: u32 = 0;
var g_title: []u8 = &.{};
var g_artist: []u8 = &.{};
var g_album: []u8 = &.{};
var g_art: []u8 = &.{};
var g_duration_ms: i64 = -1;

// ── 名称申请 / 生命周期 ───────────────────────────────────────────

/// 申请 MPRIS 服务名（被占则追加 .instance<pid>）；成功返回 true。
pub fn init(conn: *transport.Connection) bool {
    lock();
    g_conn = conn;
    unlock();

    if (tryRequest(conn, "org.mpris.MediaPlayer2.archoera")) return true;
    const pid = std.os.linux.getpid();
    const name = std.fmt.bufPrint(&g_owned, "org.mpris.MediaPlayer2.archoera.instance{d}", .{pid}) catch
        return false;
    if (tryRequest(conn, name)) {
        lock();
        g_service = g_owned[0..name.len];
        unlock();
        return true;
    }
    return false;
}

fn tryRequest(conn: *transport.Connection, name: []const u8) bool {
    const args = [_]message.Value{
        .{ .string = name },
        .{ .u32_ = 0 }, // flags：不排他（可替换）
    };
    const r = conn.call(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "RequestName",
        "su",
        &args,
        3_000,
    ) catch return false;
    defer r.deinit();
    if (!r.ok or r.values.len != 1) return false;
    const reply = r.values[0].u32_;
    return reply == 1 or reply == 4; // primaryOwner / alreadyOwner
}

/// 连接断连时清空绑定（下次 ensureConn 重新 init）。
pub fn detach() void {
    lock();
    g_conn = null;
    unlock();
}

// ── Dart 侧状态更新（backend 调用）───────────────────────────────

pub fn setTrack(meta: ?*const core.TrackMeta) void {
    lock();
    freeStr(&g_title);
    freeStr(&g_artist);
    freeStr(&g_album);
    freeStr(&g_art);
    g_track_serial +%= 1;
    g_duration_ms = -1;
    if (meta) |m| {
        g_title = dupeOrEmpty(m.title.slice());
        g_artist = dupeOrEmpty(m.artist.slice());
        g_album = dupeOrEmpty(m.album.slice());
        g_art = dupeOrEmpty(m.art_url.slice());
        g_duration_ms = m.duration_ms;
        g_position_ms = 0;
        g_position_base = transport.nowMs();
    }
    const conn = g_conn;
    unlock();
    if (conn) |c| emitChanged(c, &.{"Metadata"});
}

pub fn setPlayback(state: i32, position_ms: i64, speed: f64, volume: f64, loop: i32, shuffle: i32) void {
    lock();
    const old_state = g_state;
    g_state = @enumFromInt(@as(i32, @intCast(@mod(state, 3))));
    g_position_ms = position_ms;
    g_position_base = transport.nowMs();
    g_rate = speed;
    g_volume = volume;
    g_loop = loop;
    g_shuffle = shuffle != 0;
    const conn = g_conn;
    unlock();

    var changed: [6][]const u8 = undefined;
    var n: usize = 0;
    if (old_state != @as(PlayState, @enumFromInt(@as(i32, @intCast(@mod(state, 3)))))) {
        changed[n] = "PlaybackStatus";
        n += 1;
    }
    changed[n] = "Position";
    n += 1;
    changed[n] = "Volume";
    n += 1;
    changed[n] = "LoopStatus";
    n += 1;
    changed[n] = "Shuffle";
    n += 1;
    if (conn) |c| emitChanged(c, changed[0..n]);
}

fn dupeOrEmpty(s: ?[]const u8) []u8 {
    const src = s orelse return alloc.dupe(u8, "") catch &.{};
    return alloc.dupe(u8, src) catch &.{};
}

fn freeStr(s: *[]u8) void {
    if (s.len > 0) alloc.free(s.*);
    s.* = &.{};
}

fn currentPositionMs() i64 {
    lock();
    const st = g_state;
    const base = g_position_base;
    const pos = g_position_ms;
    unlock();
    if (st == .playing) {
        return pos + @as(i64, @intCast(transport.nowMs() -| base));
    }
    return pos;
}

// ── 方法调用分发（泵线程）─────────────────────────────────────────

pub fn handleMethodCall(conn: *transport.Connection, h: *const message.Header, body: []const u8) void {
    const iface = h.interface orelse return replyError(conn, h, "org.freedesktop.DBus.Error.UnknownInterface", "");
    const member = h.member orelse return replyError(conn, h, "org.freedesktop.DBus.Error.UnknownMethod", "");

    if (std.mem.eql(u8, iface, IFACE_PROPS)) {
        if (std.mem.eql(u8, member, "Get")) return propGet(conn, h, body);
        if (std.mem.eql(u8, member, "GetAll")) return propGetAll(conn, h, body);
        if (std.mem.eql(u8, member, "Set")) return propSet(conn, h, body);
        return replyError(conn, h, "org.freedesktop.DBus.Error.UnknownMethod", member);
    }
    if (std.mem.eql(u8, iface, IFACE_INTROSPECT)) {
        return replyString(conn, h, INTROSPECT_XML);
    }
    if (std.mem.eql(u8, iface, IFACE_ROOT)) {
        if (std.mem.eql(u8, member, "Raise")) return replyEmpty(conn, h);
        if (std.mem.eql(u8, member, "Quit")) {
            core.dispatch(.{ .type = core.EVENT_MEDIA_COMMAND, .u = .{ .command = core.CMD_STOP } });
            return replyEmpty(conn, h);
        }
        return replyError(conn, h, "org.freedesktop.DBus.Error.UnknownMethod", member);
    }
    if (std.mem.eql(u8, iface, IFACE_PLAYER)) {
        return playerMethod(conn, h, body, member);
    }
    return replyError(conn, h, "org.freedesktop.DBus.Error.UnknownInterface", iface);
}

fn playerMethod(conn: *transport.Connection, h: *const message.Header, body: []const u8, member: []const u8) void {
    if (std.mem.eql(u8, member, "Play")) return cmd(conn, h, core.CMD_PLAY);
    if (std.mem.eql(u8, member, "Pause")) return cmd(conn, h, core.CMD_PAUSE);
    if (std.mem.eql(u8, member, "PlayPause")) return cmd(conn, h, core.CMD_TOGGLE);
    if (std.mem.eql(u8, member, "Stop")) return cmd(conn, h, core.CMD_STOP);
    if (std.mem.eql(u8, member, "Next")) return cmd(conn, h, core.CMD_NEXT);
    if (std.mem.eql(u8, member, "Previous")) return cmd(conn, h, core.CMD_PREV);
    if (std.mem.eql(u8, member, "Seek")) {
        // Seek(x offset_us)：相对位移
        const vals = message.readBody(alloc, "x", body) catch
            return replyError(conn, h, "org.freedesktop.DBus.Error.InvalidArgs", "Seek");
        defer message.freeValues(alloc, vals);
        if (vals.len == 1) {
            core.dispatch(.{ .type = core.EVENT_MEDIA_SEEK, .u = .{ .seek = .{ .rel_ms = @divTrunc(vals[0].i64_, 1000), .abs_ms = 0 } } });
        }
        return replyEmpty(conn, h);
    }
    if (std.mem.eql(u8, member, "SetPosition")) {
        // SetPosition(o trackid, x pos_us)：绝对位置
        const vals = message.readBody(alloc, "ox", body) catch
            return replyError(conn, h, "org.freedesktop.DBus.Error.InvalidArgs", "SetPosition");
        defer message.freeValues(alloc, vals);
        if (vals.len == 2) {
            core.dispatch(.{ .type = core.EVENT_MEDIA_SEEK, .u = .{ .seek = .{ .rel_ms = 0, .abs_ms = @divTrunc(vals[1].i64_, 1000) } } });
        }
        return replyEmpty(conn, h);
    }
    if (std.mem.eql(u8, member, "OpenUri")) return replyEmpty(conn, h);
    return replyError(conn, h, "org.freedesktop.DBus.Error.UnknownMethod", member);
}

fn cmd(conn: *transport.Connection, h: *const message.Header, command: i32) void {
    core.dispatch(.{ .type = core.EVENT_MEDIA_COMMAND, .u = .{ .command = command } });
    replyEmpty(conn, h);
}

// ── 属性 ──────────────────────────────────────────────────────────

fn propGet(conn: *transport.Connection, h: *const message.Header, body: []const u8) void {
    const vals = message.readBody(alloc, "ss", body) catch
        return replyError(conn, h, "org.freedesktop.DBus.Error.InvalidArgs", "Get");
    defer message.freeValues(alloc, vals);
    if (vals.len != 2) return replyError(conn, h, "org.freedesktop.DBus.Error.InvalidArgs", "Get");
    const iface = vals[0].string;
    const name = vals[1].string;
    const sig = propSig(iface, name) orelse
        return replyError(conn, h, "org.freedesktop.DBus.Error.UnknownProperty", name);

    var b = message.MessageBuilder.init(alloc, message.MSG_METHOD_RETURN, conn.nextSerial());
    defer b.deinit();
    b.fieldReplySerial(h.serial) catch return;
    if (h.sender) |s| b.fieldDestination(s) catch return;
    b.fieldSignature("v") catch return;
    b.body.putVariantSig(sig) catch return;
    writePropValue(&b.body, iface, name) catch return;
    conn.sendOneWay(&b) catch {};
}

fn propGetAll(conn: *transport.Connection, h: *const message.Header, body: []const u8) void {
    const vals = message.readBody(alloc, "s", body) catch
        return replyError(conn, h, "org.freedesktop.DBus.Error.InvalidArgs", "GetAll");
    defer message.freeValues(alloc, vals);
    if (vals.len != 1) return replyError(conn, h, "org.freedesktop.DBus.Error.InvalidArgs", "GetAll");
    const iface = vals[0].string;

    var b = message.MessageBuilder.init(alloc, message.MSG_METHOD_RETURN, conn.nextSerial());
    defer b.deinit();
    b.fieldReplySerial(h.serial) catch return;
    if (h.sender) |s| b.fieldDestination(s) catch return;
    b.fieldSignature("a{sv}") catch return;

    const names: []const []const u8 = if (std.mem.eql(u8, iface, IFACE_PLAYER))
        &PLAYER_PROPS
    else if (std.mem.eql(u8, iface, IFACE_ROOT))
        &ROOT_PROPS
    else
        return replyError(conn, h, "org.freedesktop.DBus.Error.UnknownInterface", iface);

    const mark = b.body.beginArray(8) catch return;
    for (names) |n| {
        const sig = propSig(iface, n) orelse continue;
        b.body.putDictSvKey(n, sig) catch return;
        writePropValue(&b.body, iface, n) catch return;
    }
    b.body.endArray(mark) catch return;
    conn.sendOneWay(&b) catch {};
}

fn propSet(conn: *transport.Connection, h: *const message.Header, body: []const u8) void {
    const vals = message.readBody(alloc, "ssv", body) catch
        return replyError(conn, h, "org.freedesktop.DBus.Error.InvalidArgs", "Set");
    defer message.freeValues(alloc, vals);
    if (vals.len != 3) return replyError(conn, h, "org.freedesktop.DBus.Error.InvalidArgs", "Set");
    const name = vals[1].string;
    const inner = vals[2].variant;
    lock();
    if (std.mem.eql(u8, name, "Volume")) {
        if (inner.* == .f64_) g_volume = inner.f64_;
    } else if (std.mem.eql(u8, name, "LoopStatus")) {
        if (inner.* == .string) {
            if (std.mem.eql(u8, inner.string, "Track")) g_loop = 1 else if (std.mem.eql(u8, inner.string, "None")) g_loop = 0 else g_loop = 0;
        }
    } else if (std.mem.eql(u8, name, "Shuffle")) {
        if (inner.* == .boolean) g_shuffle = inner.boolean;
    } else {
        unlock();
        return replyError(conn, h, "org.freedesktop.DBus.Error.PropertyReadOnly", name);
    }
    unlock();
    replyEmpty(conn, h);
}

const PLAYER_PROPS = [_][]const u8{
    "PlaybackStatus", "LoopStatus", "Rate", "Shuffle", "Metadata", "Volume", "Position",
    "MinimumRate", "MaximumRate", "CanGoNext", "CanGoPrevious", "CanPlay", "CanPause", "CanSeek", "CanControl",
};
const ROOT_PROPS = [_][]const u8{
    "CanQuit", "CanRaise", "HasTrackList", "Identity", "DesktopEntry", "SupportedUriSchemes", "SupportedMimeTypes",
};

fn propSig(iface: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, iface, IFACE_ROOT)) {
        if (std.mem.eql(u8, name, "CanQuit") or std.mem.eql(u8, name, "CanRaise") or std.mem.eql(u8, name, "HasTrackList")) return "b";
        if (std.mem.eql(u8, name, "Identity") or std.mem.eql(u8, name, "DesktopEntry")) return "s";
        if (std.mem.eql(u8, name, "SupportedUriSchemes") or std.mem.eql(u8, name, "SupportedMimeTypes")) return "as";
        return null;
    }
    if (std.mem.eql(u8, iface, IFACE_PLAYER)) {
        if (std.mem.eql(u8, name, "PlaybackStatus") or std.mem.eql(u8, name, "LoopStatus")) return "s";
        if (std.mem.eql(u8, name, "Rate") or std.mem.eql(u8, name, "Volume") or std.mem.eql(u8, name, "MinimumRate") or std.mem.eql(u8, name, "MaximumRate")) return "d";
        if (std.mem.eql(u8, name, "Shuffle") or std.mem.eql(u8, name, "CanGoNext") or std.mem.eql(u8, name, "CanGoPrevious") or std.mem.eql(u8, name, "CanPlay") or std.mem.eql(u8, name, "CanPause") or std.mem.eql(u8, name, "CanSeek") or std.mem.eql(u8, name, "CanControl")) return "b";
        if (std.mem.eql(u8, name, "Metadata")) return "a{sv}";
        if (std.mem.eql(u8, name, "Position")) return "x";
        return null;
    }
    return null;
}

fn writePropValue(w: *message.Writer, iface: []const u8, name: []const u8) message.Error!void {
    if (std.mem.eql(u8, iface, IFACE_ROOT)) {
        if (std.mem.eql(u8, name, "CanQuit")) return w.putBool(false);
        if (std.mem.eql(u8, name, "CanRaise")) return w.putBool(true);
        if (std.mem.eql(u8, name, "HasTrackList")) return w.putBool(false);
        if (std.mem.eql(u8, name, "Identity")) return w.putString("ArchoeraMusic");
        if (std.mem.eql(u8, name, "DesktopEntry")) return w.putString("awa.archoera.betastudio2.archoera_music");
        if (std.mem.eql(u8, name, "SupportedUriSchemes") or std.mem.eql(u8, name, "SupportedMimeTypes")) {
            const m = try w.beginArray(4);
            return w.endArray(m);
        }
    }
    // Player
    if (std.mem.eql(u8, name, "PlaybackStatus")) {
        lock();
        const s = g_state;
        unlock();
        return w.putString(switch (s) {
            .playing => "Playing",
            .paused => "Paused",
            .stopped => "Stopped",
        });
    }
    if (std.mem.eql(u8, name, "LoopStatus")) {
        lock();
        const l = g_loop;
        unlock();
        return w.putString(if (l == 1) "Track" else "Playlist");
    }
    if (std.mem.eql(u8, name, "Rate") or std.mem.eql(u8, name, "MinimumRate") or std.mem.eql(u8, name, "MaximumRate")) {
        return w.putF64(1.0);
    }
    if (std.mem.eql(u8, name, "Shuffle")) {
        lock();
        const sh = g_shuffle;
        unlock();
        return w.putBool(sh);
    }
    if (std.mem.eql(u8, name, "Volume")) {
        lock();
        const v = g_volume;
        unlock();
        return w.putF64(v);
    }
    if (std.mem.eql(u8, name, "Position")) {
        return w.putI64(currentPositionMs() * 1000); // 微秒
    }
    if (std.mem.eql(u8, name, "Metadata")) {
        return writeMetadata(w);
    }
    // Can*：首期恒真（bridge §9 决策：命令落空由 Dart 忽略）
    return w.putBool(true);
}

fn writeMetadata(w: *message.Writer) message.Error!void {
    lock();
    const title = g_title;
    const artist = g_artist;
    const album = g_album;
    const art = g_art;
    const dur = g_duration_ms;
    const serial = g_track_serial;
    unlock();

    var idbuf: [64]u8 = undefined;
    const trackid = std.fmt.bufPrint(&idbuf, "/org/mpris/MediaPlayer2/Track/{d}", .{serial}) catch
        "/org/mpris/MediaPlayer2/Track/0";

    const mark = try w.beginArray(8);
    try w.putDictSvKey("mpris:trackid", "o");
    try w.putString(trackid);
    if (dur > 0) {
        try w.putDictSvKey("mpris:length", "x");
        try w.putI64(dur * 1000); // 微秒
    }
    if (title.len > 0) {
        try w.putDictSvKey("xesam:title", "s");
        try w.putString(title);
    }
    if (artist.len > 0) {
        try w.putDictSvKey("xesam:artist", "as");
        const am = try w.beginArray(4);
        try w.putString(artist);
        try w.endArray(am);
    }
    if (album.len > 0) {
        try w.putDictSvKey("xesam:album", "s");
        try w.putString(album);
    }
    if (art.len > 0) {
        try w.putDictSvKey("mpris:artUrl", "s");
        try w.putString(art);
    }
    try w.endArray(mark);
}

// ── PropertiesChanged 推送 ────────────────────────────────────────

fn emitChanged(conn: *transport.Connection, changed: []const []const u8) void {
    var b = message.MessageBuilder.init(alloc, message.MSG_SIGNAL, conn.nextSerial());
    defer b.deinit();
    b.fieldPath(OBJECT_PATH) catch return;
    b.fieldInterface(IFACE_PROPS) catch return;
    b.fieldMember("PropertiesChanged") catch return;
    b.fieldSignature("sa{sv}as") catch return;
    b.body.putString(IFACE_PLAYER) catch return;
    const mark = b.body.beginArray(8) catch return;
    for (changed) |n| {
        const sig = propSig(IFACE_PLAYER, n) orelse continue;
        b.body.putDictSvKey(n, sig) catch return;
        writePropValue(&b.body, IFACE_PLAYER, n) catch return;
    }
    b.body.endArray(mark) catch return;
    const inv = b.body.beginArray(4) catch return;
    b.body.endArray(inv) catch return;
    conn.sendOneWay(&b) catch {};
}

// ── 回复助手 ──────────────────────────────────────────────────────

fn replyEmpty(conn: *transport.Connection, h: *const message.Header) void {
    var b = message.MessageBuilder.init(alloc, message.MSG_METHOD_RETURN, conn.nextSerial());
    defer b.deinit();
    b.fieldReplySerial(h.serial) catch return;
    if (h.sender) |s| b.fieldDestination(s) catch return;
    conn.sendOneWay(&b) catch {};
}

fn replyString(conn: *transport.Connection, h: *const message.Header, s: []const u8) void {
    var b = message.MessageBuilder.init(alloc, message.MSG_METHOD_RETURN, conn.nextSerial());
    defer b.deinit();
    b.fieldReplySerial(h.serial) catch return;
    if (h.sender) |d| b.fieldDestination(d) catch return;
    b.fieldSignature("s") catch return;
    b.body.putString(s) catch return;
    conn.sendOneWay(&b) catch {};
}

fn replyError(conn: *transport.Connection, h: *const message.Header, err: []const u8, msg: []const u8) void {
    var b = message.MessageBuilder.init(alloc, message.MSG_ERROR, conn.nextSerial());
    defer b.deinit();
    b.fieldErrorName(err) catch return;
    b.fieldReplySerial(h.serial) catch return;
    if (h.sender) |s| b.fieldDestination(s) catch return;
    b.fieldSignature("s") catch return;
    b.body.putString(msg) catch return;
    conn.sendOneWay(&b) catch {};
}

const INTROSPECT_XML =
    "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\" " ++
    "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">" ++
    "<node><interface name=\"org.mpris.MediaPlayer2.Player\">" ++
    "<method name=\"Play\"/><method name=\"Pause\"/><method name=\"PlayPause\"/>" ++
    "<method name=\"Stop\"/><method name=\"Next\"/><method name=\"Previous\"/>" ++
    "<method name=\"Seek\"><arg direction=\"in\" type=\"x\"/></method>" ++
    "<method name=\"SetPosition\"><arg direction=\"in\" type=\"o\"/><arg direction=\"in\" type=\"x\"/></method>" ++
    "</interface><interface name=\"org.mpris.MediaPlayer2\">" ++
    "<method name=\"Raise\"/><method name=\"Quit\"/></interface></node>";

// ── 单测：属性签名与元数据编组 ────────────────────────────────────

const t = std.testing;

test "propSig covers key player props" {
    try t.expectEqualStrings("s", propSig(IFACE_PLAYER, "PlaybackStatus").?);
    try t.expectEqualStrings("a{sv}", propSig(IFACE_PLAYER, "Metadata").?);
    try t.expectEqualStrings("x", propSig(IFACE_PLAYER, "Position").?);
    try t.expectEqualStrings("b", propSig(IFACE_ROOT, "CanRaise").?);
    try t.expect(propSig(IFACE_PLAYER, "Nope") == null);
}

test "metadata marshals to a{sv}" {
    lock();
    g_title = alloc.dupe(u8, "T") catch unreachable;
    g_artist = alloc.dupe(u8, "A") catch unreachable;
    g_album = &.{};
    g_art = &.{};
    g_duration_ms = 1000;
    g_track_serial = 7;
    unlock();

    var w = message.Writer.init(t.allocator);
    defer w.deinit();
    try writeMetadata(&w);

    // page_allocator：解析树含指针，测试不追踪泄漏
    const v = try message.readBody(std.heap.page_allocator, "a{sv}", w.slice());
    try t.expectEqual(@as(usize, 1), v.len);
    try t.expect(v[0].array.len >= 3); // trackid + length + title + artist

    // 清理测试状态
    lock();
    freeStr(&g_title);
    freeStr(&g_artist);
    g_duration_ms = -1;
    unlock();
}

// ── live 端到端：真实总线上的 MPRIS 服务 ──────────────────────────

var g_live_commands: u32 = 0;

fn liveCoreCb(event: *const core.Event, user: ?*anyopaque) callconv(.c) void {
    _ = user;
    if (event.type == core.EVENT_MEDIA_COMMAND) g_live_commands += 1;
}

fn liveMethodCall(ctx: *anyopaque, conn: *transport.Connection, h: *const message.Header, body: []const u8) void {
    _ = ctx;
    handleMethodCall(conn, h, body);
}
fn liveNoop(ctx: *anyopaque, conn: *transport.Connection, h: *const message.Header, body: []const u8) void {
    _ = .{ ctx, conn, h, body };
}

var g_pump_conn: ?*transport.Connection = null;
var g_pump_run = std.atomic.Value(bool).init(false);

fn pumpThread() void {
    while (g_pump_run.load(.acquire)) {
        if (g_pump_conn) |c| _ = c.pump();
        transport.sleepMs(5);
    }
}

test "live: mpris service responds to GetAll and Play" {
    const a = t.allocator;
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return;

    var server = try transport.Connection.connectSession(a);
    defer server.deinit();
    const handler = transport.Handler{
        .ctx = @ptrFromInt(1),
        .onSignalFn = liveNoop,
        .onMethodCallFn = liveMethodCall,
    };
    server.handler = &handler;
    _ = init(&server);
    g_conn = &server;

    g_live_commands = 0;
    core.setEventCallback(liveCoreCb, null);
    defer core.setEventCallback(null, null);

    g_pump_conn = &server;
    g_pump_run.store(true, .release);
    const th = try std.Thread.spawn(.{}, pumpThread, .{});
    defer {
        g_pump_run.store(false, .release);
        th.join();
        g_pump_conn = null;
    }

    var client = try transport.Connection.connectSession(a);
    defer client.deinit();

    // GetAll(Player) → a{sv}
    const svc = g_service;
    const ga_args = [_]message.Value{.{ .string = IFACE_PLAYER }};
    const ga = try client.call(svc, OBJECT_PATH, IFACE_PROPS, "GetAll", "s", &ga_args, 3_000);
    defer ga.deinit();
    try t.expect(ga.ok);
    try t.expectEqual(@as(usize, 1), ga.values.len);
    try t.expect(ga.values[0].array.len >= 14); // Player 全属性

    // Play → 服务端 dispatch MEDIA_COMMAND
    const p = try client.call(svc, OBJECT_PATH, IFACE_PLAYER, "Play", "", &.{}, 3_000);
    defer p.deinit();
    try t.expect(p.ok);

    var i: u32 = 0;
    while (i < 100 and g_live_commands == 0) : (i += 1) transport.sleepMs(5);
    try t.expect(g_live_commands >= 1);

    detach();
    g_conn = null;
}
