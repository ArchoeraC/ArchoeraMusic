// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Windows SMTC（SystemMediaTransportControls）——WinRT COM vtable 直调（P3b）。
//!
//! **权威来源**：vtable 方法顺序由本机 `Windows.Media.winmd`（ECMA-335 元数据）
//! 解析得出（`/tmp` 脚本 `winmd_dump.py`），非猜测；IID 由 winmd 内 `[Guid]`
//! 校验（`ISystemMediaTransportControls` = 99FA3FF4-1742-42A6-902E-087D41F965EC）
//! 与 mingw `systemmediatransportcontrolsinterop.h`（interop IID）提供。
//!
//! 仅 Linux 之外的 Windows 目标编入（backend_windows 引用）。
//! 覆盖：元数据 + 播放状态 + 按钮事件 + 封面缩略图（http/本地）+ 时间轴/速率。
//! 诊断：关键路径经 `OutputDebugStringA` 输出（DebugView 可见），便于排查不显示。

const std = @import("std");
const core = @import("../core.zig");

const win = @import("win_common.zig").c;

const alloc = std.heap.c_allocator;

const HRESULT = i32;
const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

/// 诊断日志（DebugView / DbgView 可见；无输出不影响功能）。
fn log(msg: [*:0]const u8) void {
    win.OutputDebugStringA(msg);
}

/// 带 HRESULT 的诊断日志（0x%08x）。
fn logHr(comptime prefix: []const u8, hr: HRESULT) void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, prefix ++ " hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))}) catch return;
    win.OutputDebugStringA(s.ptr);
}

// combase.dll 无 x86_64 导入库 → 运行时解析（kernel32 LoadLibrary/GetProcAddress）
// 注：x86_64 上 .c 与 .winapi 同 ABI；用 .c 规避「winapi 禁 [*c] 参数」限制
const RoInitializeFn = *const fn (u32) callconv(.c) HRESULT;
const RoGetActivationFactoryFn = *const fn (HSTRING, *const win.GUID, *?*anyopaque) callconv(.c) HRESULT;
const RoActivateInstanceFn = *const fn (HSTRING, *?*anyopaque) callconv(.c) HRESULT;
const WindowsCreateStringFn = *const fn ([*]const u16, u32, *HSTRING) callconv(.c) HRESULT;
const WindowsDeleteStringFn = *const fn (HSTRING) callconv(.c) HRESULT;

var g_combase: win.HMODULE = null;
var p_RoInitialize: ?RoInitializeFn = null;
var p_RoGetActivationFactory: ?RoGetActivationFactoryFn = null;
var p_RoActivateInstance: ?RoActivateInstanceFn = null;
var p_WindowsCreateString: ?WindowsCreateStringFn = null;
var p_WindowsDeleteString: ?WindowsDeleteStringFn = null;

fn loadCombase() bool {
    if (g_combase != null) return true;
    const h = win.LoadLibraryA("combase.dll") orelse return false;
    g_combase = h;
    p_RoInitialize = @ptrCast(win.GetProcAddress(h, "RoInitialize"));
    p_RoGetActivationFactory = @ptrCast(win.GetProcAddress(h, "RoGetActivationFactory"));
    p_RoActivateInstance = @ptrCast(win.GetProcAddress(h, "RoActivateInstance"));
    p_WindowsCreateString = @ptrCast(win.GetProcAddress(h, "WindowsCreateString"));
    p_WindowsDeleteString = @ptrCast(win.GetProcAddress(h, "WindowsDeleteString"));
    return p_RoInitialize != null and p_RoGetActivationFactory != null and
        p_RoActivateInstance != null and p_WindowsCreateString != null and
        p_WindowsDeleteString != null;
}

fn release(obj: ?*anyopaque) void {
    if (obj) |o| _ = vtbl(Inspectable, o).Release(o);
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
// 以下 IID 由本机 Windows.Media/Storage/Foundation.winmd 解析（winmd2.py，已校验）
const IID_SMTC2 = win.GUID{
    .Data1 = 0xEA98D2F6,
    .Data2 = 0x7F3C,
    .Data3 = 0x4AF2,
    .Data4 = .{ 0xA5, 0x86, 0x72, 0x88, 0x98, 0x08, 0xEF, 0xB1 },
};
const IID_URI_FACTORY = win.GUID{
    .Data1 = 0x44A9796F,
    .Data2 = 0x723E,
    .Data3 = 0x4FDF,
    .Data4 = .{ 0xA2, 0x18, 0x03, 0x3E, 0x75, 0xB0, 0xC0, 0x84 },
};
const IID_RASR_STATICS = win.GUID{
    .Data1 = 0x857309DC,
    .Data2 = 0x3FBF,
    .Data3 = 0x4E7D,
    .Data4 = .{ 0x98, 0x6F, 0xEF, 0x3B, 0x1A, 0x07, 0xA9, 0x64 },
};
const IID_STORAGE_FILE_STATICS = win.GUID{
    .Data1 = 0x5984C710,
    .Data2 = 0xDAF2,
    .Data3 = 0x43C8,
    .Data4 = .{ 0x8B, 0xB4, 0xA4, 0xD3, 0xEA, 0xCF, 0xD0, 0x3F },
};

// 事件委托 QI 策略：以下接口本对象并未实现，绝不能应答 S_OK——否则调用方会
// 按错位 vtable 槽使用（如把 Invoke 当成 IInspectable::GetIids / IMarshal::
// GetUnmarshalClass），导致 add_ButtonPressed 看似成功但事件永不回调。
// IInspectable {AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90}
const IID_IINSPECTABLE = win.GUID{
    .Data1 = 0xAF86E2E0,
    .Data2 = 0xB12D,
    .Data3 = 0x4C6A,
    .Data4 = .{ 0x9C, 0x5A, 0xD7, 0xAA, 0x65, 0x10, 0x1E, 0x90 },
};
// IMarshal {00000003-0000-0000-C000-000000000046}
const IID_IMARSHAL = win.GUID{
    .Data1 = 0x00000003,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
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

/// ISystemMediaTransportControls2（winmd 15 方法；仅用 UpdateTimelineProperties）。
const Smtc2Vtbl = extern struct {
    base: Inspectable,
    get_AutoRepeatMode: *const fn (*anyopaque, *i32) callconv(.c) HRESULT,
    put_AutoRepeatMode: *const fn (*anyopaque, i32) callconv(.c) HRESULT,
    get_ShuffleEnabled: *const fn (*anyopaque, *boolean) callconv(.c) HRESULT,
    put_ShuffleEnabled: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    get_PlaybackRate: *const fn (*anyopaque, *f64) callconv(.c) HRESULT,
    put_PlaybackRate: *const fn (*anyopaque, f64) callconv(.c) HRESULT,
    UpdateTimelineProperties: *const fn (*anyopaque, *anyopaque) callconv(.c) HRESULT,
    add_PlaybackPositionChangeRequested: *const fn (*anyopaque, ?*anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_PlaybackPositionChangeRequested: *const fn (*anyopaque, EventRegistrationToken) callconv(.c) HRESULT,
    add_PlaybackRateChangeRequested: *const fn (*anyopaque, ?*anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_PlaybackRateChangeRequested: *const fn (*anyopaque, EventRegistrationToken) callconv(.c) HRESULT,
    add_ShuffleEnabledChangeRequested: *const fn (*anyopaque, ?*anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_ShuffleEnabledChangeRequested: *const fn (*anyopaque, EventRegistrationToken) callconv(.c) HRESULT,
    add_AutoRepeatModeChangeRequested: *const fn (*anyopaque, ?*anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_AutoRepeatModeChangeRequested: *const fn (*anyopaque, EventRegistrationToken) callconv(.c) HRESULT,
};

/// ISystemMediaTransportControlsTimelineProperties（winmd 10 方法，TimeSpan=i64 100ns）。
const TimelineVtbl = extern struct {
    base: Inspectable,
    get_StartTime: *const fn (*anyopaque, *i64) callconv(.c) HRESULT,
    put_StartTime: *const fn (*anyopaque, i64) callconv(.c) HRESULT,
    get_EndTime: *const fn (*anyopaque, *i64) callconv(.c) HRESULT,
    put_EndTime: *const fn (*anyopaque, i64) callconv(.c) HRESULT,
    get_MinSeekTime: *const fn (*anyopaque, *i64) callconv(.c) HRESULT,
    put_MinSeekTime: *const fn (*anyopaque, i64) callconv(.c) HRESULT,
    get_MaxSeekTime: *const fn (*anyopaque, *i64) callconv(.c) HRESULT,
    put_MaxSeekTime: *const fn (*anyopaque, i64) callconv(.c) HRESULT,
    get_Position: *const fn (*anyopaque, *i64) callconv(.c) HRESULT,
    put_Position: *const fn (*anyopaque, i64) callconv(.c) HRESULT,
};

/// IUriRuntimeClassFactory（winmd 2 方法）。
const UriFactoryVtbl = extern struct {
    base: Inspectable,
    CreateUri: *const fn (*anyopaque, HSTRING, *?*anyopaque) callconv(.c) HRESULT,
    CreateWithRelativeUri: *const fn (*anyopaque, HSTRING, HSTRING, *?*anyopaque) callconv(.c) HRESULT,
};

/// IRandomAccessStreamReferenceStatics（winmd 3 方法）。
const RasrStaticsVtbl = extern struct {
    base: Inspectable,
    CreateFromFile: *const fn (*anyopaque, ?*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    CreateFromUri: *const fn (*anyopaque, ?*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    CreateFromStream: *const fn (*anyopaque, ?*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
};

/// IStorageFileStatics（winmd 6 方法；仅用 GetFileFromPathAsync）。
const StorageFileStaticsVtbl = extern struct {
    base: Inspectable,
    GetFileFromPathAsync: *const fn (*anyopaque, HSTRING, *?*anyopaque) callconv(.c) HRESULT,
    GetFileFromApplicationUriAsync: *const fn (*anyopaque, ?*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    CreateStreamedFileAsync: *const fn (*anyopaque, HSTRING, ?*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
    ReplaceWithStreamedFileAsync: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
    CreateStreamedFileFromUriAsync: *const fn (*anyopaque, HSTRING, ?*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
    ReplaceWithStreamedFileFromUriAsync: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
};

/// IAsyncInfo（5）+ IAsyncOperation`1（3）合并布局；GetResults 取 IStorageFile。
const AsyncOpVtbl = extern struct {
    base: Inspectable,
    get_Id: *const fn (*anyopaque, *u32) callconv(.c) HRESULT,
    get_Status: *const fn (*anyopaque, *i32) callconv(.c) HRESULT,
    get_ErrorCode: *const fn (*anyopaque, *i32) callconv(.c) HRESULT,
    Cancel: *const fn (*anyopaque) callconv(.c) HRESULT,
    Close: *const fn (*anyopaque) callconv(.c) HRESULT,
    put_Completed: *const fn (*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
    get_Completed: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    GetResults: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
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
var g_smtc2: ?*anyopaque = null;
var g_duration_ms: i64 = -1;

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

fn guidEq(a: win.GUID, b: *const win.GUID) bool {
    return a.Data1 == b.Data1 and a.Data2 == b.Data2 and a.Data3 == b.Data3 and
        std.mem.eql(u8, &a.Data4, &b.Data4);
}

fn logQi(riid: *const win.GUID) void {
    var buf: [96]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "apl/smtc: QI {x:0>8}-{x:0>4}-{x:0>4}", .{
        riid.Data1, riid.Data2, riid.Data3,
    }) catch return;
    win.OutputDebugStringA(s.ptr);
}

/// 委托 QI：除 IInspectable / IMarshal 外一律应答 S_OK 并 AddRef（涵盖
/// IUnknown、IAgileObject、WinRT 运行期生成的委托 IID）。这两个接口本对象并未
/// 实现，错误应答（旧实现对所有 IID 一律 S_OK）会让 WinRT 按错位 vtable 槽调用
/// ——Invoke 被当成 GetIids / GetUnmarshalClass → add_ButtonPressed 看似成功但
/// ButtonPressed 永不回调（「面板显示曲目、按键全无响应」）。
/// 注：函数声明顺序在 Zig 容器内不敏感，无需前置声明。
fn handlerQI(this: *anyopaque, riid: *const win.GUID, out: *?*anyopaque) callconv(.c) HRESULT {
    const denied = guidEq(IID_IINSPECTABLE, riid) or guidEq(IID_IMARSHAL, riid);
    if (!denied) {
        _ = handlerAddRef(this);
        out.* = this;
        return S_OK;
    }
    logQi(riid);
    out.* = null;
    return E_NOINTERFACE;
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
            log("apl/smtc: ButtonPressed");
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
    if (!loadCombase()) {
        log("apl/smtc: loadCombase failed");
        return core.ERR_BACKEND;
    }
    const hwnd = findWindow() orelse {
        log("apl/smtc: flutter window not found");
        return core.ERR_BACKEND;
    };

    const hr_init = p_RoInitialize.?(1); // RO_INIT_MULTITHREADED
    logHr("apl/smtc: RoInitialize", hr_init);
    // 0x80010106 RPC_E_CHANGED_MODE = 线程已是 STA（Flutter 平台线程
    // CoInitializeEx(APARTMENTTHREADED)）；此时委托须应答 IAgileObject（见
    // handlerQI），否则 WinRT 跨 apartment 无法回调 ButtonPressed。

    const cls = makeHString("Windows.Media.SystemMediaTransportControls") orelse return core.ERR_BACKEND;
    defer _ = p_WindowsDeleteString.?(cls);

    var factory: ?*anyopaque = null;
    if (p_RoGetActivationFactory.?(cls, &IID_INTEROP, &factory) != S_OK or factory == null) {
        log("apl/smtc: RoGetActivationFactory failed");
        return core.ERR_BACKEND;
    }
    defer _ = vtbl(InteropVtbl, factory.?).base.Release(factory.?);

    var smtc: ?*anyopaque = null;
    if (vtbl(InteropVtbl, factory.?).GetForWindow(factory.?, hwnd, &IID_SMTC, &smtc) != S_OK or smtc == null) {
        log("apl/smtc: GetForWindow failed");
        return core.ERR_BACKEND;
    }
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

    const hr_add = sv.add_ButtonPressed(smtc.?, @ptrCast(&g_handler_obj), &g_button_token);
    logHr("apl/smtc: add_ButtonPressed", hr_add);
    if (hr_add == S_OK) {
        g_button_registered = true;
    }
    log("apl/smtc: ready");
    return core.OK;
}

const ArtworkJob = struct { url: []u8 };

fn artworkEntry(ctx: ?*anyopaque) callconv(.winapi) win.DWORD {
    const job: *ArtworkJob = @ptrCast(@alignCast(ctx.?));
    if (p_RoInitialize != null) _ = p_RoInitialize.?(1);
    setArtwork(job.url);
    alloc.free(job.url);
    alloc.destroy(job);
    return 0;
}

/// 后台线程解析封面（本地文件 GetFileFromPathAsync 可能耗时，避免阻塞 setNowPlaying）。
fn spawnArtwork(url: []const u8) void {
    const copy = alloc.dupe(u8, url) catch return;
    const job = alloc.create(ArtworkJob) catch {
        alloc.free(copy);
        return;
    };
    job.* = .{ .url = copy };
    if (win.CreateThread(null, 0, artworkEntry, @ptrCast(job), 0, null) == null) {
        alloc.free(copy);
        alloc.destroy(job);
    }
}

/// 设置封面缩略图（http(s) URL 走 CreateFromUri；本地路径走 CreateFromFile）。
fn setArtwork(url: []const u8) void {
    if (g_display == null) return;
    const is_http = std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
    log(if (is_http) "apl/smtc: artwork http" else "apl/smtc: artwork local");
    const ref = if (is_http) refFromUri(url) else refFromFile(url);
    if (ref == null) {
        log("apl/smtc: artwork ref failed");
        return;
    }
    defer release(ref);
    if (vtbl(DisplayVtbl, g_display.?).put_Thumbnail(g_display.?, ref) == S_OK) {
        log("apl/smtc: thumbnail set");
    } else {
        log("apl/smtc: put_Thumbnail failed");
    }
}

fn rasrStatics() ?*anyopaque {
    const cls = makeHString("Windows.Storage.Streams.RandomAccessStreamReference") orelse return null;
    defer _ = p_WindowsDeleteString.?(cls);
    var statics: ?*anyopaque = null;
    if (p_RoGetActivationFactory.?(cls, &IID_RASR_STATICS, &statics) != S_OK or statics == null) return null;
    return statics;
}

fn refFromUri(url: []const u8) ?*anyopaque {
    const cls_uri = makeHString("Windows.Foundation.Uri") orelse return null;
    defer _ = p_WindowsDeleteString.?(cls_uri);
    var factory: ?*anyopaque = null;
    if (p_RoGetActivationFactory.?(cls_uri, &IID_URI_FACTORY, &factory) != S_OK or factory == null) return null;
    defer release(factory);
    const hs_url = makeHString(url) orelse return null;
    defer _ = p_WindowsDeleteString.?(hs_url);
    var uri: ?*anyopaque = null;
    if (vtbl(UriFactoryVtbl, factory.?).CreateUri(factory.?, hs_url, &uri) != S_OK or uri == null) return null;
    defer release(uri);
    const statics = rasrStatics() orelse return null;
    defer release(statics);
    var ref: ?*anyopaque = null;
    if (vtbl(RasrStaticsVtbl, statics).CreateFromUri(statics, uri, &ref) != S_OK) return null;
    return ref;
}

fn refFromFile(path: []const u8) ?*anyopaque {
    const cls = makeHString("Windows.Storage.StorageFile") orelse return null;
    defer _ = p_WindowsDeleteString.?(cls);
    var statics: ?*anyopaque = null;
    if (p_RoGetActivationFactory.?(cls, &IID_STORAGE_FILE_STATICS, &statics) != S_OK or statics == null) return null;
    defer release(statics);
    const hs_path = makeHString(path) orelse return null;
    defer _ = p_WindowsDeleteString.?(hs_path);
    var op: ?*anyopaque = null;
    if (vtbl(StorageFileStaticsVtbl, statics.?).GetFileFromPathAsync(statics.?, hs_path, &op) != S_OK or op == null) return null;
    defer release(op);
    // 轮询等待 IAsyncOperation 完成（最多 ~2s；避免委托回调复杂度）
    const ov = vtbl(AsyncOpVtbl, op.?);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var status: i32 = 0;
        if (ov.get_Status(op.?, &status) != S_OK) return null;
        if (status == 1) break; // Completed
        if (status == 2 or status == 3) return null; // Canceled / Error
        win.Sleep(20);
    }
    var file: ?*anyopaque = null;
    if (ov.GetResults(op.?, &file) != S_OK or file == null) return null;
    defer release(file);
    const rs = rasrStatics() orelse return null;
    defer release(rs);
    var ref: ?*anyopaque = null;
    if (vtbl(RasrStaticsVtbl, rs).CreateFromFile(rs, file, &ref) != S_OK) return null;
    return ref;
}

/// QI 出 ISystemMediaTransportControls2（时间轴/速率用）。
fn ensureSmtc2() ?*anyopaque {
    if (g_smtc2 != null) return g_smtc2;
    const smtc = g_smtc orelse return null;
    var out: ?*anyopaque = null;
    if (vtbl(SmtcVtbl, smtc).base.QueryInterface(smtc, &IID_SMTC2, &out) != S_OK) return null;
    if (out == null) return null;
    g_smtc2 = out;
    return out;
}

/// 更新系统进度条（TimeSpan = 100ns）。
fn updateTimeline(position_ms: i64) void {
    const s2 = ensureSmtc2() orelse return;
    const cls = makeHString("Windows.Media.SystemMediaTransportControlsTimelineProperties") orelse return;
    defer _ = p_WindowsDeleteString.?(cls);
    var obj: ?*anyopaque = null;
    if (p_RoActivateInstance.?(cls, &obj) != S_OK or obj == null) return;
    defer release(obj);
    const tv = vtbl(TimelineVtbl, obj.?);
    const end: i64 = if (g_duration_ms > 0) g_duration_ms * 10_000 else 0;
    const pos: i64 = position_ms * 10_000;
    _ = tv.put_StartTime(obj.?, 0);
    _ = tv.put_EndTime(obj.?, end);
    _ = tv.put_MinSeekTime(obj.?, 0);
    _ = tv.put_MaxSeekTime(obj.?, end);
    _ = tv.put_Position(obj.?, pos);
    _ = vtbl(Smtc2Vtbl, s2).UpdateTimelineProperties(s2, obj.?);
}

pub fn setTrack(title: ?[]const u8, artist: ?[]const u8, art_url: ?[]const u8, duration_ms: i64) void {
    g_duration_ms = duration_ms;
    if (g_music == null) {
        log("apl/smtc: setTrack but music props unavailable");
        return;
    }
    if (title) |t| setMusicProp(.title, t);
    if (artist) |a| {
        setMusicProp(.artist, a);
        setMusicProp(.album_artist, a);
    }
    if (g_display) |d| _ = vtbl(DisplayVtbl, d).Update(d);
    if (art_url) |u| spawnArtwork(u);
    log("apl/smtc: setTrack done");
}

pub fn setPlayback(state: i32, position_ms: i64) void {
    const smtc = g_smtc orelse return;
    const st: i32 = switch (state) {
        0 => PlaybackStatus.stopped,
        1 => PlaybackStatus.playing,
        else => PlaybackStatus.paused,
    };
    _ = vtbl(SmtcVtbl, smtc).put_PlaybackStatus(smtc, st);
    updateTimeline(position_ms);
    log("apl/smtc: setPlayback done");
    // 播放速率（1.0 播放 / 0.0 暂停）让系统自行外推进度
    if (ensureSmtc2()) |s2| {
        _ = vtbl(Smtc2Vtbl, s2).put_PlaybackRate(s2, if (state == 1) 1.0 else 0.0);
    }
}

pub fn deinit() void {
    if (g_smtc) |s| {
        const sv = vtbl(SmtcVtbl, s);
        if (g_button_registered) _ = sv.remove_ButtonPressed(s, g_button_token);
        _ = sv.base.Release(s);
        g_smtc = null;
    }
    release(g_smtc2);
    g_smtc2 = null;
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

/// 冒烟自检：ButtonPressed 委托是否注册成功（add_ButtonPressed == S_OK）。
pub fn debugIsButtonRegistered() bool {
    return g_button_registered;
}
