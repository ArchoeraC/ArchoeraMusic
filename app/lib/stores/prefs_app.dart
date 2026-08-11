import 'app_prefs.dart';

// ── 应用级键（app. 前缀）──────────────────────────────────────
const closeBehaviorKey = 'app.closeBehavior';
const developerModeKey = 'app.developerMode';

/// 开发者组件开关键（会话级，默认全关）：
/// 「FPS/内存监控浮层」独立开关，跟随开发者模式，关闭应用后一并重置。
const devFpsMonitorKey = 'app.devFpsMonitor';

/// 关闭应用时行为（ask=每次询问 / background=后台播放 / quit=直接退出）。
const String defaultCloseBehavior = 'ask';

/// 应用级偏好：关闭行为与开发者模式。
extension AppLevelPrefs on AppPrefs {
  /// 关闭应用时行为（非法值回退默认）。
  String get closeBehavior {
    final v = data[closeBehaviorKey];
    if (v is String && (v == 'background' || v == 'quit')) return v;
    return defaultCloseBehavior;
  }

  /// 开发者模式（默认关）：隐藏的下载接口（侧边栏 / 右键菜单 /
  /// 设置-下载分类）仅在开启后显示。设置-关于内长按「版本」10 秒开启。
  /// **会话级开关**：不持久化，关闭应用后下次启动强制回到关闭状态
  /// （见 [AppPrefsNotifier.build]）。
  bool get developerMode => data[developerModeKey] as bool? ?? false;

  /// 设置「关闭应用时」行为（ask/background/quit）。
  AppPrefs copyWithCloseBehavior(String value) =>
      AppPrefs(initialData: {...data, closeBehaviorKey: value});

  AppPrefs copyWithDeveloperMode(bool value) =>
      AppPrefs(initialData: {...data, developerModeKey: value});

  /// 开发者「FPS/内存监控浮层」开关（默认关，见 [devFpsMonitorKey]）。
  bool get devFpsMonitor => data[devFpsMonitorKey] as bool? ?? false;

  AppPrefs copyWithDevFpsMonitor(bool value) =>
      AppPrefs(initialData: {...data, devFpsMonitorKey: value});
}
