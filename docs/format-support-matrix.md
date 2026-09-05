# 音频格式支持矩阵（三维）

> 2026-09-04 · 全面盘点自研内核 / 生产引擎 / 曲库扫描三层对格式的支持现状。
> 元数据列由 **TagLibSharp 2.3.0（scanner 实际引用版本）实测**：对真实或 ffmpeg 自造样本执行
> `TagLib.File.Create` 探测（见 `format-gap-analysis.md` 历史与下方测量方法）。
> 内核列对应 `app/core/audio-engine/kernel/fmt/*`（自研解码，`zig build test` 现 434/434 绿）。

## 1. 三维支持模型（务必区分）

| 层 | 载体 | 决定 | 状态 |
|---|---|---|---|
| **L1 内核自研解码** | `kernel/fmt/*`（Zig，434 单测全绿） | 该格式**能否脱离 FFmpeg 解码** | 常见格式已全覆盖（见 §2 内核列 ✅） |
| **L2 生产引擎** | `app/core/audio-engine`（C/CMake） | 播放时实际解码器 | 以 **FFmpeg 兜底**为主（`avformat/avcodec` 全量），内核逐步接管 |
| **L3 曲库扫描** | `app/core/scanner`（C#）`ScannerEngine.cs` `AudioExt` 白名单 **16 种** + TagLibSharp 提元数据 | 文件**能否入库显示** | 白名单 = mp3 flac ogg opus oga m4a aac wav ape wv dsf dsd dff mp4 aiff aif |

**推论**：某格式「能播」≠「能被收藏」。文件即使 L1/L2 都能解，只要扩展名不在 L3 白名单，
scanner 直接忽略，用户曲库不显示。内核已实现但白名单缺的扩展 = 本轮最大隐性缺口。

## 2. 全格式矩阵

图例：内核 fmt = 是否自研实现（格式级）；白名单 = C# `AudioExt`；TagLib = TagLibSharp 2.3.0 实测能否提时长/属性；✅=支持，❌=不支持，—=未实现/未测。
「路径」= 落库建议（见 §3）。

| 扩展 / 格式 | 内核 fmt（自研） | 引擎 FFmpeg | L3 白名单 | TagLib 实测 | 备注 / 落库建议 |
|---|---|---|---|---|---|
| mp3 / mp2 / mp1 | ✅（Layer I/II/III） | ✅ | mp3 在，**mp2/mp1 不在** | mp3 OK、**mp2 OK（MPEG L2）**、mp1 按同族可解 | 加 mp2（+mp1）进白名单，TagLib 可直提 |
| flac | ✅ | ✅ | ✅ | OK | — |
| ogg / oga | ✅（Opus/Vorbis/FLAC） | ✅ | ✅（ogg/oga） | OK（vorbis/opus） | ogg 内 Speex 轨未实现（见 §4） |
| opus | ✅ | ✅ | ✅ | OK | — |
| m4a / mp4 | ✅（ALAC+AAC+SBR/PS） | ✅ | ✅ | OK | — |
| aac（ADTS 裸流） | ✅ | ✅ | ✅ | **OK** | — |
| latm / loas | ✅（fmt/latm.zig） | ✅ | ❌ | **UNSUP** | 广播少见；TagLib 无元数据 → 不入库或内核兜底 |
| wav / rf64 / w64 | ✅（PCM/G.711/ADPCM/GSM/MACE） | ✅ | wav 在，**w64/rf64 不在** | wav OK、**w64 UNSUP** | w64 需内核 Info 兜底才可入库 |
| aiff / aif / aifc | ✅（含 ima4/GSM） | ✅ | aiff/aif 在，**aifc 不在** | aiff OK | aifc 少见；建议补白名单 |
| caf | ✅（未压缩 PCM 已并入 fmt/wav） | ✅ | ❌ | **UNSUP** | 压缩轨少见；未压缩 PCM 内核可播但 TagLib 无 → 内核兜底候选 |
| au / snd | ✅（未压缩并入 fmt/wav） | ✅ | ❌ | **UNSUP** | 同上 |
| ape | ✅（bit-exact） | ✅ | ✅ | 未测（TagLib 支持） | — |
| wv（WavPack） | ✅（bit-exact） | ✅ | ✅ | 未测（TagLib 支持） | `.wvc` companion 需与 .wv 同读（非独立轨道） |
| dsf / dsd / dff | ✅（DSD→PCM） | ✅ | ✅ | dsf OK、dff 未测 | — |
| asf / **wma**（wmav1/v2/pro/lossless/voice） | ✅（全族） | ✅ | ✅（wma，2026-09-04） | **wma OK（含 speech/lossless/multichannel）** | 已入白名单（.asf 未入） |
| dts / dca / dtshd（core/XLL/X96/XCH/XXCH） | ✅（bit-exact 定点） | ✅ | ❌ | **UNSUP** | 电影音轨；TagLib 无元数据 → 需内核 Info 兜底（决策项） |
| ac3 / eac3（.ac3/.ec3） | ✅ | ✅ | ❌ | **UNSUP** | 同上 |
| mlp / thd / truehd | ✅ | ✅ | ❌ | 未测（预期 UNSUP） | 同上 |
| amr / 3gp(amr) | ✅（vendored OpenCORE） | ✅ | ❌ | **amr UNSUP** | 语音录音；决策项 |
| amrwb / awb | ✅（全 9 mode） | ✅ | ❌ | raw UNSUP（3gp/mp4 包装需另测） | 决策项 |
| **mka**（Matroska 纯音频） | ✅（fmt/mka，2026-09-04） | ✅ | ✅（2026-09-04） | **mka OK（AAC/AC3/Opus 内轨均可提时长）** | 容器+白名单完成 |
| mpc / mpp / mp+（Musepack SV7/8） | ✅ SV8+SV7 均 bit-exact（fmt/mpc） | ✅ | ✅（2026-09-04） | **mpc OK（SV7/SV8 实测）** | 全部完成（2026-09-04） |
| tta（TrueAudio） | ✅（fmt/tta，bps 8/16/24、mono/stereo，100% bit-exact） | ✅ | ❌ | **UNSUP（实测）** | 内核已接入；不入库（待 Info 兜底） |
| spx（Ogg-Speex） | ✅（fmt/spx，NB/WB/UWB/VBR，100% bit-exact） | ✅ | ❌ | **UNSUP（实测）** | 内核已接入（2026-09-04）；不入库（待 Info 兜底） |
| **mka 内 Vorbis** | ✅（Ogg 合成复用 stb_vorbis，容器层 0 差异；codec 层 ±1 LSB 既有） | ✅ | ✅（随 mka） | mka OK | 2026-09-04 接入 |
| **mka 内 DTS-HD MA/XBR/XXCH** | ✅（合成 .dtshd 容器复用 fmt/dts 全管线；XLL/XBR+XXCH 均逐位） | ✅ | ✅（随 mka） | mka OK | 2026-09-04 接入 |
| **DTS XBR / LBR（DTS Express）/ DTS:X** | ✅ XBR bit-exact；✅ LBR 已移植（子组件与 FFmpeg C 逐位，无公开真实样本）；DTS:X 对齐 ffmpeg（解 MA 部分+profile 标注，对象渲染同 ffmpeg 不做） | ✅ | — | — | 2026-09-04 补齐 |
| shn（Shorten） | ✅（fmt/shn，bit-exact，v0/v1/v2 U8/S16） | ✅ | ❌ | **UNSUP（实测）** | 内核已接入（2026-09-04）；不入库（待 Info 兜底） |
| ofr（OptimFROG） | ❌ | ✅ | ❌ | 未测 | 极罕见 |
| ra / rm（RealAudio cook/sipr/atrc/ra144/288） | ❌ | ✅ | ❌ | 未测 | 老网络音频；维持 FFmpeg 兜底 |
| oma / aa3 / at3（ATRAC） | ❌ | ✅ | ❌ | 未测 | Sony 设备音频；兜底 |
| vqf（TwinVQ） | ❌ | ✅ | ❌ | 未测 | 极罕；兜底 |
| aax / aa（Audible DRM） | ❌ | ⚠️（DRM 多不可） | ❌ | — | 受 DRM 保护，超出解码范畴 |
| mod/xm/s3m/it（tracker） | ❌ | ✅ | ❌ | 未测 | chiptune；与音乐曲库定位不同，维持兜底 |
| mid/kar/rmi（MIDI） | ❌（需合成器渲染） | ✅（部分） | ❌ | — | 非音频文件解码，一般不作为曲目 |
| xwma / xma1/2、hca、bink、playstation 等游戏音轨 | ❌ | ✅ | ❌ | — | 游戏专用；P2 维持 FFmpeg 兜底 |

## 3. 决策记录（2026-09-04）

1. **P0 内核层：补 MKA（Matroska）纯音频容器解复用**。收益最高——容器内 AAC / AC3 / DTS /
   FLAC / Opus / WavPack / TrueHD 等 codec 内核已全部自研，只缺容器层把轨道解出来；
   且 TagLib 实测对 mka（内 AAC/AC3/Opus）可提元数据 → 白名单可安全加入 `.mka`，用户文件
   「既能入库也能自研解码」一步到位。
2. **L3 白名单扩容（✅ 已完成 2026-09-04）**：`ScannerEngine.AudioExt` 加入内核可解 **且
   TagLib 实测支持** 的扩展：`.wma`、`.mka`、`.mpc`/`.mpp`/`.mp+`、`.mp2`、`.aifc`
   （scanner `dotnet build` 0 错误）。实测 **TagLib UNSUP 而未入者**：`.tta`、`.mp1`、`.asf`、
   `.caf`、`.w64`、`.dts/.dtshd/.dca`、`.ac3/.ec3`、`.mlp/.thd`、`.amr/.awb`、`.latm`。
3. **元数据兜底（决策项，需产品确认）**：dts/dtshd、ac3/ec3、mlp/thd、amr/awb、latm、
   au/caf/w64 等 TagLib 无元数据、但内核能解的裸流/影视音轨，若要在曲库可见，需在 scanner
   增加「内核 Info 兜底」（调用 audio-engine/kernel 的 probe→Info 取时长/位深，替代 TagLib），
   否则保持不进曲库（文件仍可经文件系统直接播放）。优先级取决于产品是否把「电影音轨/录音」当曲目。
4. 低优残余（L1 内核）：DTS LBR/DTS:X、AMR-WB 6k60 1-f32-ulp、wmavoice 逐函数浮点对拍等，按
   `format-gap-analysis.md` §3/P2 处理。

## 4. 旧版 / 小众格式「参考价值」清单（下一批内核实现候选）

按「接入价值 × 常见度」建议排序（均需自造/收集真实样本后启动；每项独立子代理）：

| 优先 | 格式 | 价值 / 说明 | 对应 ffmpeg 参考 |
|---|---|---|---|
| ~~P1~~ **Musepack（.mpc/.mpp，SV7/SV8）** | SV8 已接入（2026-09-04，fmt/mpc，100% bit-exact）；SV7 待做 | `mpc8.c`（已完成）/ `mpc7.c`（待） |
| ~~P1~~ **TTA（.tta）** | 已接入（2026-09-04，fmt/tta，bps 8/16/24，100% bit-exact） | `tta.c`（已完成） |
| P2 | **Ogg-Speex（.spx）** | 老 VoIP；复用 ogg 解复用 + 新增 Speex 子解码 | `speexdec.c`、`celt`/`speex` 表 |
| P2 | **Shorten（.shn）** | 2000 年代无损老物 | `shorten.c` |
| P2 | **MPEG-1 裸流 mp1/mp2 落库** | 内核已可解，补白名单即可（非内核工作） | — |
| P3 | OptimFROG / TAK / .ofr / realaudio cook | 极罕见/老旧，维持 FFmpeg 兜底即可，暂缓 | — |
| P3 | MIDI / tracker / 游戏音轨 | 定位外（非压缩音频解码），维持 FFmpeg 兜底 | — |

## 5. 测量方法与可复现性

- TagLib 矩阵：`dotnet` 控制台引 `TagLibSharp 2.3.0`，对样本执行 `TagLib.File.Create`；
  样本 = ffmpeg n9.0.1 自造（sine 2.5s，覆盖 wav/aiff/mp3/mp2/flac/m4a/aac/ogg/opus/ac3/eac3/latm/
  caf/au/w64/mka(mp4a/ac3/opus)）+ FATE 真实样本（wma 四变体、dtshd 七样本、dsf）。
- 内核支持列以 `kernel/probe.zig` `Format`/`formats` 开关与 `zig build test`（434/434）为准；
  验证级别见各 `fmt/*` 单测（bit-exact / corr golden）。
- 该文档与 `format-gap-analysis.md` 配套阅读：本文是「当前支持面快照」，后者是「缺口演化记录」。

---

## 6. 终审（2026-09-04 重比对，ffmpeg n9.0.1 227 个音频解码器 vs 内核）

常见格式已无缺口。剩余分三类：

**A. L1 内核 codec 缺口（已于 2026-09-04 终验全部关闭）**

> 终验后（2026-09-04 晚）：LBR/DST 多声道——官方无真实样本（DTS Express 无公开样例；
> SACD 5.1 为商业内容）。已修 3 处真实 LBR bug（采样率表改用 dca 表、长窗抽取位移、>5 声道掩码越界）
> 并加多声道参数/掩码/排列对拍（no-asm 参考 C 锚定）；DST 补 6 声道/边界单测。LBR/DST 真实多声道内容端到端仍待样本。
1. ✅ **MP4 容器 codec 面**：`fmt/m4a.zig` 扩展 FLAC(bit-exact)/Opus(±1 LSB)/AC-3/E-AC-3(高 corr)/MP3('.mp3')，elst priming/seek 对齐 ffmpeg。
2. ✅ **DST**：`fmt/dst/`（dstdec.c 移植）接 DFF-DST（DSD64 2ch FATE 样本：DST→DSD→dsd2pcm 与 ffmpeg f32 逐位一致）。
3. ✅ **TAK**：`fmt/tak/`（takdec.c 移植）FATE luckynight **100% bit-exact**（修复 FIR code_size 作用域 + 多余 residue 写回两处）。
4. ✅ **ALS**（MPEG-4 无损，mp4 `mp4als`）：`fmt/als/`（alsdec.c+bgmc.c 移植，含 RA/LTP/块切换/JS/mcc/BGMC），
   FATE conformance 00-05(2ch48k16b) + 09(**512ch**) 全样本与 ffmpeg **100% bit-exact**；m4a 委托接入。
4. 维持 FFmpeg 兜底（P2，不值自研）：RealAudio(cook/sipr/ra144/288)、ATRAC1/3/plus/9、TwinVQ/QDM2、
   HCA/XMA/Bink（游戏）、APTX/SBC（蓝牙）、语音族(G.722-729/iLBC/QCELP/EVRC/Nellymoser/…)、游戏 ADPCM 变体。
   注：`aac_fixed/ac3_fixed/mp3float/libopus/libvorbis` 等为 ffmpeg 内部别名/双实现，非独立格式。

**B. L3 白名单/曲库快赢（✅ 已完成 2026-09-04）**
- `ScannerEngine.AudioExt` 已加 `.m4b`、`.webm`（TagLib 实测可提时长；`.weba` TagLib 不映射故未加）。

**C. 产品决策项（未实施）**
- 「内核 Info 兜底」：tta/spx/shn/dts/dtshd/ac3/ec3/mlp/thd/amr/awb/latm/caf/au/w64 等内核可解但
  TagLib 无元数据的格式，若要进曲库需 scanner 接内核 probe→Info（时长/位深）；否则保持「文件系统直放、
  不入库」。
