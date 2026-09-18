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
 *    实现需要留存时自行拷贝；实现永不向 Dart 返回需释放的内存；
 *  - AplEvent 仅在回调期间有效（栈上），Dart 侧必须立即取值。
 *
 * 导出：Windows 上 `extern "C"` 不会自动导出符号，故用 APL_API 显式
 * `__declspec(dllexport)`；构建桥接库时须定义 ARCHOERA_PLATFORM_BUILD。
 */
#ifndef ARCHOERA_PLATFORM_H
#define ARCHOERA_PLATFORM_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) || defined(__CYGWIN__)
#if defined(ARCHOERA_PLATFORM_BUILD)
#define APL_API __declspec(dllexport)
#else
#define APL_API __declspec(dllimport)
#endif
#elif defined(__GNUC__) && __GNUC__ >= 4
#define APL_API __attribute__((visibility("default")))
#else
#define APL_API
#endif

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
#define APL_CAP_SYSTEM_THEME       (1u << 8) /* 系统深浅色（light/dark） */
#define APL_CAP_OS_SESSION         (1u << 9) /* ArchoeraOS 合成器会话（archoera_shell_v1，仅 Wayland 且运行于 archoera-shell） */
#define APL_CAP_SYS_STATS          (1u << 10) /* 系统资源快照（CPU/内存/磁盘/运行时长/温度） */
#define APL_CAP_BLUETOOTH          (1u << 11) /* 蓝牙适配器状态（BlueZ；无适配器/无 BlueZ 时不置位） */
#define APL_CAP_WIFI               (1u << 12) /* WiFi（NetworkManager；无无线设备/NM 时不置位） */

/* ── 生命周期 ───────────────────────────────────────────────────── */
APL_API int32_t apl_abi_version(void);   /* 契约版本 */
APL_API int32_t apl_init(void);          /* 进程级一次；重复调用幂等 */
APL_API int32_t apl_shutdown(void);      /* join 线程、释放抑制、注销媒体会话；幂等 */
APL_API uint32_t apl_capabilities(void); /* 能力位图；未 init 亦可查询 */

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
    AplString art_bytes;   /* 本地封面字节（Dart 读文件后传入）；Windows 走内存流，其余忽略 */
} AplTrackMeta;

/* ── SystemPower ───────────────────────────────────────────────── */
APL_API int32_t apl_power_set_sleep_inhibit(int32_t on);
APL_API int32_t apl_power_set_screen_events(int32_t on);

/* ── SystemWindow ──────────────────────────────────────────────── */
APL_API int32_t apl_window_set_events(int32_t on);

/* ── SystemMedia ───────────────────────────────────────────────── */
APL_API int32_t apl_media_set_track(const AplTrackMeta *track); /* NULL = 清除 */
APL_API int32_t apl_media_set_playback(int32_t state,   /* 0=stopped 1=playing 2=paused */
                                       int64_t position_ms,
                                       double speed, double volume,
                                       int32_t loop,    /* 0=list 1=one */
                                       int32_t shuffle);
APL_API int32_t apl_media_set_window(int64_t window);   /* HWND/NSWindow*；非桌面忽略 */

/* 单实例：1=首实例；0=已有实例（调用方应退出）；<0=错误。进程内幂等。 */
APL_API int32_t apl_instance_acquire(void);

/* ── ArchoeraOS 会话（archoera_shell_v1）─────────────────────────── */
/* 仅当运行在 archoera-shell kiosk 会话下（Wayland socket 暴露该全局）时可用；
 * 未接入时以下请求返回 APL_ERR_UNSUPPORTED，事件流为空。 */

/* 订阅/退订会话事件（APL_EVENT_OS_* / 媒体键命令）。
 * 订阅成功时合成器会立即下发当前会话状态（能力位/亮度/音量/电池/会话/屏幕）。 */
APL_API int32_t apl_os_set_events(int32_t on);

/* 请求（越界百分比由合成器夹取；无对应能力位时被静默忽略）。 */
APL_API int32_t apl_os_set_brightness(int32_t percent);
APL_API int32_t apl_os_set_volume(int32_t percent);
APL_API int32_t apl_os_set_screen_enabled(int32_t on);
APL_API int32_t apl_os_power_off(void);
APL_API int32_t apl_os_reboot(void);
APL_API int32_t apl_os_suspend(void);
APL_API int32_t apl_os_hibernate(void);

/* 显示设置（仅 archoera-shell udev 后端提供 output 能力位时生效）。
 * 合成器会夹取缩放（100%-400%）并忽略连接器不支持的尺寸/变换。 */
APL_API int32_t apl_os_set_output_scale(int32_t scale_milli); /* 千分数，如 1500=150% */
APL_API int32_t apl_os_set_output_mode(int32_t width, int32_t height); /* 0,0 = 首选模式 */
APL_API int32_t apl_os_set_output_transform(int32_t transform); /* 0..7，见 wl_output.transform */

/* 注入一个按键（屏幕键盘 → 合成器 → 焦点客户端/输入法）。
 * keycode 为 evdev 键码（KEY_*，如 KEY_A=30），并非 XKB keycode；state 0=释放 1=按下。
 * 合成器按物理键盘路径处理，输入法（fcitx5）可正常消费；仅 archoera_shell_v1
 * 的 keyboard 能力位置位时生效。修饰键由调用方自行按下/释放。 */
APL_API int32_t apl_os_key(int32_t keycode, int32_t state);

/* 系统提示（UTF-8 title/body；用于“已有实例”提示等）。失败返回负值。 */
APL_API int32_t apl_notify(const char *title, const char *body);

/* ── 系统资源 / 蓝牙（只读快照；轮询式，无事件）─────────────────── */
typedef struct AplSysStats {
    int32_t cpu_count;        /* 逻辑核数 */
    int32_t cpu_percent;      /* 0-100；自上次调用起的平均占用（首次 -1） */
    int64_t mem_total_kb;
    int64_t mem_available_kb;
    int64_t swap_total_kb;
    int64_t swap_free_kb;
    int64_t disk_total_kb;    /* 数据目录所在文件系统（不可得时 0） */
    int64_t disk_free_kb;
    int64_t uptime_sec;
    int32_t temp_millic;      /* 温度 ×1000；<0 = 无传感器/不可得 */
} AplSysStats;

/* 读取系统资源快照；成功返回 0 并写 out（结构体由调用方分配）。 */
APL_API int32_t apl_sys_stats(AplSysStats *out);

/* ── 显卡（只读快照；Linux 走 DRM/sysfs）───────────────────────── */
/* 说明：当前只实现 Linux（`/sys/class/drm/card*` + hwmon + 驱动特有文件），
 * 未实现平台返回 APL_ERR_UNSUPPORTED。字符串生命周期同 WiFi：仅在该次调用后、
 * 下一次同类调用前有效。usage_percent 对 Intel(i915/xe) 暂不可得（需 fdinfo 统计），
 * 返回 -1；Amdgpu 走 gpu_busy_percent。 */
typedef struct AplGpuInfo {
    AplString name;              /* 可读名（厂商 + 驱动；如 "Intel i915"） */
    AplString driver;            /* 内核驱动：amdgpu / i915 / xe / nouveau / virtio-pci … */
    AplString pci_id;            /* "1002:164e"；非 PCI（如 virtio）为空 */
    int32_t temperature_millic;  /* 温度 ×1000；<0 = 无传感器 */
    int32_t usage_percent;       /* 0-100；-1 = 不可得 */
    int64_t vram_total_kb;       /* <=0 = 不可得 */
    int64_t vram_used_kb;        /* <=0 = 不可得 */
    int32_t clock_mhz;           /* 当前核心频率；<0 = 不可得 */
} AplGpuInfo;

/* 列出显卡；out 由调用方分配。无 DRM 设备（或未实现）返回负值。 */
APL_API int32_t apl_gpu_list(AplGpuInfo *out, uint32_t max, uint32_t *count);

typedef struct AplBtState {
    int32_t present;           /* 存在蓝牙适配器 */
    int32_t powered;           /* 适配器已开启 */
    int32_t discoverable;
    int32_t pairable;
    int32_t devices_connected; /* 已连接设备数 */
    AplString adapter_name;    /* 适配器名（仅调用期间有效；无适配器时 data=NULL） */
} AplBtState;

/* 读取蓝牙适配器状态；无 BlueZ/无适配器返回负值（Dart 侧据此显示「无蓝牙」）。 */
APL_API int32_t apl_bt_state(AplBtState *out);

/* ── WiFi（NetworkManager）──────────────────────────────────────── */
/* 说明：以下接口 Linux 走 system bus 的 NetworkManager；未实现平台返回
 * APL_ERR_UNSUPPORTED，Dart 侧据此隐藏「WiFi」分区。
 * 字符串生命周期：输出结构体里的 AplString 指向后端内部缓冲，
 * **仅在该次调用返回后、下一次同类调用之前有效**，Dart 侧应立即复制。 */

typedef struct AplWifiState {
    int32_t present;      /* 系统有无线设备（rfkill/NM） */
    int32_t enabled;      /* 无线总开关已打开 */
    int32_t connected;    /* 已连接某个 AP */
    int32_t signal;       /* 当前连接信号 0-100；未连接 = -1 */
    AplString ssid;       /* 当前 SSID（未连接 data=NULL） */
    AplString ip;         /* IPv4 地址（未连接 data=NULL） */
    AplString security;   /* 当前连接安全类型（如 "wpa-psk"；未知可为 NULL） */
} AplWifiState;

/* security 取值（与 NM 名称无关的稳定枚举，便于 Dart 直接判断是否需要密码） */
#define APL_WIFI_SEC_OPEN     0
#define APL_WIFI_SEC_WEP      1
#define APL_WIFI_SEC_PSK      2 /* WPA/WPA2/WPA3 个人版 */
#define APL_WIFI_SEC_8021X    3 /* 企业版（本 UI 暂不支持配置） */
#define APL_WIFI_SEC_UNKNOWN  4

typedef struct AplWifiNetwork {
    AplString ssid;
    int32_t signal;       /* 0-100 */
    int32_t security;     /* APL_WIFI_SEC_* */
    int32_t connected;
    int32_t saved;        /* 已有保存的连接配置（可免密重连） */
} AplWifiNetwork;

/* 读取 WiFi 概况。无 NM / 无无线设备返回负值。 */
APL_API int32_t apl_wifi_state(AplWifiState *out);

/* 触发一次扫描并返回结果（内部等待扫描完成，可能耗时数百毫秒）。
 * out 为调用方数组，写入最多 max 条，*count 回传实际条数。 */
APL_API int32_t apl_wifi_scan(AplWifiNetwork *out, uint32_t max, uint32_t *count);

/* 连接：psk=NULL 表示开放网络或已有保存配置。成功返回 0（异步连接已发起）。 */
APL_API int32_t apl_wifi_connect(const char *ssid, const char *psk);
APL_API int32_t apl_wifi_disconnect(void);
APL_API int32_t apl_wifi_set_enabled(int32_t on);
/* 删除已保存的连接配置。 */
APL_API int32_t apl_wifi_forget(const char *ssid);

/* ── 蓝牙控制（BlueZ）───────────────────────────────────────────── */
/* 与 apl_bt_state（只读快照）配套：这里做扫描/配对/连接/开关。
 * 字符串生命周期同 WiFi：结果仅在该次调用后、下一次同类调用前有效。 */

typedef struct AplBtDevice {
    AplString address;    /* "AA:BB:CC:DD:EE:FF" */
    AplString name;       /* 可读名（可能为空） */
    int32_t paired;
    int32_t connected;
    int32_t rssi;         /* 扫描期间信号 dBm；未知 < 0 */
} AplBtDevice;

/* 开始/停止发现（配对前通常需要先 start）。 */
APL_API int32_t apl_bt_scan_start(void);
APL_API int32_t apl_bt_scan_stop(void);
/* 读取已知设备列表（含刚发现的）；out 由调用方分配。 */
APL_API int32_t apl_bt_devices(AplBtDevice *out, uint32_t max, uint32_t *count);

/* 配对（内部注册 agent 并等待结果，可能耗时数秒；无 PIN 的 Just Works 设备直接完成）。 */
APL_API int32_t apl_bt_pair(const char *address);
APL_API int32_t apl_bt_connect(const char *address);
APL_API int32_t apl_bt_disconnect(const char *address);
/* 取消配对并移除设备记录。 */
APL_API int32_t apl_bt_forget(const char *address);
APL_API int32_t apl_bt_set_enabled(int32_t on);

/* 一次性读取系统主题色（0=成功并写 r/g/b，0-255；<0=不可得）。
 * 注：应用层不应主动轮询/查询系统色；正常路径是 apl_system_accent_set_events
 * 订阅后由平台**推送**（订阅时立即推当前值，之后推变化）。本函数仅作备用。 */
APL_API int32_t apl_system_accent(int32_t *r, int32_t *g, int32_t *b);

/* 订阅系统主题色：平台**推送**（OS → Dart）——
 *   - 订阅成功时立即推送一次当前色；
 *   - 之后系统色变化时推送。
 * 事件 APL_EVENT_SYSTEM_ACCENT 携带 u.accent（r/g/b，0-255），Dart 无需再查询。 */
APL_API int32_t apl_system_accent_set_events(int32_t on);

/* 订阅系统深浅色：平台**推送**（OS → Dart）——
 *   - 订阅成功时立即推送一次当前值；
 *   - 之后系统深浅色变化时推送。
 * 事件 APL_EVENT_SYSTEM_THEME 携带 u.theme.dark（1=深色，0=浅色）。 */
APL_API int32_t apl_system_theme_set_events(int32_t on);

/* ── Live 安装向导（仅 Live 镜像；ArchoeraOS）───────────────────── *
 * 说明：只有 Live 环境（存在 /etc/archoera-live）可用；已安装系统返回
 * APL_ERR_UNSUPPORTED。这里不做任何子进程：磁盘清单读 /sys/block，
 * 计划/口令由本层写文件，启动安装通过在 **system bus** 上调 systemd 的
 * StartUnit（polkit 允许活动会话的 kiosk 用户启动该单元）。
 * 字符串生命周期同 WiFi：仅在该次调用后、下一次同类调用前有效。 */

typedef struct AplLiveDisk {
    AplString name;       /* 不含 /dev/，如 "nvme0n1" */
    int64_t size_bytes;
    AplString model;
    AplString transport;  /* nvme / sata / usb / mmc / … */
    int32_t is_live;      /* 1 = 当前 Live 介质所在磁盘（禁止选为目标） */
} AplLiveDisk;

typedef struct AplLivePlan {
    AplString disk;       /* "/dev/nvme0n1" */
    AplString hostname;
    AplString username;
    AplString locale;     /* 如 "zh_CN.UTF-8" */
    AplString timezone;   /* 如 "Asia/Shanghai" */
    AplString keymap;     /* 如 "us" / "cn" */
    AplString fs;         /* "ext4" | "btrfs" */
    AplString swap;       /* "none" | "file" */
    int32_t encrypt;      /* 0/1 → LUKS2 加密 root */
    int32_t autologin;    /* 0/1 → 是否保持 tty1 自动登录进 kiosk */
    AplString luks_passphrase; /* encrypt=1 时必填 */
    AplString user_password;   /* 空 = 不设（kiosk 自动登录不需要） */
    AplString root_password;   /* 空 = 保持 root 锁定 */
} AplLivePlan;

typedef struct AplLiveInstallStatus {
    int32_t running;      /* 单元正在运行 */
    int32_t done;         /* /run/archoera-install/done 存在 */
    int32_t failed;       /* failed 文件存在（message 为原因） */
    int32_t percent;      /* -1 = 未知 */
    AplString message;    /* 当前步骤说明 */
} AplLiveInstallStatus;

/* 1 = 当前是 Live 环境（/etc/archoera-live 存在），否则 0。 */
APL_API int32_t apl_live_available(void);

/* 候选目标磁盘（已排除 loop/zram/sr/dm/md；含 is_live 标记）。 */
APL_API int32_t apl_live_disk_list(AplLiveDisk *out, uint32_t max, uint32_t *count);

/* 写计划（含 0600 的 secrets）并启动安装单元。返回 0 = 已启动。 */
APL_API int32_t apl_live_install_start(const AplLivePlan *plan);

/* 读取安装进度（供向导轮询）。 */
APL_API int32_t apl_live_install_status(AplLiveInstallStatus *out);

/* ── 反向事件（OS → Dart）──────────────────────────────────────── */
typedef enum {
    APL_EVENT_MEDIA_COMMAND = 1,
    APL_EVENT_MEDIA_SEEK    = 2,
    APL_EVENT_SCREEN_STATE  = 3,
    APL_EVENT_WINDOW_STATE  = 4,
    APL_EVENT_BACKEND_STATE = 5, /* u.backend_lost：1=后端断连 */
    APL_EVENT_SYSTEM_ACCENT = 6, /* 系统主题色（u.accent：r/g/b 0-255，平台推送） */
    APL_EVENT_SYSTEM_THEME  = 7, /* 系统深浅色（u.theme.dark：1=深色，平台推送） */
    /* ── ArchoeraOS 会话（archoera_shell_v1）── */
    APL_EVENT_OS_CAPABILITIES = 8,  /* u.os.caps：会话能力位（见 apl_os_* 注释） */
    APL_EVENT_OS_BRIGHTNESS   = 9,  /* u.os.value：亮度 0-100 */
    APL_EVENT_OS_VOLUME       = 10, /* u.os.value：会话音量 0-100 */
    APL_EVENT_OS_BATTERY      = 11, /* u.os.battery：present/percent/charging */
    APL_EVENT_OS_SESSION      = 12, /* u.os.session：1=ready 2=shutting_down 3=suspending */
    APL_EVENT_OS_SCREEN       = 13, /* u.os.screen：1=亮屏 0=熄屏 */
    APL_EVENT_OS_POWER_KEY    = 14, /* u.os.power_key：0=power 1=sleep 2=suspend */
    APL_EVENT_OS_OUTPUT       = 15, /* u.os_output：主输出 宽/高/缩放×1000/变换/刷新 mHz */
} AplEventType;

typedef enum {
    APL_CMD_PLAY = 0, APL_CMD_PAUSE, APL_CMD_TOGGLE, APL_CMD_STOP,
    APL_CMD_NEXT, APL_CMD_PREV,
    APL_CMD_VOLUME_UP = 6, APL_CMD_VOLUME_DOWN, APL_CMD_VOLUME_MUTE,
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
        struct { int32_t r; int32_t g; int32_t b; } accent; /* SYSTEM_ACCENT：0-255 */
        struct { int32_t dark; } theme; /* SYSTEM_THEME：1=深色 0=浅色 */
        /* ── ArchoeraOS 会话 ── */
        struct { int32_t caps; } os_caps;      /* OS_CAPABILITIES */
        struct { int32_t value; } os_value;    /* OS_BRIGHTNESS / OS_VOLUME：0-100 */
        struct { int32_t present; int32_t percent; int32_t charging; } os_battery;
        struct { int32_t state; } os_session;  /* 1=ready 2=shutting_down 3=suspending */
        struct { int32_t screen; } os_screen;  /* 1=亮屏 0=熄屏 */
        struct { int32_t key; } os_power_key;  /* 0=power 1=sleep 2=suspend */
        /* 主输出状态（OS_OUTPUT）：宽/高（物理像素）、缩放千分数、变换（0..7）、刷新率 mHz */
        struct {
            int32_t width;
            int32_t height;
            int32_t scale_milli;
            int32_t transform;
            int32_t refresh_millihz;
        } os_output;
    } u;
} AplEvent;

/* 事件回调：可在任意 OS 线程触发；Dart 侧须用 NativeCallable.listener。
 * event 仅在回调期间有效（栈上），user_data 由 Dart 提供原样回传。
 * cb = NULL 注销（线程安全，置位后生效）。 */
typedef void (*AplEventCallback)(const AplEvent *event, void *user_data);

APL_API int32_t apl_set_event_callback(AplEventCallback cb, void *user_data);

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERA_PLATFORM_H */
