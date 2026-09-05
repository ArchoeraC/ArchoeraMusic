/**
 * player.c — 自写播放器实现（miniaudio，替代 libmpv/media_kit，§10.8）
 *
 * miniaudio v0.11.25（MIT-0/公有领域双许可）单头文件实现：
 *   - MA_SOUND_FLAG_DECODE：OGG 全解码到内存（本地完整转码文件几~几十 MB，
 *     seek 即时跳转，无重解码）
 *   - 输出设备：ALSA/PulseAudio/PipeWire（Linux）、WASAPI（Windows）、
 *     CoreAudio（macOS），跨平台零系统依赖
 * 位置事件按音频位置驱动（每 50ms 音频 1 帧，对齐 FFT 拉模式 50ms 轮询：
 * 若保持 100ms，Dart _pollSpectrum 两次读到同一 position，FFT 窗口实际
 * 每 100ms 才前进一次（10Hz），节拍检测命中率会掉 ~40%（实测 127→74/min）。
 */
#define _POSIX_C_SOURCE 200809L

#include "player.h"

#include "resampler.h"
#include <libavutil/samplefmt.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdatomic.h>

/* 单头文件实现仅编译一次（player.c 内） */
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

/* 位置事件推送间隔默认值（音频秒）：50ms 对齐 FFT 拉模式轮询（20Hz 分析）。
   运行期经 player_set_position_interval 可动态调整（降频协商，见
   engine-event-push-plan：normal 50ms / minimized 500ms / unfocused 1000ms） */
#define POSITION_INTERVAL_MS 50

struct PlayerCtx {
    ma_engine engine;
    ma_sound sound;
    int has_sound;
    int playing;
    double duration_ms;
    ma_uint64 sample_rate;
    /* “优质”sink 选择：自建 context（engine 不拥有），engine 生命周期内有效 */
    ma_context context;
    int context_initialized;
    ma_device_id device_id;   /* 选中 sink 的 id（决定用默认时忽略） */
    /* 位置事件间隔（ms，运行期可调，替代编译期常量） */
    int position_interval_ms;
    ma_uint64 last_pos_frame;
    int ended_reported;
    int poll_count;
    /* seek 保护窗口：seek 后游标可能滞后/短暂回退（音频线程未同步），
       pending 期间不推送位置事件，避免旧游标值把 UI 刷回原进度 */
    int seek_pending;
    ma_uint64 seek_target_frame;
    int seek_poll_count;
    player_event_fn on_event;
    void *user_data;

    /* ── 流式播放（raw 设备 + 环形缓冲，§B）──────────────────── */
    int stream_mode;            /* 1 = 流式（非文件播放） */
    ma_device stream_device;    /* raw 输出设备 */
    int stream_dev_inited;      /* ma_device 已 init */
    int stream_dev_started;     /* ma_device 已 start */
    int stream_active;          /* 有喂入过 PCM（首包后为 1，供 playing 事件判定） */
    unsigned stream_dev_rate;   /* 设备采样率（原生适配/原生 sink） */
    unsigned stream_dev_ch;     /* 设备声道数 */
    unsigned stream_feed_rate;  /* 喂入内容采样率 */
    unsigned stream_feed_ch;    /* 喂入内容声道数 */
    unsigned stream_volume_bits; /* 音量（float 位模式，设备回调无锁读） */
    /* 线程安全环形缓冲（SPSC）：生产者=引擎线程，消费者=设备音频回调 */
    float *ring;                /* 容量 ring_cap*stream_dev_ch 个 float */
    size_t ring_cap;            /* 帧容量（2 的幂） */
    _Atomic size_t ring_w;      /* 写帧计数（生产者独占写） */
    _Atomic size_t ring_r;      /* 读帧计数（设备回调独占写） */
    _Atomic int  stream_eof;    /* 解码流已结束（喂完最后一块） */
    _Atomic int  stream_stop;   /* 设备回调置位：EOF 且缓冲空 → 请求停止 */
    _Atomic unsigned stream_underrun; /* 统计（诊断） */
    /* 播放位置游标：已消费内容时间基（ms）+ 设备已消费帧（非流式文件模式不用） */
    double stream_pos_base_ms;
    ma_uint64 stream_consumed_frames; /* 累计设备消费帧数（本设备） */
    /* 流式诊断日志（ARCHOERA_DEBUG_STREAM=1，回调零开销时禁用） */
    int stream_debug;
    /* feed→设备 重采样（源率/声道 ≠ 设备原生时；0/0 直通则 NULL） */
    Resampler *stream_swr;
    float *stream_conv_buf;     /* 重采样输出缓冲 */
    int     stream_conv_cap_frames;
    double  stream_dev_ratio;   /* 内容秒 → 设备帧 换算 = dev_rate/feed_rate */
};

/* 播放自然结束回调（设备线程） */
static void on_sound_end(void *p_user_data, ma_sound *p_sound)
{
    (void)p_sound;
    PlayerCtx *p = (PlayerCtx *)p_user_data;
    if (!p) return;
    p->playing = 0;
    p->ended_reported = 1;
}

/* ── “优质” sink 选择 ──────────────────────────────────────────────
 * 动机：PipeWire/pulse 默认 sink 若是蓝牙 HFP（s16le 1ch 16kHz，HSP/HFP 通话
 * profile），miniaudio ma_device 可 init/start 但 data callback 饥饿（静音/
 * 卡顿）；切到内置模拟立体声（48k/2ch）满速。媒体引擎播放前先挑一个
 * native 采样率>=44100 且声道>=2 的 sink，只有全不合格才回退默认，避免无声。
 */

/* “合格”门槛：与旧 ma_engine 全速实证一致（内置 48k/2ch 满速；HFP 16k/1ch 饥饿） */
#define PLAYER_SINK_MIN_RATE     44100u
#define PLAYER_SINK_MIN_CHANNELS 2u

static ma_bool32 arch_str_contains_ci(const char *haystack, const char *needle);

/* 纯选择器（公开以便确定性单测；实现见 player.h 注释） */
int player_sink_select(const player_sink_candidate *p_candidates,
                       int candidate_count,
                       const char *env_override,
                       char *p_reason, size_t reason_cap)
{
    int i;
    int default_idx = -1;

    if (p_reason && reason_cap > 0) p_reason[0] = '\0';

    if (p_candidates == NULL || candidate_count <= 0) {
        if (p_reason) snprintf(p_reason, reason_cap, "无候选，回退默认");
        return -1;
    }

    for (i = 0; i < candidate_count; ++i) {
        if (p_candidates[i].is_default) { default_idx = i; break; }
    }

    /* 策略（2026-09-05 修订）：尊重用户选择，不自动改道。
       用户可能不期望外放、也可能就是要外放——引擎只按“显式指定”或
       “系统默认”路由，绝不悄悄把输出换到别的 sink。
       1) env 显式覆盖：id/name 子串命中即选（大小写不敏感），不受质量限制；
       2) 否则一律用系统默认（返回 -1 = 不指定 device id）。
       若默认设备是低质量/单声道（如蓝牙 HFP 16k/1ch），仅给提示，不擅改。 */
    if (env_override != NULL && env_override[0] != '\0') {
        for (i = 0; i < candidate_count; ++i) {
            if ((p_candidates[i].id &&
                 arch_str_contains_ci(p_candidates[i].id, env_override)) ||
                (p_candidates[i].name &&
                 arch_str_contains_ci(p_candidates[i].name, env_override))) {
                if (p_reason) snprintf(p_reason, reason_cap,
                    "env 指定命中: %s", p_candidates[i].name);
                return i;
            }
        }
        if (p_reason) snprintf(p_reason, reason_cap,
            "env 未命中（%.48s），用系统默认", env_override);
        return -1;
    }

    if (default_idx >= 0) {
        const player_sink_candidate *d = &p_candidates[default_idx];
        if (d->has_native && (d->sample_rate < PLAYER_SINK_MIN_RATE ||
                              d->channels < PLAYER_SINK_MIN_CHANNELS)) {
            if (p_reason) snprintf(p_reason, reason_cap,
                "默认 %s (%uhz/%uch 低质量/单声道，如蓝牙 HFP)——尊重所选，不自动切换；"
                "如需高质量输出请把系统默认切到 A2DP/其它设备或用 ARCHOERA_AUDIO_SINK 指定",
                d->name, d->sample_rate, d->channels);
        } else {
            if (p_reason) snprintf(p_reason, reason_cap,
                "用系统默认: %s", d->name);
        }
        return -1;
    }

    if (p_reason) snprintf(p_reason, reason_cap, "无默认候选，用系统默认");
    return -1;
}

/* arch_ 前缀工具（避开 miniaudio 实现内部大量 ma_/ma__ 静态命名空间） */

/* 大小写不敏感子串查找（只处理 ASCII，设备名均为 ASCII 居多；中文名经 UTF-8
   逐字节小写仍可比较，母串与子串同编码时行为正确） */
static ma_bool32 arch_str_contains_ci(const char *haystack, const char *needle)
{
    size_t hn, nn, i, j;

    if (haystack == NULL || needle == NULL || needle[0] == '\0') {
        return (needle != NULL && needle[0] == '\0') ? MA_TRUE : MA_FALSE;
    }
    hn = strlen(haystack);
    nn = strlen(needle);
    if (nn > hn) return MA_FALSE;

    for (i = 0; i + nn <= hn; ++i) {
        for (j = 0; j < nn; ++j) {
            char hc = haystack[i + j], nc = needle[j];
            if (hc >= 'A' && hc <= 'Z') hc = (char)(hc - 'A' + 'a');
            if (nc >= 'A' && nc <= 'Z') nc = (char)(nc - 'A' + 'a');
            if (hc != nc) break;
        }
        if (j == nn) return MA_TRUE;
    }
    return MA_FALSE;
}

/* player_probe_entry：枚举得 id/name/isDefault（pulse/alsa 枚举不带 native
   格式），再逐个 ma_context_get_device_info 取原生 sampleRate/channels。 */
typedef struct {
    player_sink_candidate c;
    ma_device_id dev_id;                /* 完整设备 id（按选中整拷给 engine） */
    char id_buf[MA_MAX_DEVICE_NAME_LENGTH + 1];
    char name_buf[MA_MAX_DEVICE_NAME_LENGTH + 1];
} player_probe_entry;

static const char *arch_device_id_str(const ma_context *pCtx, const ma_device_id *pId,
                                     char *pOut, size_t outCap)
{
    if (pId == NULL) { if (outCap) pOut[0] = '\0'; return pOut; }
    switch (pCtx->backend) {
    case ma_backend_pulseaudio:
        ma_strncpy_s(pOut, outCap, pId->pulse, (size_t)-1); break;
    case ma_backend_alsa:
        ma_strncpy_s(pOut, outCap, pId->alsa, (size_t)-1); break;
    default:
        /* 非 pulse/alsa 后端不做显式选择（回到默认设备语义） */
        if (outCap) {
            pOut[0] = '\0';
        }
        break;
    }
    return pOut;
}

/* 采集候选列表：返回堆上数组（calloc），*p_count 个数；失败返回 NULL。
   返回数组需 player_probe_free 释放。 */
static player_probe_entry *player_probe_collect(ma_context *pCtx, int *p_count)
{
    ma_result r;
    ma_device_info *pPlay = NULL, *pCap = NULL;
    ma_uint32 nPlay = 0, nCap = 0;
    player_probe_entry *out;
    ma_uint32 i;

    if (p_count) *p_count = 0;
    if (pCtx == NULL) return NULL;

    r = ma_context_get_devices(pCtx, &pPlay, &nPlay, &pCap, &nCap);
    if (r != MA_SUCCESS || nPlay == 0 || pPlay == NULL) {
        return NULL;
    }

    out = (player_probe_entry *)calloc(nPlay, sizeof(*out));
    if (!out) return NULL;

    for (i = 0; i < nPlay; ++i) {
        player_probe_entry *e = &out[i];
        ma_device_info di;

        e->c.id   = e->id_buf;
        e->c.name = e->name_buf;
        e->dev_id = pPlay[i].id;
        arch_device_id_str(pCtx, &pPlay[i].id, e->id_buf, sizeof(e->id_buf));
        ma_strncpy_s(e->name_buf, sizeof(e->name_buf), pPlay[i].name, (size_t)-1);
        e->c.is_default = pPlay[i].isDefault ? 1 : 0;
        e->c.sample_rate = 0;
        e->c.channels = 0;
        e->c.has_native = 0;

        /* native 格式：get_device_info 逐个查（pulse 填 sink sample_spec 等） */
        MA_ZERO_OBJECT(&di);
        if (ma_context_get_device_info(pCtx, ma_device_type_playback,
                                       &pPlay[i].id, &di) == MA_SUCCESS &&
            di.nativeDataFormatCount > 0) {
            e->c.sample_rate = di.nativeDataFormats[0].sampleRate;
            e->c.channels    = di.nativeDataFormats[0].channels;
            e->c.has_native  = 1;
        }
    }
    if (p_count) *p_count = (int)nPlay;
    return out;
}

static void player_probe_free(player_probe_entry *p)
{
    if (p) { free(p); }
}

/* 初始化一个可供 ma_engine 自建设备使用的 context（优先 pulse，其次 alsa，
   与 miniaudio 默认 Linux 后端优先级一致）。成功返回 0，失败返回 -1。 */
static int player_context_open(ma_context *pCtx)
{
    static const ma_backend backends[] = { ma_backend_pulseaudio, ma_backend_alsa };
    ma_result r = ma_context_init(backends, 2, NULL, pCtx);
    if (r != MA_SUCCESS) return -1;
    return 0;
}

/* ── 会话无关 sink 枚举导出（Dart 侧 archoera_mediaengine_list_sinks 复用）── */

int player_list_sinks(player_sink_info *out, int cap)
{
    ma_context ctx;
    int n = 0;
    int i;
    player_probe_entry *probes;

    if (!out || cap <= 0) return -1;
    if (player_context_open(&ctx) != 0) return -1;

    probes = player_probe_collect(&ctx, &n);
    if (probes == NULL || n <= 0) {
        if (probes) player_probe_free(probes);
        ma_context_uninit(&ctx);
        return 0;
    }
    for (i = 0; i < n && i < cap; ++i) {
        player_sink_info *dst = &out[i];
        dst->sample_rate = probes[i].c.sample_rate;
        dst->channels    = probes[i].c.channels;
        dst->has_native  = probes[i].c.has_native;
        dst->is_default  = probes[i].c.is_default;
        ma_strncpy_s(dst->id, sizeof(dst->id), probes[i].c.id, (size_t)-1);
        ma_strncpy_s(dst->name, sizeof(dst->name),
                     probes[i].c.name, (size_t)-1);
    }
    player_probe_free(probes);
    ma_context_uninit(&ctx);
    return (n < cap) ? n : cap;
}

PlayerCtx *player_start_opts(const char *ogg_path,
                                const char *sink_id,
                                const player_start_options *opts,
                                player_event_fn on_event,
                                void *user_data)
{
    ma_result r;
    PlayerCtx *p;
    player_start_options st_opts =
        opts ? *opts : PLAYER_START_OPTIONS_DEFAULT;
    const char *env_override;
    int ctx_inited = 0;
    int sel_idx = -1;
    char reason[192];
    char sink_name[MA_MAX_DEVICE_NAME_LENGTH + 1];
    char sink_dev[MA_MAX_DEVICE_NAME_LENGTH + 1];
    unsigned sink_rate = 0, sink_ch = 0;
    int sink_native_known = 0;
    int native_adapt = 0;
    ma_uint32 eng_rate = 0, eng_ch = 0;

    if (!ogg_path) return NULL;

    p = (PlayerCtx *)calloc(1, sizeof(PlayerCtx));
    if (!p) return NULL;
    p->on_event = on_event;
    p->user_data = user_data;
    p->position_interval_ms = POSITION_INTERVAL_MS;

    /* ── 输出 sink 选择 + ma_engine 初始化 ───────────────────────────
       2026-09-05：只尊重显式选择（env / 本函数 sink_id 参数），绝不自动改道。
       若落到蓝牙 HFP 等 low/native 设备（16k/1ch），ma_engine 若以 48k/2ch 打开
       会 data callback 饥饿（静音/卡）；本函数检测目标设备 native 为单声道或
       <44.1kHz 时，把引擎设备按设备原生 rate/channels 打开（原生格式适配），
       使所选设备满速出声；常规设备保持引擎默认路径（语义不变）。 */
    if (sink_id != NULL) {
        /* mediaengine 会话路径：sink_id 权威（空串 = 系统默认、忽略 env） */
        env_override = (sink_id[0] != '\0') ? sink_id : NULL;
    } else {
        /* CLI 兼容路径：无显式传参时沿用 env ARCHOERA_AUDIO_SINK */
        env_override = getenv("ARCHOERA_AUDIO_SINK");
        if (env_override && env_override[0] == '\0') env_override = NULL;
    }

    snprintf(reason, sizeof(reason), "默认路径（无自建 context）");
    sink_name[0] = '\0';
    sink_dev[0] = '\0';

    if (player_context_open(&p->context) == 0) {
        ctx_inited = 1;
        int n = 0;
        int default_idx = -1;
        player_probe_entry *probes = player_probe_collect(&p->context, &n);
        if (probes != NULL && n > 0) {
            /* player_sink_select 需要连续数组（stride=sizeof(candidate)），
               这里做浅拷贝：c.id/c.name 仍指向各自 probe 内的缓冲，
               选择期间 probes 保持存活 */
            player_sink_candidate *cands =
                (player_sink_candidate *)calloc((size_t)n, sizeof(*cands));
            if (cands != NULL) {
                int i;
                for (i = 0; i < n; ++i) {
                    cands[i] = probes[i].c;
                    if (cands[i].is_default && default_idx < 0) default_idx = i;
                }
                sel_idx = player_sink_select(cands, n, env_override,
                                             reason, sizeof(reason));
                free(cands);
            } else {
                snprintf(reason, sizeof(reason), "候选拷贝失败，用默认");
            }

            /* 定位“本会话目标”sink（显式选中者；否则系统默认项）用于
               打日志 + 原生格式适配判定。默认项取自枚举里的 is_default
               （比 ma_context_get_device_info(NULL) 更可靠——后者会返回
               context 级默认采样规格而非低质默认 sink 的真实 native）。 */
            int target_idx = sel_idx;
            if (target_idx < 0) target_idx = default_idx;

            if (sel_idx >= 0) {
                /* 显式选中某个 sink → engine device id 指向它 */
                p->device_id = probes[sel_idx].dev_id;
            }
            if (target_idx >= 0) {
                player_probe_entry *t = &probes[target_idx];
                ma_strncpy_s(sink_name, sizeof(sink_name),
                             t->c.name, (size_t)-1);
                ma_strncpy_s(sink_dev, sizeof(sink_dev),
                             t->c.id, (size_t)-1);
                sink_rate = t->c.sample_rate;
                sink_ch   = t->c.channels;
                sink_native_known = t->c.has_native;
            } else if (sel_idx >= 0) {
                /* 枚举中没有默认项但选中了某 sink（极端）：仅用其 id/name */
                ma_strncpy_s(sink_name, sizeof(sink_name),
                             probes[sel_idx].c.name, (size_t)-1);
                ma_strncpy_s(sink_dev, sizeof(sink_dev),
                             probes[sel_idx].c.id, (size_t)-1);
                sink_rate = probes[sel_idx].c.sample_rate;
                sink_ch   = probes[sel_idx].c.channels;
                sink_native_known = probes[sel_idx].c.has_native;
            }
        } else {
            if (probes) player_probe_free(probes);
            probes = NULL;
            snprintf(reason, sizeof(reason), "枚举无候选，用默认");
        }
        if (probes) player_probe_free(probes);
    } else {
        fprintf(stderr, "[player] 自建 pulse/alsa context 失败，回退默认 context\n");
    }

    /* ── 原生格式适配判定 ────────────────────────────────────────
       目标设备 native 单声道或 <44.1kHz（如蓝牙 HFP 16k/1ch s16）时，
       按设备原生 rate/channels 打开 ma_engine 设备（format 仍 f32，采样率/
       声道由 pulse/pipewire 服务端与 sink 原生的 s16 间转换——实测满速）。
       常规设备（>=44.1k && >=2ch）与 native 未知设备保持默认（0/0 自动）。 */
    if (sink_native_known &&
        (sink_ch < PLAYER_SINK_MIN_CHANNELS ||
         sink_rate < PLAYER_SINK_MIN_RATE)) {
        native_adapt = 1;
        eng_rate = sink_rate;
        eng_ch   = sink_ch;
    }

    {
        ma_engine_config econfig = ma_engine_config_init();
        if (ctx_inited) {
            econfig.pContext = &p->context;
            if (sel_idx >= 0) econfig.pPlaybackDeviceID = &p->device_id;
        }
        if (native_adapt && eng_rate > 0 && eng_ch > 0) {
            econfig.sampleRate = eng_rate;
            econfig.channels   = eng_ch;
        }
        r = ma_engine_init(&econfig, &p->engine);
        if (r != MA_SUCCESS && ctx_inited) {
            /* 选中 sink 已消失 / 绑定 context 的引擎 init 失败 → 重试默认路径 */
            fprintf(stderr,
                "[player] 自建 context + 选中 sink 的 engine init 失败 %d，"
                "回退默认设备\n", (int)r);
            ma_engine_config fcfg = ma_engine_config_init();
            r = ma_engine_init(&fcfg, &p->engine);
        }
        p->context_initialized = (r == MA_SUCCESS && ctx_inited) ? 1 : 0;
        if (r != MA_SUCCESS) {
            fprintf(stderr, "[player] ma_engine_init 失败: %d\n", (int)r);
            if (ctx_inited) ma_context_uninit(&p->context);
            free(p);
            return NULL;
        }
        if (ctx_inited && !p->context_initialized) {
            /* engine 走了默认 context，自建 context 已无用 */
            ma_context_uninit(&p->context);
        }
    }

    {
        ma_backend used_backend = ma_backend_null;
        const char *backend_name = "<unknown>";
        ma_uint32 dev_rate = 0;
        ma_uint32 dev_ch = 0;
        if (p->engine.pDevice != NULL && p->engine.pDevice->pContext != NULL) {
            used_backend = p->engine.pDevice->pContext->backend;
            backend_name = ma_get_backend_name(used_backend);
            dev_rate = p->engine.pDevice->sampleRate;
            dev_ch   = p->engine.pDevice->playback.channels;
        }
        fprintf(stderr,
            "[player] sink=%s(%s) backend=%s native=%uhz/%uch "
            "native_adapt=%d engine_dev=%uhz/%uch reason=%s\n",
            (sink_name[0] ? sink_name : "<default>"),
            (sink_dev[0] ? sink_dev : "<default>"),
            backend_name, sink_rate, sink_ch, native_adapt,
            dev_rate, dev_ch, reason);
    }

    /* 全解码模式：seek 即时；无需实时解码线程 */
    r = ma_sound_init_from_file(&p->engine, ogg_path,
                                MA_SOUND_FLAG_DECODE, NULL, NULL, &p->sound);
    if (r != MA_SUCCESS) {
        fprintf(stderr, "[player] 加载 %s 失败: %d\n", ogg_path, (int)r);
        ma_engine_uninit(&p->engine);
        free(p);
        return NULL;
    }
    p->has_sound = 1;
    ma_sound_set_end_callback(&p->sound, on_sound_end, p);

    ma_format fmt;
    ma_uint32 channels = 0;
    ma_uint32 sample_rate = 0;
    if (ma_sound_get_data_format(&p->sound, &fmt, &channels, &sample_rate,
                                 NULL, 0) == MA_SUCCESS) {
        p->sample_rate = sample_rate;
    }
    ma_uint64 len_frames = 0;
    if (p->sample_rate > 0 &&
        ma_sound_get_length_in_pcm_frames(&p->sound, &len_frames) == MA_SUCCESS) {
        p->duration_ms = (double)len_frames * 1000.0 / (double)p->sample_rate;
    }

    /* 播放器创建参数：音量/初始位置在启动前应用（无缝续播不闪头不跳音）。 */
    if (p->has_sound) {
        ma_sound_set_volume(&p->sound, st_opts.volume);
        if (st_opts.seek_ms > 0 && p->sample_rate > 0) {
            ma_uint64 frame =
                (ma_uint64)(st_opts.seek_ms / 1000.0 *
                            (double)p->sample_rate);
            if (frame >= len_frames && len_frames > 0) {
                frame = (len_frames > 0) ? len_frames - 1 : 0;
            }
            ma_sound_seek_to_pcm_frame(&p->sound, frame);
            p->last_pos_frame = frame;
        }
    }

    /* playing 事件：完整时长就绪，Flutter 回填 + 开始显示播放状态。
       （切 sink 平滑重启时 emit_playing=0 静默，Dart 无需重复收到 playing） */
    if (st_opts.emit_playing && p->on_event) {
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "{\"type\":\"playing\",\"duration_ms\":%.0f}", p->duration_ms);
        p->on_event(buf, p->user_data);
    }

    if (!st_opts.start_paused) {
        ma_sound_start(&p->sound);
        p->playing = 1;
    } else {
        p->playing = 0;
    }
    return p;
}

PlayerCtx *player_start(const char *ogg_path,
                        const char *sink_id,
                        player_event_fn on_event,
                        void *user_data)
{
    return player_start_opts(ogg_path, sink_id, NULL, on_event, user_data);
}

/* ═══════════════════ 流式播放（raw 设备 + 环形缓冲）═══════════════════
 *
 * 与文件播放（ma_engine/ma_sound 全解码文件）平行的一套“流”路径：
 *   引擎线程（pcm_out 回调）喂 float PCM → 环形缓冲 → ma_device 数据回调
 *   按设备节奏消费。ring 满时 producer 阻塞 = 背压 → 解码自动 ≈ 实时。
 * 线程模型：ring_w 由引擎线程独占写、ring_r 由设备音频线程独占写，其余仅读
 * （release/acquire 保证数据可见性）；无锁、音频回调零阻塞（绝不 malloc/lock）。
 */

/* 环形缓冲容量（秒，2s：解码提前量 = 缓冲上限，消费为实时） */
#define STREAM_RING_SECONDS 2.0f

static float stream_volume_get(const PlayerCtx *p)
{
    float v;
    memcpy(&v, &p->stream_volume_bits, sizeof(v));
    return v;
}

static void stream_volume_set(PlayerCtx *p, float v)
{
    memcpy(&p->stream_volume_bits, &v, sizeof(v));
}

/* 设备数据回调（音频线程）：从 ring 取 frameCount 帧到输出，不足补零静音 */
static void stream_data_cb(ma_device *pDevice, void *pOutput, const void *pInput,
                           ma_uint32 frameCount)
{
    (void)pInput;
    PlayerCtx *p = (PlayerCtx *)pDevice->pUserData;
    if (!p || !pOutput) return;
    float *dst = (float *)pOutput;
    ma_uint32 ch = p->stream_dev_ch;
    const size_t cap = p->ring_cap;
    const size_t w = atomic_load_explicit(&p->ring_w, memory_order_acquire);
    const size_t r = atomic_load_explicit(&p->ring_r, memory_order_relaxed);
    const size_t avail = w - r;
    const size_t n = (avail < (size_t)frameCount) ? avail : (size_t)frameCount;
    const size_t mask = cap - 1;

    if (n > 0) {
        const size_t start = r & mask;
        const size_t first = (cap - start) < n ? (cap - start) : n;
        memcpy(dst, &p->ring[start * ch], first * ch * sizeof(float));
        if (first < n) {
            memcpy(dst + first * ch, &p->ring[0], (n - first) * ch * sizeof(float));
        }
    }
    if (n < (size_t)frameCount) {
        memset(dst + n * ch, 0, ((size_t)frameCount - n) * ch * sizeof(float));
        atomic_fetch_add_explicit(&p->stream_underrun,
                                  (unsigned)(frameCount - n),
                                  memory_order_relaxed);
    }
    float vol = stream_volume_get(p);
    if (vol != 1.0f) {
        for (ma_uint32 i = 0; i < frameCount * ch; i++) dst[i] *= vol;
    }
    atomic_store_explicit(&p->ring_r, r + n, memory_order_release);

    /* EOF 且缓冲耗尽：请求停止（由 player_poll 停设备并发 ended） */
    if (n == 0 &&
        atomic_load_explicit(&p->stream_eof, memory_order_acquire)) {
        atomic_store_explicit(&p->stream_stop, 1, memory_order_release);
        if (p->stream_debug) {
            fprintf(stderr, "[stream-dbg] cb set stop (frameCount=%u)\n",
                    frameCount);
        }
    }
}

/* 从底层 ma_device 停止设备（在音频回调线程之外调用） */
static void stream_device_stop(PlayerCtx *p)
{
    if (!p->stream_dev_inited || !p->stream_dev_started) return;
    ma_device_stop(&p->stream_device);
    p->stream_dev_started = 0;
}

static void stream_device_start(PlayerCtx *p)
{
    if (!p->stream_dev_inited || p->stream_dev_started) return;
    if (ma_device_start(&p->stream_device) == MA_SUCCESS) {
        p->stream_dev_started = 1;
    }
}

static void stream_free_ring(PlayerCtx *p)
{
    if (p->ring) { free(p->ring); p->ring = NULL; }
    p->ring_cap = 0;
    if (p->stream_swr) { resampler_destroy(p->stream_swr); p->stream_swr = NULL; }
    if (p->stream_conv_buf) { free(p->stream_conv_buf); p->stream_conv_buf = NULL; }
    p->stream_conv_cap_frames = 0;
}

/* 幂等释放流设备资源（device/ring/swr）；不释放 p（含 context）。 */
static void stream_teardown(PlayerCtx *p)
{
    if (!p) return;
    stream_device_stop(p);
    if (p->stream_dev_inited) {
        ma_device_uninit(&p->stream_device);
        p->stream_dev_inited = 0;
    }
    p->stream_dev_started = 0;
    stream_free_ring(p);
    p->stream_active = 0;
    atomic_store_explicit(&p->stream_eof, 0, memory_order_release);
    atomic_store_explicit(&p->stream_stop, 0, memory_order_release);
    atomic_store_explicit(&p->stream_underrun, 0, memory_order_relaxed);
    atomic_store_explicit(&p->ring_w, 0, memory_order_relaxed);
    atomic_store_explicit(&p->ring_r, 0, memory_order_relaxed);
}

PlayerCtx *player_stream_open(const char *sink_id,
                              const player_start_options *opts,
                              int content_rate, int content_channels,
                              player_event_fn on_event, void *user_data)
{
    ma_result r;
    PlayerCtx *p;
    player_start_options st_opts =
        opts ? *opts : PLAYER_START_OPTIONS_DEFAULT;
    const char *env_override;
    int ctx_inited = 0;
    int sel_idx = -1;
    char reason[192];
    char sink_name[MA_MAX_DEVICE_NAME_LENGTH + 1];
    unsigned sink_rate = 0, sink_ch = 0;
    int sink_native_known = 0;
    int native_adapt = 0;
    unsigned dev_rate, dev_ch;
    size_t cap_frames, cap_pow2;
    int i;

    if (!content_rate || content_channels <= 0) return NULL;

    p = (PlayerCtx *)calloc(1, sizeof(PlayerCtx));
    if (!p) return NULL;
    p->stream_mode = 1;
    p->on_event = on_event;
    p->user_data = user_data;
    p->position_interval_ms = POSITION_INTERVAL_MS;
    p->stream_feed_rate = (unsigned)content_rate;
    p->stream_feed_ch = (unsigned)content_channels;
    p->stream_debug = (getenv("ARCHOERA_DEBUG_STREAM") != NULL);
    stream_volume_set(p, st_opts.volume);
    p->playing = st_opts.start_paused ? 0 : 1;

    /* ── sink 选择（与 player_start_opts 同语义）────────────────── */
    if (sink_id != NULL) {
        env_override = (sink_id[0] != '\0') ? sink_id : NULL;
    } else {
        env_override = getenv("ARCHOERA_AUDIO_SINK");
        if (env_override && env_override[0] == '\0') env_override = NULL;
    }
    sink_name[0] = '\0';
    snprintf(reason, sizeof(reason), "默认路径（无自建 context）");

    if (player_context_open(&p->context) == 0) {
        ctx_inited = 1;
        int n = 0;
        int default_idx = -1;
        player_probe_entry *probes = player_probe_collect(&p->context, &n);
        if (probes != NULL && n > 0) {
            player_sink_candidate *cands =
                (player_sink_candidate *)calloc((size_t)n, sizeof(*cands));
            if (cands != NULL) {
                for (i = 0; i < n; ++i) {
                    cands[i] = probes[i].c;
                    if (cands[i].is_default && default_idx < 0) default_idx = i;
                }
                sel_idx = player_sink_select(cands, n, env_override,
                                             reason, sizeof(reason));
                free(cands);
            } else {
                snprintf(reason, sizeof(reason), "候选拷贝失败，用默认");
            }
            int target_idx = (sel_idx >= 0) ? sel_idx : default_idx;
            if (sel_idx >= 0) {
                p->device_id = probes[sel_idx].dev_id;
            }
            if (target_idx >= 0) {
                player_probe_entry *t = &probes[target_idx];
                ma_strncpy_s(sink_name, sizeof(sink_name), t->c.name, (size_t)-1);
                sink_rate = t->c.sample_rate;
                sink_ch   = t->c.channels;
                sink_native_known = t->c.has_native;
            }
        } else {
            if (probes) player_probe_free(probes);
            probes = NULL;
            snprintf(reason, sizeof(reason), "枚举无候选，用默认");
        }
        if (probes) player_probe_free(probes);
    } else {
        ctx_inited = 0;
    }

    /* ── 设备格式：低质/单声道 sink（HFP 等）按原生 rate/ch 打开并由
     *   feed→设备 swr 转换；常规 sink 按其原生格式（Pulse 服务端再 SRC）；
     *   native 未知 → 跟随内容格式。 */
    if (sink_native_known &&
        (sink_ch < PLAYER_SINK_MIN_CHANNELS ||
         sink_rate < PLAYER_SINK_MIN_RATE)) {
        native_adapt = 1;
    }
    if (native_adapt && sink_rate > 0 && sink_ch > 0) {
        dev_rate = sink_rate;
        dev_ch   = sink_ch;
    } else if (sink_native_known && sink_rate > 0 && sink_ch > 0) {
        dev_rate = sink_rate;
        dev_ch   = sink_ch;
    } else {
        dev_rate = (unsigned)content_rate;
        dev_ch   = (unsigned)(content_channels > 2 ? 2 : content_channels);
    }
    if (dev_ch < 1) dev_ch = 1;
    if (dev_ch > 2) dev_ch = 2;
    p->stream_dev_rate = dev_rate;
    p->stream_dev_ch   = dev_ch;
    p->stream_dev_ratio = (double)dev_rate / (double)content_rate;

    /* ── 环形缓冲（2s 容量，2 的幂）──────────────────────────── */
    cap_frames = (size_t)((double)dev_rate * STREAM_RING_SECONDS);
    cap_pow2 = 1;
    while (cap_pow2 < cap_frames) cap_pow2 <<= 1;
    p->ring_cap = cap_pow2;
    p->ring = (float *)malloc(cap_pow2 * dev_ch * sizeof(float));
    if (!p->ring) {
        if (ctx_inited) ma_context_uninit(&p->context);
        free(p);
        return NULL;
    }
    atomic_init(&p->ring_w, 0);
    atomic_init(&p->ring_r, 0);
    atomic_init(&p->stream_eof, 0);
    atomic_init(&p->stream_stop, 0);
    atomic_init(&p->stream_underrun, 0);

    /* ── feed→设备 重采样（swr；格式相同则 NULL 直通）────────── */
    if (dev_rate != (unsigned)content_rate || dev_ch != (unsigned)content_channels) {
        p->stream_swr = resampler_create(content_rate, content_channels,
                                          AV_SAMPLE_FMT_FLT,
                                          (int)dev_rate, (int)dev_ch);
        if (!p->stream_swr) {
            stream_free_ring(p);
            if (ctx_inited) ma_context_uninit(&p->context);
            free(p);
            return NULL;
        }
    }

    /* ── raw 设备 ─────────────────────────────────────────────── */
    {
        ma_device_config dcfg = ma_device_config_init(ma_device_type_playback);
        dcfg.playback.format   = ma_format_f32;
        dcfg.playback.channels = dev_ch;
        dcfg.sampleRate        = dev_rate;
        dcfg.dataCallback      = stream_data_cb;
        dcfg.pUserData         = p;
        if (ctx_inited && sel_idx >= 0) {
            dcfg.playback.pDeviceID = &p->device_id;
        }
        r = ma_device_init(ctx_inited ? &p->context : NULL, &dcfg,
                           &p->stream_device);
        if (r == MA_SUCCESS && ctx_inited && !sink_native_known) {
            /* 以请求格式开默认设备失败 → 重试（默认 context，等价文件模式回退） */
        } else if (r != MA_SUCCESS) {
            /* 回退：无 context 默认路径 */
            fprintf(stderr,
                "[player] 流设备 init 失败 %d（自建 context），回退默认设备\n",
                (int)r);
            ma_device_config fcfg = ma_device_config_init(ma_device_type_playback);
            fcfg.playback.format   = ma_format_f32;
            fcfg.playback.channels = dev_ch;
            fcfg.sampleRate        = dev_rate;
            fcfg.dataCallback      = stream_data_cb;
            fcfg.pUserData         = p;
            r = ma_device_init(NULL, &fcfg, &p->stream_device);
        }
        if (r != MA_SUCCESS) {
            fprintf(stderr, "[player] 流设备 init 失败: %d（无声路径，继续转码落盘）\n",
                    (int)r);
            if (ctx_inited) ma_context_uninit(&p->context);
            stream_free_ring(p);
            free(p);
            return NULL;
        }
        p->stream_dev_inited = 1;
        p->stream_dev_started = 0;
        p->stream_active = 0;
    }

    {
        ma_backend used_backend = ma_backend_null;
        const char *backend_name = "<unknown>";
        ma_uint32 real_rate = p->stream_device.sampleRate;
        ma_uint32 real_ch = p->stream_device.playback.channels;
        if (p->stream_device.pContext != NULL) {
            used_backend = p->stream_device.pContext->backend;
            backend_name = ma_get_backend_name(used_backend);
        }
        fprintf(stderr,
            "[player:stream] sink=%s backend=%s native=%uhz/%uch "
            "native_adapt=%d device=%uhz/%uch feed=%uhz/%uch ring=%zu帧(%.1fs) "
            "reason=%s\n",
            (sink_name[0] ? sink_name : "<default>"),
            backend_name, sink_rate, sink_ch, native_adapt,
            real_rate, real_ch, p->stream_feed_rate, p->stream_feed_ch,
            p->ring_cap,
            (double)p->ring_cap / (double)dev_rate, reason);
    }

    /* 播放器就绪事件（等价文件模式：设备打开、可开始出声） */
    if (st_opts.emit_playing && p->on_event) {
        char buf[128];
        snprintf(buf, sizeof(buf), "{\"type\":\"playing\"}");
        p->on_event(buf, p->user_data);
    }

    if (!st_opts.start_paused) {
        stream_device_start(p);
    } else {
        p->playing = 0;
    }
    return p;
}

int player_stream_write(PlayerCtx *p, const float *pcm, int samples)
{
    if (!p || !p->stream_mode || !p->stream_dev_inited) return -1;
    if (samples <= 0 || !pcm) return -1;

    const unsigned ch = p->stream_feed_ch;
    (void)ch;
    const float *src = pcm;
    int frames = samples;

    /* feed→设备重采样（dev_rate/ch ≠ content 时） */
    if (p->stream_swr) {
        int max_out = (int)(((int64_t)samples * (int64_t)p->stream_dev_rate) /
                            (int64_t)p->stream_feed_rate) + 64;
        if (max_out > p->stream_conv_cap_frames) {
            float *nb = (float *)realloc(p->stream_conv_buf,
                (size_t)max_out * p->stream_dev_ch * sizeof(float));
            if (!nb) return -1;
            p->stream_conv_buf = nb;
            p->stream_conv_cap_frames = max_out;
        }
        const uint8_t *inp = (const uint8_t *)src; /* 交错 f32：单平面指针 */
        frames = resampler_process(p->stream_swr, &inp, samples,
                                   p->stream_conv_buf,
                                   p->stream_conv_cap_frames);
        if (frames <= 0) return 0;
        src = p->stream_conv_buf;
    }

    const size_t need = (size_t)frames;
    const size_t cap = p->ring_cap;
    const size_t mask = cap - 1;
    const unsigned dch = p->stream_dev_ch;

    /* 环形缓冲满则阻塞等待（背压：解码按设备消费推进） */
    for (;;) {
        const size_t w = atomic_load_explicit(&p->ring_w, memory_order_relaxed);
        const size_t r = atomic_load_explicit(&p->ring_r, memory_order_acquire);
        if (cap - (w - r) >= need) break;
        ma_sleep(1); /* 1ms 让步（音频回调线程继续消费） */
    }
    {
        const size_t w = atomic_load_explicit(&p->ring_w, memory_order_relaxed);
        const size_t start = w & mask;
        const size_t first = (cap - start) < need ? (cap - start) : need;
        memcpy(&p->ring[start * dch], src, first * dch * sizeof(float));
        if (first < need) {
            memcpy(&p->ring[0], src + first * dch,
                   (need - first) * dch * sizeof(float));
        }
        atomic_store_explicit(&p->ring_w, w + need, memory_order_release);
    }

    /* 首包后启动设备（此前可能 start_paused / 等待首数据） */
    if (!p->stream_active) {
        p->stream_active = 1;
    }
    if (p->playing && !p->stream_dev_started) {
        stream_device_start(p);
    }
    return 0;
}

void player_stream_end(PlayerCtx *p)
{
    if (!p || !p->stream_mode) return;
    atomic_store_explicit(&p->stream_eof, 1, memory_order_release);
}

int player_stream_active(const PlayerCtx *p)
{
    return p && p->stream_mode && p->stream_active;
}

double player_stream_played_ms(const PlayerCtx *p)
{
    if (!p || !p->stream_mode) return 0.0;
    const size_t r = atomic_load_explicit(&p->ring_r, memory_order_relaxed);
    return p->stream_pos_base_ms + (double)r * 1000.0 / (double)p->stream_dev_rate;
}

double player_stream_buffered_ms(const PlayerCtx *p)
{
    if (!p || !p->stream_mode) return 0.0;
    const size_t w = atomic_load_explicit(&p->ring_w, memory_order_relaxed);
    const size_t r = atomic_load_explicit(&p->ring_r, memory_order_relaxed);
    return (double)(w - r) * 1000.0 / (double)p->stream_dev_rate;
}

void player_stream_set_pos_base(PlayerCtx *p, double base_ms)
{
    if (!p || !p->stream_mode) return;
    p->stream_pos_base_ms = base_ms;
    p->last_pos_frame = 0;
}

void player_stream_seek_reset(PlayerCtx *p)
{
    if (!p || !p->stream_mode) return;
    stream_device_stop(p);
    stream_free_ring(p);
    /* 重新分配空 ring（容量随设备率；seek 后解码重新喂入） */
    {
        size_t cap_frames = (size_t)((double)p->stream_dev_rate * STREAM_RING_SECONDS);
        size_t cap_pow2 = 1;
        while (cap_pow2 < cap_frames) cap_pow2 <<= 1;
        p->ring_cap = cap_pow2;
        p->ring = (float *)malloc(cap_pow2 * p->stream_dev_ch * sizeof(float));
    }
    /* seek 后喂入继续：重建 feed→设备 重采样（stream_free_ring 已释放） */
    if (p->stream_dev_rate != p->stream_feed_rate ||
        p->stream_dev_ch != p->stream_feed_ch) {
        p->stream_swr = resampler_create((int)p->stream_feed_rate,
                                          (int)p->stream_feed_ch,
                                          AV_SAMPLE_FMT_FLT,
                                          (int)p->stream_dev_rate,
                                          (int)p->stream_dev_ch);
    }
    atomic_store_explicit(&p->ring_w, 0, memory_order_release);
    atomic_store_explicit(&p->ring_r, 0, memory_order_release);
    atomic_store_explicit(&p->stream_eof, 0, memory_order_release);
    atomic_store_explicit(&p->stream_stop, 0, memory_order_release);
    p->stream_pos_base_ms = 0.0;
    p->stream_active = 0;
    p->ended_reported = 0;
}

int player_stream_switch_sink(PlayerCtx *p, const char *sink_id)
{
    ma_result r;
    int ctx_inited;
    int sel_idx = -1;
    char reason[192];
    unsigned sink_rate = 0, sink_ch = 0;
    int sink_native_known = 0;
    int native_adapt = 0;
    unsigned dev_rate, dev_ch;
    int i;

    if (!p || !p->stream_mode || !p->stream_dev_inited) return -1;

    /* 旧设备停止并释放 */
    {
        double played = player_stream_played_ms(p);
        stream_device_stop(p);
        ma_device_uninit(&p->stream_device);
        p->stream_dev_inited = 0;
        /* 保留 ring 计数并平移位置基：ring 清空后位置从已播放点延续 */
        p->stream_pos_base_ms = played;
    }

    ctx_inited = p->context_initialized ? 1 : 0;
    if (!ctx_inited) {
        if (player_context_open(&p->context) != 0) return -1;
        ctx_inited = 1;
        p->context_initialized = 0; /* 由下方一致处理 */
    }

    {
        const char *env_override = (sink_id && sink_id[0]) ? sink_id : NULL;
        int n = 0;
        int default_idx = -1;
        char sink_name[MA_MAX_DEVICE_NAME_LENGTH + 1];
        player_probe_entry *probes = player_probe_collect(&p->context, &n);
        snprintf(reason, sizeof(reason), "默认路径");
        sink_name[0] = '\0';
        if (probes != NULL && n > 0) {
            player_sink_candidate *cands =
                (player_sink_candidate *)calloc((size_t)n, sizeof(*cands));
            if (cands != NULL) {
                for (i = 0; i < n; ++i) {
                    cands[i] = probes[i].c;
                    if (cands[i].is_default && default_idx < 0) default_idx = i;
                }
                sel_idx = player_sink_select(cands, n, env_override,
                                             reason, sizeof(reason));
                free(cands);
            }
            int target_idx = (sel_idx >= 0) ? sel_idx : default_idx;
            if (sel_idx >= 0) {
                p->device_id = probes[sel_idx].dev_id;
            }
            if (target_idx >= 0) {
                player_probe_entry *t = &probes[target_idx];
                ma_strncpy_s(sink_name, sizeof(sink_name), t->c.name, (size_t)-1);
                sink_rate = t->c.sample_rate;
                sink_ch   = t->c.channels;
                sink_native_known = t->c.has_native;
            }
        }
        if (probes) player_probe_free(probes);
    }

    if (sink_native_known &&
        (sink_ch < PLAYER_SINK_MIN_CHANNELS || sink_rate < PLAYER_SINK_MIN_RATE)) {
        native_adapt = 1;
    }
    if (native_adapt && sink_rate > 0 && sink_ch > 0) {
        dev_rate = sink_rate;
        dev_ch   = sink_ch;
    } else if (sink_native_known && sink_rate > 0 && sink_ch > 0) {
        dev_rate = sink_rate;
        dev_ch   = sink_ch;
    } else {
        dev_rate = p->stream_feed_rate;
        dev_ch   = (p->stream_feed_ch > 2 ? 2 : p->stream_feed_ch);
    }
    if (dev_ch < 1) dev_ch = 1;
    if (dev_ch > 2) dev_ch = 2;
    p->stream_dev_rate = dev_rate;
    p->stream_dev_ch   = dev_ch;
    p->stream_dev_ratio = (double)dev_rate / (double)p->stream_feed_rate;

    /* 重建 swr（格式可能变化） */
    if (p->stream_swr) { resampler_destroy(p->stream_swr); p->stream_swr = NULL; }
    if (p->stream_conv_buf) { free(p->stream_conv_buf); p->stream_conv_buf = NULL; }
    p->stream_conv_cap_frames = 0;
    if (dev_rate != p->stream_feed_rate || dev_ch != p->stream_feed_ch) {
        p->stream_swr = resampler_create((int)p->stream_feed_rate,
                                          (int)p->stream_feed_ch,
                                          AV_SAMPLE_FMT_FLT,
                                          (int)dev_rate, (int)dev_ch);
    }

    /* 清空缓冲：新设备从当前解码点续播 */
    atomic_store_explicit(&p->ring_w, 0, memory_order_release);
    atomic_store_explicit(&p->ring_r, 0, memory_order_release);

    {
        ma_device_config dcfg = ma_device_config_init(ma_device_type_playback);
        dcfg.playback.format   = ma_format_f32;
        dcfg.playback.channels = dev_ch;
        dcfg.sampleRate        = dev_rate;
        dcfg.dataCallback      = stream_data_cb;
        dcfg.pUserData         = p;
        if (ctx_inited && sel_idx >= 0) {
            dcfg.playback.pDeviceID = &p->device_id;
        }
        r = ma_device_init(ctx_inited ? &p->context : NULL, &dcfg,
                           &p->stream_device);
        if (r != MA_SUCCESS) {
            fprintf(stderr, "[player] 流设备切 sink init 失败 %d\n", (int)r);
            p->stream_dev_inited = 0;
            return -1;
        }
        p->stream_dev_inited = 1;
        p->stream_dev_started = 0;
    }
    if (p->playing) {
        stream_device_start(p);
    }
    return 0;
}

void player_get_state(PlayerCtx *p, int *playing, double *pos_ms, float *volume)
{
    if (playing) *playing = 0;
    if (pos_ms)  *pos_ms = 0.0;
    if (volume)  *volume = 1.0f;
    if (!p) return;

    if (p->stream_mode) {
        if (playing) *playing = p->playing ? 1 : 0;
        if (volume)  *volume = stream_volume_get(p);
        if (pos_ms)  *pos_ms = player_stream_played_ms(p);
        return;
    }

    if (!p->has_sound) return;

    if (playing) *playing = p->playing ? 1 : 0;
    if (volume)  *volume = ma_sound_get_volume(&p->sound);
    if (pos_ms && p->sample_rate > 0) {
        ma_uint64 cur = 0;
        if (ma_sound_get_cursor_in_pcm_frames(&p->sound, &cur) == MA_SUCCESS) {
            *pos_ms = (double)cur * 1000.0 / (double)p->sample_rate;
        }
    }
}

void player_command(PlayerCtx *p, const char *type,
                    const double *pos_ms, const double *gain)
{
    if (!p) return;

    if (p->stream_mode) {
        if (!p->stream_dev_inited) return; /* 无声路径：命令无效 */
        if (strcmp(type, "play") == 0) {
            p->playing = 1;
            if (p->stream_active) stream_device_start(p);
        } else if (strcmp(type, "pause") == 0) {
            stream_device_stop(p);
            p->playing = 0;
        } else if (strcmp(type, "set_playing") == 0 && gain) {
            if (*gain != 0.0) {
                p->playing = 1;
                if (p->stream_active) stream_device_start(p);
            } else {
                stream_device_stop(p);
                p->playing = 0;
            }
        } else if (strcmp(type, "seek") == 0 && pos_ms) {
            /* 流式 seek 由调用方“停流 + 重建管线 + seek_reset”处理；
               这里仅立即确认位置，避免 UI 等待位置事件 */
            p->seek_pending = 0;
            p->last_pos_frame = 0;
            if (p->on_event) {
                char buf[128];
                snprintf(buf, sizeof(buf),
                         "{\"type\":\"position\",\"position_ms\":%.0f}", *pos_ms);
                p->on_event(buf, p->user_data);
            }
        } else if (strcmp(type, "set_volume") == 0 && gain) {
            stream_volume_set(p, (float)*gain);
        } else if (strcmp(type, "get_status") == 0) {
            double ms = player_stream_played_ms(p);
            char buf[256];
            snprintf(buf, sizeof(buf),
                     "{\"type\":\"status\",\"position_ms\":%.0f,"
                     "\"duration_ms\":%.0f,\"playing\":%s}",
                     ms, p->duration_ms, p->playing ? "true" : "false");
            p->on_event(buf, p->user_data);
        }
        return;
    }

    if (!p->has_sound) return;

    if (strcmp(type, "play") == 0) {
        ma_sound_start(&p->sound);
        p->playing = 1;
    } else if (strcmp(type, "pause") == 0) {
        ma_sound_stop(&p->sound);
        p->playing = 0;
    } else if (strcmp(type, "set_playing") == 0 && gain) {
        if (*gain != 0.0) {
            ma_sound_start(&p->sound);
            p->playing = 1;
        } else {
            ma_sound_stop(&p->sound);
            p->playing = 0;
        }
    } else if (strcmp(type, "seek") == 0 && pos_ms && p->sample_rate > 0) {
        ma_uint64 frame =
            (ma_uint64)(*pos_ms / 1000.0 * (double)p->sample_rate);
        ma_sound_seek_to_pcm_frame(&p->sound, frame);
        p->last_pos_frame = frame;
        /* 开启保护窗口：游标同步期间不推送位置事件（防旧值刷回 UI） */
        p->seek_pending = 1;
        p->seek_target_frame = frame;
        p->seek_poll_count = 0;
        /* 立即确认：以 seek 目标值推送一次 position，Dart 立即回填新位置，
           不会先闪回原进度再跳转 */
        if (p->on_event) {
            char buf[128];
            snprintf(buf, sizeof(buf),
                     "{\"type\":\"position\",\"position_ms\":%.0f}", *pos_ms);
            p->on_event(buf, p->user_data);
        }
    } else if (strcmp(type, "set_volume") == 0 && gain) {
        ma_sound_set_volume(&p->sound, (float)*gain);
    } else if (strcmp(type, "get_status") == 0) {
        ma_uint64 cur = 0;
        if (ma_sound_get_cursor_in_pcm_frames(&p->sound, &cur) != MA_SUCCESS) {
            cur = 0;
        }
        double ms = p->sample_rate > 0
            ? (double)cur * 1000.0 / (double)p->sample_rate : 0.0;
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "{\"type\":\"status\",\"position_ms\":%.0f,"
                 "\"duration_ms\":%.0f,\"playing\":%s}",
                 ms, p->duration_ms, p->playing ? "true" : "false");
        p->on_event(buf, p->user_data);
    }
}

void player_set_position_interval(PlayerCtx *p, int interval_ms)
{
    if (!p) return;
    if (interval_ms < 20) interval_ms = 20;
    p->position_interval_ms = interval_ms;
}

int player_poll(PlayerCtx *p)
{
    if (!p) return 0;

    if (p->stream_mode) {
        if (!p->stream_dev_inited) return 0;
        /* 位置事件：按设备已消费位置驱动（与文件模式游标语义一致） */
        if (p->playing && p->stream_dev_rate > 0) {
            double cur_ms = player_stream_played_ms(p);
            int interval = p->position_interval_ms;
            if (interval < 20) interval = 20;
            ma_uint64 step = p->stream_dev_rate / (1000 / interval);
            if (step == 0) step = 1;
            /* 以 ms 步长近似（消费帧数换算） */
            double step_ms = (double)step * 1000.0 / (double)p->stream_dev_rate;
            if (cur_ms - (double)p->last_pos_frame >= step_ms) {
                p->last_pos_frame = (ma_uint64)cur_ms;
                char buf[128];
                snprintf(buf, sizeof(buf),
                         "{\"type\":\"position\",\"position_ms\":%.0f}", cur_ms);
                p->on_event(buf, p->user_data);
            }
        }

        /* 结束：解码流 EOF 且缓冲耗尽且设备已停止请求 */
        if (atomic_load_explicit(&p->stream_stop, memory_order_acquire) &&
            p->stream_dev_started) {
            stream_device_stop(p);
        }
        if (atomic_load_explicit(&p->stream_eof, memory_order_acquire)) {
            size_t w = atomic_load_explicit(&p->ring_w, memory_order_acquire);
            size_t r = atomic_load_explicit(&p->ring_r, memory_order_acquire);
            if (w == r && !p->stream_dev_started && !p->ended_reported) {
                p->ended_reported = 1;
                p->playing = 0;
            }
        }
        if (p->ended_reported) {
            p->ended_reported = 0;
            if (p->on_event) p->on_event("{\"type\":\"player:ended\"}", p->user_data);
            return 1;
        }
        if (p->stream_debug) {
            size_t w = atomic_load_explicit(&p->ring_w, memory_order_relaxed);
            size_t r = atomic_load_explicit(&p->ring_r, memory_order_relaxed);
            fprintf(stderr, "[stream-dbg] poll eof=%d stop=%d dev_started=%d "
                            "w=%zu r=%zu play=%.1f\n",
                    atomic_load_explicit(&p->stream_eof, memory_order_relaxed),
                    atomic_load_explicit(&p->stream_stop, memory_order_relaxed),
                    p->stream_dev_started, w, r, player_stream_played_ms(p));
        }
        return 0;
    }

    if (!p || !p->has_sound) return 0;

    /* 位置事件：按音频位置驱动（每 position_interval_ms 音频 1 帧） */
    if (p->playing && p->sample_rate > 0) {
        ma_uint64 cur = 0;
        if (ma_sound_get_cursor_in_pcm_frames(&p->sound, &cur) == MA_SUCCESS) {
            int interval = p->position_interval_ms;
            if (interval < 20) interval = 20;   /* 下限 20ms（50Hz）防误设 */
            ma_uint64 div = 1000 / interval;
            if (div == 0) div = 1;              /* interval > 1000ms 兜底 */
            ma_uint64 step = p->sample_rate / div;
            if (step == 0) step = 1;
            if (p->seek_pending) {
                /* 等待游标进入目标区域（±400ms）后解除保护；期间不推送，
                   防止 seek 前旧游标值把 UI 刷回原进度。seek 到末尾附近时
                   游标可能停在 duration 前，超时兜底强制解除 */
                if (cur >= p->seek_target_frame &&
                    cur <= p->seek_target_frame + step * 4) {
                    p->seek_pending = 0;
                    p->last_pos_frame = cur;
                } else if (++p->seek_poll_count > 60) {
                    p->seek_pending = 0;
                    p->last_pos_frame = cur;
                }
            } else if (cur >= p->last_pos_frame + step) {
                p->last_pos_frame = cur;
                double ms = (double)cur * 1000.0 / (double)p->sample_rate;
                char buf[128];
                snprintf(buf, sizeof(buf),
                         "{\"type\":\"position\",\"position_ms\":%.0f}", ms);
                p->on_event(buf, p->user_data);
            }
        }
    }

    /* 自然结束事件（只报一次） */
    if (p->ended_reported) {
        p->ended_reported = 0;
        if (p->on_event) p->on_event("{\"type\":\"player:ended\"}", p->user_data);
        return 1;
    }
    return 0;
}

void player_stop(PlayerCtx *p)
{
    if (!p) return;
    if (p->stream_mode) {
        stream_teardown(p);
        if (p->context_initialized) {
            ma_context_uninit(&p->context);
            p->context_initialized = 0;
        }
        free(p);
        return;
    }
    if (p->has_sound) {
        ma_sound_stop(&p->sound);
        ma_sound_uninit(&p->sound);
        p->has_sound = 0;
    }
    ma_engine_uninit(&p->engine);
    if (p->context_initialized) {
        ma_context_uninit(&p->context);
        p->context_initialized = 0;
    }
    free(p);
}
