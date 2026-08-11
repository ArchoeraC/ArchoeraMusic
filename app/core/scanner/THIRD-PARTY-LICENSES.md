# 曲库扫描器第三方许可证声明（scanner / C#）

本目录 `server/scanner` 为 SPlayer-Next 服务端的 C# / .NET 曲库扫描器，
随本软件以 AGPL-3.0 授权。

## NuGet 依赖

| 组件 | 版本 | 许可证 | 说明 |
|---|---|---|---|
| `TagLibSharp` | 2.3.0 | **LGPL-2.1** | 音频元数据读写（MP3/FLAC/OGG/M4A/APE/WAV/DSF 等） |
| `Microsoft.Data.Sqlite` | 9.0.0 | MIT | SQLite 的 ADO.NET 提供程序 |

## TagLibSharp（LGPL-2.1）声明

`TagLibSharp` 以 **GNU Lesser General Public License v2.1（LGPL-2.1）** 发布，
在运行时通过 .NET 程序集引用方式链接（非静态合并进本扫描器二进制）。
依据 LGPL-2.1，使用者有权：(a) 获得 TagLibSharp 对应源代码；(b) 以修改后的
TagLibSharp 替换/重新链接本程序所引用的该程序集。

### 源代码获取

- TagLibSharp 仓库：https://github.com/mono/taglib-sharp
- 许可证：LGPL-2.1（完整文本见 https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html）

## 许可兼容性结论

`TagLibSharp`（LGPL-2.1）与 `Microsoft.Data.Sqlite`（MIT）均兼容 AGPL-3.0；
本扫描器整体作为 AGPL-3.0 受保护作品的一部分分发，合规。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
