# AGENTS.md — ArchoeraMusic 维护与发布指引

本文件面向在本仓库工作的 AI 助手与维护者，记录**发布/签名**等关键流程。
通用贡献规范见 `CONTRIBUTING.md`。

## Git 认证与提交签名（优先密钥方案）
- **优先使用 SSH + GPG 密钥**：`origin` 使用 SSH（`git@github.com:<owner>/<repo>.git`）认证，
  提交使用 GPG 签名，不依赖 Personal Access Token（PAT）/账号密码。
- **若发现用户仍在使用 token**（remote 为 `https://...`、配置了存 token 的 `credential.helper`、
  或需要输入 PAT 才能 push），应**主动建议其更换为密钥方案**（SSH 认证 + GPG 签名），并说明：
  token 易泄露、权限过宽、需定期轮换；密钥可细粒度控制且可签名验证来源。
- **期望配置**（`git config --global`）：
  `user.signingkey <GPG key id>`、`commit.gpgsign true`、`tag.gpgsign true`；
  remote 使用 SSH，推送无需 token。
- **验证**：`ssh -T git@github.com`（应回显用户名）；`git log --show-signature -1`（签名有效）。
- **红线**：禁止把 token、私钥写入仓库、脚本或 remote URL；凭据只保存在本地密钥环；禁止使用pkill -x自杀

## 构建与测试（提交前必跑）
```bash
cd app
flutter pub get
dart analyze lib            # 0 issue
flutter test                # 全绿
```
改动原生模块（`app/core/audio-engine`）时另跑：
```bash
cd app/core/audio-engine
zig build -Doptimize=ReleaseFast
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
cd build && ctest
```
改动平台桥接（`app/native/platform`）时另跑：
```bash
cmake -S app/native/platform -B app/native/platform/build -DCMAKE_BUILD_TYPE=Release
cmake --build app/native/platform/build -j
```

Windows/MSVC 兼容自检（本机可交叉，无需 Windows SDK）：
```bash
cd app/core/audio-engine
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast   # Zig 内核；应产出 Windows .lib 且含 zk_* 导出
# C 壳 Windows 目标编译检查（$FFDIR 为 FFmpeg 头目录；勿用 -I/usr/include，会混入 glibc）：
#   zig cc -target x86_64-windows-gnu -c -DHAS_ARCHOERA_KERNEL \
#     -Iinclude -Isrc -Iinclude/compat -I"$FFDIR" src/xxx.c
```
> 严格 MSVC（`-target x86_64-windows-msvc`）需 Windows SDK/CRT，本机缺失时跳过，以 Windows CI 为准。
> 新增 C/ABI 代码须保持：`ssize_t` 走 `audio_engine.h` 的 `_WIN32` 分支、函数指针用 `callconv(.c)`/普通 C 签名、
> 不引入 `unistd.h`/POSIX-only API；线程原语走 `include/compat/pthread.h`。

## 架构约定（务必遵守）

### 系统调用统一走 C++ 桥接器
- **所有平台/系统能力**（媒体会话、电源/防休眠、窗口状态、系统主题色、通知、单实例、
  以及未来任何系统集成）**一律在 `app/native/platform`（C++/ObjC++）实现**；
  Dart 只通过 `apl_*` C ABI（`dart:ffi`）调用。
- **禁止 Dart 直接调平台 API**：不得用 MethodChannel/平台插件、不得 `Process.run` 起系统命令/子进程、
  不得在 Dart 侧解析平台数据（坚持零 JSON、零子进程、同进程动态链接）。
- **最小权限（普通用户可完成）**：所有系统调用必须能在**普通用户**权限下完成——
  程序**不得要求管理员/root 权限**：不请求 UAC 提权、不写 `HKLM`/系统目录/需提权的位置、
  不安装服务或驱动、不注册需提权的系统资源。需要提权才能实现的能力**放弃或降级**，
  不做"请以管理员身份运行"的设计（否则一律视为不符合规范）。
  - **唯一例外：Windows 安装向导（`packaging/windows/archoera_music.iss`）的可选
    per-machine 模式**。向导可提供「仅为我安装（默认 `%LOCALAPPDATA%\Programs`，全程免提权）」
    与「为所有用户安装（默认 `Program Files`，需用户在向导内显式选择并经 UAC 提权）」两种模式，
    **默认必须是 per-user 免提权**。提权只允许发生在安装/卸载向导内且由用户显式确认；
    更新旧版时必须沿用其原有安装模式，模式不一致时以失败退出。
  - 上述例外**不适用于应用运行时**：`app/` 与 `app/native/platform` 仍一律不得请求提权，
    也不得写 `HKLM`/系统目录（per-machine 的 `HKLM` 写入只能由向导在提权后完成）。
- **新增能力流程**：`include/archoera_platform.h` 扩 ABI → `core.*` / `backend.h` 加契约 →
  三端后端各实现（`backend_windows.cpp` / `backend_linux.cpp` / `backend_macos.mm`；
  未覆盖平台落 `backend_stub.cpp`）→ Dart 绑定（`app/lib/services/platform/`）→
  各平台构建脚本/打包依赖同步（详见 `docs/platform-native-bridge.md`）。
- 桥接器**按平台官方工具链原生编译**：Windows MSVC C++/WinRT、Linux C++ + libdbus + dlopen GTK、
  macOS ObjC++；**不要再引入 Zig 承载桥接**。

### 模块化
- 按职责拆文件、单一职责，避免巨型文件（桥接器即范例：`core` / `backend` / `apl` + 每平台一个后端文件）。
- 跨平台共享逻辑放共享层（`core.*` / `backend.h`），平台特有逻辑放各平台文件；新增平台只加一个后端文件。
- 新增/修改功能时同样适用：先想清楚归属与拆分，再落代码。

### 命名与原创性（避免与 FFmpeg/上游同形）
- **我们自己的符号（类型 / 函数 / 变量 / 常量）不得照搬 FFmpeg / libopus / libspeex 等上游的标识符**；
  算法与语义可以对齐，但命名必须自有——例如抖动 PRNG 用 `JitterRng`，不用 `AVLFG`/`av_lfg_*`。
- 注释里**可以引用**上游函数/文件作为出处与对照依据（如「对照 FFmpeg `libavcodec/ac3.c`」），
  这是溯源，不构成我们的符号；但不要把上游标识符直接用作我们的类型/函数/字段名。
- 内核转写表/内部常量统一用 **`era_` 前缀**（如 `era_dca_dmixtable`、`era_celt_alpha_coef`），
  不使用上游 `ff_*` 等前缀（含表名、字段名）；测试名字符串可保留出处描述；
  **新增代码一律不得使用上游前缀**。
- 判定标准：**不出现与上游逐字相同的标识符**；算法/公式/常量值相同不违规（属规范与事实）。

### 渲染与性能
- **高渲染压力优先 GPU**：着色器/滤镜/合成走 GPU（Flutter `FragmentProgram`/shader、Skia/Impeller），
  不要在 Dart 主 isolate 做逐像素或重计算。
- 重计算/阻塞 IO 下沉到后台 isolate 或原生层；UI 线程只做轻量调度。
- 新增/修改功能同样先问"能不能 GPU 化 / 下沉原生"，再考虑 Dart 侧实现。
- **范例：播放页水纹背景**（`app/shaders/ripple.frag` +
  `app/lib/widgets/player/ripple_shader.dart` / `ripple_background.dart`）——
  单 pass 着色器完成折射/饱和/波峰高光/压暗，封面模糊与饱和在 Dart 侧**预烘焙一次**
  （不每帧全屏模糊），每帧只更新 uniform；**着色器不可用时才回退 CPU 网格自绘**。
  设计/性能预算见 `docs/player-render-optimization.md`。

### 内核并发与测试（禁止等待式竞态判定）
- 内核（`app/core/audio-engine/kernel`，Zig）是**同步 / run-to-completion** 模型：
  不得引入 `await`/异步等待语义；线程原语统一走 `std.Io` 条件变量/事件（持锁配对）。
- **禁止用等待去“凑”竞态观测值**：不以 `sleep`/`waitIdle`/超时轮询让本质不确定的断言
  （如 worker 瞬时 `idle/running/inflight`、内存 RSS、调度顺序）变得“看起来稳”。
  断言只允许两类：**完成后稳定**（原子计数 / 明确边界写入值）或**任意时刻成立的不变量**；
  瞬时并发状态只作遥测输出，不作断言。
- 并发行为的确定性验证放到**不共享线程的状态机单测**（如 `tables.WorkerTable` 的纯函数
  聚合），而非在活体线程池上观测瞬时状态。
- 偶发失败不得当“抖动”重试掩盖：发现即定位并确定性化（固定 seed、明确同步点或改断言）。

## 发布与签名

发布产物用**一把密钥（key1）**做 ECDSA P-256 / SHA-256 分离签名（`<asset>.sig1`），
由 CI 在受保护 `release` Environment（人工审批）执行；公钥随发布分发
（`ARCHOERA_PUBKEY.pem`）。私钥**绝不入库/入包**。

### 发布流程
1. 升版本 + **更新 `CHANGELOG.md`**（见下节）。
2. 打 tag（`v*`）→ CI 构建三端产物。
3. `release` 作业进入 **Environment 审批**：人工批准后，CI 用 key1 对全部资产签 `.sig1`，
   复制公钥，按 tag 从 `CHANGELOG.md` 抽取说明创建/更新 GitHub Release。

### 更新日志（CHANGELOG.md）
- 根目录 `CHANGELOG.md` 是各版本 **GitHub Release 说明的唯一来源**：release 作业按 tag
  抽取对应 `## [<version>]` 段落作为 Release 正文（见 `.github/workflows/build-all.yml`）。
- **文风**：新增条目须**沿用当前作者的风格**（口语化、「喵」、编号列表等），
  不要改成正式 Keep-a-Changelog 腔调。
- **每次发版必须更新**：在 `CHANGELOG.md` 顶部加一段
  `## [<version>] - <YYYY-MM-DD>`（与 `pubspec.yaml` 的 `version:`、git tag 一致）。
  缺段落时 Release 回退到通用文案。

### 验签（任何人）
```bash
bash app/tool/verify_release.sh /tmp/rel
# 或逐文件：
openssl dgst -sha256 -verify app/tool/watermark_pub.pem -signature x.sig1 x
```

### 密钥生成 / 轮换
```bash
# key1（同时用于二进制内水印，常量写入 app/lib/app/watermark.dart）
bash app/tool/sign_watermark.sh          # 本地运行；CI 环境会拒绝执行
```
轮换后需同步更新：`watermark.dart` 常量、`watermark_pub.pem`、CI 的 Environment secret。
旧发布保留旧公钥以便历史验签。

### 私钥材料（切勿提交/打印）
- key1：`~/.config/archoera/watermark_ec_priv.pem`
- CI secret（**Environment `release`**，非仓库级）：`ARCHOERA_WM_KEY1_PEM`（key1 PEM）。

## 仓库保护（已在 GitHub 配置）
- **Environment `release`**：Required reviewers = 维护者；部署仅允许 tag `v*`；
  含 Environment secret `ARCHOERA_WM_KEY1_PEM`（key1 PEM）。
- **Ruleset `protect-main`**（branch）：要求 PR、禁止强推（non_fast_forward）、禁止删除；
  Required approvals = 0（单人可自建 PR 自合并）。**禁止直接 push `main`**。
- **Ruleset `protect-archoeraos`**（branch `ArchoeraOS`）：禁止删除（`deletion`）、禁止强推
  （`non_fast_forward`）；**不要求 PR**（保留维护者直接推送的长期分支工作流）。
  `ArchoeraOS` 是长期维护的发行版分支，承载 shell/网络/蓝牙/安装向导等大量独有提交，
  **不得删除**。
- **Ruleset `protect-release-tags`**（tag `v*`）：禁止**更新/删除**已发布 tag（不可移动）。
  故打 tag 前务必确认版本号。
- **CODEOWNERS**：`.github/CODEOWNERS` 把 CI/工具/打包/水印等关键路径指向维护者。

## 触发一次 Release（端到端）
1. **升版本**：改 `app/pubspec.yaml` 的 `version:`（如 `0.9.15+8`）。
2. **更新 `CHANGELOG.md`**：顶部加 `## [<version>] - <YYYY-MM-DD>` 段，沿用作者文风。
3. **提交**：因 `protect-main` 禁直推，走 PR：`git switch -c chore/release-x` →
   commit → push → `gh pr create` → 自合并（0 approvals 即可）。
4. **打 tag 并推**：`git tag v<version> && git push origin v<version>`
   （`v*` 匹配部署策略；**tag 一旦推送不可删改**）。
5. **审批**：Actions → 该 run 的 release 作业停在 **Waiting for review** → Approve。
   CI 用 key1 签 `<asset>.sig1`、复制公钥、按 tag 抽取 `CHANGELOG.md` 段落作为
   Release 正文 → 官方发布完成。

## 红线
- 禁止提交任何私钥/凭据（`.gitignore` 已忽略 `*.key`、`*_priv.pem`；公钥 `watermark_pub*.pem` 需跟踪）。
- 禁止在 CI 运行 `sign_watermark.sh`（会打印私钥材料；脚本已加 `CI` 环境拒绝）。
- 签名步骤不要开 `set -x`。
- 禁止删除 `ArchoeraOS` 分支、对其强推，或把它并入 `main` 后删除（已由 ruleset
  `protect-archoeraos` 在服务端拦截；清理分支时务必排除它）。
- "Hmm"等可能会导致死循环，尽可能不要触及

