// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Linux 窗口状态（P5）：经 GTK/GDK 探测最小化/失焦。
//!
//! 为何用 GTK 而非纯 X11：Flutter Linux 嵌入层本身是 GTK，GDK 已抽象
//! X11/Wayland 两种会话；用应用自己的 GtkWindow 探测**同时覆盖两者**，
//! 避免 Wayland 会话回退 window_manager（bridge §7.1 决策）。
//!
//! 无头依赖：`dlopen` libgtk-3/libgdk-3/libglib-2.0，符号运行时解析；不
//! `@cImport` GTK 头、不链 GTK（Zig 交叉编译友好）。GTK 调用经
//! `g_main_context_invoke` 汇入 GTK 主线程；状态用 `g_timeout_add` 轻轮询
//! （500ms，窗口状态低频，开销可忽略），变化才派发事件。

const std = @import("std");
const core = @import("../core.zig");

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, sym: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

const GList = extern struct { data: ?*anyopaque, next: ?*GList, prev: ?*GList };

// GdkWindowState
const GDK_WINDOW_STATE_ICONIFIED: c_int = 1 << 1;

// glib
var g_main_context_default: *const fn () callconv(.c) ?*anyopaque = undefined;
var g_main_context_invoke: *const fn (?*anyopaque, *const fn (?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) void = undefined;
var g_timeout_add: *const fn (u32, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) callconv(.c) u32 = undefined;
var g_source_remove: *const fn (u32) callconv(.c) c_int = undefined;

// gtk
var gtk_window_list_toplevels: *const fn () callconv(.c) ?*GList = undefined;
var gtk_widget_get_visible: *const fn (?*anyopaque) callconv(.c) c_int = undefined;
var gtk_window_is_active: *const fn (?*anyopaque) callconv(.c) c_int = undefined;
var gtk_widget_get_window: *const fn (?*anyopaque) callconv(.c) ?*anyopaque = undefined;

// gdk
var gdk_window_get_state: *const fn (?*anyopaque) callconv(.c) c_int = undefined;

var g_loaded = false;
var g_win: ?*anyopaque = null;
var g_timer: u32 = 0;
var g_enabled = std.atomic.Value(bool).init(false);
var g_minimized = std.atomic.Value(bool).init(false);
var g_focused = std.atomic.Value(bool).init(true);

fn sym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque {
    return dlsym(handle, name);
}

fn load() bool {
    if (g_loaded) return true;
    // 应用已加载 GTK；优先 dlopen 具体库，失败再查全局符号
    const h_gtk = dlopen("libgtk-3.so.0", RTLD_NOW) orelse dlopen(null, RTLD_NOW);
    const h_gdk = dlopen("libgdk-3.so.0", RTLD_NOW) orelse h_gtk;
    const h_glib = dlopen("libglib-2.0.so.0", RTLD_NOW) orelse h_gtk;

    g_main_context_default = @ptrCast(@alignCast(sym(h_glib, "g_main_context_default") orelse return false));
    g_main_context_invoke = @ptrCast(@alignCast(sym(h_glib, "g_main_context_invoke") orelse return false));
    g_timeout_add = @ptrCast(@alignCast(sym(h_glib, "g_timeout_add") orelse return false));
    g_source_remove = @ptrCast(@alignCast(sym(h_glib, "g_source_remove") orelse return false));
    gtk_window_list_toplevels = @ptrCast(@alignCast(sym(h_gtk, "gtk_window_list_toplevels") orelse return false));
    gtk_widget_get_visible = @ptrCast(@alignCast(sym(h_gtk, "gtk_widget_get_visible") orelse return false));
    gtk_window_is_active = @ptrCast(@alignCast(sym(h_gtk, "gtk_window_is_active") orelse return false));
    gtk_widget_get_window = @ptrCast(@alignCast(sym(h_gtk, "gtk_widget_get_window") orelse return false));
    gdk_window_get_state = @ptrCast(@alignCast(sym(h_gdk, "gdk_window_get_state") orelse return false));
    g_loaded = true;
    return true;
}

/// GTK 库是否可用（caps 判定用）。
pub fn available() bool {
    return load();
}

fn emit() void {
    if (!g_enabled.load(.acquire)) return;
    core.dispatch(.{
        .type = core.EVENT_WINDOW_STATE,
        .u = .{ .window = .{
            .minimized = @intFromBool(g_minimized.load(.acquire)),
            .focused = @intFromBool(g_focused.load(.acquire)),
        } },
    });
}

fn poll(_: ?*anyopaque) callconv(.c) c_int {
    const win = g_win orelse return 1; // G_SOURCE_CONTINUE
    const active = gtk_window_is_active(win) != 0;
    var minimized = false;
    const gdkwin = gtk_widget_get_window(win);
    if (gdkwin != null) {
        minimized = (gdk_window_get_state(gdkwin) & GDK_WINDOW_STATE_ICONIFIED) != 0;
    }
    const changed = active != g_focused.load(.acquire) or minimized != g_minimized.load(.acquire);
    if (changed) {
        g_focused.store(active, .release);
        g_minimized.store(minimized, .release);
        emit();
    }
    return 1;
}

/// 在 GTK 主线程：取首个可见顶层窗口并启动轮询。
fn setupOnMainThread(_: ?*anyopaque) callconv(.c) void {
    var it = gtk_window_list_toplevels();
    while (it) |node| {
        const win = node.data;
        if (win != null and gtk_widget_get_visible(win) != 0) {
            g_win = win;
            break;
        }
        it = node.next;
    }
    if (g_win == null) return;
    // 立即取一次初值
    _ = poll(null);
    if (g_timer == 0) g_timer = g_timeout_add(500, poll, null);
}

pub fn setEvents(on: bool) i32 {
    if (!load()) return core.ERR_UNSUPPORTED;
    if (on) {
        g_enabled.store(true, .release);
        g_main_context_invoke(g_main_context_default(), setupOnMainThread, null);
        return core.OK;
    }
    g_enabled.store(false, .release);
    if (g_timer != 0) {
        _ = g_source_remove(g_timer);
        g_timer = 0;
    }
    return core.OK;
}
