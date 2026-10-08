# Shell 第三方许可证声明（archoera-shell）

本目录 `app/core/shell` 为 ArchoeraMusic 的**内嵌原生命令行客户端**（`archoerashell`）：
以 Rust `staticlib`（`libarchoera_shell.a`）**静态链入** Linux runner 主可执行文件
（`app/linux/CMakeLists.txt`）。其自研代码随本软件以 AGPL-3.0 授权，第三方 crate 按
各自许可使用（逐项登记见下）。静态链接的 crate 代码会进入发布二进制的文本段。

## 运行期依赖（静态链入二进制）

| 组件 | 版本 | 许可证 | AGPL-v3 兼容 | 说明 |
|---|---|---|---|---|
| `serde_json` | 1 | **MIT / Apache-2.0** | ✅ | REST 响应 JSON 解析；`preserve_order` 保持对象键序 |
| `serde` / `serde_core` | 1 | **MIT / Apache-2.0** | ✅ | 序列化框架 |
| `indexmap` | 2 | **Apache-2.0 / MIT** | ✅ | `serde_json` 的 `preserve_order` 后端（有序 Map） |
| `equivalent` | 1 | **Apache-2.0 / MIT** | ✅ | `indexmap` 键等价 |
| `hashbrown` | 0.17 | **MIT / Apache-2.0** | ✅ | `indexmap` 底层哈希表 |
| `itoa` | 1 | **MIT / Apache-2.0** | ✅ | 整数格式化 |
| `memchr` | 2 | **Unlicense / MIT** | ✅ | 字节搜索 |
| `zmij` | 1 | **MIT** | ✅ | `serde_json` 浮点格式化 |
| `libc` | 0.2 | **MIT / Apache-2.0** | ✅ | `TIOCGWINSZ` 终端列数探测 |

## 构建期依赖（仅参与构建，不进入二进制）

| 组件 | 版本 | 许可证 | AGPL-v3 兼容 | 说明 |
|---|---|---|---|---|
| `serde_json` | 1 | **MIT / Apache-2.0** | ✅ | `build.rs` 读取 Flutter ARB 生成帮助/标签文案 |
| `serde_derive` / `proc-macro2` / `quote` / `syn` / `unicode-ident` | 1 | **MIT / Apache-2.0**（`unicode-ident` 亦可 Unicode-3.0） | ✅ | 派生宏链路（构建期） |

## 说明

- 所有第三方 crate 均为宽松许可（MIT / Apache-2.0 / Unlicense），与 AGPL-3.0 聚合兼容。
- 本 crate **不引入** OpenSSL、GPL 或 nonfree 组件；HTTP 走标准库 `std::net`（仅回环明文）。
- 许可文本与聚合声明随发布产物 `licenses/` 分发（见根 `THIRD-PARTY-NOTICES.md` 与
  `app/core/*/THIRD-PARTY-LICENSES.md` 的同类登记）。
