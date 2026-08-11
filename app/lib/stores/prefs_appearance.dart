import 'package:flutter/material.dart' show Color;

import 'app_prefs.dart';

// ── 外观域键（appearance. 前缀）────────────────────────────────
const accentKey = 'appearance.accent';
const themeSourceKey = 'appearance.themeSource';
const globalTintKey = 'appearance.globalTint';
const appearanceStyleKey = 'appearance.appearanceStyle';
const backgroundImageKey = 'appearance.backgroundImage';
const backgroundBlurKey = 'appearance.backgroundBlur';
const backgroundDimKey = 'appearance.backgroundDim';
const backgroundScaleKey = 'appearance.backgroundScale';
const routeTransitionKey = 'appearance.routeTransition';
const sidebarCollapsedKey = 'appearance.sidebarCollapsed';
const sidebarNavStyleKey = 'appearance.sidebarNavStyle';
const localeKey = 'appearance.locale';
const floatingBarKey = 'appearance.floatingPlayerBar';
const fontFamilyKey = 'appearance.fontFamily';
const coverRadiusKey = 'appearance.coverRadius';
const weatherEnabledKey = 'appearance.weatherEnabled';
const weatherAutoLocateKey = 'appearance.weatherAutoLocate';
const weatherCityKey = 'appearance.weatherCity';

/// 外观域偏好：主题色/背景/动效/侧边栏/语言/字体/封面圆角。
extension AppearancePrefs on AppPrefs {
  /// 自定义主色（ARGB 值）；null = 使用设计体系默认亮蓝。
  /// 对齐原版 appearance.themeSource=custom + customColor（hex）。
  int? get accent => data[accentKey] as int?;

  /// 主题色来源（对齐原版 appearance.themeSource）：
  /// - `default`：跟随系统主题色（读取系统 accent-color，失败回退默认亮蓝）；
  /// - `custom`：自定义主色（[accentColor]）；
  /// - `cover`：从当前播放曲目封面取色（实时跟随）；
  /// - `solid`：纯色中性色板（无主题色，主/次色用灰阶）。
  String get themeSource {
    final v = data[themeSourceKey];
    if (v == 'custom' || v == 'cover' || v == 'solid') return v as String;
    return 'default';
  }

  /// 全局着色（对齐原版 appearance.globalTint）：将主题色轻微应用到
  /// 全局界面（surface 家族向主色偏移），默认关。
  bool get globalTint => data[globalTintKey] as bool? ?? false;

  /// 外观风格（对齐原版 appearance.appearanceStyle）：
  /// `solid` 纯色背景 / `image` 自定义图片背景。
  String get appearanceStyle {
    final v = data[appearanceStyleKey];
    return v == 'image' ? 'image' : 'solid';
  }

  /// 背景图片路径（磁盘绝对路径；null = 未选择，对齐 imageBackground.src）。
  String? get backgroundImage => data[backgroundImageKey] as String?;

  /// 背景模糊（px，0~80，对齐 imageBackground.blur，默认 0）。
  int get backgroundBlur =>
      ((data[backgroundBlurKey] as num?)?.toInt() ?? 0).clamp(0, 80);

  /// 遮罩浓度（0.3~0.9，对齐 imageBackground.dim，默认 0.4）。
  double get backgroundDim =>
      ((data[backgroundDimKey] as num?)?.toDouble() ?? 0.4).clamp(0.3, 0.9);

  /// 背景图缩放（1~2，对齐 imageBackground.scale，默认 1.2）。
  double get backgroundScale =>
      ((data[backgroundScaleKey] as num?)?.toDouble() ?? 1.2).clamp(1, 2);

  /// 页面切换动效（对齐原版 appearance.routeTransition）：
  /// `none` 无 / `fade` 淡入淡出 / `slide` 滑动 / `zoom` 缩放。
  String get routeTransition {
    final v = data[routeTransitionKey];
    if (v == 'none' || v == 'slide' || v == 'zoom') return v as String;
    return 'fade';
  }

  /// 折叠侧边栏（对齐原版 appearance.sidebarCollapsed，默认关）。
  bool get sidebarCollapsed => data[sidebarCollapsedKey] as bool? ?? false;

  /// 侧边栏导航高亮动效（对齐原版 appearance.sidebarNavStyle）：
  /// `default` 静态指示条 / `animated` 滑动高亮条。
  String get sidebarNavStyle {
    final v = data[sidebarNavStyleKey];
    return v == 'animated' ? 'animated' : 'default';
  }

  /// 界面语言（BCP-47 字符串如 `zh-CN` / `en`；null = 跟随系统，默认）。
  /// 设置页「语言」选择，取值范围与 [AppLocalizations.supportedLocales] 对齐。
  String? get locale => data[localeKey] as String?;

  Color? get accentColor {
    final v = accent;
    return v == null ? null : Color(v);
  }

  /// 播放条悬浮模式（对齐原版 appearance.layoutMode=floating）：
  /// 开 = 底部居中圆角胶囊悬浮条（玻璃面板 + 阴影）；关 = 全宽停靠条。
  bool get floatingPlayerBar => data[floatingBarKey] as bool? ?? false;

  /// 界面字体（内置字体族名；默认 MiSans）。
  String get fontFamily => data[fontFamilyKey] as String? ?? 'MiSans';

  /// 封面圆角（px；0/8/12，对齐原版 CoverList 观感，默认 10）。
  double get coverRadius {
    final v = data[coverRadiusKey] as num?;
    if (v == null) return 10;
    return v.toDouble().clamp(0, 16);
  }

  /// 顶栏微型天气组件（默认关；关闭时不发起任何定位/天气请求，隐私优先）。
  bool get weatherEnabled => data[weatherEnabledKey] as bool? ?? false;

  /// 天气「自动定位」（按网络 IP 换取大致位置；默认关，隐私优先）。
  bool get weatherAutoLocate => data[weatherAutoLocateKey] as bool? ?? false;

  /// 手动城市名（非空时不进行 IP 定位；null = 未设置）。
  String? get weatherCity => data[weatherCityKey] as String?;

  /// 设置自定义主色（null = 恢复默认亮蓝，**移除**落盘的自定义值）。
  ///
  /// 不能用 `?accent` null-aware 元素：只「不写入」，旧键仍会经 `...data`
  /// 残留，导致切回默认后仍是旧自定义色（无法还原）。
  AppPrefs copyWithAccent(int? accent) {
    final d = Map<String, dynamic>.of(data);
    if (accent == null) {
      d.remove(accentKey);
    } else {
      d[accentKey] = accent;
    }
    return AppPrefs(initialData: d);
  }

  /// 设置主题色来源（非法值不写入，getter 回退默认 default）。
  AppPrefs copyWithThemeSource(String value) => AppPrefs(
    initialData: {
      ...data,
      if (value == 'default' ||
          value == 'custom' ||
          value == 'cover' ||
          value == 'solid')
        themeSourceKey: value,
    },
  );

  AppPrefs copyWithGlobalTint(bool value) =>
      AppPrefs(initialData: {...data, globalTintKey: value});

  /// 设置外观风格（solid / image；非法值不写入）。
  AppPrefs copyWithAppearanceStyle(String value) => AppPrefs(
    initialData: {
      ...data,
      if (value == 'solid' || value == 'image') appearanceStyleKey: value,
    },
  );

  /// 设置图片背景配置（选图 / 模糊 / 遮罩 / 缩放）。
  ///
  /// [image] 为 null 时**移除**已落盘的背景图路径（清除按钮）：不能像其他
  /// 字段用 null-aware 元素——旧键会经 `...data` 残留，导致清除后背景图
  /// 仍生效（与 copyWithAccent 相同的问题）。
  AppPrefs copyWithBackground({
    String? image,
    int? blur,
    double? dim,
    double? scale,
  }) {
    final d = Map<String, dynamic>.of(data);
    if (image == null) {
      d.remove(backgroundImageKey);
    } else {
      d[backgroundImageKey] = image;
    }
    return AppPrefs(
      initialData: {
        ...d,
        backgroundBlurKey: ?blur?.clamp(0, 80),
        backgroundDimKey: ?dim?.clamp(0.3, 0.9),
        backgroundScaleKey: ?scale?.clamp(1, 2),
      },
    );
  }

  /// 设置页面切换动效（none/fade/slide/zoom；非法值不写入）。
  AppPrefs copyWithRouteTransition(String value) => AppPrefs(
    initialData: {
      ...data,
      if (value == 'none' ||
          value == 'fade' ||
          value == 'slide' ||
          value == 'zoom')
        routeTransitionKey: value,
    },
  );

  /// 设置侧边栏（折叠状态 / 导航高亮动效）。
  AppPrefs copyWithSidebar({bool? collapsed, String? navStyle}) => AppPrefs(
    initialData: {
      ...data,
      sidebarCollapsedKey: ?collapsed,
      if (navStyle == 'default' || navStyle == 'animated')
        sidebarNavStyleKey: navStyle,
    },
  );

  /// 设置界面语言（null = 跟随系统；移除落盘值，避免残留旧语言）。
  AppPrefs copyWithLocale(String? code) {
    final d = Map<String, dynamic>.of(data);
    if (code == null) {
      d.remove(localeKey);
    } else {
      d[localeKey] = code;
    }
    return AppPrefs(initialData: d);
  }

  AppPrefs copyWithFloatingBar(bool value) =>
      AppPrefs(initialData: {...data, floatingBarKey: value});

  AppPrefs copyWithAppearance({String? fontFamily, double? coverRadius}) =>
      AppPrefs(
        initialData: {
          ...data,
          fontFamilyKey: ?fontFamily,
          coverRadiusKey: ?coverRadius?.clamp(0, 16),
        },
      );

  /// 设置顶栏微型天气配置（组件开关 / 自动定位 / 手动城市）。
  ///
  /// [city] 为 null 时**移除**已落盘的城市（清除手动城市，避免旧值经
  /// `...data` 残留——与 copyWithAccent 相同的问题）。
  AppPrefs copyWithWeather({bool? enabled, bool? autoLocate, String? city}) {
    final d = Map<String, dynamic>.of(data);
    if (city == null) {
      d.remove(weatherCityKey);
    } else {
      d[weatherCityKey] = city;
    }
    return AppPrefs(
      initialData: {
        ...d,
        weatherEnabledKey: ?enabled,
        weatherAutoLocateKey: ?autoLocate,
      },
    );
  }
}
