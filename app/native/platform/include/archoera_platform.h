/*
 * ArchoeraMusic 平台能力原生桥接 —— C ABI 契约（唯一头文件）
 * Copyright (C) 2026 Archoera && BetaStudio2
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * 设计依据：docs/platform-native-bridge.md §3（本头文件为其草案的落地版）。
 * Dart 侧绑定：app/lib/services/platform/platform_bindings.dart（dart:ffi）。
 *
 * 约定：
 *  - 全部 extern struct / C ABI / 整型错误码，零 JSON、零子进程；
 *  - AplString.data 允许 NULL（= 字段缺失），UTF-8，仅调用期间有效，
 *    Zig 需要留存时自行拷贝；Zig 永不向 Dart 返回需释放的内存；
 *  - AplEvent 仅在回调期间有效（栈上），Dart 侧必须立即取值。
 */
#ifndef ARCHOERA_PLATFORM_H
#define ARCHOERA_PLATFORM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── 错误码 ─────────────────────────────────────────────────────── */
#define APL_OK              0
#define APL_ERR_UNSUPPORTED -1  /* 本平台无此能力（未编译后端 / 缺系统服务） */
#define APL_ERR_BACKEND     -2  /* 后端调用失败（D-Bus 断连 / WinRT 拒绝等） */
#define APL_ERR_STATE       -3  /* 未 init / 参数非法 */

/* ── 能力位图（apl_capabilities）────────────────────────────────── */
#define APL_CAP_POWER_INHIBIT      (1u << 0) /* 防休眠抑制（三平台全覆盖） */
#define APL_CAP_POWER_SCREEN_STATE (1u << 1) /* 熄屏/屏保状态事件（三平台全覆盖） */
#define APL_CAP_MEDIA_SESSION      (1u << 2) /* 系统媒体会话（MPRIS/SMTC/NowPlaying） */
#define APL_CAP_MEDIA_SEEK         (1u << 3) /* 系统 UI 可拖进度条 */
#define APL_CAP_MEDIA_ARTWORK      (1u << 4) /* 封面图可展示 */
#define APL_CAP_WINDOW_STATE       (1u << 5) /* 窗口最小化/失焦事件 */
#define APL_CAP_APP_INSTANCE       (1u << 6) /* 单实例仲裁（文件锁） */
#define APL_CAP_SYSTEM_ACCENT      (1u << 7) /* 系统主题色（DE accent） */

/* ── 生命周期 ───────────────────────────────────────────────────── */
int32_t apl_abi_version(void);   /* 契约版本 */
int32_t apl_init(void);          /* 进程级一次；重复调用幂等 */
int32_t apl_shutdown(void);      /* join 线程、释放抑制、注销媒体会话；幂等 */
uint32_t apl_capabilities(void); /* 能力位图；未 init 亦可查询 */

/* ── 字符串与曲目元数据（零 JSON）───────────────────────────────── */
typedef struct AplString {
    const char *data; /* UTF-8；NULL = 缺失 */
    size_t len;       /* 字节数（非含终止符） */
} AplString;

typedef struct AplTrackMeta {
    AplString title;       /* 必填 */
    AplString artist;      /* 多人由 Dart 预拼接 " / " */
    AplString album;
    int64_t duration_ms;   /* <0 = 未知 */
    AplString art_url;     /* http(s) URL 或本地绝对路径；NULL = 无封面 */
} AplTrackMeta;

/* ── SystemPower ───────────────────────────────────────────────── */
int32_t apl_power_set_sleep_inhibit(int32_t on);
int32_t apl_power_set_screen_events(int32_t on);

/* ── SystemWindow ──────────────────────────────────────────────── */
int32_t apl_window_set_events(int32_t on);

/* ── SystemMedia ───────────────────────────────────────────────── */
int32_t apl_media_set_track(const AplTrackMeta *track); /* NULL = 清除 */
int32_t apl_media_set_playback(int32_t state,   /* 0=stopped 1=playing 2=paused */
                               int64_t position_ms,
                               double speed, double volume,
                               int32_t loop,    /* 0=list 1=one */
                               int32_t shuffle);
int32_t apl_media_set_window(int64_t window);   /* HWND/NSWindow*；非桌面忽略 */

/* 单实例：1=首实例；0=已有实例（调用方应退出）；<0=错误。进程内幂等。 */
int32_t apl_instance_acquire(void);

/* 系统提示（UTF-8 title/body；用于“已有实例”提示等）。失败返回负值。 */
int32_t apl_notify(const char *title, const char *body);

/* 系统主题色（DE accent）：0=成功并写 *r/*g/*b(0-255)；<0=不可得。 */
int32_t apl_system_accent(int32_t *r, int32_t *g, int32_t *b);

/* ── 反向事件（OS → Dart）──────────────────────────────────────── */
typedef enum {
    APL_EVENT_MEDIA_COMMAND = 1,
    APL_EVENT_MEDIA_SEEK    = 2,
    APL_EVENT_SCREEN_STATE  = 3,
    APL_EVENT_WINDOW_STATE  = 4,
    APL_EVENT_BACKEND_STATE = 5, /* u.backend_lost：1=后端断连 */
} AplEventType;

typedef enum {
    APL_CMD_PLAY = 0, APL_CMD_PAUSE, APL_CMD_TOGGLE, APL_CMD_STOP,
    APL_CMD_NEXT, APL_CMD_PREV,
} AplCommand;

typedef struct AplEvent {
    int32_t type;
    int32_t _pad;
    union {
        int32_t command;   /* MEDIA_COMMAND */
        struct { int64_t rel_ms; int64_t abs_ms; } seek;   /* MEDIA_SEEK */
        int32_t active;    /* SCREEN_STATE：1=熄屏/屏保激活 */
        struct { int32_t minimized; int32_t focused; } window; /* WINDOW_STATE */
        int32_t backend_lost; /* BACKEND_STATE */
    } u;
} AplEvent;

/* 事件回调：可在任意 OS 线程触发；Dart 侧须用 NativeCallable.listener。
 * event 仅在回调期间有效（栈上），user_data 由 Dart 提供原样回传。
 * cb = NULL 注销（线程安全，置位后生效）。 */
typedef void (*AplEventCallback)(const AplEvent *event, void *user_data);

int32_t apl_set_event_callback(AplEventCallback cb, void *user_data);

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERA_PLATFORM_H */
