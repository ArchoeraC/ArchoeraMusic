# 首页「随机聚光」与每日推荐书架（Home Spotlight & Daily Shelf）

> 参考思路：SPlayer-Next 首页 hero 的「随机来源 + 随机起始曲」与 `Daily.vue`
> 的日推归档。本实现**仅借鉴交互目标，算法/命名/存储/文案均为自有**，与其
> 代码不逐字相同（见 §4 差异对照）。文件：
> `app/lib/services/spotlight/spotlight.dart`、
> `app/lib/services/daily/daily_shelf.dart`、
> `app/lib/stores/spotlight_provider.dart`、
> `app/lib/stores/daily_shelf_provider.dart`、
> `app/lib/widgets/home/spotlight_card.dart`。

## 1. 首页聚光（随机抽歌）

进入首页时从可用来源里抽一组歌，随机指定起始曲，展示封面 / 标题 / 预览，
可「立即播放（从起始曲）」或「换一批」。

### 1.1 来源与权重

| 来源 | 内容 | 基础权重 |
|---|---|---|
| 每日推荐 `daily` | 登录后今日日推（取书架） | 5 |
| 我的收藏 `liked` | 已加载的 NT/KG/QM「我喜欢」内存列表 | 3 |
| 本地曲库 `local` | `TracksDb.randomTracks(60)` 随机抽样 | 2 |

- **加权随机**选取来源（个性化来源优先）；上一轮来源权重按
  `kSpotlightSourceCooldownPercent`（30%）冷却，降低连中概率但不归零。
- 空来源不参与；全部为空 → 展示登录提示 / 空态。

### 1.2 可复现的随机（本实现的关键差异）

随机种子由 **逻辑日 + 重掷次数** 经 FNV-1a 派生（`spotlightSeed`），用自有的
32 位 xorshift（`SpotlightRng`）取样。这样可以：

- 同一逻辑日、同一重掷次数下选择稳定——**高频 rebuild 不会每次都换歌**；
- 重启后当日回到「默认那一抽」（重掷次数归零）；
- 点「换一批」递增重掷次数，得到**不同**且同样可复现的一抽。

> 参考实现用 `Math.random()`，每次进入都重掷且无种子；Vue 只加载一次，问题
> 不明显，但移植到频繁 rebuild 的 Flutter 会出现卡片闪烁。

### 1.3 起始曲避让

保留最近 `kSpotlightLeadMemory`（4）个起始曲 key（`source:id`），抽样时最多
重试 `kSpotlightLeadAttempts`（6）次避开；池子太小则接受随机结果。预览从起始
曲起回绕展示 3 首（窄屏隐藏）。

## 2. 每日推荐书架

### 2.1 逻辑日

以 `kDailyRolloverHour = 5` 为界（与首页「凌晨<5 点算深夜」一致）：凌晨未睡仍
算前一天，`dailyShelfDayKey` 输出 `yyyy-MM-dd`。

### 2.2 存储

JSON 文件 `daily_shelf.json`（覆盖式，失败静默）：

```
{ "v": 1, "users": { "<uid>": [ { "key": "2026-09-30", "savedAt": …, "tracks": [ … ] } ] } }
```

- **账号隔离**：按 `NeteaseAccount.userId` 分档，切号读对应档，避免串数据；
- **容量**：每账号 `kDailyShelfCap = 21` 天（今日在前），超出截断；
- 单曲损坏跳过，整档损坏回退空。

### 2.3 控制器与 UI

- `dailyShelfProvider`（`DailyShelfNotifier`）：未登录空态；登录后命中文档直接
  返回，否则拉取 `recommendSongs()` 落盘；`refresh()` 强制刷新。并发去重。
- 首页聚光的 `daily` 来源与「每日推荐」弹窗共用该书架：弹窗
  `showDailyRecommendDialog` 走同一缓存，并在头部提供「刷新」按钮
  （`TrackListDialog.onRefresh`）触发 `refresh()`。

## 3. 本地随机抽样（`TracksDb.randomTracks`）

- 中小曲库（≤4000）用 `ORDER BY RANDOM() LIMIT` 一次取样；
- 大曲库改用**随机 offset 采样**（按 `title` 稳定序、去重、带上限重试），避免
  整表随机排序的开销。

## 4. 与参考实现的差异对照（确认非照搬）

| 维度 | 参考实现 | 本实现 |
|---|---|---|
| 随机源 | `Math.random()`，每次进入重掷 | 逻辑日＋重掷次数派生种子，可复现 |
| 来源选择 | 从随机起点**轮转**兜底 | **加权随机** + 上一轮来源冷却 |
| 起始曲 | 纯随机 | 随机 + **最近起始曲避让**（记忆 4） |
| 换一批 | 无（仅进入时随机） | 有（重掷计数，避开上轮来源） |
| 日推逻辑日 | 6:00 | 5:00（与全站问候一致） |
| 日推存储 | IndexedDB，14 天 | JSON 文件，21 天 |
| 日推刷新 | 页面「更多」菜单 | 弹窗头部「刷新」按钮 |
| 本地随机 | `ORDER BY RANDOM()` | 大库随机 offset 采样 |
| 命名 / 文案 / UI | Hero/Tag/预览列表 | 聚光/可点击预览列，自有文案 |

## 5. 测试

- `test/spotlight_test.dart`：RNG 可复现、种子随重掷变化、空池/单池、来源可用
  性、`preview` 回绕、起始曲记忆去重与截断；
- `test/daily_shelf_test.dart`：逻辑日边界、写入/读取/同日覆盖、账号隔离、
  容量截断、空曲目与损坏文件、JSON 往返；
- `test/spotlight_card_test.dart`：卡片挂载与窄屏渲染不抛异常。

## 6. 后续可选项

- 「聚光」开关偏好（`spotlight.enabled`）与来源权重自定义；
- 日推弹窗的「历史日期」下拉（书架已存 21 天，UI 未做）；
- 收藏来源在首页后台预热 `ensureLoaded`，提高其被抽中的频率。
