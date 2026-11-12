# 刮削器第三方许可证声明（scraper / C++）

本目录 `app/core/scraper` 为 ArchoeraMusic 的 C++ 刮削器，
其自研代码随本软件以 AGPL-3.0 授权，第三方组件按各自许可使用（逐项登记见下）。

## 链接的第三方库

| 组件 | 链接方式 | 许可证 | 说明 |
|---|---|---|---|
| **TagLib** | `find_package(Taglib ...)`，动态链接；发布产物**随包内嵌** `libtag`（Linux 由 `app/core/bundle-linux-runtime.sh` 收拢、macOS 由 `dylibbundler`、Windows 由 vcpkg DLL 拷贝） | **LGPL-2.1**（或 MPL-1.1，双许可） | 音频元数据标签读写 |
| `scraper-crypto`（Rust staticlib） | **静态合并**进 `archoera_scraper`（`app/core/scraper-crypto`） | MIT OR Apache-2.0 | AES-128-ECB/CBC、RSA 裸模幂、MD5/SHA1、随机数、**HTTP（reqwest + rustls）** |
| `SQLite3` | 动态链接（系统） | Public Domain / SQLite blessing | 刮削状态库直写 |
| `nlohmann_json` | 头文件内联（header-only） | MIT | JSON 解析 |

## TagLib（LGPL-2.1）声明

本刮削器经 `target_link_libraries(... Taglib::tag)` 以**动态链接**方式使用 TagLib；
发布产物把 `libtag` 一并内嵌（Linux `native/`、macOS `Contents/native/`、Windows
exe 根目录），故运行期不依赖目标系统的 TagLib 版本。依据 LGPL-2.1，使用者有权：
(a) 获得 TagLib 对应源代码；(b) 以修改后的 TagLib 动态库替换本程序运行时所加载的
`libtag` 共享对象。发布产物 `licenses/` 目录随附 TagLib 许可文本
（见根 `THIRD-PARTY-NOTICES.md`）。

### 源代码获取

- TagLib 仓库：https://github.com/taglib/taglib
- 许可证：LGPL-2.1（完整文本见 https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html）

## 加密与 HTTP 后端（Rust staticlib）

2026-11 起，刮削器不再链接系统 `OpenSSL::Crypto` **与 `libcurl`**（发行版 libcurl
传递依赖 libssl/libcrypto，OpenSSL soname 升级会让已发布二进制无法加载），改用
`app/core/scraper-crypto` 的纯 Rust 实现，以 staticlib 形式静态合并进
`archoera_scraper`：

| crate | 许可证 | 用途 |
|---|---|---|
| `aes` | MIT OR Apache-2.0 | AES-128 块加密（ECB/CBC） |
| `md-5` | MIT OR Apache-2.0 | MD5 摘要 |
| `sha1` | MIT OR Apache-2.0 | SHA1 摘要 |
| `num-bigint` | MIT OR Apache-2.0 | RSA 裸模幂 |
| `getrandom` | MIT OR Apache-2.0 | 系统随机源 |
| `reqwest`（`rustls` feature） | MIT OR Apache-2.0 | 同步 HTTP 客户端（替代系统 libcurl） |

传递依赖（`cipher` / `crypto-common` / `digest` / `generic-array` / `num-traits` /
`rustls` / `aws-lc-rs` / `hyper` / `tokio` 等）同样为 MIT / Apache-2.0 / ISC 等宽松
许可（其中 `generic-array` 为 **MIT 单许可**，故 MIT 与 Apache-2.0 正文都必须随包
保留；`r-efi` 按 MIT 选项使用）；逐项清单与锁定版本见
`app/core/scraper-crypto/THIRD-PARTY-LICENSES.md` 与 `Cargo.lock`。

## 合规评估（非法律意见）

TagLib（LGPL-2.1，动态链接，替换/重链说明见上）与 SQLite3 / nlohmann_json 以及内嵌的 Rust 加密与 HTTP crates 均为宽松许可，在各自条款下可与本项目 AGPL-3.0 代码共存。
本文档为项目维护者的合理努力评估，不构成法律意见；正式依据以上游官方许可文本为准。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
