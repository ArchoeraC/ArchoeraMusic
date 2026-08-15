# 独立音频内核设计（去除 FFmpeg）—— C 方案（已废弃，保留作历史分析）

> 状态：**已废弃 · 2026-08-15**。本稿为 **C11 语言**方案的早期设计，仅保留作历史分析。
> **当前方案改用 Zig 编写**（跨平台优先 + 最小外部依赖），见
> **[`audio-kernel-zig.md`](audio-kernel-zig.md)**（权威设计，以它为准）。
>
> 本稿仍有参考价值的部分：FFmpeg 依赖点审计（§2）、格式覆盖范围（§1.3）、
> 时长/seek 语义（§9）、错误与容错（§10）、测试护栏（§13）——均已并入 Zig 设计。
> 与 Zig 方案冲突处以 Zig 方案为准（尤其是解码器选型与依赖账本）。

---

> 状态：**设计稿 v1 · 2026-08-15**
> 定位：为 `archoera-audio-engine`（`app/core/audio-engine/`）设计一套**完全不依赖 FFmpeg** 的
> 自包含音频内核。音频内核只做**音频**，**不做任何视频解码**（容器/流中的视频轨直接跳过或整体不处理）。
>
> 依据：AGPL-3.0 项目，第三方依赖必须为 Permissive（MIT / Apache-2.0 / BSD / ISC / OFL / WTFPL /
> MIT-0 / 公有领域）且与 AGPL 兼容（项目规范见 README「许可证」章节）。

---

## 目录

1. [背景与目标](#1-背景与目标)
2. [现状盘点：FFmpeg 依赖点审计](#2-现状盘点ffmpeg-依赖点审计)
3. [总体架构：独立音频内核](#3-总体架构独立音频内核)
4. [输入抽象与格式探测](#4-输入抽象与格式探测)
5. [解码层：格式注册表设计](#5-解码层格式注册表设计)
6. [各格式解码方案与许可证分析](#6-各格式解码方案与许可证分析)
7. [采样转换：格式转换 / 下混 / 重采样](#7-采样转换格式转换--下混--重采样)
8. [编码器与 OGG 封装（可选模块）](#8-编码器与-ogg-封装可选模块)
9. [时长 / 定位 / Seek 语义](#9-时长--定位--seek-语义)
10. [中断、错误与容错](#10-中断错误与容错)
11. [与既有管线 / 播放器 / FFI 的关系](#11-与既有管线--播放器--ffi-的关系)
12. [构建与打包变更](#12-构建与打包变更)
13. [测试与验证](#13-测试与验证)
14. [分阶段实施路线](#14-分阶段实施路线)
15. [风险与决策点](#15-风险与决策点)
16. [决策记录](#16-决策记录)

---

## 1. 背景与目标

### 1.1 背景

当前 `archoera-audio-engine`（C，`app/core/audio-engine/`）的解码 / 重采样 / 编码三环依赖系统 FFmpeg：

```
decode（libavformat + libavcodec）→ resample（libswresample）→ EQ → loudness → limiter
→ tempo（Rust）→ FFT → encode（libavformat muxer + libopus）→ OGG/Opus
```

FFmpeg 带来的工程问题：

1. **跨平台打包重**：三平台需随包携带 FFmpeg 运行库（Linux 内嵌 `.so.*`、Windows vcpkg DLL、
   macOS Homebrew dylib），体积与分发复杂度高（`docs/engine-builder-plan.md` 已有大量篇幅为它兜底）；
2. **major 升级破坏 ABI**：FFmpeg 每次 major 升级都 bump soname，预编译二进制随系统升级即坏
   （`CMakeLists.txt` 内嵌运行库 + `$ORIGIN` RUNPATH 也只是"躲"，不是"解"）；
3. **功能冗余**：项目是**纯音频播放器**，FFmpeg 90% 的编解码能力（尤其视频）根本用不到；
4. **依赖黑洞**：FFmpeg 构建链复杂（外部 libs、GPL 开关），不利于后续可控演进。

### 1.2 目标

1. **零 FFmpeg**：`app/core/audio-engine` 不再链接 / 不再依赖任何 FFmpeg 组件（`libav*` / `libsw*`）；
2. **纯音频内核**：只解码音频，视频轨不处理、不支持、不探测；
3. **覆盖核心格式**：满足在线平台 + 本地曲库的实际需求（见 §1.3 格式清单）；
4. **许可证合规**：全部新引入第三方为 Permissive 且与 AGPL-3.0 兼容，不引入 GPL/SSPL/非自由许可；
5. **行为不回退**：播放 / seek / FFT / EQ / 变速变调 / 位置事件与现状一致（Dart 侧 `audio_engine_process.dart`
   与 C 侧 `archoera_mediaengine.h` FFI 协议**零改动**）；
6. **内核自包含**：核心解码/采样逻辑自写或采用单文件库，构建只依赖 C 工具链（+ 可选 libopus）。

### 1.3 格式覆盖范围（音频内核职责边界）

| 优先级 | 格式 | 来源 | 说明 |
|---|---|---|---|
| **P0 必做** | MP3 / FLAC / WAV | 本地 + 网易云 + 酷狗 | 网易云默认 `encodeType=flac`，酷狗默认 mp3/flac |
| **P0 必做** | OGG / Opus | 本地 + Web 兼容转码输出 | Opus 亦为编码器目标格式 |
| **P1 必做** | AAC / M4A | QQ 音乐 + 本地 | QQ 音乐默认 m4a；AAC 是唯一"硬骨头"（§6.4） |
| **P2 可选** | Vorbis / AIFF | 本地 | `dr_wav` 已含 AIFF 容器；`stb_vorbis` 已内嵌 |
| **P3 按需** | APE / WavPack / DSD | 本地小众 | 依赖第三方库选型；DSD 建议先砍（见 §15 风险） |

> 对齐点：C# 扫描器 `ScannerEngine.cs:33-34` 支持的扩展名
> （mp3/flac/ogg/opus/oga/m4a/aac/wav/ape/wv/dsf/dsd/dff/mp4/aiff/aif）。
> **音频内核按"播放解码"职责收敛到上表；扫描器元数据读取与解码无关，不受影响。**

### 1.4 非目标

- 不做任何视频解码 / 容器多轨（含音频轨的视频容器如 MP4 带视频轨、MKV、FLV、WebM-video 均不在范围）；
- 不保留 FFmpeg 的"任意协议 URL"能力——网络输入改由 Dart 预下载（§4.3），内核只读本地文件/内存；
- 不承诺"穷举一切格式"，未支持格式返回明确错误并可由上层提示"该音源需 FFmpeg 内核"（Phase 期间保留开关，见 §15）。

---

## 2. 现状盘点：FFmpeg 依赖点审计

### 2.1 FFmpeg 符号使用面（全量）

| 文件 | 使用的 FFmpeg API | 职责 |
|---|---|---|
| `src/decoder.c` + `decoder.h` | `avformat_open_input` / `avformat_find_stream_info` / `av_find_best_stream` / `avcodec_*`（open/send/receive/flush）/ `av_read_frame` / `av_seek_frame` / `avio_alloc` 中断回调 / `av_log_set_callback` | 解复用 + 解码 + 探测 + seek + 时长 |
| `src/resampler.c` + `resampler.h` | `swr_alloc_set_opts2` / `swr_init` / `swr_convert` / `swr_free` / `av_channel_layout_default` / `av_rescale_rnd` | 任意采样格式 → float、采样率转换、声道下混 |
| `src/encoder.c` + `encoder.h` | `avformat_alloc_output_context2("ogg")` / `avio_alloc_context` / `avcodec_find_encoder(OPUS)` / `avformat_write_header` / `av_interleaved_write_frame` / `av_write_trailer` | Opus 编码 + OGG 封装 |
| `src/pipeline.c` | `AVFrame`（`sample_rate` / `ch_layout` / `format`）类型透传；`AV_SAMPLE_FMT_NONE` | 编排（FFmpeg 类型侵入点） |
| `src/main.c` / `mediaengine_lib.c` | 仅注释与 `decoder_interrupt()`（AVIOInterruptCB 语义） | 控制 / FFI / UDS |
| `include/miniaudio.h` | 无 FFmpeg（自带 dr_wav/dr_flac/dr_mp3/stb_vorbis，MIT-0/PD） | 播放器输出设备 |

### 2.2 已无 FFmpeg 的模块（保持不变）

- `equalizer.c`（自写 10 段 Biquad）
- `loudness.c`（自写 EBU R128 增益）
- `limiter.c`（自写限幅）
- `fft.c`（自写 FFT，导出 `libfft.so`，仅 libm）
- `tempo.c` + `tempo-rs`（Rust signalsmith-stretch）
- `player.c`（miniaudio 播放，含 `dr_wav` 解码 WAV）
- `pcm_uds.c`（UDS 服务）

### 2.3 结论

**FFmpeg 依赖面 = 解码 + 重采样 + 编码 三个文件 + 构建脚本。**
替换这三处，并清理 `pipeline.c` 对 `AVFrame`/`AVSampleFormat` 的类型侵入，
即完成"去 FFmpeg"。DSP 链、播放器、FFI 协议全部不动。

### 2.4 关键事实：桌面播放路径并不编码

- `mediaengine_lib.c:520`：FFI 播放模式强制 `skip_encoder = true`（转码 PCM 直落 float32 WAV）；
- `player.c`：miniaudio 用 `dr_wav` 解码该 WAV 播放；
- `main.c:897`：CLI 播放模式同样 `skip_encoder = true`。

> 即：**Opus/OGG 编码器只服务 Web 兼容路径与 CLI 批量转码**。
> 设计上编码器降级为**可选模块**（§8），桌面主链路完全不依赖它。

---

## 3. 总体架构：独立音频内核

### 3.1 模块划分

```
archoera-audio-engine（C11）
│
├── kernel/                       ← 新增：独立音频内核（本设计）
│   ├── audio_io.h/.c            输入抽象：文件/内存/回调 Reader（缓冲 + 预读 + seek）
│   ├── probe.h/.c               格式探测（魔数嗅探）
│   ├── audio_decoder.h          解码器统一接口（本设计核心契约）
│   ├── decoder_factory.c        探测 → 实例化对应格式解码模块
│   ├── fmt/
│   │   ├── ogg_opus.c           OGG 解复用（自写）+ libopus 解码（或 libopusfile 封装）
│   │   ├── ogg_vorbis.c         OGG/Vorbis（stb_vorbis，内嵌）
│   │   ├── flac.c               FLAC（dr_flac，内嵌）
│   │   ├── mp3.c                MP3（dr_mp3，内嵌）
│   │   ├── wav.c                WAV/AIFF/RF64/W64（dr_wav，内嵌）
│   │   ├── m4a.c                M4A/MP4-audio 解复用（自写）+ AAC 解码（§6.4）
│   │   └── aac_adts.c           AAC-ADTS 解复用（自写）+ AAC 解码（§6.4）
│   └── pcm/
│       ├── pcm_convert.c        采样格式转换（int16/24/32/f32/f64 → float32 交错）
│       ├── downmix.c            声道下混（多声道 → 目标声道，自写）
│       └── resampler.c          采样率转换（自写 windowed-sinc 多相 FIR）
│
├── src/
│   ├── decoder.c   → 删除，改由 decoder_factory 提供 `AudioDecoder`
│   ├── resampler.c → 删除，改由 kernel/pcm/* 提供
│   ├── encoder.c   → 删除，改由 kernel/encode/*（可选）提供
│   ├── pipeline.c  → 仅类型脱敏：AudioDecoder + kernel/pcm 替代 AVFrame/SwrContext
│   ├── equalizer.c / loudness.c / limiter.c / fft.c / tempo.c   （不变）
│   ├── player.c    → miniaudio 实现单一编译单元（见 §12.2）
│   └── main.c / mediaengine_lib.c / pcm_uds.c  （协议零改动）
│
└── encode/（可选模块，仅 Web 兼容 / CLI 批量）
    ├── opus_encoder.c      libopus 直接编码（不经过 FFmpeg）
    └── ogg_muxer.c         OGG 页封装（自写 OggS 页 / lacing / granule / CRC）
```

### 3.2 数据流（与现状一致）

```
source（本地文件 / Dart 预下载临时文件）
  → audio_io（缓冲 Reader）→ probe → decoder_factory
  → AudioDecoder.read() → 原生格式 PCM
  → pcm_convert → float32 交错
  → downmix → 目标声道
  → resampler（SRC，passthrough 时直通）
  → EQ → loudness → limiter → tempo → FFT
  → 桌面播放：PCM 落盘 float32 WAV → miniaudio 自播（skip_encoder）
  → Web/批量：opus_encoder + ogg_muxer → OGG/Opus 流
```

### 3.3 不变量（迁移护栏）

1. **FFI 协议不变**：`archoera_mediaengine.h` 全部导出符号与 `audio_engine_process.dart`
   的事件/命令语义（ready/done/playing/position/seek/...）不动；
2. **`audio_engine.h` 公开 API 不变**：`pipeline_create/process/run/...`、`EngineConfig` 字段不变；
3. **输出契约不变**：桌面输出 float32 WAV + `stream.pcm`（块格式 `[pos_ms|samples|channels]+float`）；
4. **采样率语义不变**：player 模式 `output_sample_rate<=0` 跟随源（原生 Hi-Res 直通）；
5. **DSP 顺序不变**：`decode → pcm → EQ → loudness → limiter → tempo → FFT → (encode|落盘)`。

---

## 4. 输入抽象与格式探测

### 4.1 `AudioInput`（统一读源）

```c
typedef struct AudioInput AudioInput;

/* 打开策略 */
typedef enum {
    AIO_FILE,   /* 本地文件路径 */
    AIO_MEM,    /* 内存缓冲（含长度） */
    AIO_CALLBACK, /* 自定义 onRead / onSeek / onTell（预留：fd / 管道 / 未来流式） */
} AudioInputKind;

AudioInput*  audio_input_open_path(const char *path, char *errbuf, int errbuf_size);
AudioInput*  audio_input_open_mem(const void *data, size_t size);
void         audio_input_close(AudioInput *in);

/* 缓冲读：peek 不消耗；read 消耗 */
size_t       audio_input_peek(AudioInput *in, void *buf, size_t n);
size_t       audio_input_read(AudioInput *in, void *buf, size_t n);
int          audio_input_seek(AudioInput *in, int64_t offset, int whence);
int64_t      audio_input_size(AudioInput *in);
```

- 带内部缓冲（16~64KB）与 **peek 语义**（探测需要回溯魔数）；
- `seek` 对文件直接 `fseeko`；对内存 memmove 偏移；对回调走 `onSeek`；
- **abort 标志**挂载在 `AudioInput` 上，供中断（§10）检查。

### 4.2 `probe.c`：魔数嗅探

读取前 64 字节（并解析/跳过 ID3v2 头）做识别：

| 魔数 / 特征 | 判定格式 | 解码模块 |
|---|---|---|
| `OggS` + `OpusHead` | OGG/Opus | `fmt/ogg_opus.c` |
| `OggS` + `vorbis` | OGG/Vorbis | `fmt/ogg_vorbis.c` |
| `fLaC` | FLAC | `fmt/flac.c` |
| `RIFF`+`WAVE` / `RIFX` / `RF64` / `w64` / `FORM`+`AIFF` | WAV/AIFF/W64/RF64 | `fmt/wav.c` |
| `ID3` 或 MPEG sync（`0xFF Ex/Fx`） | MP3 | `fmt/mp3.c` |
| `ftyp`（box size + `M4A ` / `mp42` 等） | M4A/MP4-audio | `fmt/m4a.c` |
| ADTS sync（`0xFF F1/F9`） | AAC-ADTS | `fmt/aac_adts.c` |
| `MAC ` | APE（P3） | 待选型 |
| `wvpk` | WavPack（P3） | 待选型 |
| `DSD ` / `FRM8`+`DSD ` | DSD（P3） | 待选型 |

- `probe()` 返回 `0 = 不支持` / `>0 = 置信度`（避免歧义，如 MP3 sync 需排除 ADTS）；
- 无匹配 → 返回带原因的错误（`errbuf` 写 `unsupported format`），上层提示。

### 4.3 网络输入：Dart 预下载（关键决策）

**现状**：`pipeline_create(source)` 的 source 可以是 URL，FFmpeg 自行 HTTP + 鉴权 + 重定向。

**新内核**：**在线源一律由 Dart 层预下载到临时文件，引擎只收本地路径。**

理由：

1. **行为对齐**：引擎本就是"全速转码 → 落盘完整 → 再播放"，预下载无额外等待成本；
2. **鉴权归位**：网易云/酷狗/QQ 音源 URL 需要平台 cookie / 签名头，Dart 平台层（`app/lib/apis/*`）
   已完整具备；引擎拿本地文件完全不需要网络与 TLS；
3. **内核瘦身**：去掉 HTTP / 重定向 / TLS（openssl/mbedtls）/ 网络中断回调，内核零网络依赖；
4. **探测与 seek 最稳**：本地文件可随机访问，时长/seek 精确。

实施形态（Dart `audio_engine_process.dart` 内）：

```
AudioEngineProcess.start(source: url, ...)
  → [新增] fetchToTemp(url, headers) → 临时文件（IO 流式写，随会话目录清理）
  → 引擎 FFI create(source = 临时文件路径, ...)
```

- 临时文件放会话目录（`{systemTemp}/archoera-...`），随会话清理，与现有 WAV/PCM 生命周期一致；
- 断流/超时由 Dart `HttpClient` 处理，失败直接走现有 `EngineError` 事件；
- 对「需要 Range 的流式广播」场景（非本项目目标）预留 `AIO_CALLBACK` 钩子，不做默认实现。

---

## 5. 解码层：格式注册表设计

### 5.1 统一接口 `audio_decoder.h`

每个格式模块实现同一套操作集合（对齐现状 `decoder.h` 的职责，脱 FFmpeg 类型）：

```c
typedef struct AudioDecoderInfo {
    int         sample_rate;     /* 源采样率（原生，未重采样） */
    int         channels;        /* 源声道数（未下混） */
    int         bits_per_sample; /* 原生位深（16/24/32），float 时为 32 */
    int         is_float;        /* 原生是否 float 样本 */
    int64_t     duration_us;     /* 时长（us；-1 = 未知/需扫描） */
    const char *codec_name;      /* 如 "mp3" / "flac" / "opus" / "aac" */
    const char *format_name;     /* 如 "ogg" / "mp4" */
} AudioDecoderInfo;

typedef struct AudioDecoder AudioDecoder;

struct AudioDecoderOps {
    int          (*probe)(const AudioInput *in);         /* 0/置信度 */
    AudioDecoder *(*open)(AudioInput *in, AudioDecoderInfo *info,
                          char *errbuf, int errbuf_size);
    /* 读取最多 max_samples 个（每声道）PCM 样本。
       *out_channels 返回实际声道数。返回读取的样本数；0=EOF；<0=错误。
       输出布局：原生采样格式，交错存储（ch0 ch1 ch0 ch1 ...）。 */
    int          (*read)(AudioDecoder *d, void *out,
                         int max_samples, int *out_channels);
    int          (*seek_ms)(AudioDecoder *d, int64_t target_ms);
    int64_t      (*position_ms)(AudioDecoder *d);
    void         (*close)(AudioDecoder *d);
};

/* 注册表 */
AudioDecoder *audio_decoder_open(const char *path, AudioDecoderInfo *info,
                                 char *errbuf, int errbuf_size);
```

- **输出为原生格式**（保留位深），采样转换由 `kernel/pcm/pcm_convert.c` 统一做——
  与现状 `resampler_set_input_format` 的"延迟初始化"语义对齐，且 DecoderInfo 在 open 时已知，
  可提前建好转换器，无需等第一帧；
- `read()` 的样本计数即"已处理音频位置"（现 pipeline 用 `resampler_get_output_samples` 追踪），
  新内核由 `AudioDecoder.position_ms()` 提供（PCM 转换器旁路时仍精确）。

### 5.2 解码器工厂

```
audio_decoder_open(path):
  in = audio_input_open_path(path)
  probe = probe_format(in)                    # 魔数嗅探（§4.2）
  for mod in registry[probe]:
      d = mod.open(in, &info, err)
      if d: return d
  return NULL + errbuf="unsupported / decode failed: <reason>"
```

- 注册表按格式静态展开（C11，`__attribute__((constructor))` 或直接查表），无动态加载；
- 探测失败可作二次尝试（如 ADTS 与 MP3 sync 混淆），返回最佳候选。

### 5.3 与现状 `decoder.h` 的映射

| 现状（FFmpeg） | 新内核 |
|---|---|
| `decoder_open(url)` | `audio_decoder_open(path)` |
| `decoder_read_frame(d, &AVFrame)` | `decoder.read(d, buf, n, &ch)` |
| `decoder_seek_ms(d, ms)` | `decoder.seek_ms(d, ms)` |
| `decoder_sample_rate/channels` | `info.sample_rate/channels`（open 时已知） |
| `decoder_duration_us` | `info.duration_us` |
| `decoder_codec_name` | `info.codec_name` |
| `decoder_interrupt()`（AVIOInterruptCB） | `audio_input_abort(in)`（见 §10） |

---

## 6. 各格式解码方案与许可证分析

> 许可审查前置条件：所有引入组件必须 **Permissive 且与 AGPL-3.0 兼容**，写入 `THIRD-PARTY-LICENSES.md`。

### 6.1 汇总表

| 格式 | 模块 | 实现 | 许可证 | 依赖形态 |
|---|---|---|---|---|
| MP3 | `fmt/mp3.c` | dr_mp3 | MIT-0 / PD | ✅ 已内嵌于 `include/miniaudio.h` |
| FLAC | `fmt/flac.c` | dr_flac | MIT-0 / PD | ✅ 已内嵌于 `include/miniaudio.h` |
| WAV/AIFF/W64/RF64 | `fmt/wav.c` | dr_wav | MIT-0 / PD | ✅ 已内嵌于 `include/miniaudio.h` |
| OGG/Vorbis | `fmt/ogg_vorbis.c` | stb_vorbis | MIT / PD | ✅ 已内嵌于 `include/miniaudio.h` |
| OGG/Opus | `fmt/ogg_opus.c` | libopusfile（推荐） | BSD-3-Clause | ➕ 新增（pkg-config/vcpkg），或自写 OGG 解复用 + libopus |
| Opus 编码 | `encode/opus_encoder.c` | libopus | BSD-3-Clause | ➕ 新增（pkg-config/vcpkg） |
| AAC / M4A / ADTS | `fmt/m4a.c` / `aac_adts.c` | OpenCORE AAC（推荐） | Apache-2.0 | ➕ 新增（vendored 或第三方源码） |
| APE / WavPack / DSD | P3 | 待选型 | — | 见 §15 |

> **核心收益**：P0 的三个必做格式（MP3/FLAC/WAV）以及 Vorbis，**零新增依赖**——
> 直接复用 `miniaudio.h` 内已内嵌的 dr_* / stb_vorbis（与播放器 `player.c` 同源同许可）。

### 6.2 dr_* / stb_vorbis 复用方案（P0）

- `miniaudio.h`（v0.11.25，2026-03-04）已内嵌 `dr_wav` / `dr_flac` / `dr_mp3` / `stb_vorbis`
  （前缀 `ma_dr_wav` 等，见文件内 `/* dr_wav_h begin */` 等段）；
- miniaudio 官方支持直接使用其解码器（`ma_decoder_*`）或底层 dr_*。**推荐直接调用底层 dr_* 函数族**
  （`ma_dr_mp3_*` / `ma_dr_flac_*` / `ma_dr_wav_*` / `ma_stb_vorbis_*`），避免引入 `ma_engine` 依赖；
- **实现编译单元**：单头文件实现只能实例化一次。新增 `kernel/ma_decoders.c`：

  ```c
  #define MINIAUDIO_IMPLEMENTATION      /* 唯一实现点（player.c 的 MINIAUDIO_IMPLEMENTATION 需移除或共享） */
  #include "miniaudio.h"                /* dr_wav/dr_flac/dr_mp3/stb_vorbis 实现随之可见 */
  ```

  `player.c` 改为仅 `#include "miniaudio.h"`（不再 `#define MINIAUDIO_IMPLEMENTATION`），
  见 §12.2 的 CMake 调整；
- 各 `fmt/*.c` 模块内部封装：
  - **WAV**：`drwav` 读取 + `drwav_seek_to_pcm_frame`（AIFF/W64/RF64 容器由 drwav 统一处理）；
  - **FLAC**：`drflac` 读取 + `drflac_seek_to_pcm_frame`（STREAMINFO 提供精确时长）；
  - **MP3**：`drmp3` 读取；时长/seek 见 §9.3（MP3 无索引，需独立处理）；
  - **Vorbis**：`stb_vorbis`（push 模式）。

### 6.3 OGG/Opus 方案（P0）

**推荐 libopusfile（BSD-3-Clause）**：官方 Ogg/Opus 播放库，封装 OggS 解复用 +
`libopus` 解码 + granule 定位 + `op_pcm_total`/`op_seekable`，成熟稳定，接口贴合需求。

- `opusfile` 自身依赖 `ogg` + `opus`（均为 BSD/MIT，兼容）；
- 引入方式：Linux/macOS `pkg-config opusfile`；Windows `vcpkg opusfile`；
  备选：不引 opusfile，自写 `fmt/ogg_opus.c`（OggS 页解析 ≈200 行）+ `libopus`（`op_decode_float`）。
  → **决策：先自写 OGG 解复用 + libopus**（内核自包含度最高、体积最小），
  **opusfile 作为"实现受阻"时的备选**（两者 API 面都被 `AudioDecoder` 抽象隔离，可无缝切换）。

### 6.4 AAC / M4A 方案（P1，唯一硬骨头）

AAC 解码复杂度高，必须引入成熟实现，候选评估：

| 候选 | 许可证 | 兼容 AGPL | 说明 | 结论 |
|---|---|---|---|---|
| **OpenCORE AAC**（Android 开源） | **Apache-2.0** | ✅ | 纯 C，AAC-LC 完整；HE-AAC（SBR/PS）需集成 `aacDecoder` + SBR/PS 组件，代码较老（2010s）需适配构建 | ✅ 推荐 |
| libfdk-aac（Fraunhofer） | 非自由许可 | ❌ | 有专利/许可争议，README 明确禁止 | ✗ |
| faad2 | GPL-2.0-or-later | ⚠️ | 与 AGPL 有兼容争议，项目「严禁引入 GPL-2.0-only」精神下不建议 | ✗ |
| 自写 AAC 解码器 | AGPL | — | 工作量级大（AAC 是最复杂音频编码之一），不现实 | ✗ |

**推荐：OpenCORE AAC（Apache-2.0）+ 自写解复用**：

- `fmt/aac_adts.c`：ADTS 解复用（帧头解析 ≈150 行，纯自写）；
- `fmt/m4a.c`：MP4/M4A **音频轨**解复用（`ftyp`/`moov`/`mvhd`/`stbl`/`stco`/`stsc`/`stsz`/`stts` 表解析，
  只取 `mp4a` 音频轨，视频轨直接跳过，≈600~800 行）；
- 解码：OpenCORE AAC `aacDecoder_DecodeFrame`（AAC-LC 为主；SBR 组件按需编译）；
- 时长：`mvhd` 提供（M4A）；ADTS 需全扫或估算（§9.3）；
- **降级策略（若 AAC 集成受阻）**：不阻塞发布——
  - 网易云/酷狗/QQ 平台可配置优先请求 mp3/flac 音源（QQ 音乐 m4a → 请求 mp3）；
  - 本地 m4a/aac 未支持时返回明确错误 + 设置项提示；
  - 保留一个**构建开关** `ARCHOERA_AAC=OFF`，默认尝试构建，失败则静默降级（见 §15）。

### 6.5 许可清单更新

替换 `app/core/audio-engine/THIRD-PARTY-LICENSES.md`：

```
| 组件 | 许可证 | 用途 | 来源 |
| miniaudio（含 dr_wav/dr_flac/dr_mp3/stb_vorbis） | MIT-0 / PD | 播放输出 + 解码 | 内嵌 |
| libopus | BSD-3-Clause | Opus 解码/编码 | pkg-config / vcpkg |
| OpenCORE AAC（可选） | Apache-2.0 | AAC 解码 | vendored |
| tempo-rs / signalsmith-stretch | MIT | 变速变调 | 已有 |
```

> 删除：FFmpeg（LGPL）声明、`rebuild-engine.sh` 的 FFmpeg 分支、`engine-builder-plan.md` 的 tcc-FFmpeg 方案相关性。

---

## 7. 采样转换：格式转换 / 下混 / 重采样

现状 `resampler.c` 用 `libswresample` 一次性完成「任意格式 → float32 + 采样率转换 + 声道下混」。
新内核拆为三个独立原语（各自可旁路，`passthrough` 时开销≈0）：

### 7.1 `pcm_convert.c`：采样格式转换

- 输入：`AudioDecoder.read()` 的原生样本（s16/s24/s32/f32/f64），交错布局；
- 输出：float32 交错；
- 实现：位深提升 + 归一化（s16 → /32768，s24 → /8388608，s32 → /2147483648），纯逐样本，无滤波器；
- **始终需要执行**（解码器输出并非 float），成本为 memcpy 级。

### 7.2 `downmix.c`：声道下混

- 输入声道数 > 目标声道数时执行（如 5.1 → 2）；否则直通；
- 参考 ITU-R BS.775 系数（对齐现状 `fft.c` 的下混系数）：
  - 5.1：`L = FL + 0.707·C + 0.707·BL`，`R = FR + 0.707·C + 0.707·BR`，LFE 不入下混；
  - 简单等权回退（未知布局时）。
- 布局信息：`AudioDecoderInfo` 提供声道数 + 布局枚举（mono/stereo/5.1/7.1/unknown）。

### 7.3 `resampler.c`：采样率转换（SRC）

- **旁路条件**：`passthrough`（桌面默认）时，`输出采样率 == 源采样率` → 零成本直通；
  仅当（a）强制 48k（`passthrough=false`，如 Web 兼容路径），或（b）后续 DSP 要求统一采样率时执行；
- **实现（自写）**：windowed-sinc（Kaiser 窗）多相 FIR，支持 `2^n` 相位 + 一次转两倍采样率链式逼近；
  - 参数：阻带 ~100dB，通带波动 <0.01dB（对齐 swr 默认质量）；
  - 目标：合理倍率（44.1k↔48k 等常见音乐采样率）下开销可接受；
  - 极大倍率（如 192k→8k）退化为线性插值兜底；
- **备选**：若自写质量/性能验证不达标，引入 `libsamplerate`（BSD-3-Clause，兼容 AGPL）；
  `AudioDecoder` 输出侧接口隔离，切换零侵入。

> 结论：P0 阶段 `pcm_convert` + `downmix` 为自写（简单、必用），SRC 自写多相 FIR 并验证；
> 性能基线见 §13.3（对齐 `swr_convert` 的基准）。

---

## 8. 编码器与 OGG 封装（可选模块）

> 桌面播放路径不编码（§2.4）。本模块只服务 Web 兼容 / CLI 批量转码，**不阻塞主链路**。

### 8.1 `opus_encoder.c`：libopus 直接编码

- 用 `libopus` 的 `opus_encoder_create` / `opus_encode_float` / `opus_encoder_destroy`，
  替代现状经 FFmpeg `avcodec_find_encoder(OPUS)`；
- 配置映射（对齐现状）：`sample_rate=48000`（Opus 固定）、`application=audio`、
  `bitrate`（映射 QualityLevel）、`frame_size=20ms`（960 samples @48k）；
- 输入为 DSP 后的 float32 交错 PCM，`opus_encode_float` 按声道数拆帧。

### 8.2 `ogg_muxer.c`：自写 OggS 封装

- 替代 `avformat_alloc_output_context2("ogg")` + `av_interleaved_write_frame`；
- 实现：`OggS` 页头（版本/序列号/页序/granule）+ lacing values + 页 CRC（CRC-32，
  可直接复用 `fft.c`/自写 CRC 表）+ OpusHead 头页 + OpusTags 元数据页；
- 规格依据 RFC 3533（Ogg）+ RFC 7845（Ogg/Opus 映射），granule = 3840·(n-1) + pre-skip 语义。

### 8.3 输出接口

保持现状 `OutputCallback`（`audio_engine.h:85`）签名不变，UDS/stdout 输出路径不动。

---

## 9. 时长 / 定位 / Seek 语义

### 9.1 统一时长模型

```
info.duration_us  ∈  { 精确(known), 估算(estimated), 未知(-1) }
```

| 格式 | 时长来源 | 精度 |
|---|---|---|
| FLAC | STREAMINFO `total_samples` | 精确 |
| WAV/AIFF | data chunk 字节数 / 字节率 | 精确 |
| OGG/Opus | 最后一个 OggS 页 granule | 精确（需扫描尾页，首帧可先出"估算"） |
| M4A | `mvhd` duration | 精确 |
| MP3 CBR | 文件大小 / 比特率 | 估算（精确可用） |
| MP3 VBR | XING/Info 头（存在时） | 估算 |
| MP3 VBR（无头）/ ADTS | 全扫（播放首遍顺带建索引） | 首遍后精确 |

### 9.2 位置跟踪

- pipeline 的"已处理音频位置"由 `AudioDecoder.position_ms()`（内部累计 read 输出样本数）
  提供，替代 `resampler_get_output_samples`；
- 涉及 `start_offset_ms`（CUE）：`seek_ms(offset)` 后从 offset 起计数，语义与现状一致。

### 9.3 MP3 seek 专项（已知短板）

- `dr_mp3` **无帧级 seek API**（MP3 无内建索引）；
- 方案：`fmt/mp3.c` 内置 **"首遍索引"** —— 播放/转码首遍时顺序解析每帧
  （frame header → 帧长 → 累计 samples），记录 `sample→file_offset` 稀疏表（每 ~1s 一个锚点）；
  完成后 `seek_ms` 用锚点二分 + 帧同步重入；
  - 首遍即桌面播放主流程（全速转码），索引伴随产生，无额外成本；
  - 批量模式（不 seek）可关闭索引（`AudioDecoderInfo` 提供 `need_index` 提示）。
- XING/Info 头存在时直接利用其帧数/字节数表，无需全扫。

### 9.4 seek 语义约束

- `seek_ms` 允许"近似"（MP3 帧对齐、Opus granule 对齐），引擎只保证 ≥ 现状精度
  （现状 `av_seek_frame(AVSEEK_FLAG_BACKWARD)` 也是关键帧/帧级对齐）；
- 桌面播放的实时 seek 走 miniaudio（WAV 即时，不涉及解码器 seek），
  解码器 seek 仅用于 CLI/Web 兼容/CUE 起始偏移。

---

## 10. 中断、错误与容错

### 10.1 中断（替代 AVIOInterruptCB）

- `AudioInput` 挂 `volatile int aborted`；
- `audio_input_abort(in)` 置位；所有 `read/seek/peek` 检查并立即返回 0/错误；
- 引擎 SIGTERM / stop 命令 → `audio_input_abort`（经 pipeline 传参，参照现状
  `decoder_interrupt` + `pipeline_signal_shutdown` 语义）；
- 本地文件读取本身不阻塞（无网络），中断响应为"下一帧边界"，延迟 < 一帧时长。

### 10.2 解码容错

沿用现状 `decoder.c` 的容错策略（逐格式模块内实现）：

- 坏帧跳过（记录 `consecutive_errors`，上限 ~256 后放弃并报错）；
- 坏包跳过、decoder flush 后继续（FLAC/MP3/Opus 均适用）；
- 单帧解码失败不中断整体（对齐现状日志过滤：FLAC sync code / MP3 timestamp 等无害告警降噪）。

### 10.3 错误码模型

`AudioDecoder.read()` 返回 `<0` 的错误码，统一映射（`kernel/audio_error.h`）：

```
AUDIO_OK=0 / AUDIO_EOF=0（read 返回 0）/ 
AUDIO_ERR_OPEN / AUDIO_ERR_UNSUPPORTED / AUDIO_ERR_CORRUPT / AUDIO_ERR_ABORTED / AUDIO_ERR_SEEK
```

pipeline 将错误转成现有事件协议：`{"type":"error","message":"..."}` → Dart `EngineError`，零改动。

---

## 11. 与既有管线 / 播放器 / FFI 的关系

### 11.1 `pipeline.c` 类型脱敏（唯一侵入点）

现状 `process_frame(AVFrame*)` 依赖 FFmpeg 类型。新内核改为：

```c
static int process_frame(AudioPipeline *p)
{
    /* decoder → pcm_convert → downmix → src → DSP 链 */
    int n = audio_decoder_read(p->dec, p->raw_buf, PCM_TEMP_CAPACITY, &p->src_channels);
    int m = pcm_convert(p->cv, p->raw_buf, n, p->src_channels, p->f32_buf);
    ...
}
```

- `AVSampleFormat` → 内核枚举；`ch_layout` → `int channels + layout 枚举`；
- `resampler_*` 调用全部替换为 `pcm_convert/downmix/resampler` 三件套；
- **公开头 `audio_engine.h` 不暴露 FFmpeg 类型**（现状已是，`EngineConfig` 纯 C 类型），Dart FFI 无感。

### 11.2 `mediaengine_lib.c` / `main.c` / `pcm_uds.c`

- 仅调整 `pipeline_create` 内部的 decoder/resampler 构造路径；
- FFI 导出符号、事件/命令 JSON 协议、UDS 语义全部不变；
- `decoder_interrupt()` → `audio_input_abort()`（pipeline 持有 AudioInput 引用）。

### 11.3 `player.c`（miniaudio）

- 播放输出逻辑不变（仍解码引擎落盘的 float32 WAV）；
- 唯一调整：`MINIAUDIO_IMPLEMENTATION` 移到 `kernel/ma_decoders.c`（§6.2 / §12.2），
  `player.c` 只 include 头——避免单头文件库重复实现导致的链接冲突。

### 11.4 Dart 侧

- `audio_engine_process.dart`：仅新增"在线源预下载到临时文件"一步（§4.3），
  事件/命令/FFT/seek 逻辑零改动；
- `fft_bindings.dart` / `pcm_analyzer.dart`：不受影响（`libfft.so` 不变）。

---

## 12. 构建与打包变更

### 12.1 `CMakeLists.txt`

- **删除**：`find_package(PkgConfig)` + `pkg_check_modules(FFMPEG ...)`、FFmpeg 运行库内嵌块、
  `${FFMPEG_*}` 的全部 target 链接与 include；
- **新增**：`kernel/` 全部源文件；`libopus`（`find_library(opus)` 或 `pkg_check_modules(OPUS)`）；
  AAC（可选，`ARCHOERA_AAC` 开关）；`kernel/ma_decoders.c` 作为唯一 miniaudio 实现单元；
- `fft` 共享库、`archoera_mediaengine`、`archoera-audio-engine` 三个 target 均不再链接 FFmpeg；
- 保持 `-fvisibility=hidden` + FFI 导出标记、RUNPATH 等现状。

### 12.2 miniaudio 实现单元收敛

```
# 新：kernel/ma_decoders.c
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

# player.c：删除 #define MINIAUDIO_IMPLEMENTATION，仅 #include "miniaudio.h"
# 编译：kernel/ma_decoders.c 加入 audio_engine_static 源列表（player.c 不再单独实例化）
```

> 必须同一翻译单元内同时需要 dr_* 与 player 的 ma_engine：统一经 `ma_decoders.c` 实例化一次即可。

### 12.3 `vcpkg.json`（Windows）

```
删除: "ffmpeg"
新增: "opus"（必要时 "opusfile"）
```

### 12.4 `build_windows.bat` / CI / 打包

- `build_windows.bat`：移除 FFmpeg vcpkg/链接步骤，OPUS 走 vcpkg `opus`；
- `.github/workflows/build-{linux,macos,windows}.yml`：移除 FFmpeg 安装/内嵌步骤；
- Linux bundle：不再拷入 FFmpeg 运行库（`build/ffmpeg/` 移除），体积显著下降；
- `rebuild-engine.sh`：FFmpeg 自编译分支删除，改为"仅重编内核"（如需保留时）。

---

## 13. 测试与验证

### 13.1 单元测试（`tests/`）

- 新增 `test_decoder_<fmt>.c`（每格式）：**黄金文件**（MP3/FLAC/OGG-OPUS/WAV/M4A 小样本）+ 输出 PCM MD5 校验；
- `test_probe.c`：魔数探测全表 + 混淆用例（ADTS vs MP3）；
- `test_pcm.c`：格式转换/下混（5.1→2）/SRC（44.1k↔48k）逐样本校验 + 误差界；
- `test_ogg_muxer.c`：自写 OGG 页输出可被 `opusinfo`/系统播放器打开；
- 现有 `test_equalizer/limiter/fft/loudness` 不受影响。

### 13.2 一致性对比（迁移护栏）

- **并行验证**：迁移期间保留 FFmpeg 内核产物（独立 target，不进发布），
  同一输入分别经两内核转码 float32 WAV，逐样本比较：
  - 全链（无 DSP）期望 `MAX_DIFF < 1e-4`（浮点路径）或逐样本 bit-exact（整数路径）；
  - 有 DSP（EQ/limiter/tempo）期望行为一致（允许内部滤波差异，用响度/频谱统计断言）。
- 退出条件：三平台核心格式全部通过后删除 FFmpeg 对照 target。

### 13.3 性能基线

- SRC 基准：`swr_convert` vs 自写多相 FIR（44.1k→48k，44.1k→96k），要求自写 ≤ 2× swr 时间 且质量达标；
- 解码吞吐：每格式单核实时因子 ≥ 5×（对齐现状"音频级处理单核实时因子 5~10x+"，§architecture 5.4）；
- 首帧耗时：探测 + open 时间对标现状 `probesize=1MB / analyzeduration=0.5s` 的启动体验。

### 13.4 集成冒烟

- 桌面：本地 flac/mp3/wav/ogg 播放 + seek + FFT 拉模式 + EQ/tempo 实时调整（AUTOPLAY 回归）；
- 在线：网易云（mp3/flac）、酷狗（mp3/flac）、QQ 音乐（P1，mp3 或 m4a）播放；
- Web 兼容：CLI 批量 OGG/Opus 输出 + `opusinfo` 校验；
- 中断：SIGTERM / stop 时解码器正确退出，无孤儿资源、无泄漏（ASan 构建回归）。

---

## 14. 分阶段实施路线

| 阶段 | 内容 | 出口标准 |
|---|---|---|
| **Phase A** 内核骨架 + P0 解码 | `kernel/`（audio_io/probe/decoder_factory/pcm 三件套）；`fmt/wav.c` `flac.c` `mp3.c`（dr_* 复用）；`player.c`/`ma_decoders.c` 单实现单元收敛；`pipeline.c` 类型脱敏；CMake 移除 FFmpeg 的 decoder/resampler 依赖（**编码器暂保留 FFmpeg 或暂时禁用 Web 兼容路径**） | 本地 mp3/flac/wav 播放 + seek + FFT + DSP 全回归；一致性对比通过；ASan 无泄漏 |
| **Phase B** Opus 链路 | `fmt/ogg_opus.c`（自写 OGG + libopus）；`encode/opus_encoder.c` + `ogg_muxer.c`；vcpkg/CI 引入 opus | 在线 mp3/flac 播放；CLI 批量 OGG/Opus 输出；Web 兼容路径恢复 |
| **Phase C** AAC/M4A | `fmt/aac_adts.c` + `fmt/m4a.c` + OpenCORE AAC（`ARCHOERA_AAC` 开关）；QQ 音乐 m4a + 本地 m4a/aac；受阻则降级策略生效 | 本地/在线 m4a/aac 播放；未支持源给出明确错误 |
| **Phase D** 收尾 | 移除全部 FFmpeg 残留（CMake/vcpkg/CI/bat/rebuild 脚本/文档）；可选格式（Vorbis/AIFF 接入，APE/WavPack/DSD 按需）；`THIRD-PARTY-LICENSES.md` 更新；清缓存设置页显示内核版本 | 三平台无任何 `libav*`/`libsw*` 引用；`ldd`/`dumpbin` 验证 |

---

## 15. 风险与决策点

| 风险/决策 | 说明 | 对策 |
|---|---|---|
| **MP3 seek/时长精度** | `dr_mp3` 无索引；VBR 无 XING 头时时长未知 | 首遍扫描建索引（桌面主流程伴随完成）；XING 优先；`duration_us` 分级（精确/估算/未知） |
| **AAC 集成复杂度** | OpenCORE 代码老、构建适配、HE-AAC 组件 | P1 才做；`ARCHOERA_AAC=OFF` 降级不阻塞；平台侧优先请求 mp3/flac 音源 |
| **SRC 质量/性能** | 自写 FIR 需对标 swr | 多相 FIR + 独立基准；不达标则引入 libsamplerate（BSD，隔离接口） |
| **miniaudio 实现单元冲突** | 单头文件库只能实例化一次 | §12.2 收敛到 `kernel/ma_decoders.c`，编译期强制单一 `MINIAUDIO_IMPLEMENTATION` |
| **OGG 尾页扫描开销** | Opus 精确时长需读尾页（大文件尾部 IO） | 首帧先给估算，后台/首遍扫描后回填精确（position 事件不受影响） |
| **在线源格式漂移** | 平台新增编码（如某些源给 ape/aac 变体） | 探测失败 → 明确错误 + 音源降级（换 flac/mp3）；记录 `unsupported` 日志供后续扩展 |
| **DSD/APE/WavPack** | 引入成本与收益不匹配（小众） | **砍掉 DSD**（与播放链路无关）；APE/WavPack 列入 P3 按需，选型遵循许可审查 |
| **Web 兼容路径存废** | 桌面已不编码，Web 路径是否保留 | Phase A 期间可临时禁用；若确认废弃则删 `encode/` 整体 |
| **FFmpeg 对照 target 残留** | 迁移期并行验证引入的额外构建 | 一次性对照 target 只入 CI 不发布，通过后删除 |

---

## 16. 决策记录

1. **零 FFmpeg**：`app/core/audio-engine` 不链接任何 `libav*`/`libsw*`；视频解码不做、不支持。
2. **P0 格式复用内嵌解码器**：MP3/FLAC/WAV（dr_mp3/dr_flac/dr_wav）、Vorbis（stb_vorbis），
   零新增依赖；miniaudio 实现单例收敛于 `kernel/ma_decoders.c`。
3. **OPUS：自写 OGG 解复用 + libopus**（备选 libopusfile，接口经 `AudioDecoder` 隔离）。
4. **AAC：OpenCORE（Apache-2.0）** + 自写 ADTS/MP4 解复用；`ARCHOERA_AAC` 开关可降级，
   平台侧优先请求 mp3/flac 音源。
5. **网络输入：Dart 预下载临时文件**，引擎只收本地路径（内核零网络/TLS 依赖，鉴权归位 Dart 层）。
6. **解码器统一接口 `AudioDecoder`**：输出原生位深交错 PCM，采样转换由
   `pcm_convert + downmix + resampler（多相 FIR）` 三件套处理；SRC 不达标则引入 libsamplerate。
7. **编码器为可选模块**：桌面路径 `skip_encoder` 不变；仅 Web 兼容/CLI 批量走
   libopus 直编码 + 自写 OGG muxer。
8. **FFI / Dart 协议零改动**：`archoera_mediaengine.h` 与 `audio_engine_process.dart`
   事件/命令语义不变；Dart 仅新增预下载一步。
9. **时长/seek 分级**：精确/估算/未知三态；MP3 首遍索引 + XING；Opus 尾页扫描后回填。
10. **许可合规**：新引入仅限 MIT-0/PD/BSD-3/Apache-2.0，逐一登记 `THIRD-PARTY-LICENSES.md`；
    明确排除 faad2（GPL）、libfdk-aac（非自由）。
