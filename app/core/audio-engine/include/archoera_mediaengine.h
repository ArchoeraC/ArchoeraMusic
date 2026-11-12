// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * archoera_mediaengine.h — 音频引擎 FFI 库（Dart 桌面端直连，替代进程 IPC）
 *
 * 命名（2026-08-07 用户决策）：本项目自研代码，统一为 archoera_mediaengine。
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
 *   - PCM 由引擎直写会话目录 stream.pcm（块格式，同 pcm_uds）；播放模式
 *     另落盘 stream.wav 供 miniaudio 自播。频谱 v2 由引擎独立频谱线程按
 *     播放位置取窗并 50ms 推送 `fft` 事件（App 不再读 PCM 做 FFT）。
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

/* ── 统一日志 sink（宿主注入）───────────────────────────────────────
 * 宿主 Dart 载入 libarchoera_log 后，把其 archoera_log_write 指针注入本引擎，
 * 引擎内部日志即走统一格式/落盘；fn=NULL 注销并回退 stderr。
 * level 取值同 archoera_log.h（0=DEBUG 1=INFO 2=WARN 3=ERROR 4=FATAL）；
 * 低于 min_level 的日志在引擎侧即丢弃（避免无谓格式化）。 */
typedef void (*ArchoeraMediaEngineLogFn)(int level, const char *tag,
                                        const char *message);
ARCHOERA_MEDIAENGINE_API void archoera_mediaengine_set_log_sink(
    ArchoeraMediaEngineLogFn fn, int min_level);

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
 * 同 [archoera_mediaengine_create]，另按源注入在线 URL 的额外请求头 [headers]
 * （`\n`/`\r\n` 分行的 `Name: value`；NULL = 无）。原生 HTTP(S) 与 FFmpeg
 * http/tls 路径均会带上，用于携带客户端标识（如 NekoMusic 的 `X-Neko-Client`）；
 * 字符串会复制保存至会话销毁。
 */
ARCHOERA_MEDIAENGINE_API ArchoeraMediaEngine *archoera_mediaengine_create_with_headers(
                                     const char *source,
                                     const char *headers,
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
 *
 * 优先交付常规事件（行上限 511B），无常规事件时交付最新一帧频谱事件
 * （`{"type":"fft",...}`，8-bit 量化 128×2 + 元数据 < 2KB）。调用方缓冲
 * 建议 ≥ 2048B；频谱事件只保留最新，读走即清。
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

/** 引擎线程是否已退出（转码+播放结束、收到 stop、或已 destroy）。 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_is_done(
    ArchoeraMediaEngine *e);

/**
 * 单会话暂存源切换（prepare_source / commit_source）的纯计算辅助：commit 时
 * 需从暂存缓冲头部丢弃的交叠 float 样本数（供确定性单测；运行期由引擎内部
 * 用同一函数）：
 *   drop_ms = old_ms - origin_ms（媒体时间，clamp >= 0）
 *   frames  = llround(drop_ms * rate / 1000 / tempo_speed)
 *   samples = frames * stage_ch（夹取到 [0, staged]）
 * [origin_ms] 必须是 stage[0] 的真实媒体时间（PCM 回调的**块起始**，不能用
 * 块起点再减块时长）。stage 里是**变速后**的输出 PCM，故用 tempo_speed 换算
 * （speed=2 时 10ms 媒体只有 5ms 输出样本）。参数非法 / 无交叠 → 0。
 */
ARCHOERA_MEDIAENGINE_API size_t archoera_mediaengine_stage_drop_samples(
    size_t staged, int stage_ch, int rate, double old_ms, double origin_ms,
    double tempo_speed);

/**
 * commit 前的**覆盖性校验**：暂存源是否覆盖旧源解码游标 `old_ms`。
 *
 * 判定按**样本**进行（与 `stage_drop_samples` 同一取整）：`drop_frames =
 * llround((old_ms - origin_ms) * rate / 1000 / tempo_speed)`，要求
 * `0 <= drop_frames <= staged/ch`。不做毫秒级容差——旧 5ms 容差（@48k 约
 * 240 帧）会把「seek 晚到 4ms」当成可切换，拼接处丢一小段内容。返回 0 表示
 * 新源起点晚于游标（续接会跳播）或暂存不足覆盖游标（续接会回放/停滞）——
 * 此时调用方必须放弃切换、保留旧源，绝不能把新源从错误位置接进 ring。
 */
ARCHOERA_MEDIAENGINE_API int archoera_mediaengine_stage_covers(
    size_t staged, int stage_ch, int rate, double old_ms, double origin_ms,
    double tempo_speed);

/**
 * M3（docs/audio-memory-source.md §6.1/§6.2）：当前可用内存（MB），供 Dart
 * 预算管理器计算 auto ceiling / requiredCeiling。失败返回 -1（回落保守下限）。
 */
ARCHOERA_MEDIAENGINE_API long long archoera_mediaengine_mem_available_mb(void);

/**
 * 测试/诊断：当前活动解码源 URL/路径（prepare→commit 切档后为**新档位**源）。
 * 返回引擎内部字符串，生命周期到下次切档/销毁；未打开返回 NULL。
 * 只读；无锁（供测试在引擎线程退出后读取，勿在运行期跨线程并发读）。
 */
ARCHOERA_MEDIAENGINE_API const char *archoera_mediaengine_source(
    const ArchoeraMediaEngine *e);

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
