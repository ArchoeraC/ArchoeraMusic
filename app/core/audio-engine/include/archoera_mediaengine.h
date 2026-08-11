/**
 * archoera_mediaengine.h — 音频引擎 FFI 库（Dart 桌面端直连，替代进程 IPC）
 *
 * 命名（2026-08-07 用户决策）：本项目自研代码，命名不沿用上游 SPlayer-Next
 * 的 splayer_* 前缀，统一为 archoera_mediaengine。
 *
 * 动机：桌面端从「子进程 spawn + AF_UNIX 三路 UDS」迁移到 FFI 直连，
 * 摆脱 AF_UNIX（Windows 无此机制）与 TCP 回退的兼容性问题。
 *
 * 模型：
 *   - 引擎在库内自有线程（转码 + miniaudio 播放），FFI 调用均为短调用
 *     （create/command/poll/destroy），不阻塞 Dart isolate；
 *   - 事件（ready/done/status/position/player:ended/error/exited）入线程安全
 *     FIFO，Dart 侧定时 poll；
 *   - 控制命令（play/pause/seek/set_volume/get_status/stop 等）入命令 FIFO，
 *     引擎线程消费；
 *   - PCM 由引擎直写会话目录 stream.pcm（块格式，同 pcm_uds），Dart 按需
 *     读文件做 FFT；播放模式另落盘 stream.wav 供 miniaudio 自播。
 *
 * Web/CLI 路径（main.c + UDS/stdout）保持不变，仅桌面 FFI 客户端使用本库。
 */
#ifndef ARCHOERAMEDIAENGINE_H
#define ARCHOERAMEDIAENGINE_H

#include "audio_engine.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ArchoeraMediaEngine ArchoeraMediaEngine;

/* 导出符号（CMake -fvisibility=hidden 下显式标记，Dart FFI 需要） */
#if defined(_WIN32)
#define ARCHOERA_MEDIAENGINE_API __declspec(dllexport)
#else
#define ARCHOERA_MEDIAENGINE_API __attribute__((visibility("default")))
#endif

/**
 * 创建引擎会话并启动引擎线程（立即开始转码）。
 *
 * @param source      输入源（本地文件路径 / 在线 URL）
 * @param cfg         引擎配置（同 CLI）
 * @param player_file 非 NULL 时进入播放模式：转码 PCM 落盘 WAV + miniaudio
 *                    自播（跳过 Opus 编码，采样率跟随源或 cfg 指定）
 * @param session_dir 会话目录（WAV/PCM 落盘于此，调用方创建与清理）
 * @param errbuf      失败信息缓冲（可传 NULL）
 * @return 引擎句柄；失败返回 NULL（源不可读 / 参数错误）
 */
ARCHOERA_MEDIAENGINE_API ArchoeraMediaEngine *archoera_mediaengine_create(
                                     const char *source,
                                     const EngineConfig *cfg,
                                     const char *player_file,
                                     const char *session_dir,
                                     char *errbuf, int errbuf_size);

/**
 * 发送控制命令（JSON 行，线程安全）。
 * 支持：play / pause / set_playing / seek / set_volume / get_status /
 * set_eq / set_normalization / set_limiter / set_fft / set_tempo* / stop。
 * 队列满返回 -1。
 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_command(
    ArchoeraMediaEngine *e, const char *json_line);

/**
 * 取一条事件（FIFO）。
 * @return 1 有事件（写入 buf，'\0' 结尾）；0 队列空。
 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_poll_event(
    ArchoeraMediaEngine *e, char *buf, int cap);

/** 会话目录（create 时传入）。 */
ARCHOERA_MEDIAENGINE_API const char *archoera_mediaengine_session_dir(
    ArchoeraMediaEngine *e);

/** 引擎线程是否已退出（转码+播放结束、收到 stop、或已 destroy）。 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_is_done(
    ArchoeraMediaEngine *e);

/**
 * 停止并销毁（请求退出 → join 引擎线程 → 释放资源）。
 * 可重复调用/传 NULL。
 */
ARCHOERA_MEDIAENGINE_API void archoera_mediaengine_destroy(
    ArchoeraMediaEngine *e);

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERAMEDIAENGINE_H */
