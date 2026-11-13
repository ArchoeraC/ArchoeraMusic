# tempo-rs 第三方许可证声明（audio-tempo）

本目录 `app/core/audio-engine/tempo-rs` 为音频引擎的变速变调静态库
（`crate-type = ["staticlib"]`，产物 `libaudio_tempo.a`），封装
**signalsmith-stretch**。自研胶水代码随本软件以 AGPL-3.0 授权，第三方 crate
均为 MIT / Apache-2.0 / BSD 系，与 AGPL-3.0 兼容。

## 运行时依赖

| 组件 | 版本 | 许可证 | 说明 |
|---|---|---|---|
| `signalsmith-stretch` | 0.1.3 | **MIT** | 变速变调核心（Signalsmith Audio） |
| `dasp` 系列（pitch/signal/…） | 0.11 | **MIT / Apache-2.0** | signalsmith-stretch 的音频样本/信号工具依赖 |
| `cc` / `libc` / `log` 等传递依赖 | — | **MIT / Apache-2.0** | 编译与平台抽象 |

## 构建期依赖

| 组件 | 许可证 | 说明 |
|---|---|---|
| `bindgen` / `clang-sys` / `syn` / `quote` / `regex` 等 | **Apache-2.0 / MIT / BSD-3-Clause** | 仅构建期生成 FFI 绑定，不进入静态库运行时 |

## 分发说明

- `libaudio_tempo.a` 静态链接进 `archoera-audio-engine` / `archoera_mediaengine`；
- MIT / Apache-2.0 允许静态合并与再分发，须保留版权与许可声明（随仓库及发布包
  `licenses/MIT.txt`、`licenses/Apache-2.0.txt` 分发）；
- 本表不构成法律意见。
