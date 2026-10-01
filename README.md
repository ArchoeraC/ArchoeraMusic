<p align="center">
  <img src="logo.png" width="128" height="128" alt="ArchoeraMusic">
</p>

# ArchoeraMusic

> 开源、多端、面向本地与在线音乐的混合架构播放器

<p align="center">
  <img src="screenshot.png" width="720" alt="ArchoeraMusic 主界面">
</p>

---

ArchoeraMusic 是一个开源的**多平台音乐播放器**，桌面为主（Linux / Windows / macOS），UI 层采用 Flutter，重型处理由多语言原生模块（C / C# / C++ / Rust / Go）经 FFI 进程内直连，无 Node 进程、无本地监听端口。

- 连接**网易云音乐 / 酷狗音乐 / QQ 音乐**等在线服务（另含实验性第三方音源，默认关闭）
- 本地音乐库扫描与元数据刮削、多平台下载
- 内置统一 C 音频引擎：EQ / 响度归一化 / 限幅器 / FFT 频谱 / 变速变调 / Opus 转码管线
- 可选 Subsonic 兼容服务端，并支持 Subsonic / Jellyfin 流媒体服务器聚合

> 本项目自研代码以 **AGPL-3.0-or-later** 开源（认可开源商业化，不提供闭源商业授权）。
> 授权边界见 [docs/licensing.md](docs/licensing.md)，用户可读声明见 [docs/software-declaration.md](docs/software-declaration.md)。

## 快速开始

> 完整的自编译手册（三端环境 / 逐模块构建 / 调试 / 打包 / 常见问题）见 **[docs/user-build-from-source.md](docs/user-build-from-source.md)**；三端打包由 [CI workflows](.github/workflows) 提供。

```bash
git clone https://github.com/BetaStudio2/ArchoeraMusic.git
cd ArchoeraMusic

# 编译模块：Linux/macOS 逐模块，Windows 用 app/core/build_windows.bat（详见上述手册）
cd app
flutter pub get
flutter run -d linux      # 或 windows / macos
```

## 文档

- [架构设计](docs/architecture.md) —— 进程模型 / 音频管线 / FFI 桥接 / 目录结构
- [用户自编译手册](docs/user-build-from-source.md) —— 三端从源码构建 / 调试 / 打包 / 缓存外置 / 常见问题
- [本地曲库：扫描与刮削](docs/local-library.md) —— 音乐库扫描 / 元数据刮削 / 目录整理
- [平台能力外观层](docs/platform-capability-facade.md) —— 防休眠 / 媒体会话 / 系统定位的能力接口
- [下载模块设计规范](docs/download-module.md) —— 下载引擎架构 / 依赖许可
- [解码基准（EraAudio vs FFmpeg）](docs/benchmark-2026-09-21.md) —— 出厂最小 FFmpeg 基线 + 多轮稳定性
- [音频 Zig 解码内核路线图](docs/audio-kernel-zig.md) —— 内核架构 / 第三方来源登记
- [许可与授权](docs/licensing.md) —— AGPL-3.0-or-later / 贡献者授权 / 未来许可升级策略
- [凭据保险库安全说明](docs/vault-security-notes.md) —— 测试后门边界 / 二进制替换防护 / 威胁模型
- [第三方声明与特别鸣谢](docs/acknowledgements.md) —— 运行库许可 / 字体 / 图标 / 开源项目致谢
- [第三方运行库许可声明](THIRD-PARTY-NOTICES.md) —— 随发布产物分发的内嵌运行库
- 其余设计与历史快照见 [`docs/`](docs/) 与 [`docs/archive/`](docs/archive/README.md)

## 许可证

本项目整体以 **GNU Affero General Public License v3** 发布（**AGPL-3.0-or-later**，正文见 [LICENSE](LICENSE)）。
在遵守 AGPL 义务（分发或提供网络服务时开放源码、保留声明并标注修改）的前提下，自由使用、学习、修改与再分发（含商业用途）均被许可；本项目不提供闭源商业授权。
贡献者授权与未来许可升级策略见 [docs/licensing.md](docs/licensing.md)。

## 第三方与致谢

第三方依赖逐项见各模块 `THIRD-PARTY-LICENSES.md` 与 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)；字体、图标与开源项目致谢见 [docs/acknowledgements.md](docs/acknowledgements.md)。

---

## 联系与贡献

- 仓库：<https://github.com/BetaStudio2/ArchoeraMusic>
- 贡献前请阅读 **[CONTRIBUTING.md](CONTRIBUTING.md)**；安全漏洞请按 [SECURITY.md](SECURITY.md) 隐式报告。
- PR 合入前需通过签名或显式确认接受 [贡献者授权](docs/licensing.md#22-贡献者授权contributor-license-grant)。
