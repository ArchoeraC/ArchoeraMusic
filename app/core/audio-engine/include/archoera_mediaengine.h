// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

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
 *   - 事件（ready/done/status/position/player:ended/sink_changed/error/exited）入线程安全
 *     FIFO；Dart 事件泵以独立接收 isolate 阻塞 `wait_event` 推送取走（无事件
 *     即睡眠，零轮询开销），`poll_event` 保留作轮询回退调试；
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
 * 从 SegStore 内存源创建引擎会话（docs/audio-memory-source.md M2：Dart 整曲
 * 拉流预填 → 引擎经 AVIO-mem 从同一 store 解码，source 置空）。
 *
 * 语义 ≈ archoera_mediaengine_create，仅引擎线程改走
 * pipeline_create_store(store, cfg, …)：engine_mode 任意（store 模式恒 FFmpeg-mem），
 * mem_mode/no_disk_cache 等现有配置语义不变。
 *
 * @param store       内存源句柄（整曲已预填、可 seek）。**生命周期归调用方**：
 *                    引擎 destroy 不释放 store（也不释放其段缓冲）；调用方须在
 *                    destroy 引擎后自行 segstore_destroy / release_all。
 * @param cfg         引擎配置（同 create）
 * @param player_file / session_dir / errbuf 同 archoera_mediaengine_create
 * @return 引擎句柄；失败返回 NULL（store 为空 / session_dir 为空 / 管线打开失败
 *         经 error 事件上报，同 create）
 */
ARCHOERA_MEDIAENGINE_API ArchoeraMediaEngine *archoera_mediaengine_create_store(
                                     SegStore *store,
                                     const EngineConfig *cfg,
                                     const char *player_file,
                                     const char *session_dir,
                                     char *errbuf, int errbuf_size);

/**
 * 枚举系统音频输出设备（**会话无关**：无需句柄，内部自建/拆除 pulse→alsa
 * context；桌面端切换输出设备前调用）。
 *
 * @param buf 输出缓冲（UTF-8 JSON 数组，调用方分配）
 * @param cap 缓冲容量
 * @return 写入字节数（≤ cap，含结尾 ']'，不含 '\0'；buf 内以 '\0' 结尾）；
 *         无设备返回 0；失败/缓冲不足返回 -1。
 *
 * JSON 格式：
 *   [{"id":"<pulse/alsa 设备 id>","name":"<描述名>","rate":<native Hz>,
 *     "channels":<n>,"default":true|false}, ...]
 * rate/channels 为设备原生格式（如蓝牙 HFP s16 16kHz/1ch 报 16000/1）；
 * native 未知时报 0。default=true 标记系统当前默认播放 sink。
 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_list_sinks(
    char *buf, int cap);

/**
 * set_sink 运行时命令（JSON 行，经 archoera_mediaengine_command 发送）：
 *   {"type":"set_sink","id":"<list_sinks 中的设备 id，或空串 = 系统默认>"}
 *
 * - 引擎记录该选择（持久化由 Dart 侧完成）；选择覆盖 env ARCHOERA_AUDIO_SINK。
 * - 会话尚未启动播放器：下次 player_start 生效；
 * - 正在播放：尝试平滑重启播放器到新设备（保留音量/续播位置），失败则沿用
 *   原设备播放并在事件里报错（不崩溃）；
 * - 目标设备原生为单声道或 <44.1kHz（如蓝牙 HFP 16k/1ch）时，播放按该设备
 *   原生格式（rate/channels）开设备，确保所选设备满速出声。
 *
 * 回报事件（poll_event）：
 *   {"type":"sink_changed","ok":true,"err":""}            // 成功（含空 id=回默认）
 *   {"type":"sink_changed","ok":false,"err":"<原因>"}     // 失败（播放器保持原样）
 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_command(
    ArchoeraMediaEngine *e, const char *json_line);

/**
 * 取一条事件（FIFO）。
 * @return 1 有事件（写入 buf，'\0' 结尾）；0 队列空。
 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_poll_event(
    ArchoeraMediaEngine *e, char *buf, int cap);

/**
 * 阻塞取一条事件（事件驱动推送；Dart 事件泵在独立接收 isolate 中调用，
 * 替代「Dart 50ms 定时 pollEvent 轮询」，空闲零唤醒、零轮询开销）。
 *
 * @param e         引擎句柄
 * @param buf       事件缓冲（调用方分配）
 * @param cap       缓冲容量
 * @param timeout_ms 等待上限（毫秒）：<0 永久等待；>=0 最多等该毫秒，
 *                   超时返 0。
 *
 * @return >0 事件字节长度（写入 buf，'\0' 结尾；与 poll_event 同协议，
 *         每行一条 JSON 事件）；0 超时无事件；-1 已销毁（destroy 已开始，
 *         唤醒等待者并告知——调用方应退出取事件循环，勿再对本句柄调用）。
 *
 * 并发/生命周期契约：
 *   - 有事件立即 pop 返回；无事件在条件变量上睡眠（事件入队即唤醒，
 *     非忙轮询）；
 *   - destroy 会唤醒所有阻塞中的 wait_event（返回 -1），并等待在
 *     wait_event 内的调用方退出后才释放内存（wait_event 与 destroy
 *     可在不同线程并发调用；同一句柄建议单线程阻塞取事件）；
 *   - 销毁开始后 wait_event 不再交付事件（stop 后的残留事件被丢弃）；
 *   - 保留 archoera_mediaengine_poll_event 兼容（轮询调试回退用）。
 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_wait_event(
    ArchoeraMediaEngine *e, char *buf, int cap, int timeout_ms);

/** 会话目录（create 时传入）。 */
ARCHOERA_MEDIAENGINE_API const char *archoera_mediaengine_session_dir(
    ArchoeraMediaEngine *e);

/** 引擎线程是否已退出（转码+播放结束、收到 stop、或已 destroy）。 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_is_done(
    ArchoeraMediaEngine *e);

/**
 * 内存播放模式（EngineConfig.no_disk_cache=1）的频谱拉取：以 end_pos_ms 为终点
 * 取最近 frames 样本，L/R 各写 frames 个 float（引擎输出恒 2ch 下混）。
 *
 * 语义对齐 Dart PcmAnalyzer.frameAt：终点样本 = 定位块内 (位置偏移×采样率) 取整；
 * 头部仍在时前缀补零；seek 重建后旧缓冲失效（配合 archoera_mediaengine_pcm_epoch
 * 丢弃旧帧索引）；被淘汰（达内存 cap 滚动丢弃）或尚未解码返回 -1。
 *
 * @return 0 命中；-1 越出保留窗 / 尚未解码；-2 参数错误或非内存模式会话。
 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_pcm_window(
    ArchoeraMediaEngine *e, int end_pos_ms, int frames,
    float *out_l, float *out_r);

/** seek 重建后的会话 epoch（重建即 +1，用于丢弃旧帧索引）；非内存模式返回 -1。 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_pcm_epoch(
    ArchoeraMediaEngine *e);

/**
 * M3（docs/audio-memory-source.md §6.1/§6.2）：当前可用内存（MB），供 Dart
 * 预算管理器计算 auto ceiling / requiredCeiling。失败返回 -1（回落保守下限）。
 */
ARCHOERA_MEDIAENGINE_API long long archoera_mediaengine_mem_available_mb(void);

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
