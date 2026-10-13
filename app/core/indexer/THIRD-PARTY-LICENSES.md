# 本地曲库搜索索引器第三方许可证声明（indexer / C#）

本目录 `app/core/indexer` 为 ArchoeraMusic 的 C# / .NET 本地曲库搜索索引器，
其自研代码随本软件以 AGPL-3.0 授权，第三方组件与数据按各自许可使用（逐项登记见下）。

## NuGet 依赖

| 组件 | 版本 | 许可证 | 说明 |
|---|---|---|---|
| `Microsoft.Data.Sqlite` | 10.0.12 | **MIT** | SQLite 的 ADO.NET 提供程序（读写 `library.db` / `search.db`），与 `app/core/scanner` 同栈 |
| `SQLitePCLRaw.lib.e_sqlite3` | 3.53.3 | **Apache-2.0** | 原生 SQLite 静态库（随 FFI 分发为 `libe_sqlite3`/`e_sqlite3.dll`），**含 FTS5** |
| `ToolGood.Words` | 3.1.0.3 | **Apache-2.0** | 汉字转拼音（含**词级多音字消歧**）、繁简互换、全角半角互换。取代自带 `pinyin.tsv` / `simp_trad.tsv` 表与手搓全角折叠；NativeAOT 经 `TrimmerRootAssembly` 保根后实测可用 |

> SQLite 本体为 **public domain**（FTS5 亦属之，随 `libe_sqlite3` 一并分发）。
> 版本 pin 与 CVE 修复说明见 `app/core/scanner/scanner.csproj`（`SQLitePCLRaw.lib.e_sqlite3`
> 3.53.3 消除 CVE-2025-6965）。
> **GB18030 / GBK 解码**改用 .NET 框架内置 `System.Text.CodePagesEncodingProvider`
> （随 .NET 10 运行时提供，无额外 NuGet 依赖、无自带数据表）。

## MIT（Microsoft.Data.Sqlite）

```
The MIT License (MIT)

Copyright (c) .NET Foundation and Contributors
```

完整文本见上游仓库 LICENSE（https://github.com/dotnet/efcore/blob/main/LICENSE.txt）。

## Apache-2.0（SQLitePCLRaw）

```
Apache License, Version 2.0
http://www.apache.org/licenses/LICENSE-2.0
```

完整文本见上游仓库 LICENSE（https://github.com/ericsink/SQLitePCL.raw/blob/master/LICENSE.txt）。

## Apache-2.0（ToolGood.Words）

```
Apache License, Version 2.0
http://www.apache.org/licenses/LICENSE-2.0

Copyright 2017-2025 ToolGood
```

完整文本见 ToolGood.Words 仓库 `LICENSE`
（https://github.com/toolgood/ToolGood.Words，NuGet 包内附 `LICENSE`）。
**免责**：该组件按 Apache-2.0「原样（AS IS）」提供，不附带任何明示或默示担保；
其拼音 / 繁简 / 全角结果由上游词库决定，本项目不对准确性作保证。版本固定为 **3.1.0.3**
（关闭上游浮动更新，见风险说明）。

## 生成数据表来源与许可

方向 A 重构后，索引侧保留以下离线生成表（拼音 / 繁简 / GB18030 / 英文阻断均已移除）：

| 数据 | 生成文件 | 上游 | 许可证 | 说明 |
|---|---|---|---|---|
| NFKC 兼容折叠 | `data/nfkc.tsv` | Python 标准库 [`unicodedata`](https://docs.python.org/3/library/unicodedata.html)（Unicode NFKC）| **Unicode License** | 遍历 U+0000..U+10FFFF、逐字符 `NFKC` 折叠（仅当归一结果 ≠ 原字符）；输入 / 输出均为码点十六进制 |
| 释义查询扩展（英→汉） | `data/def_en2hanzi.tsv` | Unicode [Unihan](https://www.unicode.org/reports/tr38/) 数据库 `kDefinition`（`Unihan_Readings.txt`）| **Unicode License** | 英文词 → 候选汉字码点（去重、主区优先 + 码点升序、每词 ≤ 8），供查询侧跨语言候选（T1） |
| 释义查询扩展（汉→英） | `data/def_hanzi2en.tsv` | Unicode [Unihan](https://www.unicode.org/reports/tr38/) 数据库 `kDefinition`（`Unihan_Readings.txt`）| **Unicode License** | 汉字码点 → 英文释义词（去重、字典序），供查询侧跨语言候选（T1） |

> `nfkc.tsv` 由 Python 标准库（其表派生自 Unicode Character Database）离线计算，
> 受 [Unicode License](https://www.unicode.org/license.txt) 约束。
> `def_en2hanzi.tsv` / `def_hanzi2en.tsv` 派生自 Unicode **Unihan** 数据库的 `kDefinition`
> 字段（经去括注 / 小写 / 停用词过滤），同受 [Unicode License](https://www.unicode.org/license.txt)
> 约束（Unihan 下载：<https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip>，
> 仓库级 `.gitignore` 忽略，缺失时脚本经宿主机代理下载到 `reference/unihan/`）。
> 两者均**仅在查询侧**（`Analyzer.AnalyzeQuery` / `HanziData`）使用，索引内容不变。
>
> 已移除的表与外部依赖（记录备查）：`pinyin-data`（MIT）/`OpenCC`（Apache-2.0）/
> `dwyl/english-words`（Unlicense）及其生成的 `pinyin.tsv` / `simp_trad.tsv` /
> `gb18030.tsv` / `en_blocklist.tsv`——相应能力改由 ToolGood.Words 与框架 CodePages 提供。

数据表由 `tools/gen_hanzi_data.py` 离线、确定性地生成（脚本仅缺表时下载 Unihan，
生成结果按码点 / 词序排序，可重现且字节稳定）。

## Unicode License（Unicode 数据）

```
Copyright © 1991-2024 Unicode, Inc. All rights reserved.
Distributed under the Terms of Use in https://www.unicode.org/copyright.html
```

## 合规评估（非法律意见）

`ToolGood.Words`（Apache-2.0）与框架 CodePages 均为宽松/框架内许可，其上提供的
拼音 / 繁简 / 全角 / GB18030 能力与本项目 AGPL-3.0 代码可共存；`data/nfkc.tsv` 派生自
Unicode 数据（Unicode License，允许自由使用）。NuGet 依赖 `Microsoft.Data.Sqlite`（MIT）
与 `SQLitePCLRaw.lib.e_sqlite3`（Apache-2.0）与 scanner 同栈，同样为宽松许可。
上述均**不**属于 GPL-2.0-only / SSPL / BSL 等本项目禁止引入的许可。
本文档为项目维护者的合理努力整理，不构成法律意见；正式依据以上游官方许可文本为准。

---

AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`；
许可总则见 `docs/licensing.md`。
