# MCP 接入（本地控制服务）

> 状态：已实现（2026-10-07）
>
> 目标：让 MCP 客户端（Claude Desktop / Codex / Cursor / 自研 Agent 等）与本机
> 播放器交互——查询播放状态、控制播放与队列、搜索在线音源与本地曲库、
> 切换主题、收藏、播放历史、只读应用偏好。

本服务**默认关闭**，不改变「单进程、无侧车」的既有形态；它是一个**事件驱动**
的本地 HTTP 监听（`dart:io` 事件循环，无轮询、无定时拉取），默认仅绑定
`127.0.0.1`，普通用户即可运行（非特权端口，无需管理员权限）。

代码位置：`app/lib/services/mcp/`（协议/动作/传输），
偏好：`app/lib/stores/prefs_mcp.dart`，设置页：`settings_sections_mcp.dart`。

---

## 1. 开启与配置

设置 → **MCP 接入**：

| 项 | 说明 |
|---|---|
| 启用 MCP 控制 | 总开关，默认关；关闭即停止监听 |
| 监听端口 | 1024~65535（默认 `14559`）；修改后自动重启监听 |
| 访问密钥 | 128-bit 十六进制，首次开启自动生成；可复制 / 重新生成 |
| 允许免密钥访问 | 默认关；开启后本机任意程序可直接访问（不推荐） |
| 允许局域网访问 | 默认关；开启绑定 `0.0.0.0`，需弹窗确认，局域网内其它设备可连接（仍要求密钥） |
| 命令行 shell | 默认可用；关闭后 `archoerashell` 子命令直接报错退出（不影响 GUI 与其它协议），设置页附可复制的命令示例 |
| 能力开关 | 11 组能力独立控制，**默认全关**；未开启的能力不出现在工具列表 / 路由中 |

> 变更端口 / 密钥 / 局域网 / 能力组会即时重启监听（幂等）。

---

## 2. 事件驱动与资源占用

- 传输层是 `dart:io` `HttpServer`（平台事件循环，epoll/kqueue），**空闲时不占用
  CPU**：没有收到请求就不会有回调，不存在轮询线程或定时拉取。
- 播放状态推送（WebSocket）**由状态变化事件触发**，不是客户端轮询；进度通知在
  推送路径上做时间节流（同一秒内合并），不额外起 Timer。
- 只有在用户开启总开关后才会绑定端口；关闭即释放监听与全部 WebSocket 连接。

因此本功能对常驻资源的影响可忽略；「不消耗资源」体现在**按需监听 + 事件驱动**，
而非常驻轮询。

---

## 3. 三种协议入口

全部为**标准格式**，不照搬任何第三方自定义封装：

| 入口 | 路径 | 协议 |
|---|---|---|
| MCP | `http://<host>:<port>/mcp` | Model Context Protocol（Streamable HTTP，JSON-RPC 2.0） |
| REST | `http://<host>:<port>/api` | HTTP + JSON（标准方法/状态码语义） |
| WebSocket | `ws://<host>:<port>/ws` | JSON-RPC 2.0（双向：请求-响应 + 服务端通知） |

`<host>` 默认 `127.0.0.1`；开启局域网访问后可用本机局域网 IP（设置页显示）。
鉴权：请求头 `X-Archoera-Key: <key>`，或 `Authorization: Bearer <key>`。
`/` 与 `/api/health` 免鉴权（仅返回无敏感信息的存活性/入口信息）。
`Origin` 校验拒绝非本机来源（DNS rebinding 防护）。

### 3.1 MCP

- 传输：Streamable HTTP。`POST /mcp` 发送 JSON-RPC 消息；响应
  `Content-Type: application/json`（不启用 SSE）。
- 握手：首个 `POST /mcp` 必须是 `initialize`；响应头返回 `Mcp-Session-Id`，
  之后所有请求携带该头。`GET /mcp` 返回 `405`（不提供 SSE 流）；
  `DELETE /mcp` 关闭会话。
- 版本协商：回显客户端请求的受支持版本，否则回退 `2025-11-25`；
  受支持集合见 `mcp_protocol.dart` 的 `kMcpSupportedVersions`。
  `MCP-Protocol-Version` 头不受支持时返回 `400`。
- 方法：`initialize`、`notifications/initialized`、`ping`、`tools/list`、
  `tools/call`、`resources/list`、`resources/read`、`prompts/list`。
- 资源：`archoera://now-playing`、`archoera://queue`、
  `archoera://library/summary`。
- 会话上限 8 个、空闲 30 分钟回收（有界内存）。

客户端配置示例（直接填写远程 URL 的客户端）：

```json
{
  "mcpServers": {
    "archoera-music": {
      "type": "http",
      "url": "http://127.0.0.1:14559/mcp",
      "headers": { "X-Archoera-Key": "<设置页显示的访问密钥>" }
    }
  }
}
```

调试：`npx @modelcontextprotocol/inspector` 选择 Streamable HTTP，填入上述 URL。

### 3.2 REST

响应：成功 `200` + JSON；错误为 `4xx/5xx` + `{"error":{"code","message"}}`。
`code` 取值：`invalid_argument`(400) / `not_found`(404) / `unsupported`(403) /
`unavailable`(503)。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/health` | 存活性（免鉴权） |
| GET | `/api/info` | 应用与服务的版本、端口、局域网标志、端点、已启用能力 |
| GET | `/api/status` | 播放状态 |
| GET | `/api/now-playing` | 当前曲目与进度 |
| GET | `/api/queue` | 播放队列与模式 |
| DELETE | `/api/queue` | 清空队列 |
| GET | `/api/preferences?keys=a,b` | 偏好只读（敏感键剔除） |
| GET | `/api/tools` | 已启用工具目录（JSON Schema） |
| POST | `/api/tools/{name}` | 通用调用（JSON 体即工具参数，覆盖全部工具） |
| GET | `/api/search?source=&q=&limit=&page=` | 在线搜索 |
| GET | `/api/library/search?q=&limit=&offset=` | 本地曲库搜索 |
| GET | `/api/library/random?limit=` | 本地随机抽曲 |
| GET | `/api/library/stats` | 本地曲库统计 |
| GET | `/api/player` | 播放状态（同 `/api/status`） |
| POST | `/api/player/play\|pause\|toggle\|stop\|next\|previous` | 播放控制 |
| POST | `/api/player/seek` | 体 `{ "positionMs": 0 }` |
| PUT | `/api/player/volume` | 体 `{ "volume": 0.5 }` |
| PUT | `/api/player/repeat` | 体 `{ "mode": "off\|list\|one" }` |
| PUT | `/api/player/shuffle` | 体 `{ "enabled": true }` |
| PUT | `/api/player/quality` | 体 `{ "quality": "hq" }` |
| POST | `/api/player/track` | 体 `{ "ref": "netease:123" }`（或 `track`/`source`+`id`） |
| POST | `/api/player/tracks` | 体 `{ "tracks": [...], "startIndex": 0 }` |
| POST | `/api/queue/play` | 体 `{ "index": 0 }` |
| POST | `/api/queue/add` | 体 `{ "tracks": [...], "position": "next\|end" }` |
| PUT | `/api/queue/tracks/move` | 体 `{ "from": 0, "to": 2 }` |
| DELETE | `/api/queue/tracks/{index}` | 移除队列项 |

其余工具（主题 / 收藏 / 历史 / 睡眠定时等）统一走 `POST /api/tools/{name}`。

### 3.3 WebSocket

连接后服务端推送 `server.hello`；客户端以 JSON-RPC 2.0 发送请求：

```json
{ "jsonrpc": "2.0", "id": 1, "method": "get_status", "params": {} }
```

服务端返回 `{"jsonrpc":"2.0","id":1,"result":{...}}`；服务端在播放状态变化时
主动推送通知（事件驱动）：

- `player.state`：播放/曲目/队列/模式等状态变化；
- `player.position`：进度（同一秒内合并节流）。

---

## 4. 工具（能力组 → 工具）

工具名同时作为 MCP 工具名、REST `/api/tools/{name}` 与 WebSocket 方法名。

| 能力组 | 工具 |
|---|---|
| `read` | `get_status`、`get_now_playing`、`get_queue`、`get_info`、`list_sources` |
| `playback` | `play`、`pause`、`toggle`、`stop`、`next_track`、`previous_track`、`seek`、`set_volume`、`set_repeat_mode`、`set_shuffle`、`set_quality`、`play_track`、`play_tracks`、`set_sleep_timer`、`cancel_sleep_timer` |
| `queue` | `queue_add`、`queue_play_index`、`queue_remove`、`queue_move`、`queue_clear` |
| `search` | `search_online`、`search_all` |
| `library` | `library_search`、`library_random`、`library_stats` |
| `preferences` | `get_preferences` |
| `appearance` | `set_theme_mode` |
| `collection` | `get_like_status`、`like_track`、`unlike_track`、`list_liked` |
| `history` | `history_list`、`history_clear` |
| `lyrics` | `get_lyrics` |
| `download` | `download_list`、`download_add`、`download_cancel`、`download_remove` |

**曲目引用**：搜索 / 曲库 / 历史结果都带稳定 `ref`（`source:id`），
`play_track` / `play_tracks` / `queue_add` / 收藏类工具优先用 `ref`
（服务端有界缓存命中），也接受完整 `track` 对象或 `source` + `id`。

---

## 5. 安全

- 默认仅绑定回环 `127.0.0.1`；局域网访问默认关，开启需弹窗确认且仍要求密钥。
- 默认要求访问密钥；密钥恒定时间比较，落盘于 `prefs.json`。
- `Origin` 校验（缺省允许 = 原生客户端；存在时仅允许 localhost/127.0.0.1/::1）。
- 能力组默认全关；关闭总开关即停止监听。
- 偏好只读接口剔除敏感键（含 key/secret/token/password/cookie/credential）。
- 不写系统目录、不注册服务、不请求提权。

> 与 `docs/architecture.md` §9「桌面端零 TCP 端口」的关系：本服务是对该原则的
> **显式可选例外**——默认不监听，只有用户主动开启后才有回环监听（可选手动放开
> 到局域网），且不改变播放链路的进程内 FFI 直连形态。

---

## 6. 命令行 `archoerashell`

随桌面端二进制内置一个命令行客户端，采用类 Unix 语法：

```bash
archoera_music archoerashell [全局选项] <命令> [参数...]
```

它**不启动 GUI**。三端均由 runner 在 Flutter 初始化之前拦截 `archoerashell` 子命令，
直接调用原生 Rust 入口（`app/core/shell`，`staticlib`）——**完全不加载 Flutter 引擎 /
Dart**，命令行调用即时返回：

- **Linux**：`app/linux/runner/main.cc` 检测子命令后调用 `archoera_shell_main`；由
  `app/linux/CMakeLists.txt` 的内嵌 cargo 目标编译 `libarchoera_shell.a` 链入。
- **Windows**：`app/windows/runner/main.cpp` 在 `wWinMain` 起始处检测子命令；runner
  CMake 编译并链入 `archoera_shell.lib`。GUI 子系统进程被终端调用时，由
  `app/core/shell/src/console.rs` 接管/补齐标准流、切 UTF-8 并开启 ANSI。
- **macOS**：`app/macos/Runner/main.swift` 在 `NSApplicationMain` 之前检测子命令；
  `Runner.xcodeproj` 的 “Build archoerashell (cargo)” 阶段编译并链入
  `libarchoera_shell.a`（`-liconv` 为 Rust std 的系统依赖）。

实现自包含：参数解析、回环 REST（`std::net`）、TUI 渲染；帮助文案由 `build.rs`
从 Flutter 的 ARB（`mcpShell*`）生成，与 Dart 端同源。（Dart 版
`app/lib/cli/mcp_shell.dart` 保留为参考与单测对象，不再参与桌面端运行时。）

三端都通过本机 MCP 服务的 REST 接口与**运行中的实例**通信——目标端口/密钥
取自应用设置（`prefs.json`），可用全局选项覆盖。

> **Windows 终端注意**：主程序是 GUI 子系统可执行文件，`cmd`/PowerShell 默认**不等待**
> 其退出，输出会送到同一控制台但可能晚于提示符返回。需要严格同步（脚本/管道）时用
> `start /wait archoera_music archoerashell …`；`stdout` 被重定向/管道时输出自动回退纯文本。

**交互式终端（REPL）**：`archoerashell` 后**不带命令**时，若 `stdin` 为交互式
终端则进入提示符模式，可连续输入命令（`exit`/`quit`/`Ctrl-D` 退出，空行忽略）；
若 `stdin` 被管道/重定向，则按行批处理（每行一条命令，`#` 开头为注释）。这与
双击/直接运行程序启动 GUI **不冲突**：GUI 启动路径的 argv 里没有 `archoerashell`。

```
全局选项:  -h/--help  -V/--version  -j/--json  -q/--quiet
           --host <host>  -p/--port <port>  -k/--key <key>
命令:      status / now-playing / play|pause|toggle|stop|next|prev
           seek <ms> / volume <0..1> / repeat <off|list|one> / shuffle <on|off>
           quality <lq|sq|hq|lossless|hi-res> / play-track <ref>
           queue [list|play <i>|add <ref>...|rm <i>|move <a> <b>|clear]
           search <source> <关键词> [-n 条数] [-p 页码]
           search-all <关键词> [-n 每源条数]
           library [关键词] [-n 条数] [--offset n] / library-random / library-stats
           like|unlike|like-status <ref> / list-liked <source> [-n 条数]
           history [-n] / history-clear / lyrics
           download [list|add <ref>... [--quality <档>]|cancel <id>|remove <id>]
           theme <light|dark|system> / sleep <分钟>|--end / sleep-cancel
           prefs [键...] / tools / info / call <工具> [--json '<参数对象>']
```

- 默认输出人类可读文本；`--json` 输出原始 JSON（便于脚本 `jq` 处理）。
- **输出风格自动探测**：`stdout` 为交互式终端且支持 ANSI 时启用 TUI 渲染
  （配色、圆角面板、进度条、对齐表格，风格贴近 OpenCode 等 Agent 终端）；
  被管道/重定向时自动回退纯文本，保证脚本解析与 `--json` 输出稳定
  （宽度按终端显示列计算，中文等宽字符同样对齐）。
- 退出码：`0` 成功 / `1` 运行期错误（连接失败、服务端错误）/ `2` 用法错误。
- 需要应用正在运行且已启用 MCP 服务；否则提示先开启。

示例：

```bash
archoera_music archoerashell status
archoera_music archoerashell search netease 周杰伦 -n 10
archoera_music archoerashell play-track netease:186016
archoera_music archoerashell --json library 周杰伦 | jq '.tracks[].title'
```

---

## 7. 实现说明

- 纯 Dart（`dart:io` `HttpServer` / `WebSocketTransformer`），无新增依赖，
  三平台一致；不调用任何平台 API，符合「系统调用统一走 C++ 桥接器」边界。
- 动作层 `McpActions` 是唯一事实源：MCP / REST / WebSocket 三入口共用同一
  工具目录与处理函数，避免协议实现漂移。
- 有界曲目缓存（默认 500 条，LRU）供跨请求的 `ref` 引用。
- 单测：`app/test/mcp_protocol_test.dart`（配置值语义、恒定时间比较、缓存、
  MCP 握手/会话/工具列举与调用、工具目录完整性）、
  `app/test/mcp_http_test.dart`（真实回环 HTTP：鉴权 / Origin / REST / MCP 往返）、
  `app/test/mcp_shell_test.dart`（CLI 命令解析、全局选项、REST/tool 映射与输出）。
- CLI 实现（Dart 回退）：`app/lib/cli/mcp_shell.dart`（纯 `dart:io`，可注入客户端便于单测）；
  TUI 版式独立在 `app/lib/cli/mcp_shell_render.dart`（CJK 感知宽度、面板/表格/进度条）；
  `app/lib/main.dart` 在 GUI 初始化前识别 `archoerashell` 子命令。
- CLI 实现（原生，三端）：`app/core/shell/`（Rust `staticlib`，`cargo test` 自测；
  `width.rs` 显示宽度、`render.rs` TUI、`http.rs` 回环 HTTP、`cli.rs` 解析/分派/REPL、
  `console.rs` Windows 控制台引导、`build.rs` 从 ARB 生成帮助文案）；Linux
  `app/linux/{runner/main.cc,CMakeLists.txt}`、Windows
  `app/windows/runner/{main.cpp,CMakeLists.txt}`、macOS
  `app/macos/Runner/{main.swift,Runner.xcodeproj}` 分别链入。
