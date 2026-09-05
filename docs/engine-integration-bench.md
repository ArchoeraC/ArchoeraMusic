# 引擎集成与基准（EraAudio vs Stable）

> 2026-09-05 · 解码引擎选择（Flutter UI，冷重启生效）、C↔Zig 兼容层、
> 内存流式化与基准结论速记。配套 `app/core/audio-engine/tests/bench/`。

## 1. 引擎选择
- Dart prefs：`audio.engine` = `'stable'`（FFmpeg，默认）/ `'eraudio'`（自研 Zig 内核，实验性）。
  UI 在设置 playback 分类，切换后冷重启生效（Vault 同款流程），l10n 9 语种。
- C 契约：`EngineConfig.engine_mode`（0/1）随 FFI config 传入；Dart 镜像 `EngineConfigC.engineMode`。
- CLI：`archoera-audio-engine <file> [--engine-mode 0|1]`。
- `src/native_decoder.{h,c}`：EraAudio 先 `zk_decoder_open`（`libarchoera_kernel.a`，Zig 静态库），
  未接管（ZK_UNSUPPORTED 等）/失败 → 日志 + 回退 FFmpeg；native 输出 f32 交错喂同一 swr/DSP 链。
- CMake：优先复用 `zig-out/lib/libarchoera_kernel.a`（或跑 `zig build` 生成）并静态链接；
  无 zig 时 `HAS_ARCHOERA_KERNEL=OFF` 走 stub（EraAudio 全回退）。

### ⚠️ 构建顺序（陈旧产物坑）
改动 kernel 后必须：`zig build -Doptimize=ReleaseFast` → `cmake --build build`。
曾因链接到陈旧 `libarchoera_kernel.a` 出现「m4a AAC 段错误」假象（Debug 下 m4a open 也有
大栈帧问题，引擎请勿用 Debug kernel）。

## 2. EOF / 错误语义（已收敛）与输出一致性
### EOF 与错误语义（2026-09-05 收敛）
- **EOF 判定单一来源**：`src/pipeline.c native_process_chunk` 只以 `native_decoder_read` 返回
  0 帧为 EOF（此前把 `encoder_write_pcm` 成功返回 0 误判为 EOF → EraAudio 只输出 ~0.067s，
  已修；成功统一收敛为「已处理」）。含 resampler 缓冲 pending（out_samples==0 继续读）、
  tempo、末帧 flush、encoder flush、skip_encoder（player 模式）各路径复核均无早退。
- **错误 ≠ EOF**：`kernel/engine.zig zkRead` 此前把 `dec.read()` 的**任何错误吞成 0 返回**
  （`catch return 0`）→ 坏帧/损坏文件被静默截断为 EOF。现改为：EOF 仍是 `read` 返回 0 帧；
  解码错误经**负状态码**上报（返回值 = `-err.Status`：-3=Corrupt / -4=DecodeFailed / -8=IoError 等，
  与 `include/kernel_bridge.h` 的 `ZkStatus` 逐号对齐）。契约同步：`kernel_bridge.h` 注释、
  `kernel/kernel.zig` 导出（`zk_decoder_read` 返回 `long long`，<0 即错误）、
  `src/native_decoder.c`（`native_decoder_read` 透传负值）、`native_decoder.h` 语义注释。
  `pipeline.c` 对 `<0` 报「自研内核解码错误」并中止（批量模式 rc=3），不再静默短输出。
  注意：多数格式解码器对中途坏帧本身具备重同步/PLC（mp3 逐字节重同步、flac 帧 CRC 跳帧、
  opus 丢包隐藏），这些不构成错误，仍会继续解码到文件尾（与 FFmpeg 行为一致）；负值错误仅
  在解码器真正不可恢复时上报。
- **修复的静默截断实例 —— mp3/mp2 read 分块丢帧**：`kernel/fmt/mp3/lib.zig readImpl` 曾在
  输出缓冲（max_samples）不够容纳一整帧时**丢弃该帧尾部样本**（`avail<frames` 直接 break），
  输出随 read 分块大小变化：引擎每 chunk 读 2048 帧而 mp3 帧=1152 → 每块丢 256 样本，
  mp3/mp2 输出恒定偏短 **~11%**（big300.mp3 只出 ~267s / 300s）。修复：解码帧尾残余跨
  read 调用保留（`Ctx.tail` 缓冲，seek 时清空），解码样本数不再依赖分块大小，全流输出
  == ffmpeg 物理帧数（`zig build test` 565 全绿；mka mp3 golden 更新为与 ffmpeg 等长）。

### Stable vs EraAudio 输出长度（逐格式，2026-09-05 修复后）
解码样本数比对 = 内核 read 全量输出帧数（44.1k/48k 源域）vs FFmpeg `-f s16le` 参考（每声道），
见下表；Era 输出经同一 48k/2ch 重采样 + Opus 编码链后按 OGG 输出字节比对 Stable。

| 格式 | 解码样本数 vs Stable | Era OGG 输出 vs Stable | 结论 |
|---|---|---|---|
| flac / wv(pcm 轨) / wav / tta / mka(flac,pcm) | == | 逐字节一致（0B） | lossless PCM bit-exact，长度对齐 |
| m4a(AAC) | ==（13,230,000 @44.1k，含 elst/CodecDelay 语义） | 基本等长（同 packet 数/同 granule），字节差内容级：big300 −15B、nz +4B、big900 +15B | 非尾差/非采样差，见 §2.1 |
| ogg(vorbis) / opus | ==（5,760,000 @48k；pre-skip/末页 granule 修整一致） | 基本等长（同 packet/同 granule），字节差内容级：nz.opus −2B、x.opus −19B、big300.ogg −19B | 非尾差/非采样差，见 §2.1 |
| mp3 | == 物理帧数（= ffmpeg 全流）；big300 = 13,233,024 | 差 +3~4 Opus 帧（≈+2.5KB @300s） | 唯一残余：ffmpeg 消费 Xing/LAME gapless trim（delay+padding ≈3024 样本 @300s）而自研 mp3 尚未解析；**非截断**，见 §2.2 |
| mp2 | ==（88,704） | packet 数一致，字节差内容级（±~500B） | 长度对齐 |
| ac3 / ec3 / aac(.aac/.mka 内轨) | == | packet 数一致，字节差内容级 | 长度对齐 |

### 2.1 m4a(8B)/opus(2B) 尾差根因（定档：内容级，非长度级）
逐 OGG 页解析比对：m4a/opus/vorbis 的 Era 与 Stable 输出**packet 数与末页 granule 完全相同**，
即喂入 Opus 编码器的重采样样本数完全一致 → 不存在 priming/skip/gapless/尾帧丢弃差异
（CodecDelay/elst、pre-skip、末页 granule 语义均已与 FFmpeg 对齐）。OGG 总字节的少量差异
（nz.opus 实测 −2B、m4a ±~15B）来自**有损解码 PCM 非 bit-exact**：同一 bitstream 经两套
解码器（自研 vs FFmpeg）输出小幅不同样本（16bit 域 RMS 数百级，含 ±1~数 LSB 实现差），
再经同一 libopus 编码为不同包载荷/字节 → 少量字节差。属无损类（flac/wv/pcm）才可能逐字节
一致。**判定：无需对齐，如实定档为内容级差异**；长度（样本数）两边一致。
个别异常样本：`big.opus`(120s) 字节差 +35KB 属自研 opus 解码长期漂移的内容级现象（packet 数
仍相同），待专项核对；`x.ogg`(2s) −6KB 同理（内容级），非长度问题。

### 2.2 mp3 残余（如实定档，建议后续）
修复分块丢帧后 mp3 为**全物理帧解码**（无截断）；与 Stable 的输出样本数差 = ffmpeg 从
Xing/LAME 头读取的 encoder delay+padding gapless 修整（实测 big300.mp3 ≈3024 样本 ≈ +3~4
Opus 帧）。自研 mp3 目前只读 Xing/Info 的帧数，未消费 LAME/"Lavc" tag 的 delay/padding →
输出包含首端 encoder priming 与尾端 pad。对齐方式（后续项）：解析首帧 LAME/Lavc 的
delay(12bit)/padding(12bit)，起始跳 delay、末尾按 total−padding 截断。不做会造成音频错位的
整体前移。

## 3. 内存流式化（防 OOM）
- 普查：其余 fmt 均为流式；唯一整读是 `fmt/mka`。
- `fmt/mka` 已流式化：open 只扫 header/Info/Tracks（小）；read/seek 按 Cluster 有界读取
  （单块上限 32MB，用后即释放）；FLAC/PCM/Opus 走 callback 流式 feed（真流式）；
  AAC/AC3/EAC3/MP3/DTS/Vorbis 因内层解码器依赖整流/随机访问 → 有界整拼 + `spool_budget=256MB`
  超限返回 UnsupportedFormat（引擎回退 FFmpeg，杜绝真 OOM）。
- 实测（引擎 VmRSS 峰值，基座 ~34MB）：big300.mka(34MB)/big600.mka(68MB) 均 ~35MB → **不随文件线性增长**；
  改前 big300≈98MB、big600≈163MB（≈2×容器）。

## 4. 基准（tests/bench/，2026-09-05 EOF/错误语义修复后重跑）
- 最新产物：`tests/bench/data/BENCH_2026-09-05.csv` + 自动报告 `tests/bench/BENCH_2026-09-05.md`
  （`make_report.py` 生成）。
- 全格式矩阵 CPU×RT：Era native 全时长解码后首次可测（此前 EOF bug 使 native 秒退不可测）。
  代表性摘录（墙钟/源时长）：

| 文件 | 时长(s) | Stable×RT | Era×RT(native) |
|---|---|---|---|
| big300.m4a (AAC) | 300 | 0.0051 | 0.0059 |
| big300.ogg (vorbis) | 300 | 0.0052 | 0.0057 |
| big.opus | 120 | 0.0055 | 0.0064 |
| big300.mp3 | 300 | 0.0051 | 0.0056 |
| big300.flac | 300 | 0.0051 | 0.0218 |
| big600.mka (flac 轨) | 600 | 0.0050 | 0.0078 |
| big.wav (pcm) | 120 | 0.0051 | 0.0047 |

  结论：有损类与 mka 与 Stable 同量级（×RT 0.005–0.008，≈130–200× 实时）；
  直解 `.flac`（大/高熵内容）native 相对最慢 ×RT≈0.022（≈45× 实时，仍实时余量大），
  CPU 差异主要在自研 flac 帧解码器，待专项优化；pcm/wv 等无损 native ≤ Stable。
- RSS 平台值与趋势（重出，`BENCH_2026-09-05.md` §2/§3）：
  - **mka 流式平台值 ~35MB**（big300 35.5 / big600 35.2，不随体积涨）✓；
  - flac/wv/mp3/vorbis/opus/wav/tta/ac3/ec3 Era 恒定 ~34–36MB（流式，big900/74MB 不涨）；
  - m4a/AAC 固定高缓冲 ~51–61MB（非整读；aac_st/big300/big900 均 ~60MB 恒定，待裁 allocator
    保留区/缓冲复用）；x.mka(AAC 轨) ~51MB。

重跑命令：`zig build -Doptimize=ReleaseFast && cmake --build build && python3 tests/bench/run_bench.py --corpus /tmp/eng`
（`zig build test` 保持 565 全绿）。

## 5. 已知限制 / 待办
- mp3：gapless（LAME/Xing delay+padding）尚未消费 → Era 输出多含首端 priming/尾 pad
  （+3~4 Opus 帧 @300s；非截断）。对齐方案见 §2.2。mp3 内轨经 mka 已由容器层 CodecDelay/
  DiscardPadding 修整，输出 == ffmpeg。
- 直解 `.flac` native CPU×RT ≈0.022（重内容），显著慢于 Stable/同码流 mka 轨 → 专项优化点。
- 有损格式（AAC/Opus/Vorbis/MP3）解码 PCM 与 FFmpeg 非 bit-exact → OGG 输出存在内容级字节差
  （长度/样本数一致；flac/wv/pcm 等无损逐字节一致）。个别长样本（如 big.opus）内容级字节差
  较大，待专项核对自研 opus 长流漂移。
- m4a/AAC 固定 ~60MB 工作集、mka/其余 ~34–36MB 平台值：可后续裁 allocator 保留区/缓冲复用。
- native 路径若干 codec 仍需有界整拼（非整文件，256MB 预算）——真实超大 mka 内 AAC/AC3/DTS 会回退 FFmpeg。
- OGG/Opus 容器对损坏页的恢复目前按流尾处理（无声称错误、可能比 FFmpeg 早停）；不可恢复错误
  已走负状态码上报，但容器层坏页尚可加「跳页续扫」。EraAudio 仍标「实验性」。


## 6. 2026-09-05 收口
- **mp3/mp2 gapless 对齐**（fmt/mp3）：精确解析 Xing/Info + LAME/Lavc/Lavf 36B 扩展 delay/padding；
  内核 read 起丢 encoder_delay、尾截 padding，Xing 帧整体跳过。样本数 8 档与 ffmpeg 全一致
  （nz=5,292,000 / big300=13,230,000 / big900=39,690,000 等），corr≈1.0、max_abs≤1（±LSB）。
  引擎 OGG 长度由 ~+1–2.5KB 收敛到 ±40B（余为 ±1LSB→Opus/DSP 编码响应，非时长差）。574/574。
- **m4a/AAC 高水位裁剪**（fmt/m4a + fmt/aac）：根因=M4aCtx/Aac 整结构字面量物化 ~9MB 零常量整块拷贝 +
  open 期 1MB frame_buf 预分配 + SBR 缓冲全量初值。改：逐字段初始化（未用 union 留虚拟零页）、
  frame_buf on-demand、元素槽首用惰性零化、SBR 惰性 ensure/init。zk 层 AAC open/峰：~30MB→~10.5–12.4MB
  （-59~-65%）；引擎 Era m4a RSS 51–61MB→~40MB。L2 建议：ChannelState 重型缓冲按元素独立小分配，可将
  AAC 压到与流式一致。
- **Opus「长流漂移」定档为不存在**：600–960s（SILK/HYBRID/CELT、mono/stereo、多码率/多帧长/奇尾/任意
  chunk/任意 seek）mine 与 `libopus` 全程 ≥0.999、多数窗逐位一致；各 30s 窗 exact 恒定→无状态累积。
  系统 ffmpeg 默认 **native** opus 与 libopus 在低码率 SILK/HYBRID 白噪有**静态**差（mine 忠实 libopus）。
  **比对 Opus 请用 `ffmpeg -c:a libopus`。**
- **新增缺口（待办）**：fmt/ogg(opus/vorbis) open 未读尾页 granule → `duration_unknown`，引擎 Era 显示
  "时长 0.0s"（Stable=960s）——不影响样本/内容，仅播放器总时长/进度显示。修复=open 时 seek 读末页
  granule（reader 支持文件 seek）。


## 7. 2026-09-05 时长与内存二次收口
- **Ogg 家族时长**（fmt/ogg 新增 `scanTailPage` 共享原语，64KB 尾窗 + EOS 校验；callback 流降级）：
  Opus/Vorbis/Speex/Ogg-FLAC `duration_us` 精确化（Speex first_pts 语义对齐 oggparsespeex；Ogg-FLAC 在
  STREAMINFO total=0 时用 granule 补齐）。**Opus 取 granule（含 pre-skip）对齐 ffprobe/Stable 显示**；
  有效样本数仍由解码侧 pre_skip 消费（职责分离）。EraAudio 引擎日志时长不再 0.0s。
- **AAC L2**（fmt/aac + m4a 接线）：`Aac.che` 改 `?*Che` 按元素首用独立分配（`@sizeOf(Aac)` 8.35MB→57KB，
  断言锁定）；SBR `?*Sbr` 惰性；9 处槽位访问全守卫；deinit 幂等。zk 层 m4a RSS **12.2–12.6MB→4.5–5.1MB**；
  引擎 m4a **34.9–35.8MB**（≈opus 流式地板 +0.4–1.3MB）。输出逐位回归（nz/aac51/big900/HE/PS/5.1 hash 全等）。
- **全格式 duration 审查与修复**：adts/latm（跳帧计数 exact）、amr（ToC 扫描 exact，ffprobe 自身为码率估算
  且不准）、amrwb/dts/.dtshd（预解码总数/AUPR exact，dtshd 时长此前完全失效→现 exact）、wma 全族
  （asf play_duration−preroll，自洽性校验）、dsf（Data 区整块计，不信任谎报的 sample_count）、ape µs 舍入；
  ac3/eac3 bounded 前导外推 estimate（<0.2ms 偏差，不做全扫）；mlp/truehd/shn 裸流保持 unknown（格式本质）。
  wmapro/wmalossless 截断样本 mine=解码真值（ffprobe PTS 估算不可靠）。矩阵详见报告：
  wav/flac/mka/mp3/wv/ape/tta/tak/mpc/dsd=exact；adts/latm/amr/amrwb/dts/wma=exact；ac3/ec3=estimate；
  shn/mlp/truehd=unknown。
- **工具**：`kernel/info_dump.zig`（全链路 Info 打印，审查用）。
- 审查期间并行代理现象记录：并行代理曾报 engine Stable 段错误为**并发重链瞬时态**，收敛后 Stable 正常。


## 8. 2026-09-05 输出 sink 自动选择（PipeWire 蓝牙 HFP 无声修复）
- 现象：默认 sink = 蓝牙 HSP/HFP（16k/1ch，如 HUAWEI FreeLace Pro active profile=headset-head-unit）
  时，miniaudio(pulse) ma_device 可 init/start 但 data callback 饥饿（2.5s 仅 ~1800 帧 vs 内置 121500），
  Stable/EraAudio 均无声且可致卡顿（根因在输出设备，非解码内核）。
- 修复（v1 曾自动选“优质”sink，后经产品决策**撤回**——不应替用户改输出设备，用户可能不期望外放或就是要外放）：
  `src/player.c` `player_sink_select()` 现**只尊重选择**：env `ARCHOERA_AUDIO_SINK=<子串>` 显式路由；
  否则一律用系统默认，绝不自动切到其它 sink。默认设备为低质量/单声道（蓝牙 HFP 16k/1ch）时仅打印
  提示（建议把系统默认切到 A2DP/其它设备或用 env 指定），不擅改路由。
  ma_engine 经自建 pulse→alsa context + `pPlaybackDeviceID` 钉到选中 sink（`MA_PA_STREAM_DONT_MOVE`）；
  日志 `[player] sink=<名>(<id>) backend=… native=…hz/ch reason=…`；engine init 失败回退默认路径。
- 验证：默认内置→用默认；默认 BT-HFP→用默认（尊重选择，仅提示，不自动改道）；env=HUAWEI→显式路由到 HFP。
  播放语义不变。附：HFP sink 按其原生格式(s16/16k/1ch)可满速泵流，强上 f32/48k 才饥饿——若要让所选 HFP 也出声，
  需按设备原生格式适配（UI 输出设备选择为后续项）。


## 9. 2026-09-05 输出设备选择（UI）+ 蓝牙原生格式适配
- 原则：**只响应显式选择，绝不自动改道**。用户可：系统默认 / 指定 sink。
- 引擎：导出 `archoera_mediaengine_list_sinks(buf,cap)`（会话无关，JSON: id/name/rate/channels/default）；
  命令 `{"type":"set_sink","id":…}`（播放中平滑切换或下次启动生效）→ 事件 `sink_changed`；
  初始还可读 env `ARCHOERA_AUDIO_SINK`。原生适配：所选设备 native 为单声道/<44.1k（如蓝牙 HFP 16k/1ch）
  时以 native 开 ma_engine（16000hz/1ch），满速泵流（实测 1.00x 速率、sink-input 指向目标）；常规设备语义不变。
- Dart：prefs `audio.sink`；设置 playback「输出设备」（list_sinks 列「系统默认」+设备，rate/ch 副标题+默认徽章）；
  低质/HFP 行显示质量受限说明 + A2DP 引导（断开重连→切“音频/A2DP”→仍 Headset 则重配对）；l10n 11 key ×9。
- 验证：默认内置→正常；显式选 HFP→原生 16k/1ch 满速；`set_sink ""`回默认；env 启动生效；转码期提前 set 下次即用；
  CTest 4/4、`zig build test` 596/596；bundle 392MB（list_sinks 导出确认）。


## 9b. 输出设备音质策略（通话/HFP 门控）
- 认知：通话模式（HFP 16k mono）对音乐“几乎毁音质”，部分耳机可能故意不兼容/异常；音乐默认绝不该悄悄走通话/低质设备。
- 引擎 `list_sinks` 每项增加 `"class":"a2dp|hfp|low|hdmi|usb|internal|unknown"`（启发式：native<44.1k 或单声道且带蓝牙/headset 特征→hfp；蓝牙且≥44.1k/2ch→a2dp；余按名/特征）。
- Dart：按 class/规格分类 good vs call；call 行带“通话/低质”错误 chip；选中/系统默认=call 时**需显式确认**（危险文案：音质通话级、部分耳机故意不兼容）才应用，或一键“改用高质量输出”（用户显式动作，不自动改道）；系统默认=call 顶部非阻断 banner。
- 原则不变：绝不静默自动切设备；一切为用户显式动作。


## 10. 2026-09-05 FLAC 提速 + 流式起播 + 简约进度触摸
- FLAC 慢根因：`kernel/io.zig` `.file` 形态**逐字节 positional read**（每字节一次 syscall，200s 文件 ~2700 万次）。
  修复：.file 加 16KB 前瞻缓存（seek/peek 语义不变，不预读越界字节；其它格式通用受益）。收益：
  kernel 直解 46×→~345×（200s 16-bit 4.30s→0.58s；600s 32-bit 10.39→1.10s）；引擎整链 200s flac
  5.34s→1.35s（≈148×）；bit-exact 逐位（校验和一致）。596/596、ctest 4/4。
- 流式起播：不再“整段解码完才播”。raw ma_device + SPSC 无锁 ring（2.7s 容量，满则背压≈实时），
  pcm_out（EQ/响度/限幅/tempo 后）经 ring 喂设备；非 48k/2ch 目标（如 HFP 16k/1ch）用 swr 原生适配。
  CLI(--player-file)与 mediaengine FFI 均接入：首块 PCM 出声≈会话 30ms（旧路径要等全解码完成）；
  内容仍同步写 stream.wav/.pcm（SHA 与旧路径逐字节一致，Stable/EraAudio 双路径 PARITY）；seek=重建+跳转、
  暂停冻结、EOF 排空自然结束。旧文件播放路径保留作回退/`ARCHOERA_STREAM_DISABLE=1` 调试。
- 简约进度触摸：进度细条（hover 才显 Slider）对触摸无 hover → 完全不可 seek。修复：细条自身挂
  横向点按/拖动（触摸+鼠标），onChanged 跟随/onChangeEnd seek；点击跳转；命中区高 22→44px；
  不与竖直手势冲突；悬停/Slider 路径不变。


## 11. 2026-09-05 桌面风格菜单动效（去 Android 感）
- 新组件族 `lib/widgets/common/s_menu.dart`：`SMenu.show`（anchorRect 下拉 / position 右键）、`SMenuItem`
  （icon/leading/trailing/shortcut/checked/danger/submenu/section/divider）、`SMenuTrigger`、`SDropdownButton`。
- 动效：开=淡入+锚向 6px 位移+scale0.96→1，140ms easeOutCubic（缩放原点=锚边）；关=反向 100ms easeInCubic
  （overlay 动画完成才移除）；性能模式直切。样式：item 高 34、圆角 12、1px 描边、双层阴影、
  hover/键盘焦点高亮、暗色/accent 与 SDialog 同源。
- 行为：点外/Esc 关、↑↓ 循环+自动滚动、Enter/Space 激活、子菜单 hover 180ms/→ 展开；关闭后焦点归还触发源。
- 迁移 14 处调用点（PopupMenuButton×5、DropdownButton×3、右键门面委托×10 处共用）；**播放条播放列表与
  系统托盘保持原样**（托盘为原生 OS 菜单）。测试 `test/s_menu_test.dart`（5 项）全过；dart analyze 0 issue。


## 12. 2026-09-05 回退与修复
- **菜单动效回退**：SMenu 桌面菜单族因观感不如原版被用户否决 → 逆向迁移回 Material 原风格
  （PopupMenuButton/DropdownButton/原右键 SContextMenu overlay+InkWell/TweenAnimationBuilder），删除
  s_menu.dart/test；引擎选择/输出设备等新功能保留；播放条播放列表/托盘不动。
- **“播放全部”卡加载修复**：根因 = `_startSession` 以 `await engine.done` 为启动门槛，而**流式起播后 done
  只在曲尾到达** → load 整曲不返回、按钮 loading 不收敛、也无法切其它曲。改为新门槛 `engine.started`
  （ready 事件即完成；stop()/error 放行 pending），done 仅作 EOF 标记。新增会话启动门槛回归测试
  （playback_engine_session_gate_test 4 例）；引擎 destroy 中断 7ms，非引擎阻塞。
- **播放页“定位/回到顶部”按钮主题**：查证源码已 scheme 自适应（浅色深图标/浅底，对比度 5.6:1）；
  若用户见“切浅色仍深”，多半是**图片背景外观(appearanceStyle=image)强制暗色**或旧产物——需换标准主题/重编确认。


## 13. 2026-09-05 冷启动断点续播修复
- 引擎侧：Stable(FFmpeg)/EraAudio(native) 的 offset 续播本就正确（本地/HTTP、双引擎、流式下均验证，
  ~0.03s 精度）；无需改 C/zig。
- Dart 根因：`restore()` 先写“暂停展示态”落盘 → 磁盘 `playing=true@pos` 在引擎真正起播前被降级为
  `playing=false@pos`；续播成功会自愈，但最近 `started`(ready) 门槛让失败在就绪前就收敛，若该次续播
  失败则降级快照被永久保留 → 之后每次冷启动都不再自动续播。
- 修复：`_autoResumeInFlight` + `_retryableSnapshot` 保护——自动续播期间 `_persistSession` 遇 paused 一律
  写回“可续播”原快照，直到 EnginePlaying/Error/stop 等终态才解除；补尾部边界（pos==duration→从头）与
  dispose 期 `ref.read` 生命周期 bug。回归测试 playback_session_restore_test 4 例（ARCHOERA_DATA_DIR 隔离）。


## 14. 2026-09-05 引擎事件改事件驱动（去 50ms 轮询）
- 原：Dart 每 50ms Timer.periodic → pollEvent 轮询 FIFO。
- 改：C 导出 `archoera_mediaengine_wait_event(handle,buf,cap,timeout_ms)`（condvar 睡眠，非忙轮询；
  destroy 唤醒等待者；destroyed/waiters/drain 保证安全）；Dart 用独立接收 isolate 阻塞 wait_event(-1)，
  事件经 SendPort 回主 isolate 走原分发（串行不丢）；50ms Timer 移除。保留 poll_event 与
  `ARCHOERA_EVENT_POLL_FALLBACK=1` 回退；testHarness 不变。
- 验证：ready ~6–18ms 即时；空闲 CPU 0（无周期唤醒）；ctest 5/5（新增 wait 测试：阻塞/超时/销毁唤醒）；
  60s 本地曲 done 在曲尾实时到达、1200+ 事件无丢失；3 轮 start/stop 稳定；dart analyze 0；gate/session 12/12。
- 备注：online_playback_test（网络曲目）按旧“全速转码”假设等 engine.done 180s，流式语义下 done 需实时播到
  曲尾才达——该测试为语义/环境遗留（本地曲目验证正确），建议后续按流式语义重写。


## 15. 2026-09-05 其它轮询清理
- 盘点结果：内部高频忙轮询仅剩两处需去化——已处理：
  1) `pcm_uds` 5ms accept 轮询 → `poll(listen_fd)` 事件驱动（含单调时钟超时）。
  2) scraper 120ms Timer poll → 原生 `archoera_scraper_wait_event`（condvar/destroy 唤醒，同引擎契约）
     + Dart 接收 isolate 事件泵；终态后一次性 isDone 复查（非周期）；失败回退开关 ARCHOERA_SCRAPER_POLL_FALLBACK。
     验证：scraper ctest（入队/超时/销毁唤醒/空闲 CPU≈0）全过；scraper_pump_test 双模式过；dart analyze 0。
- 定性保留（非浪费/合理）：引擎流式 20ms 解码节拍（背压 pacing）；audio 事件泵 50ms 轮询仅作为 isolate
  握手失败回退；nav_header 天气业务周期刷新；网易云/酷狗登录 1–2s QR 状态查询（外部协议）；subsonic poll 为文档示例无周期调用者。


## 16. 2026-09-05 QQMusic 完整可播接入
- 参照新版上游 SPlayer-Dev/SPlayer-Next（/tmp/spx）QQ 实现，扩展 lib/apis/qqmusic：core 对齐（cookie/uin
  经 sessionStore 持久化、UA/comm 伪装、config android 伪装、credential/vip、qrlogin QQ/微信）、模块新增
  song_url(GetVkey 多音质/访客可播免费曲)、user_detail、login_qr、album/artist/comment；search 四分类等对齐。
- 新增 lib/services/qqmusic/qqmusic_api.dart（结果映射到 netease Track/Cover 层 + resolvePlayUrl + QR 登录/登出）。
- UI：搜索页 QQ 段（四分类+点播）、QQ 扫码登录对话框（QQ/微信）、顶栏账号菜单 QQ 登录/登出、歌单/专辑/歌手弹窗、
  QQ 歌词、playback 源解析/音质；l10n 9 语种。真实链路验证：搜索→免费曲访客直链 HTTP200 可播；VIP 按接口返回
  “需会员/无版权”语义；QQ 扫码出码。回归测试 qqmusic_direct_test 8 项。
- 诚实边界：不绕过付费；扫码 check_sig/微信 405 多跳需真机验证；榜单未接 QQ UI（首页榜单为 Kugou 专属）；
  QQ 下载需 Rust 引擎加源未做；红心收藏 QQ 无官方 like API 故隐藏；接口风控/限流需随上游单点修。


## 17. 2026-09-05 QQ 收藏(我喜欢) + 聚合搜索
- 红心：QQ 键=songmid（like_controller 新增 qqmusic 路由，修复“误走网易云”）；本地持久化 qq_liked.json；
  toggle 乐观+已登录实验在线收藏失败回滚本地；启动/登录/登出监听同步（在线并入 add-only）。「我喜欢」页新增 QQ 段。
- 在线实验收藏（社区逆向调研，标注来源/日期）：dir-201（“我的喜欢”）DissInfo 读取、AddSonglist/DelSonglist 红心，
  常量 kQqFavExperimental=true；未登录/缺 songid 抛可读错；不绕付费。需真机扫码登录验证在线往返。
- 聚合搜索：all=songs 三方（网易+酷狗+QQ）并行合并；albums/artists/playlists 亦三方聚合；CoverItem.source 角标；
  详情按 source 分发（QQ/网易云专辑·歌手·歌单均可开）。红心在 QQ 单平台与 all 均启用。
- 验证：dart analyze 0；qq_like_test 8 项过；bundle 393M。


## 18. 2026-09-05 QQ 搜索风控诊断与处理
- 根因：QQ 搜索失败为 **IP 级配额/风控 inner=2001**（HTTP200、request.code=2001、meta.is_filter=-12、间歇+分钟级配额），
  请求形态与 SPlayer-Next 零差异；旧代码自动重试 2 次→风暴加剧。
- 修复：风险码(2001)不自动重试；网络瞬时退避(300/600ms)；单发+20s 冷却+手动重试门禁（防连打）；
  聚合 all 逐源独立 try/catch——QQ 失败只横幅「{平台}暂不可用+详情+重试」，其它源照常；单 QQ 平台给可读内码文案。
  另修真实参数 bug：QQ 歌手搜索单页硬上限 30（其余 50）静默空结果——模块层夹紧 + 分页除数修正。
- 上游对照：SPlayer-Next 对非零码一律退避重试 2 次（不区分风控）、无聚合；MineRadio 一族为本地/可视化播放器无 QQ
  在线源（GitHub 检索 clone 需鉴权，未得代码，按其“分开获取+聚合、单源容错”理念本端实现）。
- 验证：dart analyze 0；新增 failure/state 测试 11 项（2001→risk 1 次、transient 重试、单源降级、冷却门禁）；bundle 393M。
- 策略：不硬猜/不绕付费；IP 仍 2001 时应用单发+可读提示；建议住宅/真机 IP 验证（形态与上游一致）。


## 19. 2026-09-05 流式 seek 卡死 / 断点续播失效（同根）修复
- 根因：内核 FLAC `seekToSample` 把 seekpoint.stream_offset 当**文件绝对偏移**；规范上它是**相对首个音频帧**的
  偏移。带大元数据（PICTURE/VORBIS_COMMENT，如用户 NETEASE flac audio_start≈449KB）时 seek 落进元数据 →
  decodeOneFrame Corrupt → native seek 返回 ZK_CORRUPT → offset 起播（断点续播=start_offset>0）会话永不 ready，
  播放中 seek 重建失败停播——②是①连带，唯一根因。Stable(FFmpeg) 路径不受影响。
- 修复：fmt/flac `seektableFrameStart`（规范相对偏移=audio_start+off+CRC 校验，兼容绝对偏移旧编码器，失败前向扫描重同步）；
  引擎 `mediaengine_stream_rebuild` 事务化（先建新管成功才停旧）、`mediaengine_stream_seek` 失败只回执不拖停、
  主循环“段循环+排空循环”使 EOF 尾段 seek 能续播新段；`pipeline` native seek 失败自动回退 FFmpeg；
  Dart `await engine.started` 加 30s 上限（超时按失败收敛）。
- 验证：zk ABI r=3→0（30/60/120/200s）；FFI 双引擎×多格式多次 seek/offset 起播全部即时；zig 597/597、ctest 6/6、
  dart analyze 0；新增 flac seektable 回归 + test_native_seek（无头）。注意：真机默认 sink 若漂到蓝牙 HFP 会饿死回调
  （与本次无关），验证可 ARCHOERA_AUDIO_SINK 钉内置。
