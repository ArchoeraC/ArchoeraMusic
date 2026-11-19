# 可插拔视觉样式：注册表与模块化

> 状态：已实现。播放页背景、封面切换、频谱、页面转场、侧栏导航、主题色来源、
> 外观风格、播放页布局均通过“契约 + 注册表 + 独立模块”接入；消费方只解析
> 偏好 id，不再维护 `switch (style)` 分支。

## 1. 统一模式

每个样式域由三部分组成：

| 部分 | 职责 |
| --- | --- |
| 契约 / Context | 只读快照 + `id` + `build`（或纯函数映射） |
| 注册表 | `const List<...>` 内建模块；id → 实例 Map；未知 id 回退默认项 |
| 模块 | 一个样式一个文件，迁移动画/渲染/映射参数 |

消费方（页面/组件）只做两件事：

1. 从偏好取字符串 id；
2. `xxxFor(id)` 查注册表并委托模块。

偏好白名单（`stores/prefs_*.dart`）仍负责持久化校验；设置页负责展示顺序与
本地化文案。注册表与白名单是两处声明，由对应守卫测试保证一致。

## 2. 注册表清单

| 样式域 | 契约 / 注册表 | 模块目录 | 偏好白名单 | 守卫测试 |
| --- | --- | --- | --- | --- |
| 播放页布局 | `pages/player/layouts/player_layout.dart` | `pages/player/layouts/` | `coverLayouts` | `player_layout_registry_test.dart` |
| 播放页背景 | `widgets/player/background/player_background_style.dart` + `..._registry.dart` | `widgets/player/background/styles/` | `playerBgTypes` | `player_background_registry_test.dart` |
| 封面切换 | `widgets/player/cover_transitions/cover_transition.dart` + `..._registry.dart` | `widgets/player/cover_transitions/transitions/` | `transitionStyles` | `cover_transition_registry_test.dart` |
| 频谱样式 | `widgets/player/spectrum_view/styles/spectrum_style.dart` + `..._registry.dart` | `widgets/player/spectrum_view/styles/` | `spectrumStyles` | `spectrum_style_registry_test.dart` |
| 页面转场 | `app/route_transitions/route_transition.dart` + `..._registry.dart` | `app/route_transitions/transitions/` | `routeTransitionIds` | `route_transition_registry_test.dart` |
| 侧栏导航 | `widgets/layout/side_bar/nav_styles/sidebar_nav_style.dart` + `..._registry.dart` | `widgets/layout/side_bar/nav_styles/` | `sidebarNavStyleIds` | `sidebar_nav_style_registry_test.dart` |
| 主题色来源 | `theme/theme_sources/theme_source_style.dart` + `..._registry.dart` | `theme/theme_sources/` | `themeSourceIds` | `theme_appearance_registry_test.dart` |
| 外观风格 | `app/appearance_styles/appearance_style.dart` + `..._registry.dart` | `app/appearance_styles/` | `appearanceStyleIds` | `theme_appearance_registry_test.dart` |

## 3. 新增一种样式

1. 在对应模块目录新建文件，实现契约；
2. 加进注册表的 `const List`；
3. 在对应偏好白名单与设置页登记同一个 id（需要新增文案时同步 ARB）；
4. 在守卫测试中确认注册表 id 与白名单一致；
5. 跑 `dart analyze lib` 与对应 `flutter test`。

## 4. 约定

- 模块不直接订阅播放位置/高频状态；需要的数据由 Context 一次性传入。
- 注册表返回 `const` 单例；未知 id 必须回退默认项，保证旧数据/降级安全。
- 动画参数、渲染常量从原实现逐项迁移，重构不得改变观感。
- 多个样式共用逻辑时提取 helper（如频谱波形、封面 out-in 状态机），但每个
  样式仍保留独立模块与稳定 id。
- 背景样式切换与封面 `fade` 共用 `widgets/common/cross_fade_switcher.dart`；
  系统关闭动画时统一直切。

## 5. 内容状态过渡（不是可配样式，不要新增注册表）

页面里「加载 / 错误 / 空态 / 内容」的切换、设置分类与搜索态切换、详情页首屏
都属于**状态机**过渡，没有用户可选样式，因此不放进上面的样式注册表，而是统一
复用同一个基元：`widgets/common/cross_fade_switcher.dart`。

- 用法：外层 `CrossFadeSwitcher(switchKey: 状态身份, child: 目标态)`；同一状态
  内的数据刷新不换 key，因此不会为每次刷新加淡入。
- 身份划分要**粗**：只区分状态（`loading` / `empty` / `list`…），不要把关键词、
  tab、滚动位置放进 key——搜索输入、切 tab 这类高频操作加动效只会拖慢手感。
- 时长固定 200ms / `Curves.ease`，内部经 `animDuration` 处理；性能模式
  （`MediaQuery.disableAnimations`）自动归零，调用方不要再包一层判断。
- 过渡期间两层同时挂载：离场层是 `IgnorePointer` + 排除语义；新层的 `State`
  会在过渡结束时**保留**（`CrossFadeSwitcher` 用稳定 key 做元素复用），所以
  列表滚动位置、输入焦点不会被重置。
- 两层同时挂载意味着同一份 `ScrollController` 可能被两个滚动视图同时 attach。
  需要滚动的内容要给每个状态身份各自持有一份 controller（设置弹窗即按相位
  分桶），不要在过渡内容里复用同一个 `ScrollController` 实例。

封面像素层的淡入不是「状态过渡」，走 `widgets/list/cover_image.dart` 的
`CoverArt` + `coverFrameFade`：只在**这张图自己的解码首帧**到达时做一次
180ms 淡入；图片由解码采样批量出帧，不要做排队/错峰延迟，缓存同步命中
（`wasSynchronouslyLoaded`）直接出图，滚动回看不重放。
