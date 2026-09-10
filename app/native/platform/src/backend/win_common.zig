//! 共享 WinRT/Win32 C 导入（backend_windows 与 win_smtc 共用，保证类型一致）。
pub const c = @cImport({
    @cInclude("windows.h");
    @cInclude("powrprof.h");
    @cInclude("roapi.h");
    @cInclude("hstring.h");
    @cInclude("systemmediatransportcontrolsinterop.h");
});
