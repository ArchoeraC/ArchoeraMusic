# 刮削器加密后端第三方许可证声明（scraper-crypto / Rust）

本目录 `app/core/scraper-crypto` 是 ArchoeraMusic 刮削器的加密后端，用于替代原先
动态链接的系统 `OpenSSL::Crypto`。**自研代码**随本软件以 **AGPL-3.0-or-later**
授权（见 `Cargo.toml` 的 `license` 字段）；第三方 crates 按各自许可使用。

该 crate 以 `staticlib` 形式**静态合并**进 `archoera_scraper`（Rust 标准库同为
MIT OR Apache-2.0，一并静态链接），随发布产物分发，
因此下列许可文本与声明需随包提供（发布产物 `licenses/` 目录中已包含
`Apache-2.0.txt` 与 `MIT.txt`）。

## 直接依赖

| crate | 锁定版本 | 许可证 | 用途 |
|---|---|---|---|
| `aes` | 0.8.4 | MIT OR Apache-2.0 | AES-128 块加密（ECB / CBC） |
| `md-5` | 0.10.6 | MIT OR Apache-2.0 | MD5 摘要 |
| `sha1` | 0.10.7 | MIT OR Apache-2.0 | SHA1 摘要 |
| `num-bigint` | 0.4.8 | MIT OR Apache-2.0 | RSA 裸模幂 |
| `getrandom` | 0.2.17 | MIT OR Apache-2.0 | 系统随机源（Linux `getrandom` / macOS `getentropy` / Windows `BCryptGenRandom`） |

## 传递依赖

| crate | 锁定版本 | 许可证 |
|---|---|---|
| `block-buffer` | 0.10.4 | MIT OR Apache-2.0 |
| `cfg-if` | 1.0.5 | MIT OR Apache-2.0 |
| `cipher` | 0.4.4 | MIT OR Apache-2.0 |
| `cpufeatures` | 0.2.17 | MIT OR Apache-2.0 |
| `crypto-common` | 0.1.7 | MIT OR Apache-2.0 |
| `digest` | 0.10.7 | MIT OR Apache-2.0 |
| **`generic-array`** | 0.14.7 | **MIT**（仅 MIT，无 Apache 选项） |
| `inout` | 0.1.4 | MIT OR Apache-2.0 |
| `libc` | 0.2.191 | MIT OR Apache-2.0 |
| `num-integer` | 0.1.47 | MIT OR Apache-2.0 |
| `num-traits` | 0.2.19 | MIT OR Apache-2.0 |
| `typenum` | 1.20.1 | MIT OR Apache-2.0 |
| `version_check` | 0.9.5 | MIT / Apache-2.0 |
| `autocfg` | 1.5.1 | Apache-2.0 OR MIT |
| `wasi` | 0.11.1 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |

> 精确版本以同目录 `Cargo.lock` 为准（升级依赖时同步更新本表）。
> `generic-array` 为 MIT 单许可，因此发布产物必须同时保留 **MIT** 与
> **Apache-2.0** 正文，不能只附 Apache-2.0。

## 合规评估（非法律意见）

上述 crates 均为 MIT / Apache-2.0 系宽松许可（`wasi` 另含 LLVM 例外），与本项目
AGPL-3.0-or-later 聚合、静态链接分发兼容；不引入 GPL/AGPL 之外的 copyleft 义务。
本文档为项目维护者的合理努力评估，不构成法律意见；正式依据以上游官方许可文本为准。

## 上游与源码

- RustCrypto（`aes` / `cipher` / `digest` / `md-5` / `sha1` 等）：
  https://github.com/RustCrypto
- `num-bigint` / `num-integer` / `num-traits`：https://github.com/rust-num
- `getrandom`：https://github.com/rust-random/getrandom
- `generic-array`：https://github.com/fizyk20/generic-array
- 各 crate 源码与完整许可文本也可从 https://crates.io 对应版本下载。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
