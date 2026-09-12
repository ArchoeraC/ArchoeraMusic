# 刮削器第三方许可证声明（scraper / C++）

本目录 `app/core/scraper` 为 ArchoeraMusic 的 C++ 刮削器，
其自研代码随本软件以 AGPL-3.0 授权，第三方组件按各自许可使用（逐项登记见下）。

## 链接的第三方库

| 组件 | 链接方式 | 许可证 | 说明 |
|---|---|---|---|
| **TagLib** | `find_package(Taglib ...)`，动态链接系统 `libtag`（Fedora `dnf install taglib` 提供 `.so`） | **LGPL-2.1** | 音频元数据标签读写 |
| `libcurl` | 动态链接（系统） | curl License（MIT/X 派生） | HTTP 客户端 |
| `OpenSSL`（`OpenSSL::Crypto`） | 动态链接（系统） | Apache-2.0（含 OpenSSL 例外） | HTTPS / SHA1 |
| `SQLite3` | 动态链接（系统） | Public Domain / SQLite blessing | 刮削状态库直写 |
| `nlohmann_json` | 头文件内联（header-only） | MIT | JSON 解析 |

## TagLib（LGPL-2.1）声明

本刮削器经 `target_link_libraries(... Taglib::tag)` 以**动态链接**方式使用 TagLib。
依据 LGPL-2.1，使用者有权：(a) 获得 TagLib 对应源代码；(b) 以修改后的
TagLib 动态库替换本程序运行时所加载的 `libtag` 共享对象。

### 源代码获取

- TagLib 仓库：https://github.com/taglib/taglib
- 许可证：LGPL-2.1（完整文本见 https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html）

## 合规评估（非法律意见）

TagLib（LGPL-2.1，动态链接，替换/重链说明见上）与 libcurl / OpenSSL / SQLite3 / nlohmann_json 均为宽松许可，在各自条款下可与本项目 AGPL-3.0 代码共存。
本文档为项目维护者的合理努力评估，不构成法律意见；正式依据以上游官方许可文本为准。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
