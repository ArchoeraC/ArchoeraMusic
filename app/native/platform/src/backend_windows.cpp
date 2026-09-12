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

#include <atomic>
#include <cstdio>
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
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.UI.Notifications.h>
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
        case WM_CLOSE:
            g_minimized.store(true, std::memory_order_release);
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
    while (g_accent_on.load(std::memory_order_acquire)) {
        if (::RegNotifyChangeKeyValue(hkey, FALSE, REG_NOTIFY_CHANGE_LAST_SET, ev,
                                      TRUE) != ERROR_SUCCESS) {
            break;
        }
        // 500ms 轮询退出标志（RegNotifyChangeKeyValue 阻塞不可取消）
        if (::WaitForSingleObject(ev, 500) == WAIT_OBJECT_0 &&
            g_accent_on.load(std::memory_order_acquire)) {
            dispatch(makeSystemAccent());
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
using namespace winrt::Windows::Storage::Streams;

// ISystemMediaTransportControlsInterop
// {ddb0472d-c911-4a1f-86d9-dc3d71a95f5a}
MIDL_INTERFACE("ddb0472d-c911-4a1f-86d9-dc3d71a95f5a")
ISystemMediaTransportControlsInterop : public ::IUnknown {
   public:
    virtual HRESULT STDMETHODCALLTYPE GetForWindow(HWND app_window, REFIID riid,
                                                   void** ppv) = 0;
};

// ISystemMediaTransportControls {99FA3FF4-1742-42A6-902E-087D41F965EC}
constexpr GUID kIidSmtc = {
    0x99FA3FF4,
    0x1742,
    0x42A6,
    {0x90, 0x2E, 0x08, 0x7D, 0x41, 0xF9, 0x65, 0xEC}};

// SMTC 需与顶层窗口关联（GetForWindow）。**关键**：GetForWindow 要求目标窗口的
// 所属线程会泵消息（内部向窗口线程投递并等待）——若窗口建在调用线程上，而该
// 线程正阻塞在此调用中（Dart FFI 线程）→ 真机死锁（日志停在 hwnd=... 后不再前进）。
// 故把隐藏窗口放到**专用消息泵线程**（对齐 Chromium gfx::SingletonHwnd：窗口与
// SMTC 调用可分属不同线程，只要窗口线程在泵消息）。HWND 为 POD，无静态析构。
struct HiddenWndState {
    std::atomic<HWND> hwnd{nullptr};
    std::atomic<bool> quit{false};
    std::thread* thread = nullptr;
    DWORD thread_id = 0;
};
HiddenWndState g_hidden;

void hiddenWndThreadMain() {
    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    constexpr wchar_t kClass[] = L"ArchoeraMusicSmtcHiddenWnd";
    WNDCLASSW wc = {};
    wc.lpfnWndProc = ::DefWindowProcW;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.lpszClassName = kClass;
    ::RegisterClassW(&wc);
    HWND hwnd = ::CreateWindowExW(0, kClass, L"", WS_OVERLAPPED, 0, 0, 0, 0,
                                  nullptr, nullptr, wc.hInstance, nullptr);
    g_hidden.thread_id = ::GetCurrentThreadId();
    g_hidden.hwnd.store(hwnd, std::memory_order_release);
    MSG msg;
    while (!g_hidden.quit.load(std::memory_order_acquire) &&
           ::GetMessageW(&msg, nullptr, 0, 0) > 0) {
        ::TranslateMessage(&msg);
        ::DispatchMessageW(&msg);
    }
    ::CoUninitialize();
}

HWND hiddenWindow() {
    HWND existing = g_hidden.hwnd.load(std::memory_order_acquire);
    if (existing != nullptr) return existing;
    g_hidden.thread = new std::thread(hiddenWndThreadMain);
    for (int i = 0; i < 500; i++) {
        HWND h = g_hidden.hwnd.load(std::memory_order_acquire);
        if (h != nullptr) return h;
        ::Sleep(10);
    }
    log("apl/smtc: hidden window thread timeout");
    return nullptr;
}

void destroyHiddenWindow() {
    if (g_hidden.thread == nullptr) return;
    g_hidden.quit.store(true, std::memory_order_release);
    if (g_hidden.thread_id != 0) {
        ::PostThreadMessageW(g_hidden.thread_id, WM_QUIT, 0, 0);
    }
    if (g_hidden.thread->joinable()) g_hidden.thread->join();
    delete g_hidden.thread;
    g_hidden.thread = nullptr;
    g_hidden.hwnd.store(nullptr, std::memory_order_release);
}

struct State {
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
    HWND hwnd = findFlutterWindow();
    if (hwnd == nullptr) {
        log("apl/smtc: init hwnd=null");
        return ERR_BACKEND;
    }
    log("apl/smtc: init begin");
    try {
        try {
            winrt::init_apartment(winrt::apartment_type::single_threaded);
        } catch (winrt::hresult_error const& e) {
            logHr("apl/smtc: init_apartment", e.code());
        } catch (...) {
            log("apl/smtc: init_apartment unknown");
        }

        auto interop = winrt::get_activation_factory<ISystemMediaTransportControlsInterop>(
            L"Windows.Media.SystemMediaTransportControls");
        log("apl/smtc: interop ok");
        HWND target = hiddenWindow();
        if (target == nullptr) target = hwnd;
        {
            char hb[160];
            std::snprintf(hb, sizeof(hb), "apl/smtc: hwnd=%p target=%p", hwnd,
                          target);
            logRaw(hb);
        }
        SystemMediaTransportControls controls{nullptr};
        winrt::check_hresult(
            interop->GetForWindow(target, kIidSmtc, winrt::put_abi(controls)));
        log("apl/smtc: GetForWindow ok");
        s.controls = controls;

        s.updater = controls.DisplayUpdater();
        s.updater.Type(MediaPlaybackType::Music);
        s.music = s.updater.MusicProperties();
        log("apl/smtc: display updater ok");

        s.button_token = controls.ButtonPressed(
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

        controls.IsEnabled(true);
        controls.IsPlayEnabled(true);
        controls.IsPauseEnabled(true);
        controls.IsNextEnabled(true);
        controls.IsPreviousEnabled(true);
        controls.IsStopEnabled(true);

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
    s.duration_ms = 0;
    s.initialized = false;
    delete sp;
    sp = nullptr;
    destroyHiddenWindow();
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
        ToastNotificationManager::CreateToastNotifier(L"ArchoeraMusic")
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

}  // namespace

// ── 后端接口 ──────────────────────────────────────────────────────

uint32_t caps() {
    return CAP_POWER_INHIBIT | CAP_POWER_SCREEN_STATE | CAP_WINDOW_STATE |
           CAP_MEDIA_SESSION | CAP_APP_INSTANCE | CAP_SYSTEM_ACCENT;
}

int32_t init() {
    // 显式 AppUserModelID（Win11 媒体浮出/任务栏分组更稳；失败忽略）。
    if (HMODULE shell = ::LoadLibraryA("shell32.dll")) {
        using SetAumidFn = HRESULT(WINAPI*)(PCWSTR);
        auto fn = reinterpret_cast<SetAumidFn>(
            ::GetProcAddress(shell, "SetCurrentProcessExplicitAppUserModelID"));
        if (fn != nullptr) fn(L"Archoera.ArchoeraMusic");
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

bool systemAccent(int32_t* r, int32_t* g, int32_t* b) {
    // 1) DWM\AccentColor：DWORD 按 ABGR 存（0xAABBGGRR）→ R=低字节
    DWORD v = 0;
    if (readDwmDword(L"AccentColor", &v)) {
        if (r != nullptr) *r = static_cast<int32_t>(v & 0xFF);
        if (g != nullptr) *g = static_cast<int32_t>((v >> 8) & 0xFF);
        if (b != nullptr) *b = static_cast<int32_t>((v >> 16) & 0xFF);
        return true;
    }
    // 2) 回退：DWM 着色色（0xAARRGGBB）
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

int32_t notify(const char* title, const char* body) {
#ifdef ARCHOERA_WINRT
    if (toastNative(title, body)) return OK;
#endif
    messageBox(title, body);
    return OK;
}

}  // namespace archoera
