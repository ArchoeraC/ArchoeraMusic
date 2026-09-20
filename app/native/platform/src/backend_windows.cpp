// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Windows 后端（MSVC C++）：Win32（防休眠 / 熄屏 / 窗口状态 / 单实例 /
//! 主题色）+ WinRT（SMTC 媒体会话、原生 Toast）。
//!
//! 由 CMake 以 MSVC 编译（见 CMakeLists.txt）。WinRT 部分在 cppwinrt 头可得时
//! 自动启用（`__has_include(<winrt/base.h>)`）；否则降级（SMTC 静默禁用、Toast
//! 走 MessageBox）。
//!
//! SMTC 对齐 Chromium `system_media_controls_win.cc`：C++/WinRT 标准委托注册
//! `ButtonPressed`；窗口用调用线程自建的隐藏窗口（对齐 `gfx::SingletonHwnd`）。

#include "backend.h"

#include "core.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <unknwn.h>

#include <dwmapi.h>
#include <propkey.h>
#include <propvarutil.h>
#include <shlobj.h>
// ShellExecuteW / ILCreateFromPathW / ILFree 等 shell 助手：WIN32_LEAN_AND_MEAN
// 下 windows.h 不再隐式包含 shellapi.h，需显式引入（否则 MSVC C2039/C3861）。
#include <shellapi.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>

#if defined(__has_include)
#if __has_include(<winrt/base.h>)
#define ARCHOERA_WINRT 1
#endif
#endif

#ifdef ARCHOERA_WINRT
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Media.Core.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Notifications.h>
#include <winrt/Windows.UI.ViewManagement.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#endif

namespace archoera {
namespace {

// ── 诊断日志 ──────────────────────────────────────────────────────
// 同时写 OutputDebugStringA（DebugView）与多个日志文件：
//   <exe 同级>\archoera_smtc.log / %TEMP%\archoera_smtc.log /
//   %USERPROFILE%\archoera_smtc.log / C:\archoera_smtc.log
constexpr int kLogMaxPaths = 4;
char g_log_paths[kLogMaxPaths][MAX_PATH] = {};
int g_log_path_count = 0;

void tryAddLogPath(const char* full) {
    if (g_log_path_count >= kLogMaxPaths) return;
    FILE* f = nullptr;
    if (fopen_s(&f, full, "a") == 0 && f != nullptr) {
        std::fclose(f);
        std::snprintf(g_log_paths[g_log_path_count], MAX_PATH, "%s", full);
        g_log_path_count++;
    }
}

void initLogPath() {
    if (g_log_path_count > 0) return;
    char buf[MAX_PATH];
    if (::GetModuleFileNameA(nullptr, buf, MAX_PATH) > 0) {
        char* slash = nullptr;
        for (char* p = buf; *p; ++p) {
            if (*p == '\\' || *p == '/') slash = p;
        }
        if (slash != nullptr) *slash = 0;
        char p2[MAX_PATH];
        std::snprintf(p2, MAX_PATH, "%s\\archoera_smtc.log", buf);
        tryAddLogPath(p2);
    }
    if (::GetTempPathA(MAX_PATH, buf) > 0) {
        char p2[MAX_PATH];
        std::snprintf(p2, MAX_PATH, "%sarchoera_smtc.log", buf);
        tryAddLogPath(p2);
    }
    const DWORD n = ::GetEnvironmentVariableA("USERPROFILE", buf, MAX_PATH);
    if (n > 0 && n < MAX_PATH) {
        char p2[MAX_PATH];
        std::snprintf(p2, MAX_PATH, "%s\\archoera_smtc.log", buf);
        tryAddLogPath(p2);
    }
    tryAddLogPath("C:\\archoera_smtc.log");
}

void logRaw(const char* line) {
    ::OutputDebugStringA(line);
    if (g_log_path_count == 0) initLogPath();
    SYSTEMTIME st;
    ::GetLocalTime(&st);
    for (int i = 0; i < g_log_path_count; i++) {
        FILE* f = nullptr;
        if (fopen_s(&f, g_log_paths[i], "a") != 0 || f == nullptr) continue;
        std::fprintf(f, "[%02d:%02d:%02d.%03d] %s\n", st.wHour, st.wMinute,
                     st.wSecond, st.wMilliseconds, line);
        std::fclose(f);
    }
}

void log(const char* msg) { logRaw(msg); }
void logHr(const char* prefix, int32_t hr) {
    char buf[160];
    std::snprintf(buf, sizeof(buf), "%s hr=0x%08X", prefix,
                  static_cast<unsigned>(hr));
    logRaw(buf);
}

void logReset() {
    initLogPath();
    for (int i = 0; i < g_log_path_count; i++) {
        FILE* f = nullptr;
        if (fopen_s(&f, g_log_paths[i], "w") == 0 && f != nullptr) std::fclose(f);
    }
}

// ── AppUserModelID + Toast 快捷方式 ──────────────────────────────
// Windows Toast 前提（官方文档 enable-desktop-toast-with-appusermodelid）：
//   1) 进程设显式 AUMID；
//   2) 开始菜单/All Programs 有一个带 `System.AppUserModel.ID` 的快捷方式，
//      其值与 CreateToastNotifier(appId) 一致——否则桌面应用**无法弹 Toast**。
// 安装器通常负责；便携版/首次运行由这里补齐（COM IShellLink 方案）。
constexpr wchar_t kAumid[] = L"Archoera.ArchoeraMusic";

void setAumid() {
    if (HMODULE shell = ::LoadLibraryA("shell32.dll")) {
        using Fn = HRESULT(WINAPI*)(PCWSTR);
        auto fn = reinterpret_cast<Fn>(
            ::GetProcAddress(shell, "SetCurrentProcessExplicitAppUserModelID"));
        if (fn != nullptr) fn(kAumid);
    }
}

// 是否"安装版"（与安装目录无关，用户可自定义）：
//   - Inno Setup（现行）在安装模式对应的 hive 写 Software\ArchoeraMusic（HKA：
//     per-user → HKCU，per-machine → HKLM）；
//   - 旧 NSIS（HKLM\...\Uninstall\ArchoeraMusic）、旧 per-user 卸载项（HKCU 同名）。
// 便携版无任何标记 → 不创建快捷方式（无痕）。读取 HKCU/HKLM 普通用户即可。
bool regKeyExists(HKEY root, const wchar_t* sub) {
    HKEY key = nullptr;
    const LSTATUS rc = ::RegOpenKeyExW(root, sub, 0, KEY_READ, &key);
    if (rc != ERROR_SUCCESS) return false;
    ::RegCloseKey(key);
    return true;
}

constexpr wchar_t kUninstallSubkey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\ArchoeraMusic";

// per-machine（为所有用户安装）：卸载项在 HKLM（Inno 在 admin 模式写 HKLM）。
// per-user 只在 HKCU；便携版两者皆无。
bool isAdminInstall() {
    return regKeyExists(HKEY_LOCAL_MACHINE, L"Software\\ArchoeraMusic") ||
           regKeyExists(HKEY_LOCAL_MACHINE, kUninstallSubkey);
}

bool isInstalled() {
    return isAdminInstall() ||
           regKeyExists(HKEY_CURRENT_USER, L"Software\\ArchoeraMusic") ||
           regKeyExists(HKEY_CURRENT_USER, kUninstallSubkey);
}

bool shortcutDisabledAt(HKEY root) {
    HKEY key = nullptr;
    if (::RegOpenKeyExW(root, L"Software\\ArchoeraMusic", 0, KEY_READ, &key) !=
        ERROR_SUCCESS) {
        return false;
    }
    DWORD value = 1;
    DWORD size = sizeof(value);
    DWORD type = 0;
    const LSTATUS rc = ::RegQueryValueExW(
        key, L"StartMenuShortcut", nullptr, &type,
        reinterpret_cast<LPBYTE>(&value), &size);
    ::RegCloseKey(key);
    return rc == ERROR_SUCCESS && type == REG_DWORD && value == 0;
}

// 安装器按用户在向导里的选择写入的开始菜单快捷方式偏好（1=创建，0=不创建）。
// 偏好写在安装模式对应的 hive（HKA）；缺省/旧版无此值 → 按创建处理。
// 用户禁用时不得为 Toast 悄悄重建。
bool startMenuShortcutDisabled() {
    return shortcutDisabledAt(isAdminInstall() ? HKEY_LOCAL_MACHINE
                                               : HKEY_CURRENT_USER);
}

// Toast 快捷方式必须与安装器建在**同一路径**，否则开始菜单会出现两份
// （安装器一份、这里一份）。安装器现已直接写 AUMID（见 [Icons] AppUserModelID），
// 这里仅作兜底：路径按安装模式取（per-machine → All Users 开始菜单），
// 若已带正确 AUMID 则不动；无写权限时保存失败即放弃（不产生第二份用户级快捷方式）。
void ensureToastShortcut() {
    if (!isInstalled()) return;              // 便携版不落任何痕迹
    if (startMenuShortcutDisabled()) return;  // 用户未选择开始菜单快捷方式

    // per-machine 用 %PROGRAMDATA%（All Users 开始菜单），per-user 用 %APPDATA%。
    const wchar_t* baseEnv = isAdminInstall() ? L"PROGRAMDATA" : L"APPDATA";
    wchar_t base[MAX_PATH] = {0};
    if (::GetEnvironmentVariableW(baseEnv, base, MAX_PATH) == 0) return;
    wchar_t dir[MAX_PATH];
    if (std::swprintf(
            dir, MAX_PATH,
            L"%s\\Microsoft\\Windows\\Start Menu\\Programs\\ArchoeraMusic",
            base) <= 0) {
        return;
    }
    wchar_t lnk[MAX_PATH];
    if (std::swprintf(lnk, MAX_PATH, L"%s\\ArchoeraMusic.lnk", dir) <= 0) return;

    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);  // 冲突/重复初始化忽略
    IShellLinkW* link = nullptr;
    if (FAILED(::CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&link)))) {
        return;
    }

    // 已存在且 AUMID 正确 → 不重写（避免每次启动触碰 .lnk）
    IPersistFile* file = nullptr;
    if (SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&file)))) {
        if (SUCCEEDED(file->Load(lnk, STGM_READ))) {
            IPropertyStore* store = nullptr;
            if (SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&store)))) {
                PROPVARIANT pv;
                ::PropVariantInit(&pv);
                const bool same =
                    SUCCEEDED(store->GetValue(PKEY_AppUserModel_ID, &pv)) &&
                    pv.vt == VT_LPWSTR && std::wcscmp(pv.pwszVal, kAumid) == 0;
                ::PropVariantClear(&pv);
                store->Release();
                if (same) {
                    file->Release();
                    link->Release();
                    return;
                }
            }
        }
        file->Release();
    }

    wchar_t exe[MAX_PATH] = {0};
    if (::GetModuleFileNameW(nullptr, exe, MAX_PATH) == 0) {
        link->Release();
        return;
    }

    ::CreateDirectoryW(dir, nullptr);  // 安装器已建；缺了则补建
    link->SetPath(exe);
    // 与安装器（Inno）默认一致：工作目录 = exe 所在目录
    wchar_t workdir[MAX_PATH] = {0};
    if (std::swprintf(workdir, MAX_PATH, L"%s", exe) > 0) {
        if (wchar_t* slash = std::wcsrchr(workdir, L'\\')) *slash = L'\0';
    }
    link->SetWorkingDirectory(workdir);
    link->SetArguments(L"");
    IPropertyStore* store = nullptr;
    if (SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&store)))) {
        PROPVARIANT pv;
        ::InitPropVariantFromString(kAumid, &pv);
        store->SetValue(PKEY_AppUserModel_ID, pv);
        store->Commit();
        ::PropVariantClear(&pv);
        store->Release();
    }
    if (SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&file)))) {
        if (FAILED(file->Save(lnk, TRUE))) {
            log("apl/smtc: toast shortcut save failed (no write access?)");
        }
        file->Release();
    }
    link->Release();
    log("apl/smtc: toast shortcut ensured");
}

// ── 窗口发现（Flutter Windows 顶层窗口）───────────────────────────
constexpr wchar_t kFlutterClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

HWND findFlutterWindow() {
    HWND hwnd = ::FindWindowW(kFlutterClass, nullptr);
    if (hwnd == nullptr) return nullptr;
    DWORD pid = 0;
    ::GetWindowThreadProcessId(hwnd, &pid);
    if (pid != ::GetCurrentProcessId()) return nullptr;
    return hwnd;
}

// ── 防休眠抑制（ES_CONTINUOUS 按线程生效 → 专用常驻线程）──────────
std::atomic<bool> g_inhibit_want{false};
std::atomic<bool> g_inhibit_run{false};
// 堆指针：宿主未调 apl_shutdown 就退出时不触发静态 std::thread 析构的 terminate。
std::thread* g_inhibit_thread = nullptr;

void inhibitThread() {
    bool applied = false;
    while (g_inhibit_run.load(std::memory_order_acquire)) {
        const bool want = g_inhibit_want.load(std::memory_order_acquire);
        if (want != applied) {
            ::SetThreadExecutionState(want
                                          ? (ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
                                          : ES_CONTINUOUS);
            applied = want;
        }
        ::Sleep(200);
    }
    if (applied) ::SetThreadExecutionState(ES_CONTINUOUS);
}

// ── 熄屏检测（PowerSettingRegisterNotification + 回调）────────────
using HPOWERNOTIFY = PVOID;
extern "C" {
DWORD WINAPI PowerSettingRegisterNotification(LPCGUID SettingGuid, DWORD Flags,
                                              HANDLE Recipient,
                                              HPOWERNOTIFY* RegistrationHandle);
DWORD WINAPI PowerSettingUnregisterNotification(HPOWERNOTIFY RegistrationHandle);
}

constexpr DWORD kDeviceNotifyCallback = 2;

// GUID_CONSOLE_DISPLAY_STATE {6fe69556-704a-47a0-8f24-c28d936fda47}
const GUID kGuidConsoleDisplayState = {
    0x6fe69556,
    0x704a,
    0x47a0,
    {0x8f, 0x24, 0xc2, 0x8d, 0x93, 0x6f, 0xda, 0x47}};

struct PowerBroadcastSetting {
    GUID power_setting;
    DWORD data_len;
    UCHAR data[1];
};

// 字段顺序对齐 Windows：DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS { Callback; Context; }
struct DeviceNotifySubscribeParams {
    ULONG(WINAPI* callback)(PVOID, ULONG, PVOID);
    PVOID context;
};

std::atomic<bool> g_screen_events{false};
HPOWERNOTIFY g_power_notify = nullptr;

ULONG WINAPI powerCallback(PVOID, ULONG, PVOID setting) {
    if (!g_screen_events.load(std::memory_order_acquire)) return 0;
    if (setting == nullptr) return 0;
    const auto* s = static_cast<const PowerBroadcastSetting*>(setting);
    if (s->data_len < 1) return 0;
    const bool on = s->data[0] != 0;  // 0=关屏 1=开屏
    dispatch(makeScreenState(!on));
    return 0;
}

DeviceNotifySubscribeParams g_subscribe = {&powerCallback, nullptr};

int32_t registerScreen() {
    if (g_power_notify != nullptr) return OK;
    const DWORD rc = PowerSettingRegisterNotification(
        &kGuidConsoleDisplayState, kDeviceNotifyCallback,
        reinterpret_cast<HANDLE>(&g_subscribe), &g_power_notify);
    return rc == 0 ? OK : ERR_BACKEND;
}

void unregisterScreen() {
    if (g_power_notify != nullptr) {
        PowerSettingUnregisterNotification(g_power_notify);
        g_power_notify = nullptr;
    }
}

// ── 窗口状态（子类化 Flutter 顶层 WndProc）+ WM_APPCOMMAND 媒体键 ──
WNDPROC g_orig_wndproc = nullptr;
HWND g_hwnd = nullptr;
std::atomic<bool> g_minimized{false};
std::atomic<bool> g_focused{true};
std::atomic<bool> g_window_events{false};

void emitWindow() {
    if (!g_window_events.load(std::memory_order_acquire)) return;
    dispatch(makeWindowState(g_minimized.load(std::memory_order_acquire),
                             g_focused.load(std::memory_order_acquire)));
}

// 现代 Windows 把媒体键（含蓝牙 AVRCP）经 SMTC 派发；SMTC 非当前会话/仅前台时
// 系统退化为 WM_APPCOMMAND。二者通常互斥，故并列处理不产生双触发。
bool dispatchAppCommand(LPARAM lparam) {
    const auto raw = static_cast<unsigned long long>(lparam);
    const unsigned app = static_cast<unsigned>((raw >> 16) & 0x0FFF);
    int32_t cmd = -1;
    switch (app) {
        case 11:  // APPCOMMAND_MEDIA_NEXTTRACK
            cmd = CMD_NEXT;
            break;
        case 12:  // APPCOMMAND_MEDIA_PREVIOUSTRACK
            cmd = CMD_PREV;
            break;
        case 13:  // APPCOMMAND_MEDIA_STOP
            cmd = CMD_STOP;
            break;
        case 14:  // APPCOMMAND_MEDIA_PLAY_PAUSE
            cmd = CMD_TOGGLE;
            break;
        case 46:  // APPCOMMAND_MEDIA_PLAY
            cmd = CMD_PLAY;
            break;
        case 47:  // APPCOMMAND_MEDIA_PAUSE
            cmd = CMD_PAUSE;
            break;
        default:
            return false;
    }
    dispatch(makeCommand(cmd));
    return true;
}

LRESULT CALLBACK wndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
        case WM_SIZE:
            g_minimized.store(wparam == SIZE_MINIMIZED,
                              std::memory_order_release);
            emitWindow();
            break;
        case WM_ACTIVATE: {
            const bool focused = (static_cast<unsigned>(wparam) & 0xffff) != 0;
            g_focused.store(focused, std::memory_order_release);
            emitWindow();
            break;
        }
        case WM_SHOWWINDOW:
            // 显示/隐藏（关闭到托盘 / 托盘还原）：隐藏同样视为不可见 → 降频；
            // 显示即复位。**不能**用 WM_CLOSE 判定——关闭是否真的隐藏由
            // window_manager 的 preventClose + Dart 侧决策（退出/隐藏/询问）
            // 决定：用户取消关闭确认框、或还原窗口后，WM_CLOSE 会让状态永久
            // 停在「已最小化」而误降频。
            g_minimized.store(wparam == 0, std::memory_order_release);
            emitWindow();
            break;
        case WM_APPCOMMAND:
            if (dispatchAppCommand(lparam)) return 1;  // 已消费，不再下传
            break;
        default:
            break;
    }
    return ::CallWindowProcW(g_orig_wndproc, hwnd, msg, wparam, lparam);
}

int32_t subclassWindow() {
    if (g_hwnd != nullptr) return OK;
    HWND hwnd = findFlutterWindow();
    if (hwnd == nullptr) return ERR_BACKEND;
    const auto proc = reinterpret_cast<LONG_PTR>(&wndProc);
    const LONG_PTR orig = ::SetWindowLongPtrW(hwnd, GWLP_WNDPROC, proc);
    if (orig == 0) return ERR_BACKEND;
    g_orig_wndproc = reinterpret_cast<WNDPROC>(orig);
    g_hwnd = hwnd;
    return OK;
}

void unsubclassWindow() {
    if (g_hwnd != nullptr && g_orig_wndproc != nullptr) {
        ::SetWindowLongPtrW(g_hwnd, GWLP_WNDPROC,
                            reinterpret_cast<LONG_PTR>(g_orig_wndproc));
    }
    g_hwnd = nullptr;
    g_orig_wndproc = nullptr;
}

// ── 单实例（命名互斥体，Local\ = 每登录会话一个实例）───────────────
HANDLE g_instance_mutex = nullptr;

// ── 系统主题色：HKCU\...\DWM\AccentColor（ABGR）→ DwmGetColorizationColor ──
constexpr DWORD kRrfRtRegDword = 0x00000010;

bool readDwmDword(const wchar_t* value, DWORD* out) {
    DWORD v = 0;
    DWORD sz = sizeof(v);
    const LSTATUS rc = ::RegGetValueW(
        HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\DWM", value,
        kRrfRtRegDword, nullptr, &v, &sz);
    if (rc != ERROR_SUCCESS) return false;
    *out = v;
    return true;
}

std::atomic<bool> g_accent_on{false};
std::thread* g_accent_thread = nullptr;

// systemAccent 由 backend.h 在 archoera 命名空间声明（定义见文件后部）。
void pushAccent() {
    int32_t r = 0, g = 0, b = 0;
    if (systemAccent(&r, &g, &b)) dispatch(makeSystemAccent(r, g, b));
}

void accentThread() {
    HKEY hkey = nullptr;
    if (::RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\DWM",
                        0, KEY_NOTIFY, &hkey) != ERROR_SUCCESS) {
        return;
    }
    HANDLE ev = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (ev == nullptr) {
        ::RegCloseKey(hkey);
        return;
    }
    // 订阅即推送一次当前值（平台推送模型）。
    pushAccent();
    while (g_accent_on.load(std::memory_order_acquire)) {
        if (::RegNotifyChangeKeyValue(hkey, FALSE, REG_NOTIFY_CHANGE_LAST_SET, ev,
                                      TRUE) != ERROR_SUCCESS) {
            break;
        }
        // 500ms 轮询退出标志（RegNotifyChangeKeyValue 阻塞不可取消）
        if (::WaitForSingleObject(ev, 500) == WAIT_OBJECT_0 &&
            g_accent_on.load(std::memory_order_acquire)) {
            pushAccent();
        }
    }
    ::CloseHandle(ev);
    ::RegCloseKey(hkey);
}

// ── 系统深浅色：HKCU\...\Themes\Personalize\AppsUseLightTheme（1=浅 0=深）──
std::atomic<bool> g_theme_on{false};
std::thread* g_theme_thread = nullptr;

bool readThemeDark() {
    DWORD v = 0;
    DWORD sz = sizeof(v);
    const LSTATUS rc = ::RegGetValueW(
        HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        L"AppsUseLightTheme", kRrfRtRegDword, nullptr, &v, &sz);
    if (rc != ERROR_SUCCESS) return false;  // 缺省浅色
    return v == 0;                          // 0=深色
}

void themeThread() {
    HKEY hkey = nullptr;
    if (::RegOpenKeyExW(
            HKEY_CURRENT_USER,
            L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
            0, KEY_NOTIFY, &hkey) != ERROR_SUCCESS) {
        return;
    }
    HANDLE ev = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (ev == nullptr) {
        ::RegCloseKey(hkey);
        return;
    }
    // 订阅即推送当前值（平台推送模型）。
    dispatch(makeSystemTheme(readThemeDark()));
    while (g_theme_on.load(std::memory_order_acquire)) {
        if (::RegNotifyChangeKeyValue(hkey, FALSE, REG_NOTIFY_CHANGE_LAST_SET, ev,
                                      TRUE) != ERROR_SUCCESS) {
            break;
        }
        if (::WaitForSingleObject(ev, 500) == WAIT_OBJECT_0 &&
            g_theme_on.load(std::memory_order_acquire)) {
            dispatch(makeSystemTheme(readThemeDark()));
        }
    }
    ::CloseHandle(ev);
    ::RegCloseKey(hkey);
}

// ── WinRT：SMTC + Toast ───────────────────────────────────────────
#ifdef ARCHOERA_WINRT
namespace winrt_smtc {

using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Media;
using namespace winrt::Windows::Media::Playback;
using namespace winrt::Windows::Storage::Streams;

// SMTC 走 `MediaPlayer` 自带的 SystemMediaTransportControls（见 init()）：
// - 不再用 ISystemMediaTransportControlsInterop::GetForWindow + 自建隐藏窗口。
//   GetForWindow 要求目标窗口所属线程泵消息（内部投递并等待），真机曾死锁；
// - MediaPlayer 由系统内部创建并持有一个 SMTC，无需窗口、无需消息泵，
//   也就没有"隐藏窗口 + 泵消息"的可疑特征（对齐用户决策）。

struct State {
    // 仅为承载 SMTC 而创建的 MediaPlayer（不喂 Source、不播放）。系统为每个
    // MediaPlayer 实例内部创建一个 SystemMediaTransportControls，故无需窗口。
    MediaPlayer player{nullptr};
    SystemMediaTransportControls controls{nullptr};
    SystemMediaTransportControlsDisplayUpdater updater{nullptr};
    MusicDisplayProperties music{nullptr};
    winrt::event_token button_token{};
    bool button_registered = false;
    bool initialized = false;
    int64_t duration_ms = 0;
    InMemoryRandomAccessStream icon_stream{nullptr};
    DataWriter icon_writer{nullptr};
    IAsyncOperation<uint32_t> icon_op{nullptr};
};

State*& stateSlot() {
    static State* s = nullptr;
    return s;
}

State& state() {
    State*& s = stateSlot();
    if (s == nullptr) s = new State();
    return *s;
}

winrt::hstring H(const char* data, int32_t len) {
    if (data == nullptr || len <= 0) return {};
    return winrt::to_hstring(std::string_view(data, static_cast<size_t>(len)));
}

void setThumbnailFromBytes(const uint8_t* bytes, int32_t len) {
    auto& s = state();
    if (!s.updater || bytes == nullptr || len <= 0) return;
    try {
        auto stream = InMemoryRandomAccessStream();
        DataWriter writer(stream.as<IOutputStream>());
        writer.WriteBytes(winrt::array_view<const uint8_t>(bytes, bytes + len));
        auto op = writer.StoreAsync();
        s.icon_stream = stream;
        s.icon_writer = writer;
        s.icon_op = op;
        op.Completed([stream](IAsyncOperation<uint32_t> const&, AsyncStatus status) {
            if (status != AsyncStatus::Completed) return;
            State*& sp = stateSlot();
            if (sp == nullptr || !sp->updater) return;
            try {
                auto ref = RandomAccessStreamReference::CreateFromStream(stream);
                sp->updater.Thumbnail(ref);
                sp->updater.Update();
            } catch (...) {
            }
        });
    } catch (...) {
    }
}

void setThumbnailFromUri(winrt::hstring const& url) {
    auto& s = state();
    if (!s.updater || url.empty()) return;
    try {
        auto ref = RandomAccessStreamReference::CreateFromUri(Uri(url));
        s.updater.Thumbnail(ref);
        s.updater.Update();
    } catch (...) {
    }
}

void probe() {
    char exe[MAX_PATH] = {0};
    ::GetModuleFileNameA(nullptr, exe, MAX_PATH);
    char buf[MAX_PATH + 64];
    std::snprintf(buf, sizeof(buf), "apl/smtc: dll loaded (probe) exe=%s", exe);
    logRaw(buf);
}

int32_t init() {
    auto& s = state();
    if (s.initialized) return OK;
    logReset();
    log("apl/smtc: init begin");
    try {
        try {
            winrt::init_apartment(winrt::apartment_type::single_threaded);
        } catch (winrt::hresult_error const& e) {
            logHr("apl/smtc: init_apartment", e.code());
        } catch (...) {
            log("apl/smtc: init_apartment unknown");
        }

        // 创建 MediaPlayer 只为拿它内部的 SMTC（不喂 Source、不播放）。关掉
        // CommandManager，避免它自动接管媒体键——我们自己在 ButtonPressed 里处理。
        s.player = MediaPlayer();
        log("apl/smtc: MediaPlayer created");
        auto command_manager = s.player.CommandManager();
        if (command_manager != nullptr) {
            command_manager.IsEnabled(false);
            log("apl/smtc: CommandManager disabled");
        }

        s.controls = s.player.SystemMediaTransportControls();
        if (s.controls == nullptr) {
            log("apl/smtc: SMTC null");
            return ERR_BACKEND;
        }
        log("apl/smtc: SMTC acquired");

        s.updater = s.controls.DisplayUpdater();
        s.updater.Type(MediaPlaybackType::Music);
        s.music = s.updater.MusicProperties();
        log("apl/smtc: display updater ok");

        s.button_token = s.controls.ButtonPressed(
            [](SystemMediaTransportControls const&,
               SystemMediaTransportControlsButtonPressedEventArgs const& args) {
                int32_t cmd = -1;
                switch (args.Button()) {
                    case SystemMediaTransportControlsButton::Play:
                        cmd = CMD_PLAY;
                        break;
                    case SystemMediaTransportControlsButton::Pause:
                        cmd = CMD_PAUSE;
                        break;
                    case SystemMediaTransportControlsButton::Stop:
                        cmd = CMD_STOP;
                        break;
                    case SystemMediaTransportControlsButton::Next:
                        cmd = CMD_NEXT;
                        break;
                    case SystemMediaTransportControlsButton::Previous:
                        cmd = CMD_PREV;
                        break;
                    default:
                        return;
                }
                log("apl/smtc: ButtonPressed");
                dispatch(makeCommand(cmd));
            });
        s.button_registered = true;
        log("apl/smtc: ButtonPressed registered");

        s.controls.IsEnabled(true);
        s.controls.IsPlayEnabled(true);
        s.controls.IsPauseEnabled(true);
        s.controls.IsNextEnabled(true);
        s.controls.IsPreviousEnabled(true);
        s.controls.IsStopEnabled(true);

        s.initialized = true;
        log("apl/smtc: ready");
        return OK;
    } catch (winrt::hresult_error const& e) {
        logHr("apl/smtc: init failed", e.code());
        return ERR_BACKEND;
    } catch (...) {
        log("apl/smtc: init failed unknown");
        return ERR_BACKEND;
    }
}

void setTrack(const AplTrackMeta* meta) {
    auto& s = state();
    if (!s.initialized || !s.updater) {
        log("apl/smtc: set_track but not initialized");
        return;
    }
    try {
        const AplString empty{};
        const AplString title = meta ? meta->title : empty;
        if (title.data == nullptr || title.len == 0) {
            s.updater.ClearAll();
            s.controls.IsEnabled(false);
            s.duration_ms = 0;
            return;
        }
        const AplString artist = meta ? meta->artist : empty;
        const AplString art_url = meta ? meta->art_url : empty;
        const AplString art_bytes = meta ? meta->art_bytes : empty;
        const int64_t duration = meta ? meta->duration_ms : -1;

        s.duration_ms = duration > 0 ? duration : 0;
        s.updater.Type(MediaPlaybackType::Music);
        s.music.Title(H(title.data, static_cast<int32_t>(title.len)));
        s.music.Artist(H(artist.data, static_cast<int32_t>(artist.len)));
        s.music.AlbumArtist(H(artist.data, static_cast<int32_t>(artist.len)));
        s.controls.IsEnabled(true);
        s.updater.Update();

        if (art_bytes.data != nullptr && art_bytes.len > 0) {
            setThumbnailFromBytes(
                reinterpret_cast<const uint8_t*>(art_bytes.data),
                static_cast<int32_t>(art_bytes.len));
        } else {
            setThumbnailFromUri(
                H(art_url.data, static_cast<int32_t>(art_url.len)));
        }
        log("apl/smtc: set_track done");
    } catch (winrt::hresult_error const& e) {
        logHr("apl/smtc: set_track failed", e.code());
    } catch (...) {
        log("apl/smtc: set_track failed unknown");
    }
}

void setPlayback(int32_t playback_state, int64_t position_ms, double speed) {
    auto& s = state();
    if (!s.initialized || !s.controls) {
        log("apl/smtc: set_playback but not initialized");
        return;
    }
    try {
        MediaPlaybackStatus st = MediaPlaybackStatus::Paused;
        switch (playback_state) {
            case 0:
                st = MediaPlaybackStatus::Stopped;
                break;
            case 1:
                st = MediaPlaybackStatus::Playing;
                break;
            default:
                st = MediaPlaybackStatus::Paused;
                break;
        }
        s.controls.PlaybackStatus(st);

        auto controls2 = s.controls.try_as<ISystemMediaTransportControls2>();
        if (controls2) {
            SystemMediaTransportControlsTimelineProperties timeline;
            const int64_t end = s.duration_ms > 0 ? s.duration_ms * 10000 : 0;
            timeline.StartTime(TimeSpan{0});
            timeline.MinSeekTime(TimeSpan{0});
            timeline.Position(TimeSpan{position_ms * 10000});
            timeline.EndTime(TimeSpan{end});
            timeline.MaxSeekTime(TimeSpan{end});
            controls2.UpdateTimelineProperties(timeline);
            controls2.PlaybackRate(speed);
        }
        log("apl/smtc: set_playback done");
    } catch (winrt::hresult_error const& e) {
        logHr("apl/smtc: set_playback failed", e.code());
    } catch (...) {
        log("apl/smtc: set_playback failed unknown");
    }
}

void deinit() {
    State*& sp = stateSlot();
    if (sp == nullptr || !sp->initialized) return;
    State& s = *sp;
    try {
        if (s.button_registered && s.controls) {
            s.controls.ButtonPressed(s.button_token);
            s.button_registered = false;
        }
        if (s.updater) s.updater.ClearAll();
        if (s.controls) s.controls.IsEnabled(false);
    } catch (...) {
    }
    s.icon_op = nullptr;
    s.icon_writer = nullptr;
    s.icon_stream = nullptr;
    s.music = nullptr;
    s.updater = nullptr;
    s.controls = nullptr;
    s.player = nullptr;
    s.duration_ms = 0;
    s.initialized = false;
    delete sp;
    sp = nullptr;
}

}  // namespace winrt_smtc

bool toastNative(const char* title, const char* body) {
    try {
        using namespace winrt::Windows::UI::Notifications;
        using namespace winrt::Windows::Data::Xml::Dom;

        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
        } catch (...) {
        }

        const std::string_view t = title != nullptr ? title : "";
        const std::string_view b = body != nullptr ? body : "";

        auto tmpl = ToastNotificationManager::GetTemplateContent(
            ToastTemplateType::ToastText02);
        auto texts = tmpl.GetElementsByTagName(L"text");
        texts.Item(0).AppendChild(tmpl.CreateTextNode(winrt::to_hstring(t)));
        texts.Item(1).AppendChild(tmpl.CreateTextNode(winrt::to_hstring(b)));
        ToastNotificationManager::CreateToastNotifier(winrt::hstring(kAumid))
            .Show(ToastNotification(tmpl));
        return true;
    } catch (...) {
        return false;
    }
}
#endif  // ARCHOERA_WINRT

void messageBox(const char* title, const char* body) {
    const int wn = ::MultiByteToWideChar(CP_UTF8, 0, body, -1, nullptr, 0);
    const int tn = ::MultiByteToWideChar(CP_UTF8, 0, title, -1, nullptr, 0);
    if (wn <= 0 || tn <= 0) return;
    std::wstring wbody(static_cast<size_t>(wn), L'\0');
    std::wstring wtitle(static_cast<size_t>(tn), L'\0');
    ::MultiByteToWideChar(CP_UTF8, 0, body, -1, wbody.data(), wn);
    ::MultiByteToWideChar(CP_UTF8, 0, title, -1, wtitle.data(), tn);
    ::MessageBoxW(nullptr, wbody.c_str(), wtitle.c_str(), MB_ICONINFORMATION);
}

// ── DeepLink / 协议唤醒（HKCU 注册 + 隐藏消息窗口 + WM_COPYDATA 转发）──
// 全程当前用户、免提权：scheme 写 HKCU\Software\Classes；跨实例转发用隐藏
// 消息窗口 + WM_COPYDATA（不依赖提权，也不起子进程）。
constexpr wchar_t kDeepLinkClass[] = L"ArchoeraMusic.DeepLink";
HWND g_deeplink_hwnd = nullptr;
std::mutex g_deeplink_mutex;
std::string g_deeplink_pending;  // UTF-8；单条待取

std::wstring utf8ToWideLocal(const char* s) {
    if (s == nullptr) return std::wstring();
    const int n = ::MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    if (n <= 1) return std::wstring();
    std::wstring out(static_cast<size_t>(n - 1), L'\0');
    ::MultiByteToWideChar(CP_UTF8, 0, s, -1, out.data(), n);
    return out;
}

std::string wideToUtf8Local(const wchar_t* s) {
    if (s == nullptr) return std::string();
    const int n =
        ::WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return std::string();
    std::string out(static_cast<size_t>(n - 1), '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, s, -1, out.data(), n, nullptr, nullptr);
    return out;
}

// 从命令行中提取首个 `archoera://` 参数（去引号；只认前缀，不解析内容）。
std::string extractUrlFromCommandLine(const wchar_t* cmd) {
    if (cmd == nullptr) return std::string();
    const std::wstring line(cmd);
    const std::wstring wprefix = L"archoera://";
    size_t pos = 0;
    while (pos < line.size()) {
        while (pos < line.size() && (line[pos] == L' ' || line[pos] == L'\t')) {
            pos++;
        }
        if (pos >= line.size()) break;
        std::wstring token;
        if (line[pos] == L'"') {
            pos++;
            while (pos < line.size() && line[pos] != L'"') {
                token.push_back(line[pos++]);
            }
            if (pos < line.size()) pos++;
        } else {
            while (pos < line.size() && line[pos] != L' ' && line[pos] != L'\t') {
                token.push_back(line[pos++]);
            }
        }
        if (token.size() >= wprefix.size() &&
            ::_wcsnicmp(token.c_str(), wprefix.c_str(), wprefix.size()) == 0) {
            return wideToUtf8Local(token.c_str());
        }
    }
    return std::string();
}

void activateFlutterWindow() {
    HWND hwnd = findFlutterWindow();
    if (hwnd == nullptr) return;
    if (::IsIconic(hwnd)) ::ShowWindow(hwnd, SW_RESTORE);
    ::SetForegroundWindow(hwnd);
}

void setPendingDeepLink(const std::string& url) {
    if (url.empty()) return;
    {
        std::lock_guard<std::mutex> lock(g_deeplink_mutex);
        g_deeplink_pending = url;
    }
    dispatch(makeDeepLink());
    activateFlutterWindow();
}

LRESULT CALLBACK deepLinkWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                 LPARAM lparam) {
    if (msg == WM_COPYDATA) {
        auto* cds = reinterpret_cast<COPYDATASTRUCT*>(lparam);
        if (cds != nullptr && cds->lpData != nullptr && cds->cbData > 0 &&
            cds->cbData < 8192) {
            std::string url(static_cast<const char*>(cds->lpData), cds->cbData);
            setPendingDeepLink(url);
            return TRUE;
        }
    } else if (msg == WM_APP + 0x51) {
        activateFlutterWindow();
        return 0;
    }
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

void ensureDeepLinkWindow() {
    if (g_deeplink_hwnd != nullptr) return;
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = deepLinkWndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.lpszClassName = kDeepLinkClass;
    ::RegisterClassExW(&wc);  // 已注册返回 0，忽略
    g_deeplink_hwnd = ::CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kDeepLinkClass,
        L"ArchoeraMusic.DeepLink", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
        wc.hInstance, nullptr);
}

void destroyDeepLinkWindow() {
    if (g_deeplink_hwnd != nullptr) {
        ::DestroyWindow(g_deeplink_hwnd);
        g_deeplink_hwnd = nullptr;
    }
}

int32_t protocolRegisterWin(const char* scheme) {
    if (scheme == nullptr || *scheme == '\0') return ERR_STATE;
    const std::wstring base =
        L"Software\\Classes\\" + utf8ToWideLocal(scheme);
    HKEY hkey = nullptr;
    if (::RegCreateKeyExW(HKEY_CURRENT_USER, base.c_str(), 0, nullptr, 0,
                          KEY_WRITE, nullptr, &hkey, nullptr) != ERROR_SUCCESS) {
        return ERR_BACKEND;
    }
    const wchar_t* desc = L"URL:ArchoeraMusic";
    ::RegSetValueExW(
        hkey, nullptr, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(desc),
        static_cast<DWORD>((std::wcslen(desc) + 1) * sizeof(wchar_t)));
    const wchar_t* url_protocol = L"";
    ::RegSetValueExW(hkey, L"URL Protocol", 0, REG_SZ,
                     reinterpret_cast<const BYTE*>(url_protocol),
                     sizeof(wchar_t));
    ::RegCloseKey(hkey);

    const std::wstring cmd_key = base + L"\\shell\\open\\command";
    if (::RegCreateKeyExW(HKEY_CURRENT_USER, cmd_key.c_str(), 0, nullptr, 0,
                          KEY_WRITE, nullptr, &hkey, nullptr) != ERROR_SUCCESS) {
        return ERR_BACKEND;
    }
    wchar_t exe[MAX_PATH] = {0};
    ::GetModuleFileNameW(nullptr, exe, MAX_PATH);
    const std::wstring cmd = L"\"" + std::wstring(exe) + L"\" \"%1\"";
    ::RegSetValueExW(hkey, nullptr, 0, REG_SZ,
                     reinterpret_cast<const BYTE*>(cmd.c_str()),
                     static_cast<DWORD>((cmd.size() + 1) * sizeof(wchar_t)));
    ::RegCloseKey(hkey);
    return OK;
}

int32_t protocolUnregisterWin(const char* scheme) {
    if (scheme == nullptr || *scheme == '\0') return ERR_STATE;
    const std::wstring base =
        L"Software\\Classes\\" + utf8ToWideLocal(scheme);
    ::RegDeleteTreeW(HKEY_CURRENT_USER, base.c_str());
    return OK;
}

// 静态缓冲：out 指向它，下次调用前有效（Dart 立即拷贝）。
std::string g_deeplink_take_buf;

int32_t deepLinkTakeWin(AplString* out) {
    if (out == nullptr) return ERR_STATE;
    std::lock_guard<std::mutex> lock(g_deeplink_mutex);
    if (g_deeplink_pending.empty()) {
        out->data = nullptr;
        out->len = 0;
        return 0;
    }
    g_deeplink_take_buf = g_deeplink_pending;
    g_deeplink_pending.clear();
    out->data = g_deeplink_take_buf.c_str();
    out->len = g_deeplink_take_buf.size();
    return 1;
}

int32_t deepLinkForwardWin() {
    const std::string url = extractUrlFromCommandLine(::GetCommandLineW());
    if (url.empty()) return 0;
    HWND target = ::FindWindowW(kDeepLinkClass, nullptr);
    if (target == nullptr) return ERR_BACKEND;
    COPYDATASTRUCT cds{};
    cds.dwData = 0x41524D31;  // 'ARM1'
    cds.cbData = static_cast<DWORD>(url.size());
    cds.lpData = const_cast<char*>(url.data());
    DWORD_PTR result = 0;
    const LRESULT sent = ::SendMessageTimeoutW(
        target, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds),
        SMTO_ABORTIFHUNG | SMTO_NORMAL, 3000, &result);
    if (sent == 0) return ERR_BACKEND;
    return 1;
}

}  // namespace

// ── 后端接口 ──────────────────────────────────────────────────────

uint32_t caps() {
    return CAP_POWER_INHIBIT | CAP_POWER_SCREEN_STATE | CAP_WINDOW_STATE |
           CAP_MEDIA_SESSION | CAP_APP_INSTANCE | CAP_SYSTEM_ACCENT |
           CAP_SYSTEM_THEME | CAP_DEEP_LINK | CAP_REVEAL_PATH;
}

int32_t init() {
    setAumid();             // 显式 AUMID（媒体浮出/任务栏分组 + Toast 身份）
    ensureToastShortcut();  // Toast 前提：开始菜单快捷方式带同一 AUMID
    // 协议唤醒：隐藏消息窗口（接收次实例 WM_COPYDATA）+ 冷启动 argv 中的 URI。
    ensureDeepLinkWindow();
    {
        const std::string cold =
            extractUrlFromCommandLine(::GetCommandLineW());
        if (!cold.empty()) {
            std::lock_guard<std::mutex> lock(g_deeplink_mutex);
            g_deeplink_pending = cold;
        }
    }
#ifdef ARCHOERA_WINRT
    winrt_smtc::probe();  // 确认 DLL 已加载（写日志，便于排查）
#endif
    return OK;
}

int32_t shutdown() {
    g_inhibit_want.store(false, std::memory_order_release);
    g_inhibit_run.store(false, std::memory_order_release);
    if (g_inhibit_thread != nullptr) {
        if (g_inhibit_thread->joinable()) g_inhibit_thread->join();
        delete g_inhibit_thread;
        g_inhibit_thread = nullptr;
    }
    unregisterScreen();
    unsubclassWindow();
#ifdef ARCHOERA_WINRT
    winrt_smtc::deinit();
#endif
    g_accent_on.store(false, std::memory_order_release);
    if (g_accent_thread != nullptr) {
        if (g_accent_thread->joinable()) g_accent_thread->join();
        delete g_accent_thread;
        g_accent_thread = nullptr;
    }
    if (g_instance_mutex != nullptr) {
        ::CloseHandle(g_instance_mutex);
        g_instance_mutex = nullptr;
    }
    destroyDeepLinkWindow();
    g_screen_events.store(false, std::memory_order_release);
    g_window_events.store(false, std::memory_order_release);
    return OK;
}

int32_t powerSetSleepInhibit(int32_t on) {
    if (g_inhibit_thread == nullptr) {
        g_inhibit_run.store(true, std::memory_order_release);
        try {
            g_inhibit_thread = new std::thread(inhibitThread);
        } catch (...) {
            g_inhibit_run.store(false, std::memory_order_release);
            return ERR_BACKEND;
        }
    }
    g_inhibit_want.store(on != 0, std::memory_order_release);
    return OK;
}

int32_t powerSetScreenEvents(int32_t on) {
    if (on != 0) {
        const int32_t rc = registerScreen();
        if (rc != OK) return rc;
        g_screen_events.store(true, std::memory_order_release);
    } else {
        g_screen_events.store(false, std::memory_order_release);
    }
    return OK;
}

int32_t windowSetEvents(int32_t on) {
    if (on != 0) {
        const int32_t rc = subclassWindow();
        if (rc != OK) return rc;
        g_window_events.store(true, std::memory_order_release);
        emitWindow();  // 立即给初值
    } else {
        g_window_events.store(false, std::memory_order_release);
    }
    return OK;
}

int32_t mediaSetTrack(const AplTrackMeta* meta) {
#ifdef ARCHOERA_WINRT
    if (winrt_smtc::init() != OK) return ERR_BACKEND;
    winrt_smtc::setTrack(meta);
    return OK;
#else
    (void)meta;
    return ERR_UNSUPPORTED;
#endif
}

int32_t mediaSetPlayback(int32_t state, int64_t position_ms, double speed,
                         double, int32_t, int32_t) {
#ifdef ARCHOERA_WINRT
    if (winrt_smtc::init() != OK) return ERR_BACKEND;
    winrt_smtc::setPlayback(state, position_ms, speed);
    return OK;
#else
    (void)state;
    (void)position_ms;
    (void)speed;
    return ERR_UNSUPPORTED;
#endif
}

int32_t mediaSetWindow(int64_t) {
    // 窗口句柄由 findFlutterWindow 自动发现（Dart 无需传）；保留 ABI 槽位。
    return OK;
}

int32_t appInstanceAcquire() {
    if (g_instance_mutex != nullptr) return 1;  // 幂等
    HANDLE h = ::CreateMutexW(nullptr, FALSE, L"Local\\ArchoeraMusic.SingleInstance");
    if (h == nullptr) return ERR_BACKEND;
    if (::GetLastError() == ERROR_ALREADY_EXISTS) {
        ::CloseHandle(h);
        return 0;  // 已有实例持有
    }
    g_instance_mutex = h;
    return 1;
}

int32_t protocolRegister(const char* scheme) {
    return protocolRegisterWin(scheme);
}

int32_t protocolUnregister(const char* scheme) {
    return protocolUnregisterWin(scheme);
}

int32_t deepLinkTake(AplString* out) { return deepLinkTakeWin(out); }

int32_t deepLinkForward() { return deepLinkForwardWin(); }

int32_t windowActivate() {
    if (findFlutterWindow() == nullptr) return ERR_BACKEND;
    activateFlutterWindow();
    return OK;
}

bool systemAccent(int32_t* r, int32_t* g, int32_t* b) {
#ifdef ARCHOERA_WINRT
    // 1) 官方 API：UISettings.GetColorValue(UIColorType::Accent)（返回 Windows.UI.Color）
    try {
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
        } catch (...) {
        }
        winrt::Windows::UI::ViewManagement::UISettings settings;
        const auto color = settings.GetColorValue(
            winrt::Windows::UI::ViewManagement::UIColorType::Accent);
        if (color.A != 0 || color.R != 0 || color.G != 0 || color.B != 0) {
            if (r != nullptr) *r = static_cast<int32_t>(color.R);
            if (g != nullptr) *g = static_cast<int32_t>(color.G);
            if (b != nullptr) *b = static_cast<int32_t>(color.B);
            return true;
        }
    } catch (...) {
    }
#endif
    // 2) 注册表 DWM\AccentColor：DWORD 按 ABGR 存（0xAABBGGRR）→ R=低字节
    DWORD v = 0;
    if (readDwmDword(L"AccentColor", &v)) {
        if (r != nullptr) *r = static_cast<int32_t>(v & 0xFF);
        if (g != nullptr) *g = static_cast<int32_t>((v >> 8) & 0xFF);
        if (b != nullptr) *b = static_cast<int32_t>((v >> 16) & 0xFF);
        return true;
    }
    // 3) 回退：DWM 着色色（0xAARRGGBB）
    DWORD c = 0;
    BOOL blend = FALSE;
    if (::DwmGetColorizationColor(&c, &blend) == S_OK && c != 0) {
        if (r != nullptr) *r = static_cast<int32_t>((c >> 16) & 0xFF);
        if (g != nullptr) *g = static_cast<int32_t>((c >> 8) & 0xFF);
        if (b != nullptr) *b = static_cast<int32_t>(c & 0xFF);
        return true;
    }
    return false;
}

int32_t systemAccentSetEvents(bool on) {
    const bool was = g_accent_on.exchange(on, std::memory_order_acq_rel);
    if (on && !was) {
        try {
            g_accent_thread = new std::thread(accentThread);
        } catch (...) {
            g_accent_on.store(false, std::memory_order_release);
            return ERR_BACKEND;
        }
    }
    return OK;
}

int32_t systemThemeSetEvents(bool on) {
    const bool was = g_theme_on.exchange(on, std::memory_order_acq_rel);
    if (on && !was) {
        try {
            g_theme_thread = new std::thread(themeThread);
        } catch (...) {
            g_theme_on.store(false, std::memory_order_release);
            return ERR_BACKEND;
        }
    }
    return OK;
}

int32_t notify(const char* title, const char* body) {
#ifdef ARCHOERA_WINRT
    if (toastNative(title, body)) return OK;
#endif
    messageBox(title, body);
    return OK;
}

int32_t revealPath(const char* path) {
    if (path == nullptr || *path == '\0') return ERR_STATE;
    const std::wstring w = utf8ToWideLocal(path);
    if (w.empty()) return ERR_BACKEND;
    const DWORD attrs = ::GetFileAttributesW(w.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES) return ERR_BACKEND;  // 路径不存在
    if ((attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        // 目录：直接用文件管理器打开。
        const auto r = reinterpret_cast<INT_PTR>(::ShellExecuteW(
            nullptr, L"open", w.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
        return r > 32 ? OK : ERR_BACKEND;
    }
    // 文件：打开所在目录并选中该文件。
    PIDLIST_ABSOLUTE pidl = ::ILCreateFromPathW(w.c_str());
    if (pidl == nullptr) return ERR_BACKEND;
    const HRESULT hr = ::SHOpenFolderAndSelectItems(pidl, 0, nullptr, 0);
    ::ILFree(pidl);
    return SUCCEEDED(hr) ? OK : ERR_BACKEND;
}

}  // namespace archoera
