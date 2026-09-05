# 音频格式覆盖缺口分析（vs FFmpeg）

> 2026-09-01（2026-09-03 刷新）· 对照系统 ffmpeg n9.0.1（`-decoders` 227 个音频解码器、`-demuxers` 368 个解复用器）
> 与自研内核 `app/core/audio-engine/kernel/fmt/*` 逐项比对。
> 目的：明确「还缺哪些常见/小众格式」，为内核渐进接管 FFmpeg 提供路线。
>
> **2026-09-03~04 刷新要点**：WMA 全族、DTS 全族、AMR-WB、AAC LATM、MKA 容器均已自研并接入，**常见格式解码缺口清零**；AMR-WB 位精确冲刺后 s16 全流 100% bit-exact。2026-09-04 又补 **Musepack SV8** 与 **TTA**（均 100% bit-exact）。剩余仅为小众圈、SV7 与低优残余。

---

## 1. 现状：已支持（自研/接入，可直接播放）

### 容器（demuxer）
| 容器 | 说明 |
|---|---|
| WAV / RF64 / W64 | PCM/float/G.711/ADPCM/GSM/MACE，`fmt/wav/` |
| AIFF / AIFC | 大端 PCM、sowt、ima4（ADPCM IMA QT）、GSM |
| FLAC | `fmt/flac/` |
| MP3 | ID3v2/v1、Xing/Info、APIC、ReplayGain，`fmt/mp3/` |
| MP4 / M4A | `fmt/m4a.zig`：ALAC + AAC（含 SBR/PS）轨 |
| ADTS / AAC | `fmt/adts.zig` |
| APE | `fmt/ape/` |
| WavPack (.wv) | `fmt/wv/` |
| OGG | Opus / Vorbis / FLAC，`fmt/ogg.zig` |
| DSF / DFF (DSD) | `fmt/dsd.zig` |
| AMR (.amr/.3gp) | `fmt/amr.zig` |
| AC-3 / E-AC-3 | `fmt/ac3/` |
| MLP / TrueHD | `fmt/mlp/` |

### 编解码（codec）
- **PCM 全系**：s8/u8、s16/u16、s24/u24、s32/u32、s64、f32、f64，大小端 + planar 变体
- **G.711**：alaw / mulaw
- **ADPCM**：IMA WAV (0x11)、MS ADPCM (2)、IMA QT (AIFC ima4)、OKI/Yamaha/CT、SANYO、SWF、XAN/ZORK DPCM
- **GSM**（WAV GSM_MS + AIFF 纯 GSM）、**MACE-3/6**
- **FLAC**、**ALAC**、**APE**、**WavPack**（全无损，bit-exact 验收）
- **MP1 / MP2 / MP3**（Layer I/II/III 全链）
- **AAC**：LC / HE-AAC v1 (SBR) / HE-AAC v2 (PS)——内容帧与参考构建 bit-exact
- **Opus**（自研 CELT/SILK）、**Vorbis**（stb_vorbis）、**DSD**（抽取→PCM）、**AMR-NB**、**AMR-WB**（G.722.2，全 9 mode，16000 Hz）
- **AC-3 / E-AC-3**、**MLP / TrueHD**
- **WMA**（wmav1/v2，ASF）——core 完成并接入（corr 1.0 / 99.9%+ bit-exact）
- **DTS core**（.dts/.dca）——定点解码，bitexact 对齐 ffmpeg 定点路径

---

## 2. 与 ffmpeg 的对比总览

ffmpeg 227 个音频解码器 / 368 个解复用器，我们已覆盖其中约 **45+ 个 codec + 16 个容器**（按 family 归并，含本轮 WMA/DTS/AMR-WB）。

### 2.1 常见主流格式——覆盖情况
| 格式 | 我们 | ffmpeg | 备注 |
|---|---|---|---|
| MP3 (incl. MP2/MP1) | ✅ | ✅ | Layer I/II/III |
| AAC / HE-AAC / HE-AAC v2 | ✅ | ✅ | 含 5.1/7.1 LC |
| FLAC | ✅ | ✅ | |
| ALAC | ✅ | ✅ | |
| WAV / AIFF | ✅ | ✅ | 含常见 ADPCM/GSM/MACE |
| OGG / Opus / Vorbis / FLAC | ✅ | ✅ | |
| APE (Monkey's) | ✅ | ✅ | |
| WavPack | ✅ | ✅ | |
| M4A / MP4 音频 | ✅ | ✅ | |
| DSD (DSF/DFF) | ✅ | ✅ | |
| AC-3 / E-AC-3 | ✅ | ✅ | |
| TrueHD / MLP | ✅ | ✅ | |
| AMR-NB | ✅ | ✅ | |
| **WMA 全族** | ✅ | ✅ | wmav1/2、wmapro（corr 1.0）、wmalossless（4/4 样本 100% bit-exact）、wmavoice（float corr≥0.9999），全部接入 |
| **Musepack** (mpc8) | ✅ | ✅ | **SV8** 自研（fmt/mpc：mpc8.c+mpc.c+mpegaudiodsp 定点逐句移植），FATE inside-mp8 全流 456 帧 **s16 100% bit-exact**（2026-09-04）；SV7（mpc7）未实现 → open 回退 FFmpeg |
| **DTS 全族**（core/XLL/X96/XCH/XXCH） | ✅ | ✅ | core+**DTS-HD MA(XLL)**+**DTS 96/24(X96)**+**XCH/XXCH(HRA)** 定点自研，与 ffmpeg `-bitexact` 定点逐字节一致；仅 LBR/DTS:X 未做 |
| **Speex** | ❌ | ✅ | 老 VoIP |
| **AMR-WB** | ✅ | ✅ | 全 9 mode 自研（.awb/3gp）；2026-09-04 位精确冲刺后 **s16 全流 100% bit-exact**（12k65+/23k85 f32 亦 100%） |

### 2.2 容器缺口（demuxer）
| 容器 | 对应格式 | 常见度 |
|---|---|---|
| **CAF / AU** (.caf / .au) | Apple Core Audio / Sun | 少见；**未压缩 PCM 已并入 fmt/wav 支持（2026-09-02，68/68 样本原生 100% bit-exact）** |
| **AU** (.au/.snd) | Sun/NeXT | 少见 |
| **OMA/AA3** | Sony 加密（含 ATRAC3） | 少见（Sony 录音笔/Walkman） |
| **VQF** | Yamaha TwinVQ | 极罕 |
| **VOC** | Creative 语音 | 复古 |
| **XWMA** | Xbox 360 WMA | 游戏 |
| **Tak / TTA / Shorten** | 无损压缩 | 小众无损圈 |
| **AST / VAG / SVAG** | PlayStation | 游戏 |
| **QOA / OSQ / WavArc** | 新无损 | 极新 |
| **SBC** | 蓝牙 A2DP | 系统级 |
| **AC-4** | Dolby AC-4 | 新版影视 |

### 2.3 编解码缺口——常见类
| codec | 说明 | 优先级 |
|---|---|---|
| ~~WMA 剩余族~~（wmapro/wmalossless/wmavoice） | ✅ 全部完成（2026-09-03）：wmapro corr 1.0/99.98%+；wmalossless 逐字节 bit-exact；wmavoice float corr≥0.9999 | - |
| **DTS**（dca，含 .dts 裸流 / DTS-HD） | 电影音轨 | **高**——core（.dts/.dca）已自研解码并接入（2026-09-02，定点路径逐位一致 ffmpeg）；DTS-HD(XLL/LBR) 待后续 |
| ~~AAC LATM~~（aac_latm/LOAS） | ✅ 已自研完成（2026-09-04）：fmt/latm.zig 传输层复用 AAC-LC 核心，corr 1.0 | - |
| ~~AMR-WB~~ | ✅ 已自研完成（2026-09-03，全 9 mode），见 §2.1 | - |
| **Speex** | VoIP 老文件 | 中 |
| **Musepack SV8** | 无损收藏圈 | 低 → **SV8 已自研完成（2026-09-04，bit-exact）**；SV7 仍缺（回退 FFmpeg） |
| **TTA / Tak / Shorten** | 小众无损 | 低 |
| **ATRAC3/plus** | Sony | 低（SONY 设备音频） |
| **RealAudio**（cook/sipr/ra_144/ra_288） | 老网络音频 | 低 |

### 2.4 编解码缺口——小众/游戏/专用类
ffmpeg 中我们未实现的其余 ~170 个 codec，按类归并：
- **ADPCM 变体 ~59 个**：adpcm_ima_*（acorn/amv/apc/apm/cunning/dk3/dk4/ea_*/hvqm/iss/magix/moflex/mtf/oki/pda/rad/smjpeg/ssi/ws/xbox…）、adpcm_ea_*、adpcm_adx（CRI）、adpcm_psx/xa/yamaha/thp/vima/zork/swf/sanyo/ct/mtaf/afc/agm/argo/circus/dtk/n64/psxc/sbpro_*…
  - 主要服务于游戏音轨（PS1/PS2/3DO/Saturn/DC/Wii 等），普通音乐文件几乎不出现。
  - **其中 WAV/AIFF 容器内常见的已覆盖**：IMA WAV、MS ADPCM、IMA QT、OKI、Yamaha、CT、SANYO、SWF、XAN、ZORK。
- **PCM 变体 ~15 个**：pcm_s24daud、pcm_lxf、pcm_vidc、pcm_sga、pcm_bluray、pcm_dvd、planar 变体、pcm_f16le/f24le 等——特殊容器/广播/家用机，普通音频不出现。
- **语音**：G.722/726/728/729、iLBC、QCELP、EVRC、Siren、MSNSiren、comfortnoise、truespeech、Nellymoser——电话/会议系统，音乐播放场景无。
- **游戏/专用**：BinkAudio、Smacker、AHX、XMA1/2、Interplay ACM、S302M、DFPWM、Dolby E、MISC4、VMD、FastAudio、Wavesynth、8SVX、HCOM、DSS_SP、BMV 等——游戏/采集/广播专用。
- **其他小众有损**：TwinVQ、QDM2/QDMC（老 RealAudio/MP3Pro）、On2AVC（老 VP 音频）、IMC、HCA（Criware 游戏）、Metasound、Cook、RALF、RKA、ACELP.Kelvin、ALAC?（我们有）、ALS（MPEG-4 无损）、MP3on4/MP3ADU（广播复用）、APT-X/SBC（蓝牙）。

---

## 3. 建议优先级（2026-09-03 刷新：WMA core / DTS core / AMR-WB 均已自研完成）

### P0（真实播放会遇到的常见缺口）
1. ~~DTS-HD MA / DTS:X~~——✅ **已完成（2026-09-03）**：XLL（DTS-HD MA，5.1/7.1，48k/192k）+ X96（DTS 96/24）+ XCH/XXCH（HRA 6.1/7.1 EXSS）生产路径已接入，FATE dcadec-suite 样本与 ffmpeg `-bitexact` 定点**逐字节 0 差异**；仅剩 LBR / DTS:X 对象 / CSS-XXCH（无样本）未做。
2. ~~WMA 剩余族~~（wmapro/wmalossless/wmavoice）——✅ **已完成（2026-09-03）**：wmapro（FATE Beethoven 2ch / latin 5.1，corr 1.0、bit-exact 99.98–99.999%）、wmalossless（FATE luckynight/g2/master/Mega，4/4 样本逐字节 bit-exact）、wmavoice（CBR-7K/11K/19K，float corr≥0.99992）。ASF codec_tag 0x162/0x163/0x000A 分发接入。
3. ~~AAC LATM~~（`aac_latm`/LOAS 传输复用层）——✅ **已完成（2026-09-04）**：`fmt/latm.zig`（LOAS sync `0x56E000` 探测、StreamMuxConfig/PayloadLengthInfo/255 续传、ASC 复用内核解析），复用 AAC-LC 核心；自造 8 样本（mono/stereo/5.1/7.1/16k~96k，含 SMC 重复帧与变长子帧）corr=1.0、bit-exact ≥99.98%（余为 AAC 内核固有末位舍入）；HE-AAC/SBR 路径同 ADTS 未实测。

### P1（可遇可不遇）
- **Musepack SV7**（mpc SV7 解码未实现；**SV8 已完成 bit-exact**，回退路径见 §2.1）、**TTA / TAK / Shorten**（小众无损圈）、**Speex**（.spx 老 VoIP）
- **ATRAC3/plus**（.oma/.aa3，Sony）、**RealAudio**（cook/sipr/ra_144/ra_288，老 .ra/.rm）、**MPEG-4 ALS**（m4a 内无损轨，极罕）
- **CAF/AU 压缩轨**：未压缩 PCM 已并入 fmt/wav（2026-09-02 全样本 bit-exact）；容器内压缩 codec 场景少见。

### P2（游戏/专用，建议 FFmpeg 兜底）
- ADPCM 变体（除已覆盖的 WAV/AIFF 常见款）、ATRAC、RealAudio、TwinVQ、HCA、XMA、BinkAudio 等——普通音乐库几乎不会出现，保持 FFmpeg 回退即可。

---

## 4. 结论

> **2026-09-04 补充——支持面三层审计**（详见配套 `format-support-matrix.md`）：
> 本文件此前以「自研解码（内核）」单视角评估缺口，实际用户可感知支持由三层决定——
> **L1 内核 fmt（自研解码） / L2 生产引擎（FFmpeg 兜底，全量可播） / L3 曲库扫描（C# 白名单
> 16 扩展 + TagLibSharp 2.3.0 元数据）**。审计发现：内核已实现的 `.wma/.dts/.ac3/.mlp/.amr/.awb/.latm/.caf/.au/.w64/.mp2` 等扩展
> **均不在 L3 白名单** → 用户曲库不可见（隐性缺口）；`.mka` 为唯一「TagLib 可提元数据 + 容器内
> codec 内核全已实现」的高杠杆容器缺口。
> **已定路线（2026-09-04）**：① 内核补 MKA 容器层；② 白名单加安全集（.wma/.asf、.mp2/.mp1、
> .mka、.aifc——TagLib 实测支持者）；③ dts/ac3/mlp/amr/latm/caf 等 TagLib 无元数据格式的
> 「内核 Info 兜底」列为产品决策项；④ 旧版参考价值格式排序见矩阵 §4。

- **C# 扫描器基线 16 种扩展名已 100% 覆盖**（mp3/flac/ogg/opus/oga/m4a/aac/wav/ape/wv/dsf/dsd/dff/mp4/aiff/aif）。
- **2026-09-02~03 已消灭全部最常见缺口**：WMA 全族、DTS 全族、AMR-WB、CAF/AU(PCM) 均已自研接入。
- **常见格式解码缺口已清零**（2026-09-04）：WMA 全族 / DTS 全族 / AMR-WB / AAC LATM 全部自研接入；
  **内核→曲库可见面仍有缺口**（L3 白名单 16 扩展 + TagLib 限制），见配套支持矩阵。
- 低优残余按 §3.2/P2 维持 FFmpeg 兜底；全部解码器均有嵌入式 golden 回归，`zig build test` 全绿。
- **2026-09-04 终验更新**：MPEG-4 **ALS**（fmt/als，m4a 委托，fate conformance 00-05+09 全 **bit-exact** 含 512ch）、
  LBR 多声道（修 3 真实 bug + no-asm 参考锚定参数/掩码对拍）、DST 多声道单测覆盖（官方无多声道真实样本）完成。
- **2026-09-04 终验更新**：MP4 容器 codec（FLAC/Opus/AC3/EAC3/MP3-in-m4a）、DST（DFF-DST）、TAK 全部自研接入
  （TAK/MP4-FLAC/DST 逐位或高 corr）；白名单补 .m4b/.webm。自研版图至此对 ffmpeg 常见格式**无缺口**；
  剩 ALS 极罕 + 游戏/语音族按 P2 维持 FFmpeg 兜底，另 wmavoice 为 AVX2 天花板。
- **2026-09-04 更新（终版）**：MKA 容器（含内嵌 Vorbis / DTS-HD MA·XBR·XXCH）、Musepack SV8+SV7、TTA、Ogg-Speex（NB/WB/UWB/VBR）、Shorten、DTS XBR/LBR/DTS:X 全部自研接入；除 stb_vorbis 的 ±1 LSB 与 wmavoice AVX2 天花板外均 **100% bit-exact**；wmavoice 对齐 reference no-asm 后 f32 逐位 100%（vs 系统 = SIMD 天花板 32–40% f32 / 99.3–99.9% s16）。C# 白名单已扩容安全集（.wma/.mka/.mpc/.mpp/.mp+/.mp2/.aifc）。全格式状态见 `format-support-matrix.md`。
- 其余 ~170 个 ffmpeg codec 为游戏/广播/语音专用，普通音乐播放场景建议维持 FFmpeg 兜底，不值得自研。
