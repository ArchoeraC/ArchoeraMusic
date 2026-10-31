# NekoMusic 音源请求方案（客户端身份与放行）

本文记录 ArchoeraMusic 与 NekoMusic 服务端通信时的**身份与放行**方案，对应实现：
`app/lib/services/neko/neko_identity.dart`、
`app/lib/services/neko/neko_instance_identity.dart`、
`app/lib/apis/neko/neko_client.dart`、`app/core/audio-engine/src/decoder.c`。

## 背景

NekoMusic 服务端与「谁在请求」相关的约束：

1. **防爬 / 客户端区分**（`CrawlerProtectionFilter`）
   - 空 / 缺失 `User-Agent` 一律按爬虫处理（`GET` 直出 SEO HTML，其它方法 `403`）；
     旧版「空 UA 直接放行」的旁路已拆除。
   - 官方原生客户端 UA 为**整体锚定**的 `NekoMusic-<平台>/<版本>`
     （平台限 `android|pc|ios|macos|windows|linux|qt`，版本以数字开头）。
   - 未知 UA 会被降级为 SEO HTML；第三方客户端可通过服务端
     `network.allow_client_user_agents` 登记。
2. **请求防重放**（`ReplayProtectionFilter`）：全部动态接口需一次性
   `X-Neko-Nonce`，缺失 / 重放返回 `409`。
3. **客户端实例身份**（`ClientIdentityFilter`）：动态接口还需实例令牌与每请求
   ECDSA 签名（见下节「客户端实例身份」），否则 `401`。

我们既不是官方客户端，也不冒名 Android，也不做浏览器伪装（反爬对抗）。

## 方案：官方锚定 PC UA 形状 + `X-Neko-Client` + 实例身份

所有 Neko 出站请求（REST / SSE / 音频下载 / 引擎 AVIO / 原生 HTTP）带：

```
User-Agent: NekoMusic-PC/<版本>   # 官方锚定的 PC 形状（版本以数字开头）
X-Neko-Client: pc+<版本>          # 平台须与 client_id 登记平台一致
```

早期版本曾保留一条「主路径」：以 `ArchoeraMusic/<版本> (<平台>)` 本体自报。**实测服务端
不认该自报 UA**——换题等动态接口会返回 SEO HTML，导致拿不到 nonce、所有受保护请求持续
`409`。因此该主路径已**移除**：只保留官方锚定的 PC UA **形状**（版本以数字开头；读取失败
回退 `0`）。

复用官方 UA 形状只为通过 `isNativeClient` 锚定正则；真实来源仍由实例身份在服务端登记
（访问日志按 `client_id` + `instance_id` 记录），不带 Android 平台标识、不补浏览器特征头、
不参与反爬对抗。

> **合规说明（SEC-20）**：本项目**不再复用官方客户端的公开标识**。`client_id` 由
> NekoMusic 后台按第三方登记流程签发（public client，平台 `pc`，归属 ArchoeraC），
> 每个安装实例另持自有 EC P-256 私钥与实例 ID，服务端可逐实例审计与吊销。
> `User-Agent` / `X-Neko-Client` 使用的是服务端对**原生客户端**约定的格式
> （`NekoMusic-<平台>/<版本>`、`<平台>+<版本>`），不是冒充官方品牌；服务端访问日志
> 按 `client_id` + `instance_id` 区分来源。详见
> [security-review-2026-10-11.md](security-review-2026-10-11.md) SEC-20。

### 站点图片（封面 / 头像）

图片经全局 `HttpClient`（浏览器 UA）发起，`Image.network` 以 `add` 语义追加
请求头、无法覆盖 UA，故图片侧无法改用 PC UA，只补标识头与浏览器特征头：

```
X-Neko-Client: pc+<版本>
Accept: image/*
Accept-Language: zh-CN,zh;q=0.9,en;q=0.8
```

图片路径在防爬 / 防重放 / 身份三张豁免清单内，新服务端靠 `X-Neko-Client` 放行，
现存服务端靠浏览器完整性放行。

### 防重放（领取必须先换题）

服务端自「领取 nonce 必须携带挑战」起，`GET /api/replay/nonce` 不再接受裸领取。
`NekoClient` 的 nonce 池按站点走**两步领取**（对齐官方 PC 端 `ReplayNonceStore`）：

1. `GET /api/replay/challenge?read=16&write=16` 换题，读 `challenge` / `seed` /
   `difficulty` / `algorithm`；
2. 比对 `algorithm == "sha256-leading-zero-bits"`（不认识就不盲解，放弃本轮），
   在**后台 isolate**（`nekoSolveProof`，见 `apis/neko/neko_replay.dart`）找一个
   十进制计数器，使 `SHA-256(seed + ":" + counter)` 的前导零比特数 ≥ `difficulty`，
   取其十进制串作 `proof`；
3. `GET /api/replay/nonce?challenge=&proof=` 兑换读 / 写两类 nonce。

兑换被拒（`400` / `409`，服务端不区分原因）时换新题重解一次；限额 `429` / 服务不可用
`503` 时本轮打住（不紧循环撞限额），交给下次补领。批量预取、用后即弃，本地 90s 提前
作废；消费 `409`（`X-Neko-Replay-Status: missing|invalid`）时清池、换新 nonce 重试一次。

为兼容尚未提供挑战接口的旧服务端，换题返回 `404` 时回退为不带挑战的 `read` / `write`
直接领取。挑战解题是 `2^difficulty` 量级的哈希计算，放在后台 isolate，不阻塞 UI；
`nekoSolveProofSync` / `nekoMeetsDifficulty` 为纯函数，便于单测。

**本地加速（不改协议、不改 proof 形态，纯 Dart）**：

- **前缀哈希**（`apis/neko/neko_pow_sha256.dart`）：`seed + ":"` 是固定前缀，其完整
  64 字节块只压缩一次（midstate）；逐候选只压「前缀尾部 + 计数器 + pad + 长度」
  （≤ 2 块），全程零分配（计数器用十进制进位维护，不 `toString`、不建消息 / 摘要对象）。
- **多 isolate 并行 + 设备能力负反馈自适应**（`neko_pow_tuning.dart`）：按
  `counter ≡ i (mod N)` 切分候选空间（各 worker 互不重叠、合起来覆盖全部自然数），
  先解出者胜并 `kill` 其余 worker。并发数由**真实解题样本**闭环控制：
  - 初始 `min(核数 - 1, 16)`；在最高档时先向下探一次（建立对照），之后不再反复向下探；
  - 每次解题由**胜出 worker** 回报「试了多少候选 / 自身耗时」，折算该档**聚合吞吐**
    （per-worker 速率 × 并发），EMA 上升快抓、下降慢判；
  - **负反馈**：当前档 EMA 掉到最佳档的 75% 以下 → **立即**切到最佳档（不等周期）；
  - **升档二次确认**：单次探测「看起来更快」不直接采纳，先切过去**试用 2 次**，
    试用平均吞吐仍高出升档前档位 10% 才正式采纳；否则回退并惩罚该档；
  - **门槛递增**：每连续成功升一档，下一次升档要求抬高 10%（上限 1.5）——
    越接近峰值边际收益越小、断崖风险越大（P 核→E 核、功耗墙），涨得不够就不爬；
  - **门槛惩罚（无冷却、无拉黑）**：某档位**被负反馈降过 2 次**（升上去也撑不住，
    典型是峰值后的断崖：P 核→E 核 / 功耗墙）→ 之后**升回该档的门槛提高 50%**
    （15% → 22.5%）。探针仍每 8 次解题保留（用于感知设备更换 / 散热恢复），
    只是采纳难度更高；不存在「冷却期里不能试」这类时间锁；
  - **升档永久保留**：只要设备真的变快（换机 / 插电 / 降温），涨得足够多就能再爬回去；
  - **最优档位持久化**：把「已测最优档 + 设备指纹（核数 / OS）」写入
    `<数据目录>/neko_pow_workers.json`（安全读 + 原子写），下次启动**从该档位开始**
    跑负反馈 / 升档；**惩罚与降档历史不落盘**（每次启动都干净）。指纹不符
    （换机 / 虚拟机改配额）视为无缓存，按启发式重新收敛；
  - 判据必须是聚合吞吐：并发越低争用越少、单 worker 速率天然更高，只比单 worker
    会一路降到 1；
  - 难度低于 16 bit 不 spawn（`2^16` 次哈希在单核是毫秒级，spawn 不划算）。
- 语义不变：服务端只验一次哈希，**任何达标计数器都是合法 proof**。同步路径仍从 0
  起逐个试（与官方实现一致、返回最小解）；并行路径可能返回更大的计数器，同样有效。

实测（32 核、AOT、`tool/neko_pow_bench.dart`）：单核哈希吞吐 525 ns/次 → 428 ns/次；
`difficulty=16` 55 ms → 8.6 ms（6.4×）、`difficulty=18` 162 ms → 15.5 ms（10.4×）、
`difficulty=20` 247 ms → 28 ms（8.7×）、`difficulty=22` 255 ms → 28 ms（9.1×）。
控制器在健康机器上保持最高档（每 8 次解题多花一次向下探/向上探的采样成本），在
配额受限 / 降频的机器上会自动降档，并在能力恢复后爬回。

换题 / 兑换本身也是动态接口，同样经防爬过滤器，与业务请求共用同一套身份头。

## 客户端实例身份（`neko-client-v1`）

服务端在防爬之后、防重放之前新增 `ClientIdentityFilter`：除自举接口（`/api/client/*`、
`/api/replay/*`、图片前缀等，与防重放豁免一致）外，动态请求必须携带**实例身份**，
否则 `401 + X-Neko-Client-Status: invalid`。实现见
`app/lib/services/neko/neko_instance_identity.dart`。

- **应用标识**：使用**本项目自己的** `client_id`（NekoMusic 后台按 public client
  签发，平台 `pc`，归属 ArchoeraC），构建期通过 `--dart-define=NEKO_CLIENT_ID=…`
  注入（见 `app/lib/apis/neko/neko_client_config.dart`）。**未注入即禁用本源**
  （fail-closed：不注册实例、不发请求、搜索 / 我喜欢 / 收藏的源列表里也不出现）。
  `X-Neko-Client` 必须写成 `pc+<版本>`——服务端要求自报平台、令牌平台、client_id
  登记平台三者一致，因此 UA 使用服务端约定的原生客户端形状 `NekoMusic-PC/<版本>`。
- **每安装实例密钥**：首次使用时在本地生成 EC P-256 私钥（公钥导出 SPKI DER，
  base64url 提交），实例 ID 为 UUID v4；私钥只落本机
  `<数据目录>/neko_client_identity.json`（原生 `apl_file_write_atomic`，0600 原子写），
  不出现在请求体、URL 或日志里。`client_id` 本身是公开标识，单独泄露无法伪造请求。
- **注册 / 续签**：先 `GET /api/client/challenge?client_id=&platform=&purpose=` 取
  一次性挑战（绑定 IP 与 UA，5 分钟有效），再用私钥对
  `neko-client-register-v1\n…` / `neko-client-token-v1\n…` 做 `SHA256withECDSA`
  （DER 签名，base64url 无填充）换取 `{instance_id, token, expires_at}`。令牌剩余
  寿命不足 24h 即续签；续签失败但旧令牌仍有 5 分钟以上时先用旧令牌兜底。
- **每请求签名**：
  `neko-client-v1\n方法\n路径\n查询串\nclient_id\ninstance_id\n平台\nUnix 秒\n
  请求体 SHA-256(hex)\nnonce`，随请求附带
  `X-Neko-Client-{Id,Instance,Token,Timestamp,Signature}`。时间戳窗口为 ±300s，
  查询串按**实际发送的原始编码**参与签名，路径按服务端路由的解码后形式。
- **失效恢复**：`401 + X-Neko-Client-Status: invalid` → 作废本地令牌，续签（被拒则
  重新注册，注册仍被拒则轮换密钥）后自动重试一次。
- **熔断**：连续 3 次被服务端判定身份无效（client_id 停用 / 授权过期 / 公钥被拒）→
  停止重注册并标记本源不可用，避免对着服务端反复注册；设置页与错误文案给出原因。
- **旧服务端降级**：挑战接口返回 `404` / `405` 视为该站点未启用身份校验，
  后续请求不再尝试身份头，保持与旧版服务端兼容。

## 不变量

- `User-Agent` 始终非空，且为官方锚定 PC 形状 `NekoMusic-PC/<版本>`。
- `X-Neko-Client` 始终为 `pc+<版本>`，与实例身份的平台一致。
- 每个安装实例持有独立私钥与实例 ID，服务端可单独审计 / 吊销；不共享他人凭据。
- 不带 Android 平台标识，不做浏览器 UA / 特征头伪装。
- 服务端若仍把该请求降级为 SEO HTML，`NekoClient` 明确抛错，绝不把 SEO HTML 当作业务成功。
