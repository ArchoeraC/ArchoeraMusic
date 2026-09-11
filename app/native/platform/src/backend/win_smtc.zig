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
const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));

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
const CoCreateFreeThreadedMarshalerFn = *const fn (?*anyopaque, *?*anyopaque) callconv(.c) HRESULT;

var g_combase: win.HMODULE = null;
var p_RoInitialize: ?RoInitializeFn = null;
var p_RoGetActivationFactory: ?RoGetActivationFactoryFn = null;
var p_RoActivateInstance: ?RoActivateInstanceFn = null;
var p_WindowsCreateString: ?WindowsCreateStringFn = null;
var p_WindowsDeleteString: ?WindowsDeleteStringFn = null;
var p_CoCreateFreeThreadedMarshaler: ?CoCreateFreeThreadedMarshalerFn = null;

fn loadCombase() bool {
    if (g_combase != null) return true;
    const h = win.LoadLibraryA("combase.dll") orelse return false;
    g_combase = h;
    p_RoInitialize = @ptrCast(win.GetProcAddress(h, "RoInitialize"));
    p_RoGetActivationFactory = @ptrCast(win.GetProcAddress(h, "RoGetActivationFactory"));
    p_RoActivateInstance = @ptrCast(win.GetProcAddress(h, "RoActivateInstance"));
    p_WindowsCreateString = @ptrCast(win.GetProcAddress(h, "WindowsCreateString"));
    p_WindowsDeleteString = @ptrCast(win.GetProcAddress(h, "WindowsDeleteString"));
    // CoCreateFreeThreadedMarshaler：委托封送（IMarshal）用；ole32 提供。
    if (win.LoadLibraryA("ole32.dll")) |ho| {
        p_CoCreateFreeThreadedMarshaler = @ptrCast(win.GetProcAddress(ho, "CoCreateFreeThreadedMarshaler"));
    }
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
// IOutputStream {905a0fe6-bc53-11df-8c49-001e4fc686da}
const IID_IOUTPUTSTREAM = win.GUID{
    .Data1 = 0x905a0fe6,
    .Data2 = 0xbc53,
    .Data3 = 0x11df,
    .Data4 = .{ 0x8c, 0x49, 0x00, 0x1e, 0x4f, 0xc6, 0x86, 0xda },
};
// IDataWriterFactory {338c67c2-8b84-4c2b-9c50-7b8767847a1f}
const IID_IDATAWRITERFACTORY = win.GUID{
    .Data1 = 0x338c67c2,
    .Data2 = 0x8b84,
    .Data3 = 0x4c2b,
    .Data4 = .{ 0x9c, 0x50, 0x7b, 0x87, 0x67, 0x84, 0x7a, 0x1f },
};

// 事件委托 QI 策略：本对象只实现了 IUnknown + Invoke（WinRT 委托的 ABI 布局，
// 见 mingw `windows.foundation.h` 的 `*CompletedHandler` vtable：QueryInterface/
// AddRef/Release/Invoke 共 4 槽，**不**继承 IInspectable）。任何其它接口都绝不
// 能应答 S_OK——combase 会按该接口的 vtable 槽调用，而本对象只有 4 槽，会读到
// 越界/错位的函数指针。真 Windows 上标准封送会依次查询：
//   IMarshal（拒绝）→ IStdMarshalInfo::GetClassForHandler（槽 3）→ 被当成 Invoke
//   → 拿 pvDestContext 当事件参数解引用 → combase.dll 0xC0000005。
// Wine 的 SMTC 是 stub、不做封送，故不崩（只在真机复现）。
// IUnknown {00000000-0000-0000-C000-000000000046}
const IID_IUNKNOWN = win.GUID{
    .Data1 = 0x00000000,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};
// IAgileObject {94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90}（委托必须应答，事件才能
// 跨 apartment 直接回调；见 init 注释）
const IID_IAGILEOBJECT = win.GUID{
    .Data1 = 0x94EA2B94,
    .Data2 = 0xE9CC,
    .Data3 = 0x49E0,
    .Data4 = .{ 0xC0, 0xFF, 0xEE, 0x64, 0xCA, 0x8F, 0x5B, 0x90 },
};
// IInspectable {AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90}（非保留段，单独拒绝）
const IID_IINSPECTABLE = win.GUID{
    .Data1 = 0xAF86E2E0,
    .Data2 = 0xB12D,
    .Data3 = 0x4C6A,
    .Data4 = .{ 0x9C, 0x5A, 0xD7, 0xAA, 0x65, 0x10, 0x1E, 0x90 },
};
// ICallFactory {1C733A30-2A1C-11CE-ADE5-00AA0044773D}（非保留段，单独拒绝）
const IID_ICALLFACTORY = win.GUID{
    .Data1 = 0x1C733A30,
    .Data2 = 0x2A1C,
    .Data3 = 0x11CE,
    .Data4 = .{ 0xAD, 0xE5, 0x00, 0xAA, 0x00, 0x44, 0x77, 0x3D },
};
// IMarshal {00000003-0000-0000-C000-000000000046}（经典 COM）。委托封送时 combase
// 会 QI 它；**必须应答**，但返回的不能是本对象（只有 4 槽），而是
// CoCreateFreeThreadedMarshaler 的包装（对齐 windows-rs DelegateBox::QueryInterface）。
const IID_IMARSHAL = win.GUID{
    .Data1 = 0x00000003,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

/// 标准 COM 保留 IID 段 {000000xx-0000-0000-C000-000000000046}（含 IMarshal /
/// IStdMarshalInfo / IWeakReferenceSource / INoMarshal 等）。IUnknown 也落在
/// 本段，故调用方须先单独放行 IUnknown。这些接口本对象均未实现，标准封送期间
/// 若误应答 S_OK 即触发上文所述的错位槽调用崩溃。
fn isReservedComIid(riid: *const win.GUID) bool {
    return riid.Data2 == 0 and riid.Data3 == 0 and
        riid.Data4[0] == 0xC0 and riid.Data4[1] == 0x00 and riid.Data4[2] == 0x00 and
        riid.Data4[3] == 0x00 and riid.Data4[4] == 0x00 and riid.Data4[5] == 0x00 and
        riid.Data4[6] == 0x00 and riid.Data4[7] == 0x46;
}

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
const PlaybackType = struct {
    const music: i32 = 1;
};

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

/// IDataWriterFactory（winmd 1 方法）。
const DataWriterFactoryVtbl = extern struct {
    base: Inspectable,
    CreateDataWriter: *const fn (*anyopaque, ?*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
};

/// IDataWriter（槽位顺序 = wine `windows.storage.streams.h`；仅用 WriteBytes / StoreAsync）。
const DataWriterVtbl = extern struct {
    base: Inspectable,
    get_UnstoredBufferLength: *const fn (*anyopaque, *u32) callconv(.c) HRESULT,
    get_UnicodeEncoding: *const fn (*anyopaque, *i32) callconv(.c) HRESULT,
    put_UnicodeEncoding: *const fn (*anyopaque, i32) callconv(.c) HRESULT,
    get_ByteOrder: *const fn (*anyopaque, *i32) callconv(.c) HRESULT,
    put_ByteOrder: *const fn (*anyopaque, i32) callconv(.c) HRESULT,
    WriteByte: *const fn (*anyopaque, u8) callconv(.c) HRESULT,
    WriteBytes: *const fn (*anyopaque, u32, [*]const u8) callconv(.c) HRESULT,
    WriteBuffer: *const fn (*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
    WriteBufferRange: *const fn (*anyopaque, ?*anyopaque, u32, u32) callconv(.c) HRESULT,
    WriteBoolean: *const fn (*anyopaque, boolean) callconv(.c) HRESULT,
    WriteGuid: *const fn (*anyopaque, win.GUID) callconv(.c) HRESULT,
    WriteInt16: *const fn (*anyopaque, i16) callconv(.c) HRESULT,
    WriteInt32: *const fn (*anyopaque, i32) callconv(.c) HRESULT,
    WriteInt64: *const fn (*anyopaque, i64) callconv(.c) HRESULT,
    WriteUInt16: *const fn (*anyopaque, u16) callconv(.c) HRESULT,
    WriteUInt32: *const fn (*anyopaque, u32) callconv(.c) HRESULT,
    WriteUInt64: *const fn (*anyopaque, u64) callconv(.c) HRESULT,
    WriteSingle: *const fn (*anyopaque, f32) callconv(.c) HRESULT,
    WriteDouble: *const fn (*anyopaque, f64) callconv(.c) HRESULT,
    WriteDateTime: *const fn (*anyopaque, i64) callconv(.c) HRESULT,
    WriteTimeSpan: *const fn (*anyopaque, i64) callconv(.c) HRESULT,
    WriteString: *const fn (*anyopaque, HSTRING, *u32) callconv(.c) HRESULT,
    MeasureString: *const fn (*anyopaque, HSTRING, *u32) callconv(.c) HRESULT,
    StoreAsync: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    FlushAsync: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    DetachBuffer: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    DetachStream: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
};

/// IAsyncOperation<UINT32>（IAsyncInfo 5 + put/get_Completed + GetResults）。
const AsyncOpU32Vtbl = extern struct {
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

/// IAsyncOperationCompletedHandler<UINT32> 的委托布局（第 3 参为枚举 AsyncStatus=i32）。
const ThumbHandlerVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const win.GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
    Invoke: *const fn (*anyopaque, ?*anyopaque, i32) callconv(.c) HRESULT,
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

/// 委托 QI：放行 IUnknown / IAgileObject / 运行期生成的委托 IID（非保留段且
/// 非 IInspectable / ICallFactory）；**IMarshal 特殊**——返回自由线程封送器包装
/// （见 [createMarshaler]），不能返回本对象；其余（IStdMarshalInfo /
/// IWeakReferenceSource / IInspectable / ICallFactory…）一律 E_NOINTERFACE。
///
/// 历史：旧实现对未实现接口一律应答 S_OK，combase 标准封送会按错位 vtable 槽调用
/// （Invoke 被当成 GetClassForHandler / GetIids / GetUnmarshalClass）→ 0xC0000005。
/// 后改为「拒绝 IMarshal」，仍崩——因为 combase 封送委托**必须**拿到 IMarshal，
/// 拒绝后走标准封送同样错调。正解对齐 windows-rs `DelegateBox::QueryInterface`：
/// 对 IMarshal 返回 `CoCreateFreeThreadedMarshaler` 包装。
/// 注：函数声明顺序在 Zig 容器内不敏感，无需前置声明。
fn handlerQI(this: *anyopaque, riid: *const win.GUID, out: *?*anyopaque) callconv(.c) HRESULT {
    // IMarshal：combase 封送委托时必查。返回自由线程封送器包装（不能返回本对象，
    // 否则按 9 槽 IMarshal 错调 4 槽本对象 → 崩溃）。
    if (guidEq(IID_IMARSHAL, riid)) return createMarshaler(this, out);
    const supported = guidEq(IID_IUNKNOWN, riid) or guidEq(IID_IAGILEOBJECT, riid) or
        (!isReservedComIid(riid) and !guidEq(IID_IINSPECTABLE, riid) and
            !guidEq(IID_ICALLFACTORY, riid));
    if (supported) {
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

// ── 封面缩略图：Chromium 方案（InMemoryRandomAccessStream + DataWriter +
//    StoreAsync 完成回调 → CreateFromStream → put_Thumbnail → Update）──
// 流/writer/op 持有到回调完成（对齐 Chromium 的成员变量，防异步完成前析构）。
var g_thumb_stream: ?*anyopaque = null;
var g_thumb_writer: ?*anyopaque = null;
var g_thumb_op: ?*anyopaque = null;

fn thumbInvoke(this: *anyopaque, async_info: ?*anyopaque, status: i32) callconv(.c) HRESULT {
    _ = this;
    _ = async_info;
    _ = status;
    const stream = g_thumb_stream orelse return S_OK;
    if (g_display == null) return S_OK;
    const rs = rasrStatics() orelse return S_OK;
    defer release(rs);
    var ref: ?*anyopaque = null;
    if (vtbl(RasrStaticsVtbl, rs).CreateFromStream(rs, stream, &ref) != S_OK or ref == null) return S_OK;
    defer release(ref);
    _ = vtbl(DisplayVtbl, g_display.?).put_Thumbnail(g_display.?, ref);
    _ = vtbl(DisplayVtbl, g_display.?).Update(g_display.?);
    log("apl/smtc: thumbnail set (mem async)");
    return S_OK;
}

const THUMB_HANDLER_VTBL = ThumbHandlerVtbl{
    .QueryInterface = handlerQI,
    .AddRef = handlerAddRef,
    .Release = handlerRelease,
    .Invoke = thumbInvoke,
};
var g_thumb_handler_obj = HandlerObj{ .vtbl = @ptrCast(&THUMB_HANDLER_VTBL), .ref = 1 };

// ── IMarshal 包装（委托封送；对齐 windows-rs imp/marshaler.rs）──────────
//
// combase 跨 apartment 封送委托时会 QI IMarshal。本对象只有 4 槽，不能把自己当
// IMarshal 返回（会按 9 槽错调 → combase 0xC0000005）。故用
// CoCreateFreeThreadedMarshaler 建自由线程封送器，再包一层：QI(IMarshal) 返回
// 包装自身，其余 IID 转发给委托对象；6 个 IMarshal 方法转发给自由线程封送器。

const UnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const win.GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
};

const IMarshalVtbl = extern struct {
    base: UnknownVtbl,
    GetUnmarshalClass: *const fn (*anyopaque, *const win.GUID, ?*const anyopaque, u32, ?*const anyopaque, u32, *win.GUID) callconv(.c) HRESULT,
    GetMarshalSizeMax: *const fn (*anyopaque, *const win.GUID, ?*const anyopaque, u32, ?*const anyopaque, u32, *u32) callconv(.c) HRESULT,
    MarshalInterface: *const fn (*anyopaque, ?*anyopaque, *const win.GUID, ?*const anyopaque, u32, ?*const anyopaque, u32) callconv(.c) HRESULT,
    UnmarshalInterface: *const fn (*anyopaque, ?*anyopaque, *const win.GUID, *?*anyopaque) callconv(.c) HRESULT,
    ReleaseMarshalData: *const fn (*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
    DisconnectObject: *const fn (*anyopaque, u32) callconv(.c) HRESULT,
};

const MarshalerObj = extern struct {
    vtbl: *const IMarshalVtbl,
    outer: *anyopaque,
    marshaler: *anyopaque,
    ref: u32,
};

fn marshalerQI(this: *anyopaque, riid: *const win.GUID, out: *?*anyopaque) callconv(.c) HRESULT {
    const o: *MarshalerObj = @ptrCast(@alignCast(this));
    if (guidEq(IID_IMARSHAL, riid)) {
        o.ref += 1;
        out.* = this;
        return S_OK;
    }
    return handlerQI(o.outer, riid, out);
}
fn marshalerAddRef(this: *anyopaque) callconv(.c) u32 {
    const o: *MarshalerObj = @ptrCast(@alignCast(this));
    o.ref += 1;
    return o.ref;
}
fn marshalerRelease(this: *anyopaque) callconv(.c) u32 {
    const o: *MarshalerObj = @ptrCast(@alignCast(this));
    o.ref -%= 1;
    if (o.ref == 0) {
        _ = vtbl(UnknownVtbl, o.marshaler).Release(o.marshaler);
        alloc.destroy(o);
    }
    return o.ref;
}
fn marshalerGetUnmarshalClass(this: *anyopaque, riid: *const win.GUID, pv: ?*const anyopaque, ctx: u32, pvctx: ?*const anyopaque, flags: u32, pcid: *win.GUID) callconv(.c) HRESULT {
    const o: *MarshalerObj = @ptrCast(@alignCast(this));
    return vtbl(IMarshalVtbl, o.marshaler).GetUnmarshalClass(o.marshaler, riid, pv, ctx, pvctx, flags, pcid);
}
fn marshalerGetMarshalSizeMax(this: *anyopaque, riid: *const win.GUID, pv: ?*const anyopaque, ctx: u32, pvctx: ?*const anyopaque, flags: u32, psize: *u32) callconv(.c) HRESULT {
    const o: *MarshalerObj = @ptrCast(@alignCast(this));
    return vtbl(IMarshalVtbl, o.marshaler).GetMarshalSizeMax(o.marshaler, riid, pv, ctx, pvctx, flags, psize);
}
fn marshalerMarshalInterface(this: *anyopaque, stm: ?*anyopaque, riid: *const win.GUID, pv: ?*const anyopaque, ctx: u32, pvctx: ?*const anyopaque, flags: u32) callconv(.c) HRESULT {
    const o: *MarshalerObj = @ptrCast(@alignCast(this));
    return vtbl(IMarshalVtbl, o.marshaler).MarshalInterface(o.marshaler, stm, riid, pv, ctx, pvctx, flags);
}
fn marshalerUnmarshalInterface(this: *anyopaque, stm: ?*anyopaque, riid: *const win.GUID, ppv: *?*anyopaque) callconv(.c) HRESULT {
    const o: *MarshalerObj = @ptrCast(@alignCast(this));
    return vtbl(IMarshalVtbl, o.marshaler).UnmarshalInterface(o.marshaler, stm, riid, ppv);
}
fn marshalerReleaseMarshalData(this: *anyopaque, stm: ?*anyopaque) callconv(.c) HRESULT {
    const o: *MarshalerObj = @ptrCast(@alignCast(this));
    return vtbl(IMarshalVtbl, o.marshaler).ReleaseMarshalData(o.marshaler, stm);
}
fn marshalerDisconnectObject(this: *anyopaque, reserved: u32) callconv(.c) HRESULT {
    const o: *MarshalerObj = @ptrCast(@alignCast(this));
    return vtbl(IMarshalVtbl, o.marshaler).DisconnectObject(o.marshaler, reserved);
}

const MARSHALER_VTBL = IMarshalVtbl{
    .base = .{
        .QueryInterface = marshalerQI,
        .AddRef = marshalerAddRef,
        .Release = marshalerRelease,
    },
    .GetUnmarshalClass = marshalerGetUnmarshalClass,
    .GetMarshalSizeMax = marshalerGetMarshalSizeMax,
    .MarshalInterface = marshalerMarshalInterface,
    .UnmarshalInterface = marshalerUnmarshalInterface,
    .ReleaseMarshalData = marshalerReleaseMarshalData,
    .DisconnectObject = marshalerDisconnectObject,
};

/// 为委托对象 [outer] 构造 IMarshal 包装（对齐 windows-rs `marshaler()`）。
fn createMarshaler(outer: *anyopaque, out: *?*anyopaque) HRESULT {
    const f = p_CoCreateFreeThreadedMarshaler orelse return E_NOINTERFACE;
    var ft: ?*anyopaque = null;
    if (f(null, &ft) != S_OK or ft == null) return E_NOINTERFACE;
    var m: ?*anyopaque = null;
    const hr = vtbl(UnknownVtbl, ft.?).QueryInterface(ft.?, &IID_IMARSHAL, &m);
    _ = vtbl(UnknownVtbl, ft.?).Release(ft.?); // 丢弃初始 IUnknown 引用
    if (hr != S_OK or m == null) return E_NOINTERFACE;
    const o = alloc.create(MarshalerObj) catch {
        _ = vtbl(UnknownVtbl, m.?).Release(m.?);
        return E_OUTOFMEMORY;
    };
    o.* = .{ .vtbl = &MARSHALER_VTBL, .outer = outer, .marshaler = m.?, .ref = 1 };
    out.* = @ptrCast(o);
    return S_OK;
}

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

/// 设置封面缩略图（http(s) URL 走 CreateFromUri；本地路径走 CreateFromFile）。
/// 注意：`g_display` 是在 SMTC 所属 apartment（Flutter 平台线程，多为 STA）上
/// 取得的同单元接口，**必须**在该线程调用；另起线程（MTA）直接使用会触发
/// combase.dll 访问冲突（0xC0000005）——故此处同步执行、不再 spawn 线程。
fn setArtwork(url: []const u8, bytes: ?[]const u8) void {
    if (g_display == null) return;
    // 本地封面：内存流 + 异步 store（完成回调里 put_Thumbnail + Update）。
    if (bytes) |b| {
        if (b.len > 0) {
            setArtworkFromMemory(b);
            return;
        }
    }
    // http 封面：Uri → CreateFromUri（同步）。
    const is_http = std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
    if (!is_http) return;
    log("apl/smtc: artwork http");
    const ref = refFromUri(url) orelse {
        log("apl/smtc: artwork ref failed");
        return;
    };
    defer release(ref);
    _ = vtbl(DisplayVtbl, g_display.?).put_Thumbnail(g_display.?, ref);
    _ = vtbl(DisplayVtbl, g_display.?).Update(g_display.?);
    log("apl/smtc: thumbnail set (uri)");
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

/// 本地封面：Chromium 方案——`InMemoryRandomAccessStream` → `DataWriter.WriteBytes`
/// → `StoreAsync`（完成回调里 `CreateFromStream` → `put_Thumbnail` → `Update`）。
/// 全程 WinRT 原生内存流：无文件、无 StorageFile、无同步等待/轮询。
fn setArtworkFromMemory(bytes: []const u8) void {
    if (g_display == null or bytes.len == 0) return;
    const cls = makeHString("Windows.Storage.Streams.InMemoryRandomAccessStream") orelse return;
    defer _ = p_WindowsDeleteString.?(cls);
    var stream: ?*anyopaque = null;
    if (p_RoActivateInstance.?(cls, &stream) != S_OK or stream == null) return;
    var out: ?*anyopaque = null;
    if (vtbl(Inspectable, stream.?).QueryInterface(stream.?, &IID_IOUTPUTSTREAM, &out) != S_OK or out == null) {
        release(stream);
        return;
    }
    defer release(out);
    const wcls = makeHString("Windows.Storage.Streams.DataWriter") orelse {
        release(stream);
        return;
    };
    defer _ = p_WindowsDeleteString.?(wcls);
    var factory: ?*anyopaque = null;
    if (p_RoGetActivationFactory.?(wcls, &IID_IDATAWRITERFACTORY, &factory) != S_OK or factory == null) {
        release(stream);
        return;
    }
    defer release(factory);
    var writer: ?*anyopaque = null;
    if (vtbl(DataWriterFactoryVtbl, factory.?).CreateDataWriter(factory.?, out, &writer) != S_OK or writer == null) {
        release(stream);
        return;
    }
    _ = vtbl(DataWriterVtbl, writer.?).WriteBytes(writer.?, @intCast(bytes.len), bytes.ptr);
    var op: ?*anyopaque = null;
    if (vtbl(DataWriterVtbl, writer.?).StoreAsync(writer.?, &op) != S_OK or op == null) {
        release(writer.?);
        release(stream);
        return;
    }
    // 持有流/writer/op 到回调完成（对齐 Chromium 成员变量）；释放上一组。
    release(g_thumb_op);
    release(g_thumb_writer);
    release(g_thumb_stream);
    g_thumb_stream = stream;
    g_thumb_writer = writer.?;
    g_thumb_op = op.?;
    _ = vtbl(AsyncOpU32Vtbl, op.?).put_Completed(op.?, @ptrCast(&g_thumb_handler_obj));
    log("apl/smtc: artwork mem (async store)");
}

pub fn setTrack(title: ?[]const u8, artist: ?[]const u8, art_url: ?[]const u8, duration_ms: i64, art_bytes: ?[]const u8) void {
    _ = duration_ms;
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
    if (art_bytes) |b| {
        if (b.len > 0) {
            setArtwork(art_url orelse "", b);
        } else if (art_url) |u| {
            setArtwork(u, null);
        }
    } else if (art_url) |u| {
        setArtwork(u, null);
    }
    log("apl/smtc: setTrack done");
}

pub fn setPlayback(state: i32, position_ms: i64) void {
    _ = position_ms;
    const smtc = g_smtc orelse return;
    const st: i32 = switch (state) {
        0 => PlaybackStatus.stopped,
        1 => PlaybackStatus.playing,
        else => PlaybackStatus.paused,
    };
    _ = vtbl(SmtcVtbl, smtc).put_PlaybackStatus(smtc, st);
    log("apl/smtc: setPlayback done");
}

pub fn deinit() void {
    if (g_smtc) |s| {
        const sv = vtbl(SmtcVtbl, s);
        if (g_button_registered) _ = sv.remove_ButtonPressed(s, g_button_token);
        _ = sv.base.Release(s);
        g_smtc = null;
    }
    release(g_thumb_op);
    release(g_thumb_writer);
    release(g_thumb_stream);
    g_thumb_op = null;
    g_thumb_writer = null;
    g_thumb_stream = null;
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
