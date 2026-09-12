// ArchoeraMusic — Windows SMTC（SystemMediaTransportControls）C++/WinRT 实现
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 对齐 Chromium `components/system_media_controls/win/system_media_controls_win.cc`：
// 用 C++/WinRT 的标准委托投影注册 `ButtonPressed`，彻底弃用此前 Zig 手写 4 槽
// COM 委托 + 自研 IMarshal（真机上 `add_ButtonPressed` 成功但事件永不回调）。
//
// 架构：本文件只做 WinRT 侧（SMTC 对象/事件/元数据/缩略图），按钮事件经
// `extern "C" apl_smtc_on_button` 回调给 Zig，由 Zig `core.dispatch` 转发到 Dart
// （保持「Flutter 桥接层 + Zig 转发」架构）。正向调用由 Zig 的 `win_smtc.zig` 转发。
//
// 仅 Windows 目标编译；需 C++/WinRT 头（vcpkg `cppwinrt`，-Dcppwinrt-include）。
// 未提供时 build.zig 跳过本文件，Zig 侧弱符号兜底（SMTC 静默禁用）。

#include <windows.h>
#include <unknwn.h>

// cppwinrt 2.x 的 `com_array::detach_abi` 以 `#ifdef _MSC_VER` 选 memset 分支，而
// Zig 的 clang 在 windows-msvc 目标下也定义 `_MSC_VER` → 触发 `-Wnontrivial-memcall`
// （CI 的 vcpkg cppwinrt 为 2.0.250303.1；3.x 已加 `!defined(__clang__)` 修复）。
// 在包含 WinRT 头之前屏蔽该警告，避免其被当作错误。
#if defined(__clang__)
#pragma clang diagnostic ignored "-Wnontrivial-memcall"
#endif

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

#include <cstdint>
#include <cstdio>
#include <string_view>
#include <vector>

// 由 Zig 侧实现：把按钮事件转发到 Dart（保持 Zig 转发）。
extern "C" void apl_smtc_on_button(int32_t button);

namespace {

using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Media;
using namespace winrt::Windows::Storage::Streams;

// ISystemMediaTransportControlsInterop
// {ddb0472d-c911-4a1f-86d9-dc3d71a95f5a}（systemmediatransportcontrolsinterop.h；
// 此处手写以避免依赖该 SDK 头，IID 与 Zig 侧一致）。
MIDL_INTERFACE("ddb0472d-c911-4a1f-86d9-dc3d71a95f5a")
ISystemMediaTransportControlsInterop : public ::IUnknown {
  public:
    virtual HRESULT STDMETHODCALLTYPE GetForWindow(HWND app_window, REFIID riid,
                                                   void** ppv) = 0;
};

struct State {
    SystemMediaTransportControls controls{nullptr};
    SystemMediaTransportControlsDisplayUpdater updater{nullptr};
    MusicDisplayProperties music{nullptr};
    winrt::event_token button_token{};
    bool button_registered = false;
    bool initialized = false;
    int64_t duration_ms = 0;
    // 缩略图异步完成前持有（对齐 Chromium 成员变量，防异步完成前析构）。
    InMemoryRandomAccessStream icon_stream{nullptr};
    DataWriter icon_writer{nullptr};
    IAsyncOperation<uint32_t> icon_op{nullptr};
};

// 指针静态（平凡析构）：**刻意不用函数局部 `static State`**——其非平凡析构会
// 注册 `__cxa_atexit`，进而引入 CRT 终止符号（`__vcrt_*` / `__acrt_*`），而
// Zig 的 windows-msvc C++ 链接不提供这些库 → LNK 未解析。实例由 init 惰性分配、
// deinit 显式 `delete`：主动清理、不泄漏，也不触发静态析构注册。
State*& state_slot() {
    static State* s = nullptr;
    return s;
}

State& state() {
    State*& s = state_slot();
    if (s == nullptr) s = new State();
    return *s;
}

winrt::hstring H(const char* data, int32_t len) {
    if (data == nullptr || len <= 0) return {};
    return winrt::to_hstring(std::string_view(data, static_cast<size_t>(len)));
}

// 诊断日志：同时写 OutputDebugStringA（DebugView）与**多个**日志文件，便于查找：
//   <exe 同级>\archoera_smtc.log / %TEMP%\archoera_smtc.log /
//   %USERPROFILE%\archoera_smtc.log / C:\archoera_smtc.log
// 注意：路径用 POD `char[][]` 全局，**不用 std::string / 函数局部静态**——后者的
// 非平凡析构会注册 __cxa_atexit，牵连 CRT 终止符号（__vcrt_*/__acrt_*）链接失败。
#define LOG_MAX_PATHS 4
char g_log_paths[LOG_MAX_PATHS][MAX_PATH] = {};
int g_log_path_count = 0;

void tryAddLogPath(const char* full) {
    if (g_log_path_count >= LOG_MAX_PATHS) return;
    FILE* f = nullptr;
    if (::fopen_s(&f, full, "a") == 0 && f != nullptr) {
        std::fclose(f);
        std::snprintf(g_log_paths[g_log_path_count], MAX_PATH, "%s", full);
        g_log_path_count++;
    }
}

void initLogPath() {
    if (g_log_path_count > 0) return;
    char buf[MAX_PATH];
    // 1) exe 同级
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
    // 2) %TEMP%
    if (::GetTempPathA(MAX_PATH, buf) > 0) {
        char p2[MAX_PATH];
        std::snprintf(p2, MAX_PATH, "%sarchoera_smtc.log", buf);
        tryAddLogPath(p2);
    }
    // 3) %USERPROFILE%
    const DWORD n = ::GetEnvironmentVariableA("USERPROFILE", buf, MAX_PATH);
    if (n > 0 && n < MAX_PATH) {
        char p2[MAX_PATH];
        std::snprintf(p2, MAX_PATH, "%s\\archoera_smtc.log", buf);
        tryAddLogPath(p2);
    }
    // 4) C:\（管理员可写，最易找）
    tryAddLogPath("C:\\archoera_smtc.log");
}

void logRaw(const char* line) {
    ::OutputDebugStringA(line);
    if (g_log_path_count == 0) initLogPath();
    SYSTEMTIME st;
    ::GetLocalTime(&st);
    for (int i = 0; i < g_log_path_count; i++) {
        FILE* f = nullptr;
        if (::fopen_s(&f, g_log_paths[i], "a") != 0 || f == nullptr) continue;
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

// 每次 init 清空日志（只保留本次会话）。
void logReset() {
    initLogPath();
    for (int i = 0; i < g_log_path_count; i++) {
        FILE* f = nullptr;
        if (::fopen_s(&f, g_log_paths[i], "w") == 0 && f != nullptr) std::fclose(f);
    }
}

void SetThumbnailFromBytes(const uint8_t* bytes, int32_t len) {
    auto& s = state();
    if (!s.updater || bytes == nullptr || len <= 0) return;
    try {
        auto stream = InMemoryRandomAccessStream();
        DataWriter writer(stream.as<IOutputStream>());
        writer.WriteBytes(
            winrt::array_view<const uint8_t>(bytes, bytes + len));
        auto op = writer.StoreAsync();
        // 持有到完成；lambda 按值捕获 stream，避免下一次切歌改写成员后的竞态。
        s.icon_stream = stream;
        s.icon_writer = writer;
        s.icon_op = op;
        op.Completed([stream](IAsyncOperation<uint32_t> const&, AsyncStatus status) {
            if (status != AsyncStatus::Completed) return;
            // 完成时经 state_slot() 取当前实例：deinit 后为 null，避免悬垂引用。
            State*& sp = state_slot();
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

void SetThumbnailFromUri(winrt::hstring const& url) {
    auto& s = state();
    if (!s.updater || url.empty()) return;
    try {
        auto ref = RandomAccessStreamReference::CreateFromUri(Uri(url));
        s.updater.Thumbnail(ref);
        s.updater.Update();
    } catch (...) {
    }
}

}  // namespace

// 加载探针：桥接 init 时由 Zig 调用一次，确认「这个 DLL 被载入且 C++ 代码在跑」。
extern "C" void apl_smtc_win_probe(void) {
    char exe[MAX_PATH] = {0};
    ::GetModuleFileNameA(nullptr, exe, MAX_PATH);
    char buf[MAX_PATH + 64];
    std::snprintf(buf, sizeof(buf), "apl/smtc: dll loaded (probe) exe=%s", exe);
    logRaw(buf);
}

extern "C" int32_t apl_smtc_win_init(void* hwnd) {
    auto& s = state();
    if (s.initialized) return 0;
    logReset();
    if (hwnd == nullptr) {
        log("apl/smtc: init hwnd=null");
        return -1;
    }
    log("apl/smtc: init begin");
    try {
        // 线程多已由 runner 初始化为 STA（main.cpp CoInitializeEx）；重复/冲突
        // 初始化忽略即可，沿用当前 apartment。C++/WinRT 委托在 STA 上正确封送。
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
        SystemMediaTransportControls controls{nullptr};
        winrt::check_hresult(interop->GetForWindow(
            reinterpret_cast<HWND>(hwnd),
            winrt::guid_of<SystemMediaTransportControls>(),
            winrt::put_abi(controls)));
        log("apl/smtc: GetForWindow ok");
        s.controls = controls;

        s.updater = controls.DisplayUpdater();
        s.updater.Type(MediaPlaybackType::Music);
        s.music = s.updater.MusicProperties();
        log("apl/smtc: display updater ok");

        // 按钮事件：C++/WinRT 委托（agile；跨 apartment 由投影正确封送）。
        s.button_token = controls.ButtonPressed(
            [](SystemMediaTransportControls const&,
               SystemMediaTransportControlsButtonPressedEventArgs const& args) {
                int32_t button = -1;
                switch (args.Button()) {
                    case SystemMediaTransportControlsButton::Play:
                        button = 0;
                        break;
                    case SystemMediaTransportControlsButton::Pause:
                        button = 1;
                        break;
                    case SystemMediaTransportControlsButton::Stop:
                        button = 2;
                        break;
                    case SystemMediaTransportControlsButton::Next:
                        button = 6;
                        break;
                    case SystemMediaTransportControlsButton::Previous:
                        button = 7;
                        break;
                    default:
                        return;
                }
                log("apl/smtc: ButtonPressed");
                apl_smtc_on_button(button);
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
        return 0;
    } catch (winrt::hresult_error const& e) {
        logHr("apl/smtc: init failed", e.code());
        return -1;
    } catch (...) {
        log("apl/smtc: init failed unknown");
        return -1;
    }
}

extern "C" void apl_smtc_win_set_track(
    const char* title, int32_t title_len,
    const char* artist, int32_t artist_len,
    const char* album, int32_t album_len,
    int64_t duration_ms,
    const char* art_url, int32_t art_url_len,
    const uint8_t* art_bytes, int32_t art_bytes_len) {
    auto& s = state();
    if (!s.initialized || !s.updater) {
        log("apl/smtc: set_track but not initialized");
        return;
    }
    try {
        auto h_title = H(title, title_len);
        if (h_title.empty()) {
            // clearNowPlaying：清空并禁用，避免显示可执行文件名。
            s.updater.ClearAll();
            s.controls.IsEnabled(false);
            s.duration_ms = 0;
            return;
        }
        s.duration_ms = duration_ms > 0 ? duration_ms : 0;
        s.updater.Type(MediaPlaybackType::Music);
        s.music.Title(h_title);
        s.music.Artist(H(artist, artist_len));
        s.music.AlbumArtist(H(artist, artist_len));
        (void)album;
        (void)album_len;
        s.controls.IsEnabled(true);
        s.updater.Update();

        if (art_bytes != nullptr && art_bytes_len > 0) {
            SetThumbnailFromBytes(art_bytes, art_bytes_len);
        } else {
            SetThumbnailFromUri(H(art_url, art_url_len));
        }
        log("apl/smtc: set_track done");
    } catch (winrt::hresult_error const& e) {
        logHr("apl/smtc: set_track failed", e.code());
    } catch (...) {
        log("apl/smtc: set_track failed unknown");
    }
}

extern "C" void apl_smtc_win_set_playback(int32_t playback_state,
                                          int64_t position_ms, double speed) {
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

        // 时间轴 + 速率：让系统把本会话视为「活动会话」并自行外推进度
        // （蓝牙 AVRCP/媒体键按活动会话路由）。
        auto controls2 = s.controls.try_as<ISystemMediaTransportControls2>();
        if (controls2) {
            SystemMediaTransportControlsTimelineProperties timeline;
            int64_t end = s.duration_ms > 0 ? s.duration_ms * 10000 : 0;
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

extern "C" void apl_smtc_win_deinit() {
    State*& sp = state_slot();
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
    // 主动释放实例（不泄漏）；下次 init 重新分配。
    delete sp;
    sp = nullptr;
}

// 诊断（win_smoke / 真机读回校验）。
extern "C" int32_t apl_smtc_win_debug_playback_status() {
    State*& sp = state_slot();
    if (sp == nullptr || !sp->controls) return -1;
    try {
        return static_cast<int32_t>(sp->controls.PlaybackStatus());
    } catch (...) {
        return -1;
    }
}

extern "C" int32_t apl_smtc_win_debug_is_enabled() {
    State*& sp = state_slot();
    if (sp == nullptr || !sp->controls) return -1;
    try {
        return sp->controls.IsEnabled() ? 1 : 0;
    } catch (...) {
        return -1;
    }
}

extern "C" int32_t apl_smtc_win_debug_button_registered() {
    State*& sp = state_slot();
    return (sp != nullptr && sp->button_registered) ? 1 : 0;
}
