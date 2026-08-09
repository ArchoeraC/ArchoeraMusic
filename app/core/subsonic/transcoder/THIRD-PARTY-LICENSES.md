# Subsonic 转码器第三方许可证声明（subsonic-transcoder）

本目录 `server/subsonic/subsonic-transcoder` 为 SPlayer-Next 的服务端 Rust 转码器，
随本软件以 AGPL-3.0 授权。其将音频解码为 PCM 后以 **LAME** 编码为 MP3。

## 直接 Rust 依赖

| 组件 | 版本 | 许可证 | 说明 |
|---|---|---|---|
| `symphonia` | 0.5 | **MPL-2.0** | 纯 Rust 媒体容器与音频解码库（weak copyleft，文件级） |
| `mp3lame-encoder` | 0.2 | **LGPL-3.0** | LAME 编码器高级绑定 |
| `mp3lame-sys`（传递） | — | **LGPL-3.0** | LAME 的 FFI 绑定，将 LAME 以静态库形式编译链接 |
| `anyhow` | 1 | MIT | 错误处理 |
| `clap` | 4 | MIT / Apache-2.0 | 命令行解析 |

## LAME 静态链接特别声明（LGPL-2.1+）

本二进制通过 `mp3lame-sys` 将 **LAME（LGPL-2.1 或更高版本）** 的源代码
编译为静态库（`libmp3lame.a`）并直接链接进 `subsonic-transcoder` 可执行文件。
依据 LGPL-2.1 第 6 条（静态链接情形），该可执行文件被视为对 LAME 库的修改作品，
使用者享有以下权利：

1. 获得 LAME 对应源代码的自由；
2. 使用修改后的 LAME 重新链接、替换该二进制中 LAME 部分的自由。

### LAME 源代码获取

- LAME 项目主页：https://lame.sourceforge.io/
- LAME 源代码与许可证：https://sourceforge.net/projects/lame/

本软件构建时所采用的 LAME 版本由 `mp3lame-sys` crate 决定，
其随 Cargo 依赖图锁定，可在对应构建环境中经 `cargo tree` 复现。

### 可重链目标文件

为满足 LGPL-2.1 第 6(b) 条「提供可与之重新链接的目标文件」要求，
本软件在公开发布仓库中提供 `subsonic-transcoder` 的完整 Rust 源码与构建脚本，
使用者可自行取得 LAME 对应版本源码后重新执行构建以完成替换/重链。

## MPL-2.0 说明

`symphonia` 以 MPL-2.0（文件级 weak copyleft）发布。
对其任一被修改源文件的更改，须按 MPL-2.0 以相同许可证公开；
其余文件不受传染。其完整许可证文本见 https://www.mozilla.org/MPL/2.0/。

## 许可兼容性结论

MPL-2.0 与 LGPL 均为与 AGPL-3.0 兼容的 weak copyleft 许可证，
本组合作为 AGPL-3.0 受保护作品的一部分分发，合规。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
