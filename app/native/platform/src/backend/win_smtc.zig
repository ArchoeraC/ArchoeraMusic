//! Windows SMTC（SystemMediaTransportControls）——WinRT COM vtable 直调（P3b）。
//!
//! **权威来源**：vtable 方法顺序由本机 `Windows.Media.winmd`（ECMA-335 元数据）
//! 解析得出（`/tmp` 脚本 `winmd_dump.py`），非猜测；IID 由 winmd 内 `[Guid]`
//! 校验（`ISystemMediaTransportControls` = 99FA3FF4-1742-42A6-902E-087D41F965EC）
//! 与 mingw `systemmediatransportcontrolsinterop.h`（interop IID）提供。
//!
//! 仅 Linux 之外的 Windows 目标编入（backend_windows 引用）。
//! 未实现：时间轴（需 ISystemMediaTransportControls2 + TimelineProperties）与
//! 缩略图（artwork）。

const std = @import("std");
const core = @import("../core.zig");

const win = @import("win_common.zig").c;

const HRESULT = i32;
const S_OK: HRESULT = 0;

// combase.dll 无 x86_64 导入库 → 运行时解析（kernel32 LoadLibrary/GetProcAddress）
// 注：x86_64 上 .c 与 .winapi 同 ABI；用 .c 规避「winapi 禁 [*c] 参数」限制
const RoInitializeFn = *const fn (u32) callconv(.c) HRESULT;
const RoGetActivationFactoryFn = *const fn (HSTRING, *const win.GUID, *?*anyopaque) callconv(.c) HRESULT;
const WindowsCreateStringFn = *const fn ([*]const u16, u32, *HSTRING) callconv(.c) HRESULT;
const WindowsDeleteStringFn = *const fn (HSTRING) callconv(.c) HRESULT;

var g_combase: win.HMODULE = null;
var p_RoInitialize: ?RoInitializeFn = null;
var p_RoGetActivationFactory: ?RoGetActivationFactoryFn = null;
var p_WindowsCreateString: ?WindowsCreateStringFn = null;
var p_WindowsDeleteString: ?WindowsDeleteStringFn = null;

fn loadCombase() bool {
    if (g_combase != null) return true;
    const h = win.LoadLibraryA("combase.dll") orelse return false;
    g_combase = h;
    p_RoInitialize = @ptrCast(win.GetProcAddress(h, "RoInitialize"));
    p_RoGetActivationFactory = @ptrCast(win.GetProcAddress(h, "RoGetActivationFactory"));
    p_WindowsCreateString = @ptrCast(win.GetProcAddress(h, "WindowsCreateString"));
    p_WindowsDeleteString = @ptrCast(win.GetProcAddress(h, "WindowsDeleteString"));
    return p_RoInitialize != null and p_RoGetActivationFactory != null and
        p_WindowsCreateString != null and p_WindowsDeleteString != null;
}
const boolean = u8; // WinRT ABI boolean（x64 寄存器传参，宽度不敏感）
const HSTRING = ?*anyopaque; // 用不透明指针规避 x86_64_win 禁 [*c] 参数
const EventRegistrationToken = extern struct { value: i64 };

// winmd 提取的 IID（interop IID 来自 mingw 头）
const IID_INTEROP = win.GUID{
    .Data1 = 0xddb0472d,
    .Data2 = 0xc911,
    .Data3 = 0x4a1f,
    .Data4 = .{ 0x86, 0xd9, 0xdc, 0x3d, 0x71, 0xa9, 0x5f, 0x5a },
};
const IID_SMTC = win.GUID{
    .Data1 = 0x99FA3FF4,
    .Data2 = 0x1742,
    .Data3 = 0x42A6,
    .Data4 = .{ 0x90, 0x2E, 0x08, 0x7D, 0x41, 0xF9, 0x65, 0xEC },
};

// 枚举（Windows.Media 标准值）
const PlaybackStatus = struct {
    const closed: i32 = 0;
    const changing: i32 = 1;
    const stopped: i32 = 2;
    const playing: i32 = 3;
    const paused: i32 = 4;
};
const Button = struct {
    const play: i32 = 0;
    const pause: i32 = 1;
    const stop: i32 = 2;
    const fast_forward: i32 = 4;
    const rewind: i32 = 5;
    const next: i32 = 6;
    const previous: i32 = 7;
};
const PlaybackType = struct { const music: i32 = 1; };

// ── vtable（槽位顺序 = winmd 声明顺序）────────────────────────────

/// IInspectable 基类 6 槽（所有 WinRT 接口前缀）。
const Inspectable = extern struct {
    QueryInterface: *const fn (*anyopaque, *const win.GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*win.GUID) callconv(.c) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *HSTRING) callconv(.c) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.c) HRESULT,
};

const InteropVtbl = extern struct {
    base: Inspectable,
    GetForWindow: *const fn (*anyopaque, win.HWND, *const win.GUID, *?*anyopaque) callconv(.c) HRESULT,
};

/// ISystemMediaTransportControls（winmd 30 方法）。
const SmtcVtbl = extern struct {
    base: Inspectable,
    get_PlaybackStatus: *const fn (*anyopaque, *i32) callconv(.c) HRESULT,
    put_PlaybackStatus: *const fn (*anyopaque, i32) callconv(.c) HRESULT,
    get_DisplayUpdater: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    get_SoundLevel: *const fn (*anyopaque, *i32) callconv(.c) HRESULT,
    get_IsEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_IsEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    get_IsPlayEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_IsPlayEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    get_IsStopEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_IsStopEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    get_IsPauseEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_IsPauseEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    get_IsRecordEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_IsRecordEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    get_IsFastForwardEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_IsFastForwardEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    get_IsRewindEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_IsRewindEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    get_IsPreviousEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_IsPreviousEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    get_IsNextEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_IsNextEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    get_IsChannelUpEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_IsChannelUpEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    get_IsChannelDownEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_IsChannelDownEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    add_ButtonPressed: *const fn (*anyopaque, ?*anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_ButtonPressed: *const fn (*anyopaque, EventRegistrationToken) callconv(.c) HRESULT,
    add_PropertyChanged: *const fn (*anyopaque, ?*anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_PropertyChanged: *const fn (*anyopaque, EventRegistrationToken) callconv(.c) HRESULT,
};

/// ISystemMediaTransportControlsDisplayUpdater（winmd 12 方法）。
const DisplayVtbl = extern struct {
    base: Inspectable,
    get_Type: *const fn (*anyopaque, *i32) callconv(.c) HRESULT,
    put_Type: *const fn (*anyopaque, i32) callconv(.c) HRESULT,
    get_AppMediaId: *const fn (*anyopaque, *HSTRING) callconv(.c) HRESULT,
    put_AppMediaId: *const fn (*anyopaque, HSTRING) callconv(.c) HRESULT,
    get_Thumbnail: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    put_Thumbnail: *const fn (*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
    get_MusicProperties: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    get_VideoProperties: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    get_ImageProperties: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    CopyFromFileAsync: *const fn (*anyopaque, i32, ?*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    ClearAll: *const fn (*anyopaque) callconv(.c) HRESULT,
    Update: *const fn (*anyopaque) callconv(.c) HRESULT,
};

/// IMusicDisplayProperties（winmd 6 方法）。
const MusicVtbl = extern struct {
    base: Inspectable,
    get_Title: *const fn (*anyopaque, *HSTRING) callconv(.c) HRESULT,
    put_Title: *const fn (*anyopaque, HSTRING) callconv(.c) HRESULT,
    get_AlbumArtist: *const fn (*anyopaque, *HSTRING) callconv(.c) HRESULT,
    put_AlbumArtist: *const fn (*anyopaque, HSTRING) callconv(.c) HRESULT,
    get_Artist: *const fn (*anyopaque, *HSTRING) callconv(.c) HRESULT,
    put_Artist: *const fn (*anyopaque, HSTRING) callconv(.c) HRESULT,
};

/// ISystemMediaTransportControlsButtonPressedEventArgs（winmd 1 方法）。
const ArgsVtbl = extern struct {
    base: Inspectable,
    get_Button: *const fn (*anyopaque, *i32) callconv(.c) HRESULT,
};

fn vtbl(comptime T: type, obj: *anyopaque) *const T {
    const pp: *const *const T = @ptrCast(@alignCast(obj));
    return pp.*;
}

// ── 状态 ──────────────────────────────────────────────────────────

var g_smtc: ?*anyopaque = null;
var g_display: ?*anyopaque = null;
var g_music: ?*anyopaque = null;
var g_button_token: EventRegistrationToken = .{ .value = 0 };
var g_button_registered = false;

// ── 事件委托（TypedEventHandler 的 COM 实现）─────────────────────

const HandlerObj = extern struct {
    vtbl: *const HandlerVtbl,
    ref: u32,
};
const HandlerVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const win.GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    Invoke: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
};

fn handlerQI(this: *anyopaque, riid: *const win.GUID, out: *?*anyopaque) callconv(.c) HRESULT {
    _ = riid;
    out.* = this; // 宽松：委托仅被事件系统 QI（delegate/IAgileObject）
    return S_OK;
}
fn handlerAddRef(this: *anyopaque) callconv(.c) u32 {
    const o: *HandlerObj = @ptrCast(@alignCast(this));
    o.ref += 1;
    return o.ref;
}
fn handlerRelease(this: *anyopaque) callconv(.c) u32 {
    const o: *HandlerObj = @ptrCast(@alignCast(this));
    o.ref -%= 1;
    return o.ref;
}
fn handlerInvoke(this: *anyopaque, sender: ?*anyopaque, args: ?*anyopaque) callconv(.c) HRESULT {
    _ = this;
    _ = sender;
    if (args) |a| {
        const av = vtbl(ArgsVtbl, a);
        var button: i32 = -1;
        if (av.get_Button(a, &button) == S_OK) {
            const cmd: i32 = switch (button) {
                Button.play => core.CMD_PLAY,
                Button.pause => core.CMD_PAUSE,
                Button.stop => core.CMD_STOP,
                Button.next => core.CMD_NEXT,
                Button.previous => core.CMD_PREV,
                else => -1,
            };
            if (cmd >= 0) {
                core.dispatch(.{ .type = core.EVENT_MEDIA_COMMAND, .u = .{ .command = cmd } });
            }
        }
    }
    return S_OK;
}

const HANDLER_VTBL = HandlerVtbl{
    .QueryInterface = handlerQI,
    .AddRef = handlerAddRef,
    .Release = handlerRelease,
    .Invoke = handlerInvoke,
};
var g_handler_obj = HandlerObj{ .vtbl = &HANDLER_VTBL, .ref = 1 };

// ── HSTRING ───────────────────────────────────────────────────────

fn makeHString(utf8: []const u8) HSTRING {
    var wide: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, utf8) catch return null;
    var hs: HSTRING = null;
    if (p_WindowsCreateString.?(@ptrCast(&wide), @intCast(n), &hs) != S_OK) return null;
    return hs;
}

fn setMusicProp(sig: enum { title, artist, album_artist }, value: []const u8) void {
    const music = g_music orelse return;
    const mv = vtbl(MusicVtbl, music);
    const hs = makeHString(value) orelse return;
    defer _ = p_WindowsDeleteString.?(hs);
    _ = switch (sig) {
        .title => mv.put_Title(music, hs),
        .artist => mv.put_Artist(music, hs),
        .album_artist => mv.put_AlbumArtist(music, hs),
    };
}

// ── 初始化 ────────────────────────────────────────────────────────

pub fn init(findWindow: *const fn () ?win.HWND) i32 {
    if (g_smtc != null) return core.OK;
    if (!loadCombase()) return core.ERR_BACKEND;
    const hwnd = findWindow() orelse return core.ERR_BACKEND;

    _ = p_RoInitialize.?(1); // RO_INIT_MULTITHREADED

    const cls = makeHString("Windows.Media.SystemMediaTransportControls") orelse return core.ERR_BACKEND;
    defer _ = p_WindowsDeleteString.?(cls);

    var factory: ?*anyopaque = null;
    if (p_RoGetActivationFactory.?(cls, &IID_INTEROP, &factory) != S_OK) return core.ERR_BACKEND;
    if (factory == null) return core.ERR_BACKEND;
    defer _ = vtbl(InteropVtbl, factory.?).base.Release(factory.?);

    var smtc: ?*anyopaque = null;
    if (vtbl(InteropVtbl, factory.?).GetForWindow(factory.?, hwnd, &IID_SMTC, &smtc) != S_OK) return core.ERR_BACKEND;
    if (smtc == null) return core.ERR_BACKEND;
    g_smtc = smtc;

    const sv = vtbl(SmtcVtbl, smtc.?);
    _ = sv.put_IsEnabled(smtc.?, 1);
    _ = sv.put_IsPlayEnabled(smtc.?, 1);
    _ = sv.put_IsPauseEnabled(smtc.?, 1);
    _ = sv.put_IsStopEnabled(smtc.?, 1);
    _ = sv.put_IsNextEnabled(smtc.?, 1);
    _ = sv.put_IsPreviousEnabled(smtc.?, 1);

    var disp: ?*anyopaque = null;
    if (sv.get_DisplayUpdater(smtc.?, &disp) == S_OK and disp != null) {
        g_display = disp;
        const dv = vtbl(DisplayVtbl, disp.?);
        _ = dv.put_Type(disp.?, PlaybackType.music);
        var music: ?*anyopaque = null;
        if (dv.get_MusicProperties(disp.?, &music) == S_OK and music != null) g_music = music;
    }

    if (sv.add_ButtonPressed(smtc.?, @ptrCast(&g_handler_obj), &g_button_token) == S_OK) {
        g_button_registered = true;
    }
    return core.OK;
}

pub fn setTrack(title: ?[]const u8, artist: ?[]const u8) void {
    if (g_music == null) return;
    if (title) |t| setMusicProp(.title, t);
    if (artist) |a| {
        setMusicProp(.artist, a);
        setMusicProp(.album_artist, a);
    }
    if (g_display) |d| _ = vtbl(DisplayVtbl, d).Update(d);
}

pub fn setPlayback(state: i32) void {
    const smtc = g_smtc orelse return;
    const st: i32 = switch (state) {
        0 => PlaybackStatus.stopped,
        1 => PlaybackStatus.playing,
        else => PlaybackStatus.paused,
    };
    _ = vtbl(SmtcVtbl, smtc).put_PlaybackStatus(smtc, st);
}

pub fn deinit() void {
    if (g_smtc) |s| {
        const sv = vtbl(SmtcVtbl, s);
        if (g_button_registered) _ = sv.remove_ButtonPressed(s, g_button_token);
        _ = sv.base.Release(s);
        g_smtc = null;
    }
    g_display = null;
    g_music = null;
    g_button_registered = false;
}

// 测试自检用：读回属性（smoke 验证 vtable 槽位）
pub fn debugGetPlaybackStatus() i32 {
    const smtc = g_smtc orelse return -1;
    var st: i32 = -1;
    if (vtbl(SmtcVtbl, smtc).get_PlaybackStatus(smtc, &st) != S_OK) return -1;
    return st;
}

pub fn debugGetIsEnabled() i32 {
    const smtc = g_smtc orelse return -1;
    var b: boolean = 0;
    if (vtbl(SmtcVtbl, smtc).get_IsEnabled(smtc, &b) != S_OK) return -1;
    return b;
}
