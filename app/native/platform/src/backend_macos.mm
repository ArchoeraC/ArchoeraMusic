// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! macOS 后端（ObjC++）：NSProcessInfo 防休眠抑制、NSWorkspace 熄屏通知、
//! NSWindow 窗口状态、MPNowPlayingInfoCenter + MPRemoteCommandCenter 媒体会话、
//! NSColor 系统主题色、文件锁单实例、NSUserNotification 系统提示。
//!
//! 由 CMake 以 clang++（-fobjc-arc）编译，直接链接 AppKit/MediaPlayer/Foundation。

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

#include "backend.h"

#include "core.h"

#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <string>

namespace archoera {
namespace {

std::atomic<bool> g_screen_events{false};
std::atomic<bool> g_window_events{false};
std::atomic<bool> g_accent_events{false};
std::atomic<bool> g_minimized{false};
std::atomic<bool> g_focused{true};

id g_activity = nil;
bool g_remote_registered = false;

void emitWindow() {
    if (!g_window_events.load(std::memory_order_acquire)) return;
    dispatch(makeWindowState(g_minimized.load(std::memory_order_acquire),
                             g_focused.load(std::memory_order_acquire)));
}

}  // namespace
}  // namespace archoera

// ── 观察者（通知 + 远程命令目标）──────────────────────────────────
@interface ArchoeraPlatformObserver : NSObject
@end

@implementation ArchoeraPlatformObserver

- (void)onScreensSleep:(NSNotification*)note {
    (void)note;
    if (archoera::g_screen_events.load(std::memory_order_acquire)) {
        archoera::dispatch(archoera::makeScreenState(true));
    }
}

- (void)onScreensWake:(NSNotification*)note {
    (void)note;
    if (archoera::g_screen_events.load(std::memory_order_acquire)) {
        archoera::dispatch(archoera::makeScreenState(false));
    }
}

- (void)onMiniaturize:(NSNotification*)note {
    (void)note;
    archoera::g_minimized.store(true, std::memory_order_release);
    archoera::emitWindow();
}

- (void)onDeminiaturize:(NSNotification*)note {
    (void)note;
    archoera::g_minimized.store(false, std::memory_order_release);
    archoera::emitWindow();
}

- (void)onBecomeKey:(NSNotification*)note {
    (void)note;
    archoera::g_focused.store(true, std::memory_order_release);
    archoera::emitWindow();
}

- (void)onResignKey:(NSNotification*)note {
    (void)note;
    archoera::g_focused.store(false, std::memory_order_release);
    archoera::emitWindow();
}

- (void)onAccent:(NSNotification*)note {
    (void)note;
    if (archoera::g_accent_events.load(std::memory_order_acquire)) {
        archoera::dispatch(archoera::makeSystemAccent());
    }
}

- (MPRemoteCommandHandlerStatus)onPlay:(MPRemoteCommandEvent*)event {
    (void)event;
    archoera::dispatch(archoera::makeCommand(archoera::CMD_PLAY));
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)onPause:(MPRemoteCommandEvent*)event {
    (void)event;
    archoera::dispatch(archoera::makeCommand(archoera::CMD_PAUSE));
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)onToggle:(MPRemoteCommandEvent*)event {
    (void)event;
    archoera::dispatch(archoera::makeCommand(archoera::CMD_TOGGLE));
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)onNext:(MPRemoteCommandEvent*)event {
    (void)event;
    archoera::dispatch(archoera::makeCommand(archoera::CMD_NEXT));
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)onPrev:(MPRemoteCommandEvent*)event {
    (void)event;
    archoera::dispatch(archoera::makeCommand(archoera::CMD_PREV));
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)onStop:(MPRemoteCommandEvent*)event {
    (void)event;
    archoera::dispatch(archoera::makeCommand(archoera::CMD_STOP));
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)onSeek:
    (MPChangePlaybackPositionCommandEvent*)event {
    if (event != nil) {
        const int64_t ms = static_cast<int64_t>(event.positionTime * 1000.0);
        archoera::dispatch(archoera::makeSeek(0, ms));
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

@end

namespace archoera {
namespace {

ArchoeraPlatformObserver* g_observer = nil;

ArchoeraPlatformObserver* observer() {
    if (g_observer == nil) {
        g_observer = [[ArchoeraPlatformObserver alloc] init];
    }
    return g_observer;
}

NSString* nsstr(const char* s, size_t len) {
    if (s == nullptr) return @"";
    NSString* out = [[NSString alloc] initWithBytes:s
                                             length:len
                                           encoding:NSUTF8StringEncoding];
    return out != nil ? out : @"";
}

void observe(NSNotificationCenter* center, NSNotificationName name,
             SEL selector) {
    if (center == nil || name == nil) return;
    [center addObserver:observer() selector:selector name:name object:nil];
}

// ── 媒体会话 ──────────────────────────────────────────────────────
bool g_playing = false;
int64_t g_position_ms = 0;
int64_t g_duration_ms = -1;

NSImage* loadImage(const std::string& url) {
    NSString* s = nsstr(url.data(), url.size());
    if (s.length == 0) return nil;
    NSURL* nsurl = nil;
    if ([url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0]) {
        nsurl = [NSURL URLWithString:s];
    } else {
        nsurl = [NSURL fileURLWithPath:s];
    }
    if (nsurl == nil) return nil;
    return [[NSImage alloc] initWithContentsOfURL:nsurl];
}

void ensureRemoteCommands() {
    MPRemoteCommandCenter* cc = [MPRemoteCommandCenter sharedCommandCenter];
    if (cc == nil) return;
    ArchoeraPlatformObserver* obs = observer();
    NSArray<NSArray*>* pairs = @[
        @[ cc.playCommand, NSStringFromSelector(@selector(onPlay:)) ],
        @[ cc.pauseCommand, NSStringFromSelector(@selector(onPause:)) ],
        @[ cc.togglePlayPauseCommand,
           NSStringFromSelector(@selector(onToggle:)) ],
        @[ cc.nextTrackCommand, NSStringFromSelector(@selector(onNext:)) ],
        @[ cc.previousTrackCommand,
           NSStringFromSelector(@selector(onPrev:)) ],
        @[ cc.stopCommand, NSStringFromSelector(@selector(onStop:)) ],
        @[ cc.changePlaybackPositionCommand,
           NSStringFromSelector(@selector(onSeek:)) ],
    ];
    for (NSArray* pair in pairs) {
        MPRemoteCommand* command = pair[0];
        NSString* action = pair[1];
        if (command == nil) continue;
        [command addTarget:obs action:NSSelectorFromString(action)];
    }
}

}  // namespace

// ── 后端接口 ──────────────────────────────────────────────────────
uint32_t caps() {
    return CAP_POWER_INHIBIT | CAP_POWER_SCREEN_STATE | CAP_WINDOW_STATE |
           CAP_MEDIA_SESSION | CAP_APP_INSTANCE | CAP_SYSTEM_ACCENT;
}

int32_t init() {
    ensureRemoteCommands();
    return OK;
}

int32_t shutdown() {
    if (g_activity != nil) {
        [[NSProcessInfo processInfo] endActivity:g_activity];
        g_activity = nil;
    }
    g_screen_events.store(false, std::memory_order_release);
    g_window_events.store(false, std::memory_order_release);
    return OK;
}

int32_t powerSetSleepInhibit(int32_t on) {
    NSProcessInfo* pi = [NSProcessInfo processInfo];
    if (pi == nil) return ERR_BACKEND;
    if (on != 0) {
        if (g_activity != nil) return OK;
        g_activity = [pi beginActivityWithOptions:NSActivityUserInitiated
                                           reason:@"ArchoeraMusic playback"];
        return g_activity != nil ? OK : ERR_BACKEND;
    }
    if (g_activity != nil) {
        [pi endActivity:g_activity];
        g_activity = nil;
    }
    return OK;
}

int32_t powerSetScreenEvents(int32_t on) {
    if (on != 0) {
        NSWorkspace* ws = [NSWorkspace sharedWorkspace];
        NSNotificationCenter* nc = [ws notificationCenter];
        observe(nc, NSWorkspaceScreensDidSleepNotification,
                @selector(onScreensSleep:));
        observe(nc, NSWorkspaceScreensDidWakeNotification,
                @selector(onScreensWake:));
        g_screen_events.store(true, std::memory_order_release);
    } else {
        g_screen_events.store(false, std::memory_order_release);
    }
    return OK;
}

int32_t windowSetEvents(int32_t on) {
    if (on != 0) {
        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        observe(nc, NSWindowDidMiniaturizeNotification,
                @selector(onMiniaturize:));
        observe(nc, NSWindowDidDeminiaturizeNotification,
                @selector(onDeminiaturize:));
        observe(nc, NSWindowDidBecomeKeyNotification, @selector(onBecomeKey:));
        observe(nc, NSWindowDidResignKeyNotification, @selector(onResignKey:));
        g_window_events.store(true, std::memory_order_release);
        emitWindow();  // 初值
    } else {
        g_window_events.store(false, std::memory_order_release);
    }
    return OK;
}

int32_t mediaSetTrack(const AplTrackMeta* meta) {
    MPNowPlayingInfoCenter* center = [MPNowPlayingInfoCenter defaultCenter];
    if (center == nil) return ERR_BACKEND;
    if (meta == nullptr) {
        center.nowPlayingInfo = nil;
        return OK;
    }
    NSMutableDictionary* dict = [NSMutableDictionary dictionary];
    auto str = [](const AplString& s) {
        return (s.data != nullptr && s.len > 0)
                   ? std::string(s.data, s.len)
                   : std::string();
    };
    const std::string title = str(meta->title);
    const std::string artist = str(meta->artist);
    const std::string album = str(meta->album);
    const std::string art = str(meta->art_url);
    if (!title.empty()) {
        dict[MPMediaItemPropertyTitle] = nsstr(title.data(), title.size());
    }
    if (!artist.empty()) {
        dict[MPMediaItemPropertyArtist] = nsstr(artist.data(), artist.size());
    }
    if (!album.empty()) {
        dict[MPMediaItemPropertyAlbumTitle] = nsstr(album.data(), album.size());
    }
    if (!art.empty()) {
        NSImage* image = loadImage(art);
        if (image != nil) {
            dict[MPMediaItemPropertyArtwork] =
                [[MPMediaItemArtwork alloc] initWithImage:image];
        }
    }
    if (meta->duration_ms > 0) {
        dict[MPMediaItemPropertyPlaybackDuration] =
            @(static_cast<double>(meta->duration_ms) / 1000.0);
    }
    center.nowPlayingInfo = dict;
    return OK;
}

int32_t mediaSetPlayback(int32_t state, int64_t position_ms, double speed,
                         double, int32_t, int32_t) {
    MPNowPlayingInfoCenter* center = [MPNowPlayingInfoCenter defaultCenter];
    if (center == nil) return ERR_BACKEND;
    g_playing = state == 1;
    g_position_ms = position_ms;
    NSMutableDictionary* info = [center.nowPlayingInfo mutableCopy];
    if (info != nil) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
            @(static_cast<double>(position_ms) / 1000.0);
        info[MPNowPlayingInfoPropertyPlaybackRate] = @(speed);
        center.nowPlayingInfo = info;
    }
    return OK;
}

int32_t mediaSetWindow(int64_t) { return OK; }

int32_t appInstanceAcquire() {
    static int fd = -1;
    if (fd >= 0) return 1;
    const char* home = std::getenv("HOME");
    std::string dir = home != nullptr ? home : "/tmp";
    std::string path = dir + "/.archoera_music.lock";
    fd = ::open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return ERR_BACKEND;
    if (::flock(fd, LOCK_EX | LOCK_NB) != 0) {
        ::close(fd);
        fd = -1;
        return 0;
    }
    return 1;
}

bool systemAccent(int32_t* r, int32_t* g, int32_t* b) {
    NSColor* color = [NSColor controlAccentColor];
    if (color == nil) return false;
    NSColor* srgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor* use = srgb != nil ? srgb : color;
    CGFloat rr = 0, gg = 0, bb = 0, aa = 0;
    [use getRed:&rr green:&gg blue:&bb alpha:&aa];
    if (aa <= 0.0 && rr == 0.0 && gg == 0.0 && bb == 0.0) return false;
    auto toU8 = [](CGFloat x) -> int32_t {
        CGFloat v = x * 255.0 + 0.5;
        if (v <= 0.0) return 0;
        if (v >= 255.0) return 255;
        return static_cast<int32_t>(v);
    };
    if (r != nullptr) *r = toU8(rr);
    if (g != nullptr) *g = toU8(gg);
    if (b != nullptr) *b = toU8(bb);
    return true;
}

int32_t systemAccentSetEvents(bool on) {
    if (on) {
        g_accent_events.store(true, std::memory_order_release);
        NSDistributedNotificationCenter* dnc =
            [NSDistributedNotificationCenter defaultCenter];
        observe(dnc, @"AppleColorPreferencesChangedNotification",
                @selector(onAccent:));
        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        observe(nc, NSSystemColorsDidChangeNotification, @selector(onAccent:));
    } else {
        g_accent_events.store(false, std::memory_order_release);
    }
    return OK;
}

int32_t notify(const char* title, const char* body) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSUserNotification* notif = [[NSUserNotification alloc] init];
    if (notif == nil) return ERR_BACKEND;
    notif.title = nsstr(title, title != nullptr ? strlen(title) : 0);
    notif.informativeText =
        nsstr(body, body != nullptr ? strlen(body) : 0);
    NSUserNotificationCenter* center =
        [NSUserNotificationCenter defaultUserNotificationCenter];
    if (center == nil) return ERR_BACKEND;
    [center deliverNotification:notif];
#pragma clang diagnostic pop
    return OK;
}

}  // namespace archoera
