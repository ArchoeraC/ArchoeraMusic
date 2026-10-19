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
