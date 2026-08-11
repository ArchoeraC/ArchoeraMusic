# 刮削器第三方许可证声明（scraper / C++）

本目录 `app/core/scraper` 为 ArchoeraMusic（源于 SPlayer-Next 服务端）的 C++ 刮削器，
随本软件以 AGPL-3.0 授权。以下为其经 CMake 链接的系统/第三方库许可证摘要。

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

## 许可兼容性结论

TagLib（LGPL-2.1）与本项目 AGPL-3.0 兼容；libcurl / OpenSSL / SQLite3 /
nlohmann_json 均为宽松许可证，无 copyleft 冲突。
本刮削器整体作为 AGPL-3.0 受保护作品的一部分分发，合规。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
