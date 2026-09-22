# 归档文档（docs/archive）

本目录存放**已完成、已废弃或被取代**的设计稿与历史快照，仅作溯源与历史对照，**不再是现行规范**。
现行文档在 `docs/` 根目录；冲突时以现行文档为准。

> 说明：归档文件内的相互引用可能指向旧的 `docs/...` 路径（未随归档改写），属历史原文，不做维护。

| 归档文件 | 原状态 | 归档理由 | 现行替代 |
|---|---|---|---|
| `audio-kernel-no-ffmpeg.md` | 设计稿 v1 · C11 方案 | 语言改为 Zig，方案废弃 | `../audio-kernel-zig.md` |
| `engine-builder-plan.md` | 规划稿 · 冻结 | 运行时 tcc 自编译与 build.zig 冲突，降级冻结 | `../audio-kernel-zig.md` |
| `engine-master-worker-scheduling.md` | 设计稿 | 线程模型由 pool 设计取代，仅剩语义参考 | `../engine-master-pool-design.md` |
| `archoera-robustness-score.md` | 评分报告 · 2026-08-12 | 基于 v0.8.7 的过期基线 | — |
| `robustness-improvement-plan.md` | 规划稿 · 2026-08-12 | 基于上表的过期计划 | — |
| `format-gap-analysis.md` | 分析稿 · 2026-09-03 | 与现行三维矩阵重叠 | `../format-support-matrix.md` |
| `aac-ps-porting-spec.md` | 移植规格 | AAC-PS 已完成，过程稿 | `../audio-kernel-zig.md` §9.5 |
| `aac-ps-porting-spec-2.md` | 移植规格（续） | 同上 | 同上 |
| `sbr-porting-spec.md` | 移植规格 | AAC-SBR 已完成，过程稿 | 同上 |
| `benchmark-2026-09-10.md` | 基准快照 | 解码 scorecard 已被 09-21 取代 | `../benchmark-2026-09-21.md` |
| `benchmark-industry-2026-09-05.md` | 行业基准快照 | 更早历史快照 | `../benchmark-2026-09-21.md` |
| `test-suite-2026-09-10.md` | 测试套件快照 | 历史快照 | `../benchmark-2026-09-21.md` |
