# 健壮性改进规划（基于 archoera-robustness-score.md）

> 状态：规划稿 · 2026-08-12
> 来源：[archoera-robustness-score.md](./archoera-robustness-score.md)（综合 61/100）
> 定位：把评分报告的改进路线图固化为可执行计划，标注与既有四份计划（凭据保险库 /
> 下载器身份隔离 / FFI 库布局整理 / 引擎事件推送降频）的衔接，避免重复立项。

---

## 1. 现状基线（2026-08-12 评分）

| 维度 | 得分 | 等级 | 本计划目标 |
|------|------|------|------|
| 架构设计 | 80 | 良好 | 维持 |
| 性能优化 | 80 | 良好 | 维持 |
| 资源管理 | 80 | 良好 | 维持（原子化 JSON 写入 → 85） |
| 代码质量 | 65 | 中等 | 70（拆分 PlaybackNotifier / 平台 API 公共基类） |
| 运维可靠 | 60 | 及格 | 75（统一日志 / PR 触发 CI / 完善 Windows） |
| 安全防护 | 55 | 不及格 | 80（凭据保险库计划承接） |
| 错误处理 | 45 | 不及格 | 70（全局边界 + 静默吞噬治理 + HTTP 退避） |
| 测试覆盖 | 30 | 很差 | 55（Go/Rust/Dart 三层补齐 + CI 接入） |

综合：61 → 第一二阶段完成预计 70+；全计划完成预计 80+。

## 2. 方案（按投入产出比三阶段）

### 第一阶段：快速收益（低难度，无架构改动）

1. **全局错误边界**（错误处理 +15，低）
   - `runZonedGuarded` 包裹 app 启动；`FlutterError.onError` / `PlatformDispatcher.instance.onError` 兜底；
   - 未捕获异常/错误统一收口：记录日志 + 用户可见降级提示，不崩溃、不静默；
   - 挂载点：`main.dart` / `app.dart`（与 `PowerSavingFrameBinding` 同层）。

2. **静默吞噬治理**（错误处理 +10，低）
   - 40+ 处 `catch (_) {}` 逐处审计：保留 UI 静默语义处改为「捕获 → 记日志（debug 级）→ 静默返回」；
   - 统一日志入口（见第二阶段统一日志），不引入第三方 logger 前置；
   - 约束：错误信息禁止携带 token/明文凭据（与凭据保险库计划 §3.3 对齐）。

3. **PR 触发 CI 构建**（运维 +10，低）
   - 三平台 workflow 增加 `pull_request` 触发（路径过滤 `app/**`、`.github/**`）；
   - 仅构建不发布：PR 触发仅跑 compile + analyze + 单测，发布步骤仍限 tag/workflow_dispatch。

4. **原子化 JSON 写入**（资源管理 +5，低）
   - `streaming_servers.json` / 历史/播放记录等 JSON 落盘改「临时文件 + rename」原子替换；
   - 防写入中断产生半截 JSON（对齐现有 busy_timeout 的容错思路）。

### 第二阶段：重点突破（中难度）

5. **统一日志系统**（运维 +20，中）
   - 收敛各语言各自为政：Dart 层统一入口（级别控制 + 滚动文件持久化 + 时长上限）；
   - 原生层（C/Rust/Go）经 FFI 回传或独立文件，启动时合并展示；
   - 与第一阶段的全局错误边界 / 静默吞噬共用同一入口；
   - 敏感掩码：token/cookie/密码字段自动掩码（凭据保险库 §3.3 约束落地）。

6. **HTTP 指数退避重试**（错误处理 +10，中）
   - 平台 API / 下载 / 流媒体请求统一重试策略：指数退避 + 抖动 + 上限；
   - 仅对可重试错误（网络/5xx/超时）重试，4xx/鉴权/版权错误直达（对齐 Mineradio 语义）。

7. **Go Subsonic 单元测试**（测试 +10，中）
   - 子查询/鉴权/参数化 SQL 覆盖（SQL 注入回归）；
   - 接入 CI（三平台 workflow 增加 `go test`）。

8. **加密存储敏感凭据**（安全 +20，中）—— **已由 credential-vault-plan.md 承接，本计划不重复立项**；
9. **完善 Windows 支持**（运维 +10，高）—— **已启动**：Windows 播放阻塞修复（audio_engine_process UnsupportedError + FFmpeg DLL 打包）完成，待 CI 验证；与 ffi-libs-layout-plan.md 衔接。

### 第三阶段：长期优化（高难度）

10. **Dart 核心业务单元测试**（测试 +15，高）—— playback_notifier / 平台 API 解析 / 队列逻辑；
11. **拆分 PlaybackNotifier**（代码质量 +10，中）—— 1274 行单文件按职责拆（播放核心 / FFT / 队列 / 事件）；
12. **依赖安全扫描**（安全 +10，中）—— pub/cargo/go/dotnet 依赖漏洞扫描接入 CI；
13. **提取平台 API 公共基类**（代码质量 +10，中）—— 酷狗/网易 API 结构相似度高，抽公共基类消除重复。

## 3. 与既有计划的衔接

| 计划 | 覆盖范围 | 本计划引用 |
|------|----------|-----------|
| credential-vault-plan.md | 凭据静态加密/流式注入/内存保护/崩溃联动/握手（安全防护核心） | 第二阶段第 8 项 |
| ffi-libs-layout-plan.md | FFI 库集中布局（bundle/native/ 统一） | 第二阶段第 9 项（Windows 打包上下文） |
| downloader-identity-plan.md | 下载器指纹隔离/行为节流 | 不重叠，本计划不涉及 |
| engine-event-push-plan.md | 引擎事件推送降频 | 不重叠，本计划不涉及 |

## 4. 分步落地

1. **第一批（低难度四件套）**：全局错误边界 → 静默吞噬治理 → PR 触发 CI → 原子化 JSON 写入；
2. **第二批（中难度）**：统一日志系统 → HTTP 指数退避 → Go 单测（凭据保险库按其计划独立推进）；
3. **第三批（长期）**：Dart 核心单测 → 拆分 PlaybackNotifier → 依赖安全扫描 → 平台 API 公共基类。

## 5. 验证

1. `dart analyze` + `flutter test` + `cargo test` + `go test` 全绿并接入 CI；
2. 错误边界生效：人为抛未捕获异常 → 应用不崩溃、日志有记录、有用户提示；
3. 静默吞噬治理后：`grep "catch (_)"` 数量显著下降，残留处均有日志旁证；
4. PR 触发三平台 compile + analyze + 单测通过；
5. 统一日志：级别控制、滚动持久化、敏感字段掩码生效；
6. HTTP 重试：注入网络故障，观察指数退避 + 抖动 + 上限符合预期，4xx 不重试。
