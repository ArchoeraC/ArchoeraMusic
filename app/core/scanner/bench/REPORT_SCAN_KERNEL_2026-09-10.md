# Scanner × 自研内核元数据桥 联动 Benchmark（2026-09-10）

> 语料：`/tmp/opencode/link_big`（多格式真实样本，425 文件）。scanner 直桥内核 `zk_metadata_*`（probe-only，无 JSON）vs 回退 TagLibSharp。
> 口径：墙钟 monotonic、CPU=user+sys（子进程合计）、峰值 RSS=VmHWM 轮询；每配置 3 轮取最快墙钟；核心 pin P 核。

## 1. 吞吐 / CPU / 内存（kernel vs TagLib）

| 并行度 | 引擎 | wall ms | files/s | CPU(s) | 峰值 RSS MB | tracks | rc |
|---|---|---|---|---|---|---|---|
| 1 | kernel | 238 | 1784.8 | 0.240 | 52.2 | 425 | 0 |
| 1 | taglib | 226 | 1880.2 | 0.229 | 51.8 | 425 | 0 |
| 4 | kernel | 212 | 2005.7 | 0.250 | 54.0 | 425 | 0 |
| 4 | taglib | 200 | 2126.3 | 0.235 | 53.7 | 425 | 0 |
| 8 | kernel | 199 | 2139.4 | 0.245 | 55.9 | 425 | 0 |
| 8 | taglib | 196 | 2166.1 | 0.244 | 55.5 | 425 | 0 |
| 16 | kernel | 200 | 2122.7 | 0.276 | 60.0 | 425 | 0 |
| 16 | taglib | 200 | 2121.1 | 0.268 | 59.9 | 425 | 0 |

## 2. 正确性对拍（kernel vs TagLib，codec/采样率/声道/位深/时长）

- 共同文件：425；字段不一致：**0**

## 3. 按格式覆盖（kernel 结果）

| 扩展名 | 数量 | codec |
|---|---|---|
| .ape | 25 | ape |
| .dff | 25 | dsd |
| .dsf | 25 | dsd |
| .flac | 50 | flac |
| .m4a | 25 | aac |
| .mka | 25 | aac |
| .mp3 | 25 | mp3 |
| .mpc | 25 | mpc7 |
| .ogg | 25 | vorbis |
| .opus | 25 | opus |
| .spx | 25 | speex |
| .tak | 25 | tak |
| .tta | 25 | tta |
| .wav | 25 | pcm_s16le |
| .wma | 25 | wmalossless |
| .wv | 25 | wavpack |

> 说明：小语料下进程启动/DB 写入占比较大；跨机比相对值。内核路径价值在统一解析（无 JSON）、低内存与共享内核，而非单纯吞吐。