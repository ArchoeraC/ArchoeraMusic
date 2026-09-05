/**
 * player.h — 自写播放器模块（miniaudio，§10.8 替代 libmpv）
 *
 * 职责：引擎转码完成后加载 OGG 文件（MA_SOUND_FLAG_DECODE 全解码内存，
 * seek 即时）→ ma_engine 输出到系统音频设备（ALSA/PulseAudio/PipeWire/
 * WASAPI/CoreAudio，跨平台）。控制走 stdin JSON 命令（play/pause/seek/
 * set_volume/get_status），位置事件经 player_poll 周期推送。
 *
 * 线程模型：ma_engine 回调在设备线程；player_command/player_poll 由主线程
 * （stdin 命令循环）调用，ma_engine API 内部线程安全。
 */
#ifndef ARCHOERA_PLAYER_H
#define ARCHOERA_PLAYER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PlayerCtx PlayerCtx;

/** 引擎事件输出回调（json 行，含 '\0' 结束、无换行） */
typedef void (*player_event_fn)(const char *json_line, void *user_data);

/**
 * 播放输出 sink 候选（纯数据，供 player_sink_select 确定性选择，独立单测用）。
 * id/name 指向的生命周期必须覆盖整个 player_sink_select 调用期间。
 */
typedef struct {
    const char *id;         /* 后端原生 id（pulse sink 名 / alsa 设备名等） */
    const char *name;       /* 描述名（pulse description / alsa 友好名） */
    unsigned sample_rate;   /* nativeDataFormats[0].sampleRate（原生采样率） */
    unsigned channels;      /* nativeDataFormats[0].channels */
    int has_native;         /* native 格式已知（0=未知，按不合格处理） */
    int is_default;         /* 系统当前默认 playback 设备 */
} player_sink_candidate;

/**
 * 选择“优质”播放 sink（纯函数，无副作用，便于确定性单测）。
 * 规则（2026-09-05 修订：只尊重显式选择，绝不自动改道）：
 *   1) env_override 非空：返回第一个 id/name 含该子串（大小写不敏感）的候选，
 *      用户显式指定、不受质量门槛限制；未命中则继续后续规则并回填原因。
 *   2) 无 env 覆盖（或未命中）→ 一律用系统默认（返回 -1 = 不指定 device id）。
 *      默认设备低质量/单声道（如蓝牙 HFP 16k/1ch）时仅回填提示原因，不擅改。
 * @return >=0 选中候选下标；-1 用默认设备（不指定 device id）。
 */
int player_sink_select(const player_sink_candidate *p_candidates,
                       int candidate_count,
                       const char *env_override,
                       char *p_reason, size_t reason_cap);

/* 单条播放 sink 的完整自包含描述（id/name 内嵌拷贝，无需外部生命周期；
   供 list_sinks / 运行时 sink 切换等会话无关查询）。 */
#define PLAYER_SINK_ID_CAP 256

typedef struct {
    char id[PLAYER_SINK_ID_CAP];    /* 后端原生 id（pulse sink 名 / alsa 设备名） */
    char name[PLAYER_SINK_ID_CAP];  /* 描述名（pulse description / alsa 友好名） */
    unsigned sample_rate;           /* nativeDataFormats[0].sampleRate（0=未知） */
    unsigned channels;              /* nativeDataFormats[0].channels（0=未知） */
    int has_native;                 /* native 格式已知 */
    int is_default;                 /* 系统当前默认 playback 设备 */
} player_sink_info;

/**
 * 枚举全部播放 sink（含按设备取 native 格式）。
 * 会话无关：内部自建并拆除 pulse→alsa context（ma_context），不依赖任何 PlayerCtx。
 * @param out 输出数组（每项 id/name 自带缓冲）
 * @param cap 输出数组容量
 * @return >0 写入的条目数；无设备/失败返回 0 或负值。
 */
int player_list_sinks(player_sink_info *out, int cap);

/** 播放器创建选项（普通启动用默认；切 sink 平滑重启时由调用方填恢复参数）。 */
typedef struct {
    int    start_paused;  /* 1=创建后不自动播放（等待 seek/音量后再由调用方 play） */
    float  volume;        /* 初始音量（默认 1.0） */
    double seek_ms;       /* >0 时创建后、启动前先 seek 到该毫秒（无缝续播） */
    int    emit_playing;  /* 1=创建后推送 playing 事件（普通启动默认 1；重启静默用 0） */
} player_start_options;

#define PLAYER_START_OPTIONS_DEFAULT \
    ((player_start_options){0, 1.0f, 0.0, 1})

/**
 * 启动播放（带选项）：加载音频文件 →（emit_playing 时）输出 playing 事件 →
 * 应用 volume/seek → 按 start_paused 决定是否自动播放。
 *
 * @param ogg_path  待播放文件（WAV/OGG，miniaudio 内置解码）
 * @param sink_id   播放输出 sink 选择：
 *                    - NULL    ：沿用旧语义——读 env ARCHOERA_AUDIO_SINK，无则系统默认
 *                    - 非空串  ：显式选中该设备（pulse/alsa id 或描述名子串，忽略 env）
 *                    - 空串 "" ：回系统默认（忽略 env，等价用户显式确认“用默认”）
 *                  对选中设备 native 为单声道或 <44.1kHz（如蓝牙 HFP 16k/1ch）时，
 *                  自动按设备原生 rate/channels 开引擎设备（原生格式适配），使低质/
 *                  单声道设备也能满速出声；常规设备保持默认引擎路径（语义不变）。
 * @return NULL 表示失败（文件不可读 / 无音频设备 / sink init 失败）。
 */
PlayerCtx *player_start_opts(const char *ogg_path,
                                const char *sink_id,
                                const player_start_options *opts,
                                player_event_fn on_event,
                                void *user_data);

/** 兼容入口：opts 取默认；sink_id 语义同上（CLI 传 NULL 走 env）。 */
PlayerCtx *player_start(const char *ogg_path,
                        const char *sink_id,
                        player_event_fn on_event,
                        void *user_data);

/* ═══ 流式播放（边解码边出声，§B：raw 设备 + 线程安全环形缓冲）═══
 *
 * 替代「整段转码完成 → ma_engine 播 WAV 文件」的启动模型：媒体会话首块
 * pcm_out 出现即开设备出声，解码线程按设备消费节奏继续流式供给（环形缓冲
 * 满时 player_stream_write 阻塞 = 背压，解码自动近似实时）。
 *
 * 语义（与文件播放保持一致）：
 *   - 位置事件 = 已播放（设备已消费）内容时间（ms，自 open 的内容起点起算），
 *     由 player_poll 周期性推送；音量 = set_volume；play/pause/set_playing 同文件模式。
 *   - 结束：解码循环喂完最后一块后调 player_stream_end；缓冲残余播完自然结束
 *     （player_poll 返回 1 + player:ended 事件）。
 *   - seek：调用方停流（player_stream_pause_for_restart）+ 重建管线从目标偏移
 *     解码 + player_stream_seek_reset 归零播放游标后继续喂（“停/重来一致”）。 */

/** 打开流式播放输出（raw 设备 + 环形缓冲，含 sink 选择与原生格式适配）。
 * @param sink_id      与 player_start_opts 相同语义（NULL=env / 串 / 空串=默认）
 * @param content_rate/content_channels  管线 pcm_out 的内容格式（EQ/loud/…后）
 * @return NULL = 无音频设备/设备打开失败（调用方应继续转码但仅落盘，不出声）。
 */
PlayerCtx *player_stream_open(const char *sink_id,
                              const player_start_options *opts,
                              int content_rate, int content_channels,
                              player_event_fn on_event, void *user_data);

/** 喂一块解码后 PCM（content_rate/content_channels，与 open 一致；引擎线程）。
 * 环形缓冲满时阻塞直至有空间（解码按设备消费节奏推进）。
 * @return 0 成功；<0 未打开/参数错（调用方可忽略，仅转码落盘不出声）。 */
int player_stream_write(PlayerCtx *p, const float *pcm, int samples);

/** 标记解码流结束（最后一块喂完后调用）；缓冲残余播完即自然结束。 */
void player_stream_end(PlayerCtx *p);

/** 流设备已启动（ring 建立 / 首块喂入后）。0 = 流不可用（无声路径）。 */
int player_stream_active(const PlayerCtx *p);

/** 播放中切 sink（停旧设备、清缓冲、按解码点续播；失败返回 -1 原样保留）。 */
int player_stream_switch_sink(PlayerCtx *p, const char *sink_id);

/** seek/重开流前调用：停止设备并清空缓冲、播放游标归零（等待新解码喂入重启动）。 */
void player_stream_seek_reset(PlayerCtx *p);

/** 设置播放游标内容基（ms）：seek 重开后内容从新偏移起，位置 = base + 已消费。 */
void player_stream_set_pos_base(PlayerCtx *p, double base_ms);

/** 已播放（设备已消费）位置（ms，自 open/seek_reset 的内容起点起算）。 */
double player_stream_played_ms(const PlayerCtx *p);

/** 环形缓冲待播时长（ms，诊断）。 */
double player_stream_buffered_ms(const PlayerCtx *p);

/** 快照当前播放状态（播放中切 sink 时由引擎线程调用；同线程，无锁）。 */
void player_get_state(PlayerCtx *p, int *playing, double *pos_ms, float *volume);

/** 播放控制命令（type: play/pause/set_playing/seek/set_volume/get_status）。
 *  pos_ms/gain 仅在对应命令时使用（set_playing 用 gain!=0 表 playing）。 */
void player_command(PlayerCtx *p, const char *type,
                    const double *pos_ms, const double *gain);

/** 设置位置事件推送间隔（ms，降频协商）。<20ms 时钳制为 20ms。 */
void player_set_position_interval(PlayerCtx *p, int interval_ms);

/** 播放循环节拍：按音频位置周期推送 position 事件；播放自然结束返回 1。 */
int player_poll(PlayerCtx *p);

/** 停止并释放（停止播放 + 卸载 engine）。 */
void player_stop(PlayerCtx *p);

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERA_PLAYER_H */
