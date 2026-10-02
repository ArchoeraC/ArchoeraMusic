// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! macOS 后端（ObjC++）：NSProcessInfo 防休眠抑制、NSWorkspace 熄屏通知、
//! NSWindow 窗口状态、MPNowPlayingInfoCenter + MPRemoteCommandCenter 媒体会话、
//! NSColor 系统主题色、文件锁单实例、NSUserNotification 系统提示、
//! NSStatusItem 系统托盘（菜单栏图标 + 上下文菜单）。
//!
//! 由 CMake 以 clang++（-fobjc-arc）编译，直接链接 AppKit/MediaPlayer/Foundation。

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UserNotifications/UserNotifications.h>

#include "backend.h"

#include "core.h"

#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

// 系统托盘 target 前置声明（定义见文件后部；全局强引用避免 target 被释放，
// 因为 NSControl.target / NSMenuItem.target 均为弱引用）。
@class ArchoeraTrayTarget;

namespace archoera {

// 推送一次当前系统强调色（定义见文件后部）；平台推送模型，Dart 不查询。
void pushAccent();

// 推送一次当前系统深浅色（定义见文件后部）；平台推送模型，Dart 不查询。
void pushTheme();

// 记录一条待处理 deep link（定义见文件后部；macOS 经 AppleEvent 投递）。
void setPendingDeepLink(const char* uri);

namespace {

std::atomic<bool> g_screen_events{false};
std::atomic<bool> g_window_events{false};
std::atomic<bool> g_accent_events{false};
std::atomic<bool> g_theme_events{false};
std::atomic<bool> g_theme_dark{false};
std::atomic<bool> g_theme_valid{false};
std::atomic<bool> g_minimized{false};
std::atomic<bool> g_focused{true};

id g_activity = nil;
bool g_remote_registered = false;

// ── 系统托盘状态（所有 AppKit 访问均编组到主线程）────────────────────
NSStatusItem* g_tray_item = nil;    // 菜单栏状态项
NSMenu* g_tray_menu = nil;          // 当前上下文菜单
ArchoeraTrayTarget* g_tray_target = nil;  // 按钮/菜单项 action 目标
NSString* g_tray_tooltip = nil;     // 最近提示文本（重建时复用）
int32_t g_tray_trigger = 1;         // 0=左键唤出菜单；1=右键唤出菜单（默认）
bool g_tray_visible = true;         // 状态项可见性

void emitWindow() {
    if (!g_window_events.load(std::memory_order_acquire)) return;
    dispatch(makeWindowState(g_minimized.load(std::memory_order_acquire),
                             g_focused.load(std::memory_order_acquire)));
}

}  // namespace
}  // namespace archoera

// ── 系统托盘 action 目标 ──────────────────────────────────────────
// 不设置 statusItem.menu（否则任何点击都被系统吞去弹菜单、拿不到 CLICK）；
// 改为给 statusItem.button 设 target/action，在 action 内读 [NSApp currentEvent]
// 区分左右键与单击/双击。
//
// popUpStatusItemMenu: 自 10.14 起被标记废弃（官方推荐改用 menu 属性），但设置
// menu 属性会让系统自动吞掉所有点击，与「区分左右键」相冲突；此处仍需手动弹出，
// 故局部关闭该弃用告警。
static void popUpTrayMenu(NSStatusItem* item, NSMenu* menu) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [item popUpStatusItemMenu:menu];
#pragma clang diagnostic pop
}

@interface ArchoeraTrayTarget : NSObject
- (void)onTrayButton:(id)sender;
- (void)onTrayMenuItem:(id)sender;
@end

@implementation ArchoeraTrayTarget

- (void)onTrayButton:(id)sender {
    (void)sender;
    NSStatusItem* item = archoera::g_tray_item;
    if (item == nil) return;
    NSEvent* event = [NSApp currentEvent];
    const NSEventType type =
        event != nil ? event.type : NSEventTypeLeftMouseUp;
    const bool right =
        type == NSEventTypeRightMouseUp || type == NSEventTypeRightMouseDown;
    const bool left =
        type == NSEventTypeLeftMouseUp || type == NSEventTypeLeftMouseDown;
    NSMenu* menu = archoera::g_tray_menu;
    if (archoera::g_tray_trigger == 0) {
        // 0：左键唤出菜单（左键不再发 CLICK）；右键单独上报。
        if (left) {
            if (menu != nil && menu.numberOfItems > 0) {
                popUpTrayMenu(item, menu);
            }
        } else if (right) {
            archoera::dispatch(
                archoera::makeTrayClick(archoera::EVENT_TRAY_RIGHT_CLICK));
        }
        return;
    }
    // 1（默认）：右键唤出菜单；左键上报单击/双击。
    if (right) {
        if (menu != nil && menu.numberOfItems > 0) {
            popUpTrayMenu(item, menu);
        }
    } else if (left) {
        const NSInteger clicks = event != nil ? event.clickCount : 1;
        archoera::dispatch(archoera::makeTrayClick(
            clicks >= 2 ? archoera::EVENT_TRAY_DOUBLE_CLICK
                        : archoera::EVENT_TRAY_CLICK));
    }
}

- (void)onTrayMenuItem:(id)sender {
    if (![sender isKindOfClass:[NSMenuItem class]]) return;
    NSNumber* ident = [(NSMenuItem*)sender representedObject];
    if (![ident isKindOfClass:[NSNumber class]]) return;
    archoera::dispatch(archoera::makeTrayMenuCommand(ident.intValue));
}

@end

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
        archoera::pushAccent();
    }
}

- (void)onTheme:(NSNotification*)note {
    (void)note;
    if (archoera::g_theme_events.load(std::memory_order_acquire)) {
        archoera::pushTheme();
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

- (void)onOpenURL:(NSAppleEventDescriptor*)event
    withReplyEvent:(NSAppleEventDescriptor*)reply {
    (void)reply;
    NSString* url = [[event paramDescriptorForKeyword:keyDirectObject]
        stringValue];
    if (url != nil) {
        archoera::setPendingDeepLink([url UTF8String]);
    }
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
    if (url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0) {
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

// ── DeepLink / 协议唤醒（Info.plist 声明 scheme + AppleEvent 接收）──
std::mutex g_deeplink_mutex;
std::string g_deeplink_pending;   // UTF-8；单条待取
std::string g_deeplink_take_buf;  // take 返回缓冲

void setPendingDeepLink(const char* uri) {
    if (uri == nullptr || *uri == '\0') return;
    {
        std::lock_guard<std::mutex> lock(g_deeplink_mutex);
        g_deeplink_pending = uri;
    }
    dispatch(makeDeepLink());
}

// ── 后端接口 ──────────────────────────────────────────────────────
uint32_t caps() {
    return CAP_POWER_INHIBIT | CAP_POWER_SCREEN_STATE | CAP_WINDOW_STATE |
           CAP_MEDIA_SESSION | CAP_APP_INSTANCE | CAP_SYSTEM_ACCENT |
           CAP_SYSTEM_THEME | CAP_DEEP_LINK | CAP_REVEAL_PATH | CAP_TRAY;
}

int32_t init() {
    ensureRemoteCommands();
    // 协议唤醒：注册 archoera:// AppleEvent 处理器（scheme 由 Info.plist
    // CFBundleURLTypes 静态声明；运行时无需写系统注册表）。
    NSAppleEventManager* aem = [NSAppleEventManager sharedAppleEventManager];
    if (aem != nil) {
        [aem setEventHandler:observer()
                 andSelector:@selector(onOpenURL:withReplyEvent:)
               forEventClass:kInternetEventClass
                  andEventID:kAEGetURL];
    }
    // 冷启动：LaunchServices 把 URL 作为启动参数传入。
    for (NSString* arg in [[NSProcessInfo processInfo] arguments]) {
        if ([arg hasPrefix:@"archoera://"]) {
            setPendingDeepLink([arg UTF8String]);
            break;
        }
    }
    return OK;
}

int32_t shutdown() {
    if (g_activity != nil) {
        [[NSProcessInfo processInfo] endActivity:g_activity];
        g_activity = nil;
    }
    g_screen_events.store(false, std::memory_order_release);
    g_window_events.store(false, std::memory_order_release);
    trayDestroy();
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
            // macOS 的 MPMediaItemArtwork 无 initWithImage:（那是 iOS）；用
            // initWithBoundsSize:requestHandler:（10.12.2+），按请求尺寸返回原图。
            dict[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc]
                initWithBoundsSize:image.size
                    requestHandler:^NSImage*(CGSize) {
                      return image;
                    }];
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

// scheme 由 Info.plist 静态声明，运行时注册为幂等空操作。
int32_t protocolRegister(const char*) { return OK; }
int32_t protocolUnregister(const char*) { return OK; }

int32_t deepLinkTake(AplString* out) {
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

// macOS 单实例由 LaunchServices 保证，URL 直接作为 AppleEvent 投递给运行中的
// 实例，无需自行转发。
int32_t deepLinkForward() { return 0; }

int32_t windowActivate() {
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSApp activateIgnoringOtherApps:YES];
      NSWindow* w = [NSApp mainWindow];
      if (w == nil) w = [NSApp keyWindow];
      if (w != nil) [w makeKeyAndOrderFront:nil];
    });
    return OK;
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

void pushAccent() {
    int32_t r = 0, g = 0, b = 0;
    if (systemAccent(&r, &g, &b)) dispatch(makeSystemAccent(r, g, b));
}

int32_t systemAccentSetEvents(bool on) {
    if (on) {
        g_accent_events.store(true, std::memory_order_release);
        // 订阅即推送一次当前值（平台推送模型）。
        pushAccent();
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

// 系统深浅色：读 NSApp.effectiveAppearance 是否 DarkAqua 并推送。
void pushTheme() {
    NSApplication* app = [NSApplication sharedApplication];
    NSAppearance* appearance = app != nil ? app.effectiveAppearance : nil;
    bool dark = false;
    if (appearance != nil) {
        dark = [appearance.name isEqualToString:NSAppearanceNameDarkAqua];
    }
    const bool first = !g_theme_valid.exchange(true, std::memory_order_acq_rel);
    const bool changed =
        dark != g_theme_dark.exchange(dark, std::memory_order_acq_rel);
    if (first || changed) dispatch(makeSystemTheme(dark));
}

int32_t systemThemeSetEvents(bool on) {
    if (on) {
        g_theme_events.store(true, std::memory_order_release);
        // 订阅即推送一次当前值（平台推送模型）。
        pushTheme();
        NSDistributedNotificationCenter* dnc =
            [NSDistributedNotificationCenter defaultCenter];
        observe(dnc, @"AppleInterfaceThemeChangedNotification",
                @selector(onTheme:));
    } else {
        g_theme_events.store(false, std::memory_order_release);
    }
    return OK;
}

int32_t notify(const char* title, const char* body) {
    // NSUserNotification 自 macOS 11 起废弃且现代系统上不再投递 → 改用
    // UserNotifications.framework 的 UNUserNotificationCenter（10.14+）。
    // 需应用为带 bundle id 的 .app 且（新系统）代码签名，否则投递会失败。
    UNUserNotificationCenter* center =
        [UNUserNotificationCenter currentNotificationCenter];
    if (center == nil) return ERR_BACKEND;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert |
                                             UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError* error) {
                            (void)granted;
                            (void)error;
                          }];
    UNMutableNotificationContent* content =
        [[UNMutableNotificationContent alloc] init];
    content.title = nsstr(title, title != nullptr ? strlen(title) : 0);
    content.body = nsstr(body, body != nullptr ? strlen(body) : 0);
    NSString* ident = [NSString
        stringWithFormat:@"archoera-%lld",
                         (long long)([NSDate date].timeIntervalSince1970 * 1000)];
    UNNotificationRequest* request =
        [UNNotificationRequest requestWithIdentifier:ident
                                             content:content
                                             trigger:nil];
    [center addNotificationRequest:request
             withCompletionHandler:^(NSError* error) {
               (void)error;
             }];
    return OK;
}

int32_t revealPath(const char* path) {
    if (path == nullptr || *path == '\0') return ERR_STATE;
    @autoreleasepool {
        NSString* p = [NSString stringWithUTF8String:path];
        if (p == nil) return ERR_BACKEND;
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:p
                                                  isDirectory:&isDir]) {
            return ERR_BACKEND;  // 路径不存在
        }
        NSURL* url = [NSURL fileURLWithPath:p];
        NSWorkspace* ws = [NSWorkspace sharedWorkspace];
        if (isDir) {
            // 目录：直接打开（Finder）。
            [ws openURL:url];
        } else {
            // 文件：在 Finder 中打开所在目录并选中该文件。
            [ws activateFileViewerSelectingURLs:@[ url ]];
        }
    }
    return OK;
}

// ── SystemTray（菜单栏状态项 + 扁平上下文菜单）──────────────────────
namespace {

// 应用图标：18x18 菜单栏模板图（随系统主题自动明暗）；加载失败保留旧图。
void applyTrayIcon(NSStatusItem* item, NSString* path) {
    if (item == nil || item.button == nil) return;
    if (path == nil || path.length == 0) return;
    NSImage* image = [[NSImage alloc] initWithContentsOfFile:path];
    if (image == nil) {
        log(2, "platform", "tray: 图标加载失败");
        return;
    }
    image.size = NSMakeSize(18.0, 18.0);
    // template 在 ObjC++ 里是 C++ 保留字（点语法不可用），改用 setter。
    [image setTemplate:YES];  // 菜单栏模板图，随主题变色（彩色图标应改 NO）
    item.button.image = image;
}

// 主线程：按 [specs] 重建菜单（扁平；id==0 为分隔符）。
void applyTrayMenu(NSArray<NSDictionary*>* specs) {
    ArchoeraTrayTarget* target = g_tray_target;
    if (target == nil) {
        target = [[ArchoeraTrayTarget alloc] init];
        g_tray_target = target;
    }
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;  // 以显式 enabled 为准
    for (NSDictionary* spec in specs) {
        NSNumber* ident = spec[@"id"];
        if (ident == nil) continue;
        const int32_t mid = ident.intValue;
        if (mid == 0) {
            [menu addItem:[NSMenuItem separatorItem]];
            continue;
        }
        NSString* label = spec[@"label"];
        NSMenuItem* item =
            [[NSMenuItem alloc] initWithTitle:(label != nil ? label : @"")
                                      action:@selector(onTrayMenuItem:)
                               keyEquivalent:@""];
        item.target = target;
        item.representedObject = ident;
        NSNumber* enabled = spec[@"enabled"];
        item.enabled = enabled == nil ? YES : enabled.boolValue;
        NSNumber* checked = spec[@"checked"];
        if (checked != nil && checked.intValue >= 0) {
            item.state = checked.intValue != 0 ? NSControlStateValueOn
                                               : NSControlStateValueOff;
        }
        [menu addItem:item];
    }
    g_tray_menu = menu;
}

}  // namespace

int32_t trayCreate(const char* icon_path) {
    NSString* path =
        nsstr(icon_path, icon_path != nullptr ? strlen(icon_path) : 0);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (g_tray_item == nil) {
          NSStatusBar* bar = [NSStatusBar systemStatusBar];
          if (bar == nil) {
              log(3, "platform", "trayCreate: systemStatusBar 不可用");
              return;
          }
          NSStatusItem* item =
              [bar statusItemWithLength:NSVariableStatusItemLength];
          NSStatusBarButton* button = item != nil ? item.button : nil;
          if (item == nil || button == nil) {
              log(3, "platform", "trayCreate: statusItem 创建失败");
              if (item != nil) [bar removeStatusItem:item];
              return;
          }
          ArchoeraTrayTarget* target = [[ArchoeraTrayTarget alloc] init];
          button.target = target;
          button.action = @selector(onTrayButton:);
          // 同时接收左右键 mouseUp，action 内再按 trigger 分派。
          [button
              sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];
          item.visible = g_tray_visible;
          if (g_tray_tooltip != nil) button.toolTip = g_tray_tooltip;
          g_tray_item = item;
          g_tray_target = target;
      }
      applyTrayIcon(g_tray_item, path);
    });
    return OK;
}

int32_t trayDestroy() {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (g_tray_item != nil) {
          [[NSStatusBar systemStatusBar] removeStatusItem:g_tray_item];
          g_tray_item = nil;
      }
      g_tray_menu = nil;
      g_tray_target = nil;
      g_tray_tooltip = nil;
      g_tray_trigger = 1;
      g_tray_visible = true;
    });
    return OK;
}

int32_t traySetIcon(const char* icon_path) {
    NSString* path =
        nsstr(icon_path, icon_path != nullptr ? strlen(icon_path) : 0);
    dispatch_async(dispatch_get_main_queue(), ^{
      applyTrayIcon(g_tray_item, path);
    });
    return OK;
}

int32_t traySetTooltip(const char* tooltip) {
    NSString* tip = nsstr(tooltip, tooltip != nullptr ? strlen(tooltip) : 0);
    dispatch_async(dispatch_get_main_queue(), ^{
      g_tray_tooltip = tip;
      if (g_tray_item != nil && g_tray_item.button != nil) {
          g_tray_item.button.toolTip = tip;
      }
    });
    return OK;
}

int32_t traySetVisible(bool visible) {
    const bool v = visible;
    dispatch_async(dispatch_get_main_queue(), ^{
      g_tray_visible = v;
      if (g_tray_item != nil) g_tray_item.visible = v;
    });
    return OK;
}

int32_t traySetMenu(const AplTrayMenuItem* items, int32_t count) {
    NSMutableArray<NSDictionary*>* specs =
        [NSMutableArray arrayWithCapacity:(NSUInteger)(count > 0 ? count : 0)];
    for (int32_t i = 0; i < count; ++i) {
        const AplTrayMenuItem& src = items[i];
        NSString* label = nsstr(src.label.data, src.label.len);
        [specs addObject:@{
            @"id" : @(src.id),
            @"enabled" : @(src.enabled != 0),
            @"checked" : @(src.checked),
            @"label" : label != nil ? label : @"",
        }];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      applyTrayMenu(specs);
    });
    return OK;
}

int32_t traySetMenuTrigger(int32_t trigger) {
    const int32_t t = trigger != 0 ? 1 : 0;
    dispatch_async(dispatch_get_main_queue(), ^{
      g_tray_trigger = t;
    });
    return OK;
}

}  // namespace archoera
