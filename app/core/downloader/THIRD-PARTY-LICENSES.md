# Downloader 第三方许可证声明（archoera-downloader）

本目录 `app/core/downloader` 为 ArchoeraMusic 的 Rust 下载引擎（cdylib），
随本软件以 AGPL-3.0 授权。

## 直接 Rust 依赖（默认 feature：全自研签名）

> 默认编译配置下 0 个第三方平台 SDK 依赖；Kugou/Netease 签名算法为 SPlayer-Dev 自有版权代码（对照现有 Dart 版 1:1 移植），底层加密原语使用 Rust Crypto 官方 MIT/Apache-2.0 crate。

| 组件 | 版本 | 许可证 | AGPL-v3 兼容 | 说明 |
|---|---|---|---|---|
| `stream-download` | 0.22 | **MIT / Apache-2.0** | ✅ | HTTP 流式下载（reqwest-rustls 后端） |
| `tokio` | 1 | **MIT** | ✅ | 异步运行时（rt-multi-thread + fs + io-util + sync + time） |
| `futures` | 0.3 | **MIT / Apache-2.0** | ✅ | 异步 Future 工具 |
| `once_cell` | 1 | **MIT / Apache-2.0** | ✅ | 全局单例延迟初始化 |
| `serde` / `serde_json` | 1 | **MIT / Apache-2.0** | ✅ | JSON 序列化/反序列化 |
| `anyhow` / `thiserror` | 1 | **MIT / Apache-2.0** | ✅ | 错误处理 |
| `uuid` | 1 | **MIT / Apache-2.0** | ✅ | 任务 ID 生成（v4 + serde） |
| `url` / `percent-encoding` | 2 / 2 | **MIT / Apache-2.0** | ✅ | URL 解析与百分号编码 |
| `base64` | 0.22 | **MIT / Apache-2.0** | ✅ | Base64 编解码 |
| `aes` | 0.8 | **MIT / Apache-2.0** | ✅ | AES 分组密码（Rust Crypto 官方，非自研） |
| `cbc` | 0.1 | **MIT / Apache-2.0** | ✅ | CBC 模式（Rust Crypto 官方，非自研） |
| `md-5` | 0.10 | **MIT / Apache-2.0** | ✅ | MD5 哈希（Rust Crypto 官方，非自研） |
| `rsa` | 0.9 | **MIT / Apache-2.0** | ✅ | RSA PKCS#1（Rust Crypto 官方，非自研） |
| `rand` | 0.8 | **MIT / Apache-2.0** | ✅ | 安全随机数生成 |
| `pkcs7` | 0.4 | **MIT / Apache-2.0** | ✅ | PKCS#7 padding |
| `hex` | 0.4 | **MIT / Apache-2.0** | ✅ | Hex 编解码 |
| `num-bigint` / `num-traits` | 0.4 / 0.2 | **MIT / Apache-2.0** | ✅ | 大整数运算（Kugou kgCalcMid: hex→BigInt→dec） |

## 可选第三方平台 SDK（默认 off，仅 feature 切换时拉取）

| 组件 | 版本 | 许可证 | AGPL-v3 兼容 | 说明 |
|---|---|---|---|---|
| `kugou_sdk`（feature=`kugou_sdk_impl`，默认 off） | 0.2.9 | **MIT** | ✅ | 酷狗第三方 Rust SDK（crates.io）——紧急切换备胎，v1.1 之前不接通 |
| `ncm-api-rs`（feature=`netease_sdk_impl`，默认 off） | main（SPlayer-Dev 官方） | **WTFPL** | ✅ | 网易云官方 Rust SDK（371 endpoint 全覆盖）——WTFPL 等同公有领域，兼容任何许可证；仅作紧急切换备胎 |

## TLS 栈说明（无 OpenSSL 例外）

本 crate 默认 `stream-download` → `reqwest-rustls` → `rustls` → `aws-lc-rs`：
- `rustls`（MIT/Apache-2.0）：纯 Rust TLS，无 OpenSSL 4-Clause BSD 历史问题
- `aws-lc-rs`（ISC/Apache-2.0）：AWS 加密库，LICENSE 更干净，替代 ring/BoringSSL

## 自研化边界特别声明

依据 §9.6 自研边界表（download-module.md L672-L679）：

| 类别 | 是否自研 | 说明 |
|---|---|---|
| Kugou 6 签名函数 + Netease weapi | ✅ **自研（默认）** | 业务签名逻辑，100% 可控；签名变了当天跟进 |
| AES/MD5/RSA/PKCS7/BigInt 等加密原语 | ❌ **绝对不自研** | 使用 Rust Crypto 官方维护 crate；自研出 padding oracle / timing attack 漏洞得不偿失 |
| HTTP chunk download / tmp rename | ⚠️ 半自研 | 默认 `stream-download`；或移植同源 SPlayer-Next `download-engine` AGPL chunk loop |

## 许可兼容性结论

全部直接/间接依赖均为 Permissive License（MIT/Apache-2.0/WTFPL/ISC）——
FSF 官方认定全部与 AGPL-3.0 兼容。本组合作为 AGPL-3.0 受保护作品的一部分分发，合规。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
